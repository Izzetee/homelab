#!/usr/bin/env python3
"""Offline self-test of the backup producers and their hook mode (apps/_backup-hook, source only at this stage).

Render part: the source-only components, no hook object or grant renders, eight restore check CronJobs with a deny-only policy each, the
CronJob itself renders exactly as its file, the producer script has the hook mode and takes the claim lock before its first write, the bounds
and names hold.

Runtime part: the rendered scripts run against synthetic data in a temporary directory with stub tools (container paths are rewritten into
the temporary directory). The hook mode is the same script run with a pod name that contains -presync- (the pod template is the CronJob's). The
lock is a real operating-system file lock (fcntl.flock on one file for every mode, from separate processes): simultaneous scheduled, manual and
hook-mode runs, a hook-mode run started while a manual run is in flight, wait and give-up, window edges and the re-check after a wait, pruning of
both kinds of set, failure propagation, same-stamp and leftover collisions, lock path types.

Usage: selftest.py [--only <cronjob name>]   (--only limits the runtime part to one producer)
Needs: kustomize, yq, python3, dash, bash. No cluster, no container runtime, no network.
"""
import fcntl
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
# dir, cron name, family, set prefix ("" = bare stamp), kind of set, has the manual before/after membership check
APPS = [
    ("apps/tools/affine", "affine-pg-dump", "shell", "affine", "dump", True),
    ("apps/tools/juraticker", "juraticker-pg-dump", "shell", "juraticker", "dump", True),
    ("apps/identity/authentik-db", "authentik-pg-dump", "shell", "authentik", "dump", False),
    ("apps/tools/penpot", "penpot-pg-dump", "shell", "penpot", "penpot", False),
    ("apps/tools/wiki", "wiki-pg-dump", "shell", "", "wiki", True),
    ("apps/tools/n8n", "n8n-backup", "python", "n8n", "files", True),
    ("apps/tools/uptime-kuma", "uptime-kuma-backup", "python", "uptimekuma", "files", True),
    ("apps/tools/open-webui", "open-webui-backup", "python", "open-webui", "files", True),
]
SHELLS = {"/bin/sh": shutil.which("dash") or "/bin/sh", "/bin/bash": shutil.which("bash")}
LOCK = ".partial-lock"
HOOKDIR = ".presync"
fails = 0


def wr(path, text):
    with open(path, "w") as f:
        f.write(text)


def rd(path):
    with open(path) as f:
        return f.read()


def ok(msg):
    print("ok   " + msg)


def bad(msg):
    global fails
    fails += 1
    print("FAIL " + msg)


def check(cond, msg):
    (ok if cond else bad)(msg)


def build(path):
    out = subprocess.run(["kustomize", "build", os.path.join(ROOT, path)], check=True, capture_output=True, text=True).stdout
    js = subprocess.run(["yq", "-o=json", "-I=0", "."], input=out, check=True, capture_output=True, text=True).stdout
    return [json.loads(line) for line in js.splitlines() if line.strip()], out


def hook_and_cron(path):
    docs, _ = build(path)
    crons = [d for d in docs if d["kind"] == "CronJob" and d["metadata"].get("labels", {}).get("homelab.io/backup") == "true"]
    hooks = [d for d in docs if d["kind"] == "Job"]
    return crons, hooks


def source_cron(path, name):
    for f in sorted(os.listdir(os.path.join(ROOT, path))):
        if f.endswith(".yaml") and f != "kustomization.yaml":
            js = subprocess.run(["yq", "-o=json", "-I=0", "."], input=rd(os.path.join(ROOT, path, f)), capture_output=True, text=True, check=False).stdout
            for line in js.splitlines():
                d = json.loads(line) if line.strip() else {}
                if d.get("kind") == "CronJob" and d["metadata"]["name"] == name:
                    return d
    raise SystemExit("source of " + name + " not found")


def script_of(cron):
    return cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]["args"][0]


def normalised_prelude(script, family, deadline):
    """The shared head of a producer script (mode, window guard, lock, hook directory), its own deadline made neutral."""
    if family == "shell":
        a = script.index("umask 077\n")
        b = script.index("stamp=$(date -u +%Y%m%dT%H%M%SZ)\n")
    else:
        a = script.index("os.umask(0o077)\n")
        b = script.index('base = f"{NAME}-')
    head = script[a:b]
    for token in (f"({deadline}s)", f"+ {deadline} + 300"):
        head = head.replace(token, token.replace(str(deadline), "D"))
    return head


# ---------------------------------------------------------------- render part
def render_checks():
    base = os.path.join(ROOT, "apps/_backup-hook")
    check(sorted(os.listdir(base)) == ["README.md", "affine", "single"], "components: single and affine only (source-only, nothing else under the directory)")
    for d in ("affine", "single"):
        check(sorted(os.listdir(base + "/" + d)) == ["kustomization.yml", "source.yaml"], f"component {d}: source and replacements only, no Job, no policy, no resource of its own")
    check(rd(base + "/affine/source.yaml") == rd(base + "/single/source.yaml"), "components: affine source.yaml equals single")
    named = rd(base + "/affine/kustomization.yml").replace("      name: affine-pg-dump\n", "")
    check(named == rd(base + "/single/kustomization.yml"), "components: affine replacements equal single's apart from the named source")
    check("config.kubernetes.io/local-config" in rd(base + "/single/source.yaml") and "kind: Job" not in rd(base + "/single/kustomization.yml"), "components: the source is local config, no Job is targeted")
    heads = {"shell": set(), "python": set()}
    hooks_total = restore_total = 0
    for path, cname, family, *_rest in APPS:
        docs, _ = build(path)
        crons = [d for d in docs if d["kind"] == "CronJob" and d["metadata"].get("labels", {}).get("homelab.io/backup") == "true"]
        rcs = [d for d in docs if d["kind"] == "CronJob" and d["metadata"].get("labels", {}).get("homelab.io/restore-check") == "true"]
        hooks = [d for d in docs if d["kind"] == "Job" or d.get("metadata", {}).get("labels", {}).get("homelab.io/backup-hook")]
        tag = cname
        check(len(crons) == 1, f"{tag}: one backup CronJob")
        cron = crons[0]
        hooks_total += len(hooks)
        restore_total += len(rcs)
        check(not hooks and not any(d["kind"] in ("BackupHookSource", "ServiceAccount", "Role", "RoleBinding", "ValidatingAdmissionPolicy") for d in docs), f"{tag}: no hook Job, no local-config object and no API grant renders")
        check(len(rcs) == 1 and rcs[0]["metadata"]["name"] == cname + "-restore-check" and rcs[0]["metadata"]["namespace"] == cron["metadata"]["namespace"], f"{tag}: one restore check CronJob named after the backup, in its namespace")
        crn = [d for d in docs if d["kind"] == "CiliumNetworkPolicy" and d["metadata"]["name"] == "restore-check"]
        check(len(crn) == 1 and "egress" not in crn[0]["spec"] and "ingress" not in crn[0]["spec"] and crn[0]["spec"]["ingressDeny"] == [{"fromEntities": ["all"]}] and crn[0]["spec"]["egressDeny"] == [{"toEntities": ["all"]}], f"{tag}: the restore check policy only denies")
        check(cron == source_cron(path, cname), f"{tag}: the CronJob renders exactly as its file (manual copies stay exact)")
        cs = cron["spec"]["jobTemplate"]["spec"]
        d = cs["activeDeadlineSeconds"]
        check(d <= 3600, f"{tag}: CronJob deadline {d}s")
        check("-presync-" in script_of(cron), f"{tag}: the producer script has the hook mode (pod name contains -presync-)")
        pod = cs["template"]["spec"]
        main = pod["containers"][0]
        check("initContainers" not in pod and len(pod["containers"]) == 1, f"{tag}: one container, no init container")
        mounts = [m for m in main["volumeMounts"] if m["name"] == "backup"]
        check(mounts == [{"name": "backup", "mountPath": "/backup"}], f"{tag}: the claim root is mounted at /backup, no sub-path")
        res = main["resources"]
        check(set(res["requests"]) == {"cpu", "memory"} and set(res["limits"]) == {"memory"}, f"{tag}: the CronJob container: cpu and memory requests, a memory limit only")
        check(len(cname) + len("-manual-202501011200-abcde") < 63, f"{tag}: manual pod host name stays below the 63 character limit")
        check(len(cname) + len("-presync-run-abcde") < 63, f"{tag}: hook-mode pod host name stays below the 63 character limit")
        # producer script: lock before the first write; the shared head; the deadline in the guard is the CronJob's
        script = script_of(cron)
        lock_at = script.index(".partial-lock")
        before = "".join(line for line in script[:lock_at].splitlines(True) if not line.startswith("import "))
        verbs = ("pg_dump", "mkdir", "ls -1", "rm ", "tar", "makedirs", "listdir", "sqlite3.connect", "termination-log", "sha256", "gzip")
        check(not any(v in before for v in verbs) and "stamp" not in before and "base = " not in before, f"{tag}: nothing is written, listed or created before the lock")
        check(script.count(".partial-lock") == 1 and "flock" in script, f"{tag}: one lock on the claim root")
        check(f"({d}s)" in script and f"+ {d} + 300" in script, f"{tag}: window guard uses the CronJob's deadline ({d}s)")
        heads[family].add(normalised_prelude(script, family, d))
        check(script.count("hook_window") >= 3, f"{tag}: window guard before and after the lock")
        check(("mode == \"manual\"" in script) if family == "python" else ('[ "$mode" = manual ]' in script or "manual) ;;" in script), f"{tag}: manual mode branch present")
    for family, found in heads.items():
        check(len(found) == 1, f"{family} producers: one shared head (lock, mode, guard, hook directory), no variant")
    check(hooks_total == 0, f"hook objects rendered over the eight applications: {hooks_total} (this stage installs the producers and the restore checks only)")
    check(restore_total == 8, f"restore check CronJobs rendered over the eight applications: {restore_total}")
    check(not os.path.exists(os.path.join(base, "dispatcher")) and not os.path.exists(os.path.join(ROOT, "apps/identity/authentik/presync-hook.yaml")), "no hook directory of another kind and no second Authentik hook")


# ---------------------------------------------------------------- runtime part
STUBS = {
    # the clock of the guard, from a file the test can change while a run waits
    "date": """#!/bin/sh
if [ -n "${FAKE_NOW_FILE:-}" ] && [ "$*" = "-u +%s" ]; then cat "$FAKE_NOW_FILE"; exit 0; fi
if [ -n "${FAKE_STAMP:-}" ] && [ "$*" = "-u +%Y%m%dT%H%M%SZ" ]; then echo "$FAKE_STAMP"; exit 0; fi
exec /bin/date "$@"
""",
    "sha256sum": '#!/bin/sh\n[ -z "${FAIL_SHA:-}" ] || exit 1\nexec shasum -a 256 "$@"\n',
    "grep": '#!/bin/sh\n[ -z "${FAIL_GREP:-}" ] || exit 2\nexec /usr/bin/grep "$@"\n',
    # flock(1) semantics (-w seconds, file descriptor number last) on the real kernel lock of the inherited descriptor
    "flock": """#!/usr/bin/env python3
import fcntl, sys, time
a = sys.argv[1:]
wait = float(a[a.index("-w") + 1]) if "-w" in a else 0.0
fd = int(a[-1])
end = time.monotonic() + wait
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.exit(0)
    except BlockingIOError:
        if time.monotonic() >= end:
            sys.exit(1)
        time.sleep(0.02)
""",
    "pg_dump": """#!/bin/sh
[ -z "${FAIL_DUMP:-}" ] || { echo "stub pg_dump failed" >&2; exit 1; }
[ -z "${CONCLOG:-}" ] || echo "S $$" >>"$CONCLOG"
[ -z "${INTRUDE:-}" ] || : >"$INTRUDE"
[ -z "${SLOW:-}" ] || sleep "$SLOW"
[ -z "${CONCLOG:-}" ] || echo "E $$" >>"$CONCLOG"
while [ $# -gt 0 ]; do [ "$1" = -f ] && { echo "synthetic dump" >"$2"; exit 0; }; shift; done
""",
    "mktemp": '#!/bin/sh\nexec /usr/bin/mktemp "${TMPDIR:?}/tmp.XXXXXXXXXX"\n',
    "psql": '#!/bin/sh\n[ -z "${FAIL_PSQL:-}" ] || exit 1\necho 3\n',
}
# python family: where the shell family's pg_dump stub does its slow, logged, intruding step
PY_STEP = """import os as _o
if _o.environ.get("CONCLOG"):
    open(_o.environ["CONCLOG"], "a").write(f"S {_o.getpid()}\\n")
if _o.environ.get("INTRUDE"):
    open(_o.environ["INTRUDE"], "w").close()
time.sleep(float(_o.environ.get("SLOW") or 0))
if _o.environ.get("CONCLOG"):
    open(_o.environ["CONCLOG"], "a").write(f"E {_o.getpid()}\\n")
"""
HOLD = """import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
print("held", flush=True)
time.sleep(float(sys.argv[2]))
"""


def mkstubs(d):
    os.makedirs(d)
    for n, t in STUBS.items():
        p = os.path.join(d, n)
        wr(p, t)
        os.chmod(p, 0o700)


def set_files(prefix, kind, stamp):
    b = f"{prefix}-{stamp}" if prefix else stamp
    if kind == "dump":
        return [b + ".dump", b + ".dump.sha256"]
    if kind == "penpot":
        return [b + ".dump", b + ".dump.sha256", b + ".count", b + ".objects"]
    if kind == "wiki":
        return [b + ".dump", b + ".dump.sha256", b + ".count", b + ".files.sha256"]
    return [f"{b}.{e}" for e in ("db.gz", "tar.gz", "db.gz.sha256", "tar.gz.sha256")]


def mkdb(path):
    c = sqlite3.connect(path)
    c.execute("create table t (x integer)")
    c.execute("insert into t values (1)")
    c.commit()
    c.close()


class App:
    def __init__(self, row):
        self.path, self.cname, self.family, self.prefix, self.kind, self.has_check = row
        crons, _ = hook_and_cron(self.path)
        self.cron = crons[0]
        # hook mode: the CronJob's own template run under a pod name that contains -presync-
        self.hook = {"metadata": {"name": self.cname + "-presync-run"}, "spec": {"template": self.cron["spec"]["jobTemplate"]["spec"]["template"], "activeDeadlineSeconds": self.cron["spec"]["jobTemplate"]["spec"]["activeDeadlineSeconds"]}}
        self.cmain = self.cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]
        self.hmain = self.hook["spec"]["template"]["spec"]["containers"][0]
        self.d = self.hook["spec"]["activeDeadlineSeconds"]
        self.hosts = {
            "nightly": self.cname + "-29012345-abcde",
            "manual": self.cname + "-manual-202501011200-abcde",
            "hook": self.hook["metadata"]["name"] + "-x7k2p",
        }
        self.ext = set_files(self.prefix, self.kind, "x")[0].split("x")[-1]  # the extension that marks one set


def fixture(app):
    """Synthetic data directory and older sets in the backup root."""
    t = tempfile.mkdtemp(prefix="hooktest.")
    for sub in ("backup", "data", "tmp"):
        os.makedirs(os.path.join(t, sub))
    mkstubs(os.path.join(t, "bin"))
    if app.family == "python":
        d = os.path.join(t, "data")
        dbname = {"n8n-backup": "database.sqlite", "uptime-kuma-backup": "kuma.db", "open-webui-backup": "webui.db"}[app.cname]
        mkdb(os.path.join(d, dbname))
        wr(os.path.join(d, "note.txt"), "synthetic")
        if app.cname == "open-webui-backup":
            os.makedirs(os.path.join(d, "vector_db"))
            mkdb(os.path.join(d, "vector_db", "chroma.sqlite3"))
    if app.kind == "wiki":
        wr(os.path.join(t, "data", "file one.txt"), "synthetic")
    for i in range(14):
        for f in set_files(app.prefix, app.kind, f"20250101T0000{i:02d}Z"):
            wr(os.path.join(t, "backup", f), "old")
    wr(os.path.join(t, "now"), str(1_800_000_000 // 86400 * 86400 + 12 * 3600))  # a clock outside the window
    return t


def inject(text, anchor, code):
    """code lines (same indentation as the anchor line) placed before the one line that holds the anchor"""
    ms = list(re.finditer(r"^( *)" + re.escape(anchor), text, re.MULTILINE))
    assert len(ms) == 1, f"expected one line with {anchor!r}, found {len(ms)}"
    ins = "".join(ms[0].group(1) + line + "\n" for line in code.splitlines())
    return text[: ms[0].start()] + ins + text[ms[0].start():]


FAULT = 'if os.environ.get("FAIL_STEP") == "{step}" and os.environ.get("FAIL_EXT") == ext:\n    raise OSError("injected")'


def once(text, old, new):
    assert text.count(old) == 1, f"expected one {old!r} in the script, found {text.count(old)}"
    return text.replace(old, new)


def rewrite(text, t, tag, wait):
    """Container paths into the temporary directory, the lock wait made short, the clock readable from a file, a slow logged step added."""
    text = text.replace("/etc/hostname", f"{t}/hostname.{tag}").replace("/dev/termination-log", f"{t}/term.{tag}")
    text = text.replace("/backup", t + "/backup")
    text = re.sub(r"(?<![\w.])/data(?![\w-])", t + "/data", text)
    text = re.sub(r"(?<![\w.])/stage(?![\w-])", f"{t}/stage.{tag}", text)
    if "flock -w 120 9" in text:
        text = once(text, "flock -w 120 9", f"flock -w {wait} 9")
        text = once(text, "$(date -u +%s)", "$(date -u +%s)")  # the guard reads the clock through the stubbed date
    else:
        text = once(text, "give_up = time.monotonic() + 120", f"give_up = time.monotonic() + {wait}")
        text = once(text, "int(time.time())", 'int(open(os.environ["FAKE_NOW_FILE"]).read())')
        text = once(text, "time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())", "(os.environ.get('FAKE_STAMP') or time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()))")
        text = once(text, 'with open(tmp, "rb") as f, gzip.open(', PY_STEP + 'with open(tmp, "rb") as f, gzip.open(')
        text = inject(text, "h = hashlib.sha256()", FAULT.format(step="checksum"))
        text = inject(text, 'with open(path + ".sha256", "w") as f:', FAULT.format(step="sidecar"))
    return text


def spawn(t, container, script, hostname, env=None, tag="a", wait=2):
    wr(os.path.join(t, f"hostname.{tag}"), hostname + "\n")
    for stale in (os.path.join(t, f"stage.{tag}"),):  # an emptyDir is new for every pod
        shutil.rmtree(stale, ignore_errors=True)
        os.makedirs(stale)
    term = os.path.join(t, f"term.{tag}")
    if os.path.exists(term):
        os.remove(term)
    cmd = [SHELLS.get(c, c) for c in container["command"]]
    e = {"PATH": os.path.join(t, "bin") + ":" + os.environ["PATH"], "HOME": os.path.join(t, "tmp"), "TMPDIR": os.path.join(t, "tmp"), "LC_ALL": "C", "FAKE_NOW_FILE": os.path.join(t, "now")}
    e.update(env or {})
    for item in container.get("env", []):
        if "value" in item and item["name"] not in e:
            e[item["name"]] = item["value"]
    e.pop("PGPASSWORD", None)
    return subprocess.Popen(cmd + [rewrite(script, t, tag, wait)], env=e, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=t)


class Done:
    def __init__(self, p, t, tag):
        self.out, self.err = p.communicate(timeout=120)
        self.rc = p.returncode
        path = os.path.join(t, f"term.{tag}")
        self.term = rd(path) if os.path.exists(path) else None


def finish(p, t, tag="a"):
    return Done(p, t, tag)


def run(t, container, script, hostname, env=None, tag="a", wait=2):
    return finish(spawn(t, container, script, hostname, env, tag, wait), t, tag)


def listing(d):
    return sorted(os.listdir(d)) if os.path.isdir(d) else []


def stat_of(d, skip=(LOCK,)):
    return {f: (os.stat(os.path.join(d, f)).st_mtime_ns, os.stat(os.path.join(d, f)).st_size) for f in listing(d) if f not in skip and os.path.isfile(os.path.join(d, f))}


def set_re(prefix):
    return re.compile((re.escape(prefix) + "-" if prefix else "") + r"\d{8}T\d{6}Z$")


def hold(path, seconds):
    p = subprocess.Popen([sys.executable, "-c", HOLD, path, str(seconds)], stdout=subprocess.PIPE, text=True)
    assert p.stdout is not None and p.stdout.readline().strip() == "held"
    return p


def lock_is_held(path):
    if not os.path.exists(path):
        return False
    fd = os.open(path, os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    except BlockingIOError:
        return True
    finally:
        os.close(fd)


def wait_held(path, limit=20):
    end = time.monotonic() + limit
    while time.monotonic() < end:
        if lock_is_held(path):
            return True
        time.sleep(0.02)
    return False


def sets_in(d, app):
    return sorted(f for f in listing(d) if f.endswith(app.ext))


def alternating(log):
    lines = rd(log).split() if os.path.exists(log) else []
    marks = lines[0::2]
    return len(marks) > 0 and all(m == ("S" if i % 2 == 0 else "E") for i, m in enumerate(marks)) and marks[-1] == "E"


def set_clock(t, hms):
    h, m, s = map(int, hms.split(":"))
    wr(os.path.join(t, "now"), str(1_800_000_000 // 86400 * 86400 + h * 3600 + m * 60 + s))


def refused(app, hms):
    h, m, s = map(int, hms.split(":"))
    s = h * 3600 + m * 60 + s
    return any(s < 14400 + 86400 * k and s + app.d + 300 >= 3600 + 86400 * k for k in (0, 1))


def runtime_checks(only=None):
    for row in APPS:
        if only and row[1] != only:
            continue
        app = App(row)
        tag = app.cname
        t = fixture(app)
        try:
            scenario_window(app, tag)
            scenario_contention(app, tag)
            scenario_failure(app, tag)
            scenario_retention(app, tag)
            scenario_simultaneous(app, tag)
            scenario_same_stamp(app, tag)
            scenario_late_failure(app, tag)
            scenario_wiki_manifest(app, tag)
            scenario_lock_file(app, tag)
        finally:
            shutil.rmtree(t, ignore_errors=True)


def new_root(app):
    t = fixture(app)
    return t, os.path.join(t, "backup")


def scenario_window(app, tag):
    t, root = new_root(app)
    try:
        seed = listing(root)
        edges_ok = True
        for hms in ("00:00:00", "00:20:00", "00:29:00", "00:30:00", "00:50:00", "01:00:00", "02:30:00", "03:59:59", "04:00:00", "04:00:01", "12:00:00", "22:54:59", "23:00:00", "23:25:00", "23:30:00", "23:55:00", "23:59:59"):
            set_clock(t, hms)
            r = run(t, app.hmain, app.hmain["args"][0], app.hosts["hook"])
            want = refused(app, hms)
            if (r.rc == 76) != want or r.rc not in (0, 76):
                edges_ok = False
                print(f"     edge {hms} d={app.d}: rc={r.rc} refused-expected={want} {r.err.strip()[-160:]}")
            if want and (listing(root) != seed or r.term is not None):
                edges_ok = False
                print(f"     edge {hms}: a refused hook wrote something")
            if not want:
                shutil.rmtree(os.path.join(root, HOOKDIR), ignore_errors=True)
                os.remove(os.path.join(root, LOCK))
                for f in set(listing(root)) - set(seed):
                    os.remove(os.path.join(root, f))
        check(edges_ok, f"{tag}: hook window edges (deadline {app.d}s): refused inside and up to deadline+margin before the window, also across midnight; a refusal writes nothing, not even the lock file")
        for hms, want in (("03:59:59", True), ("04:00:00", False), ("01:30:00", True), ("23:55:00", app.d >= 3600)):
            check(refused(app, hms) == want, f"{tag}: oracle sanity {hms}")
        # the window binds the hook only
        set_clock(t, "02:00:00")
        r = run(t, app.cmain, app.cmain["args"][0], app.hosts["nightly"])
        check(r.rc == 0, f"{tag}: the scheduled run is not subject to the hook's window guard" + ("" if r.rc == 0 else " :: " + r.err.strip()[-200:]))
        # re-check after a wait: allowed at the start, inside the window once the lock is free
        set_clock(t, "12:00:00")
        h = hold(os.path.join(root, LOCK), 2)
        sets_before = stat_of(root)
        p = spawn(t, app.hmain, app.hmain["args"][0], app.hosts["hook"], tag="w", wait=8)
        time.sleep(0.6)
        set_clock(t, "00:40:00")
        r = finish(p, t, "w")
        h.kill()
        h.wait()
        check(r.rc == 76 and r.term is None and not os.path.exists(os.path.join(root, HOOKDIR)) and stat_of(root) == sets_before, f"{tag}: window re-checked after the wait: refused (76), nothing created or touched (rc {r.rc})")
    finally:
        shutil.rmtree(t, ignore_errors=True)


def scenario_contention(app, tag):
    t, root = new_root(app)
    try:
        seed = listing(root)
        before = stat_of(root)
        h = hold(os.path.join(root, LOCK), 60)  # a run in flight (any mode) owns the one lock
        for mode in ("hook", "manual", "nightly"):
            c = app.hmain if mode == "hook" else app.cmain
            r = run(t, c, c["args"][0], app.hosts[mode], wait=1)
            gone = set(listing(root)) - {LOCK}
            check(r.rc == 75 and r.term is None and stat_of(root) == before and gone == set(seed), f"{tag}: {mode} run while the lock is held: gives up with 75, nothing created, written or removed" + ("" if r.rc == 75 else f" (rc {r.rc}) {r.err.strip()[-160:]}"))
            check("another run holds the lock" in r.err, f"{tag}: {mode} run reports the held lock the same way")
        check(not os.path.exists(os.path.join(root, HOOKDIR)), f"{tag}: first-ever hook with a run in flight did not create the hook directory")
        h.kill()
        h.wait()
        # bounded wait, then success once the holder is gone
        h = hold(os.path.join(root, LOCK), 1.2)
        r = run(t, app.hmain, app.hmain["args"][0], app.hosts["hook"], tag="w", wait=10)
        check(r.rc == 0 and r.term is not None, f"{tag}: a hook waits for the lock and then runs" + ("" if r.rc == 0 else f" (rc {r.rc}) {r.err.strip()[-160:]}"))
        h.kill()
        h.wait()
    finally:
        shutil.rmtree(t, ignore_errors=True)


def scenario_failure(app, tag):
    t, root = new_root(app)
    try:
        seed_sets = sets_in(root, app)
        r = run(t, app.hmain, app.hmain["args"][0], app.hosts["hook"])
        check(r.rc == 0, f"{tag}: hook run succeeds" + ("" if r.rc == 0 else " :: " + r.err.strip()[-200:]))
        hdir = os.path.join(root, HOOKDIR)
        good = stat_of(hdir)
        time.sleep(1.1)  # a failing run of the same second would remove the files of its own stamp
        check(os.path.isdir(hdir) and oct(os.stat(hdir).st_mode & 0o777) == "0o700", f"{tag}: hook directory created (0700) by the hook")
        if app.family == "shell":
            r = run(t, app.hmain, app.hmain["args"][0], app.hosts["hook"], env={"FAIL_DUMP": "1"})
        else:
            gone = []
            for f in os.listdir(os.path.join(t, "data")):
                if f.endswith((".sqlite", ".db")):
                    os.rename(os.path.join(t, "data", f), os.path.join(t, "data", f + ".gone"))
                    gone.append(f)
            r = run(t, app.hmain, app.hmain["args"][0], app.hosts["hook"])
            for f in gone:
                os.rename(os.path.join(t, "data", f + ".gone"), os.path.join(t, "data", f))
        check(r.rc not in (0, 75, 76) and r.term is None, f"{tag}: a failing hook backup exits non-zero without a termination message (rc {r.rc})")
        check(good.items() <= stat_of(hdir).items(), f"{tag}: the failure removed no earlier hook set")
        if app.kind in ("penpot", "wiki"):
            before = stat_of(hdir)
            r = run(t, app.hmain, app.hmain["args"][0], app.hosts["hook"], env={"FAIL_PSQL": "1"})
            check(r.rc != 0 and stat_of(hdir) == before, f"{tag}: a half-written hook set is removed again")
        r = run(t, app.hmain, app.hmain["args"][0], app.hosts["hook"])
        check(r.rc == 0, f"{tag}: after a failure the lock is free again (next hook runs)")
        check(sets_in(root, app) == seed_sets, f"{tag}: hook runs left the sets of the claim root as they were")
        check(LOCK not in listing(hdir), f"{tag}: no lock file in the hook directory (one lock, on the root)")
    finally:
        shutil.rmtree(t, ignore_errors=True)


def scenario_retention(app, tag):
    t, root = new_root(app)
    try:
        hdir = os.path.join(root, HOOKDIR)
        os.makedirs(hdir, mode=0o700)
        for i in range(13):  # one below the bound
            for f in set_files(app.prefix, app.kind, f"20240101T0000{i:02d}Z"):
                wr(os.path.join(hdir, f), "old")
        night = stat_of(root)
        r = run(t, app.hmain, app.hmain["args"][0], app.hosts["hook"])
        check(r.rc == 0 and len(sets_in(hdir, app)) == 14 and "20240101T000000Z" in "".join(listing(hdir)), f"{tag}: hook at the boundary: 14 sets in its directory, none pruned")
        check(stat_of(root) == night, f"{tag}: ... root of the claim untouched")
        time.sleep(1.1)
        r = run(t, app.hmain, app.hmain["args"][0], app.hosts["hook"])
        n = sets_in(hdir, app)
        check(r.rc == 0 and len(n) == 14 and not any("20240101T000000Z" in f for f in n), f"{tag}: hook past the boundary: the oldest hook set goes, 14 stay")
        check(stat_of(root) == night, f"{tag}: ... the scheduled sets in the root are not touched, no slot used")
        # scheduled run afterwards: prunes the root only, bare termination name
        r = run(t, app.cmain, app.cmain["args"][0], app.hosts["nightly"])
        rootsets = sets_in(root, app)
        check(r.rc == 0 and set_re(app.prefix).match(r.term or "") is not None, f"{tag}: scheduled run next to the hook directory keeps its bare termination name")
        check(len(rootsets) == 14 and set_files(app.prefix, app.kind, "20250101T000000Z")[0] not in rootsets, f"{tag}: scheduled run keeps its 14 newest in the root")
        check(len(sets_in(hdir, app)) == 14, f"{tag}: scheduled retention left the hook directory alone")
        # manual run: no prune, membership assertion holds with the hook directory and the lock file present
        time.sleep(1.1)
        r = run(t, app.cmain, app.cmain["args"][0], app.hosts["manual"])
        check(r.rc == 0 and len(sets_in(root, app)) == 15 and set_re(app.prefix).match(r.term or "") is not None, f"{tag}: manual run: passes its directory assertion, prunes nothing, bare termination name" + ("" if r.rc == 0 else " :: " + r.err.strip()[-200:]))
        check(listing(root).count(LOCK) == 1 and listing(root).count(HOOKDIR) == 1, f"{tag}: one lock file and one hook directory in the root, all modes")
        hr = run(t, app.hmain, app.hmain["args"][0], app.hosts["hook"])
        check(hr.rc == 0 and set_re(app.prefix).match(hr.term or "") is not None, f"{tag}: hook termination message is a bare set id ({hr.term})")
    finally:
        shutil.rmtree(t, ignore_errors=True)


def scenario_simultaneous(app, tag):
    # (1) a manual run in flight, a hook and a scheduled run start meanwhile (a first-ever hook: no hook directory yet)
    t, root = new_root(app)
    try:
        log = os.path.join(t, "conc.log")
        slow = {"SLOW": "1.2", "CONCLOG": log}
        hook_dir = os.path.join(root, HOOKDIR)
        a = spawn(t, app.cmain, app.cmain["args"][0], app.hosts["manual"], env=slow, tag="m", wait=30)
        started = wait_held(os.path.join(root, LOCK))
        h = spawn(t, app.hmain, app.hmain["args"][0], app.hosts["hook"], env=slow, tag="h", wait=30)
        n = spawn(t, app.cmain, app.cmain["args"][0], app.hosts["nightly"], env=slow, tag="n", wait=30)
        time.sleep(0.5)
        mid = os.path.exists(hook_dir)
        ra, rh, rn = finish(a, t, "m"), finish(h, t, "h"), finish(n, t, "n")
        check(started and not mid, f"{tag}: manual run in flight: a starting first-ever hook does not create the hook directory")
        check(ra.rc == 0 and rh.rc == 0 and rn.rc == 0, f"{tag}: manual, hook and scheduled run started together all complete, one after the other (rc {ra.rc}/{rh.rc}/{rn.rc})" + "".join(" :: " + x.err.strip()[-150:] for x in (ra, rh, rn) if x.rc))
        check(alternating(log), f"{tag}: the three critical steps never overlapped (one real lock for all modes)")
        check(all(set_re(app.prefix).match(x.term or "") for x in (ra, rh, rn)), f"{tag}: every mode reports a bare set name")
        check(len(sets_in(hook_dir, app)) == 1 and len(sets_in(root, app)) == 14, f"{tag}: the hook's set is in its directory only; the root keeps its bound")
        check(any((ra.term or "x") in f for f in listing(root)), f"{tag}: the manual set survived the scheduled prune (newest)")
    finally:
        shutil.rmtree(t, ignore_errors=True)
    # (2) a hook in flight creates the hook directory, a manual run and a scheduled run wait: the manual listing taken after the lock includes it
    t, root = new_root(app)
    try:
        log = os.path.join(t, "conc.log")
        slow = {"SLOW": "1.2", "CONCLOG": log}
        h = spawn(t, app.hmain, app.hmain["args"][0], app.hosts["hook"], env=slow, tag="h", wait=30)
        wait_held(os.path.join(root, LOCK))
        a = spawn(t, app.cmain, app.cmain["args"][0], app.hosts["manual"], env=slow, tag="m", wait=30)
        n = spawn(t, app.cmain, app.cmain["args"][0], app.hosts["nightly"], env=slow, tag="n", wait=30)
        rh, ra, rn = finish(h, t, "h"), finish(a, t, "m"), finish(n, t, "n")
        check(rh.rc == 0 and ra.rc == 0 and rn.rc == 0, f"{tag}: hook in flight, manual and scheduled run wait and then pass (the hook directory appears before the manual listing, no race) (rc {rh.rc}/{ra.rc}/{rn.rc})" + "".join(" :: " + x.err.strip()[-150:] for x in (rh, ra, rn) if x.rc))
        check(alternating(log), f"{tag}: ... and never overlapped")
        # a second hook object of the same claim (the second Authentik Application) is serialized the same way
        if app.cname == "authentik-pg-dump":
            second = app.cname.replace("-pg-dump", "-app-pg-dump") + "-presync-k9x2z"
            h1 = spawn(t, app.hmain, app.hmain["args"][0], app.hosts["hook"], env=slow, tag="h1", wait=30)
            wait_held(os.path.join(root, LOCK))
            h2 = spawn(t, app.hmain, app.hmain["args"][0], second, env=slow, tag="h2", wait=30)
            r1, r2 = finish(h1, t, "h1"), finish(h2, t, "h2")
            check(r1.rc == 0 and r2.rc == 0, f"{tag}: the second Application's hook name is serialized with the first (rc {r1.rc}/{r2.rc})")
            check(not any("-manual-" in x for x in (second, app.hosts["hook"])), f"{tag}: neither hook name can be taken for a manual copy")
    finally:
        shutil.rmtree(t, ignore_errors=True)
    # (3) a stray entry that appears while a manual run works is still caught by its before/after assertion
    if app.has_check:
        t, root = new_root(app)
        try:
            r = run(t, app.cmain, app.cmain["args"][0], app.hosts["manual"], env={"INTRUDE": os.path.join(root, "stray")})
            check(r.rc != 0 and "not the earlier entries plus this set" in r.err and r.term is None, f"{tag}: manual before/after membership check still refuses a changed directory (rc {r.rc})")
        finally:
            shutil.rmtree(t, ignore_errors=True)


def entry_bytes(p):
    if os.path.islink(p):
        return os.readlink(p)
    if not os.path.isfile(p):
        return None
    with open(p, "rb") as f:
        return f.read()


def snapshot(d, skip=(LOCK,)):
    """Every entry of a directory by name: link target or content bytes, and modification time (a link is not followed); the lock file of a first run is not an entry of a set."""
    return {n: (entry_bytes(os.path.join(d, n)), None if os.path.isdir(os.path.join(d, n)) and not os.path.islink(os.path.join(d, n)) else os.lstat(os.path.join(d, n)).st_mtime_ns) for n in listing(d) if n not in skip}


STAMP = "20250601T000000Z"


def hook_names(app):
    """Every name the hook of this producer creates for one stamp, finals and temporaries."""
    names = set_files(app.prefix, app.kind, STAMP)
    if app.family == "python":
        b = f"{app.prefix}-{STAMP}"
        names += [f".{b}.db{x}" for x in ("", "-journal", "-wal", "-shm")]
    return names


def client(app, mode):
    return app.hmain if mode == "hook" else app.cmain


def sets_dir(root, mode):
    return os.path.join(root, HOOKDIR) if mode == "hook" else root


def scenario_same_stamp(app, tag):
    """One clock reading, a leftover of the set name, an orphan, a temporary file or a dangling link, in every mode (a scheduled run after a manual one included):
    the second run fails before it writes, the earlier bytes and entries stay, no termination message."""
    env = {"FAKE_STAMP": STAMP}
    for m1, m2 in (("hook", "hook"), ("manual", "nightly"), ("nightly", "manual"), ("nightly", "nightly")):
        t, root = new_root(app)
        try:
            first = run(t, client(app, m1), client(app, m1)["args"][0], app.hosts[m1], env=env)
            check(first.rc == 0, f"{tag}: first {m1} run with a fixed stamp succeeds" + ("" if first.rc == 0 else " :: " + first.err.strip()[-200:]))
            kept_root, kept_hook = snapshot(root), snapshot(os.path.join(root, HOOKDIR))
            c = client(app, m2)
            second = run(t, c, c["args"][0], app.hosts[m2], env=env, tag="b")
            check(second.rc not in (0, 75, 76) and second.term is None, f"{tag}: {m2} run after a {m1} run of the same stamp fails without a termination message (rc {second.rc})")
            check(snapshot(root) == kept_root and snapshot(os.path.join(root, HOOKDIR)) == kept_hook, f"{tag}: ... earlier set bytes and entries retained, nothing created or removed ({m1}, {m2})")
        finally:
            shutil.rmtree(t, ignore_errors=True)
    for mode in ("hook", "manual", "nightly"):
        for name in hook_names(app):
            for kind in ("orphan", "dangling"):
                t, root = new_root(app)
                try:
                    d = sets_dir(root, mode)
                    os.makedirs(d, mode=0o700, exist_ok=True)
                    if kind == "orphan":
                        wr(os.path.join(d, name), "keep")
                    else:
                        os.symlink(os.path.join(t, "absent"), os.path.join(d, name))
                    kept = snapshot(root), snapshot(os.path.join(root, HOOKDIR))
                    c = client(app, mode)
                    r = run(t, c, c["args"][0], app.hosts[mode], env=env)
                    good = r.rc not in (0, 75, 76) and r.term is None and (snapshot(root), snapshot(os.path.join(root, HOOKDIR))) == kept and not os.path.exists(os.path.join(t, "absent"))
                    check(good, f"{tag}: {mode} run refuses a {kind} {name.replace(STAMP, 'STAMP')}: fails, nothing written or removed (rc {r.rc})")
                finally:
                    shutil.rmtree(t, ignore_errors=True)


def full_hook_dir(app, root, n=14):
    d = os.path.join(root, HOOKDIR)
    os.makedirs(d, mode=0o700)
    for i in range(n):
        for f in set_files(app.prefix, app.kind, f"20240101T0000{i:02d}Z"):
            wr(os.path.join(d, f), "old")


def scenario_late_failure(app, tag):
    """A failure after the first output was written, with every class at its full size: no earlier member or byte is lost or pruned, no termination message,
    and the failed run's own partial files do not stay (they would count as a set and push an older one out)."""
    if app.family == "python":
        faults = [{"FAIL_EXT": e, "FAIL_STEP": st} for e in ("db.gz", "tar.gz") for st in ("checksum", "sidecar")]
    else:
        faults = [{"FAIL_SHA": "1"}] + ([{"FAIL_PSQL": "1"}] if app.kind in ("penpot", "wiki") else [])
    for mode in ("hook", "manual", "nightly"):
        for env in faults:
            t, root = new_root(app)
            try:
                full_hook_dir(app, root)
                kept = snapshot(root), snapshot(os.path.join(root, HOOKDIR))
                c = client(app, mode)
                r = run(t, c, c["args"][0], app.hosts[mode], env=env)
                label = ",".join(f"{k.lower()[5:]}={v}" for k, v in env.items())
                check(r.rc not in (0, 75, 76) and r.term is None and (snapshot(root), snapshot(os.path.join(root, HOOKDIR))) == kept, f"{tag}: {mode} run, late failure ({label}) at full size: nonzero, no termination message, nothing earlier lost, no partial left (rc {r.rc})")
            finally:
                shutil.rmtree(t, ignore_errors=True)


def scenario_wiki_manifest(app, tag):
    """An attachment name the manifest check refuses, and a manifest check that cannot run, with every class at its full size."""
    if app.kind != "wiki":
        return
    for mode in ("hook", "nightly"):
        for what, env in (("invalid name", {}), ("grep error", {"FAIL_GREP": "1"})):
            t, root = new_root(app)
            try:
                if what == "invalid name":
                    wr(os.path.join(t, "data", "bad\\name.txt"), "synthetic")
                full_hook_dir(app, root)
                kept = snapshot(root), snapshot(os.path.join(root, HOOKDIR))
                c = client(app, mode)
                r = run(t, c, c["args"][0], app.hosts[mode], env=env)
                d = sets_dir(root, mode)
                now = snapshot(d)
                lost = [n for n, v in kept[1 if mode == "hook" else 0].items() if now.get(n) != v]
                extra = len(sets_in(d, app)) - 14
                # a hook set (and every set whose check could not run) is removed again; a scheduled set with an invalid name stays visible, unpruned
                want_extra = 1 if (mode == "nightly" and what == "invalid name") else 0
                check(r.rc not in (0, 75, 76) and r.term is None and not lost and extra == want_extra, f"{tag}: {mode} run, manifest {what}, full size: nonzero, no termination message, nothing earlier lost or pruned (rc {r.rc})")
            finally:
                shutil.rmtree(t, ignore_errors=True)


def scenario_lock_file(app, tag):
    """The shared lock path: an existing plain file keeps its bytes; a link or another type is refused in every mode and touches no earlier file."""
    for mode in ("hook", "manual", "nightly"):
        c = app.hmain if mode == "hook" else app.cmain
        t, root = new_root(app)
        try:
            lock = os.path.join(root, LOCK)
            wr(lock, "keep")
            r = run(t, c, c["args"][0], app.hosts[mode])
            check(r.rc == 0 and rd(lock) == "keep", f"{tag}: {mode} run keeps the bytes of an existing lock file (no truncation)")
        finally:
            shutil.rmtree(t, ignore_errors=True)
        for kind in ("link", "dangling", "directory"):
            t, root = new_root(app)
            try:
                lock = os.path.join(root, LOCK)
                prior = os.path.join(root, listing(root)[0])
                if kind == "link":
                    os.symlink(prior, lock)
                elif kind == "dangling":
                    os.symlink(os.path.join(t, "absent"), lock)
                else:
                    os.mkdir(lock)
                kept = snapshot(root, skip=())
                r = run(t, c, c["args"][0], app.hosts[mode])
                check(r.rc not in (0, 75, 76) and r.term is None and snapshot(root, skip=()) == kept and not os.path.exists(os.path.join(t, "absent")), f"{tag}: {mode} run refuses a lock path that is a {kind}: fails, prior files untouched (rc {r.rc})")
            finally:
                shutil.rmtree(t, ignore_errors=True)


def main():
    for tool in ("kustomize", "yq"):
        if not shutil.which(tool):
            raise SystemExit("missing tool " + tool)
    render_checks()
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
    runtime_checks(only)
    print("RESULT", "FAIL" if fails else "OK", f"({fails} failed)" if fails else "")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
