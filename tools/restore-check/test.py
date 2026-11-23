#!/usr/bin/env python3
"""Tests of the restore checks (apps/_restore-check).

STATIC  the rendered manifests of every application: names, schedule form, time zone, read-only claim, no credentials, no token,
        restricted pod security, termination message from the file, resources and scratch bounds, a deny-all policy that selects the
        pods (Kubernetes selector semantics, an empty selector selects every pod), one shared script per backend.
HOST    the rendered SQLite check, backup and hook scripts run with the local python3 (container paths rewritten into a temporary
        directory) against synthetic sets: real gzip, sqlite3 and tarfile, not the pinned image. The select half of the pg_dump check
        runs with the local bash and GNU tools (hand-off modes included).
ENGINE  the rendered scripts run in the pinned images of the manifests with docker (a Linux daemon on a local unix socket, whatever the
        client's platform; a remote or non-unix endpoint is refused; named local volumes whose owner and mode are
        set per test, never bind-mounted host directories): synthetic source data, the real backup and hook scripts write one golden
        set per class, each case runs on its own copy. pg_dump sets: select and restore run as separate containers with the users of the
        manifest, the hand-off modes are checked between them, the archive is restored by a role without superuser rights. Containers
        run unprivileged (no capabilities except CHOWN for the volume setup, read-only root, no new privileges), have no network (the
        synthetic source database and the dump steps share one internal network of the test), get no host environment, no docker socket
        and no kubeconfig, and are removed afterwards. Synthetic values (the sentinel, the n8n key) reach the containers only inside the
        helper program on stdin, never as an argument; a generated key never leaves its container.

Every case checks the exit code, that each output line is one of the fixed forms, that no synthetic data value (a random sentinel in rows,
file names and the key file) appears in stdout, stderr or the termination message, and that scratch is empty afterwards.

Usage: test.py [static] [host] [engine] [<app> ...]   (default: all three tiers and all applications; an app is the backup CronJob name
       or the directory name, e.g. `engine penpot n8n`). The engine tier needs a Linux docker daemon on a local unix socket; a missing,
       remote or non-Linux engine is a FAIL when `engine` was asked for. A pinned image is used only when present under its exact
       digest (else pulled by that reference). Needs kustomize, yq, python3. No cluster, no credentials, no real data. A setup failure names its fixed
       test phase only.
"""
import gzip
import hashlib
import io
import json
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else "/"  # the helper runs from stdin
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
# dir, backend, backup CronJob, database file of the SQLite backup
APPS = [
    ("apps/tools/affine", "pg", "affine-pg-dump", None),
    ("apps/tools/juraticker", "pg", "juraticker-pg-dump", None),
    ("apps/tools/wiki", "pg", "wiki-pg-dump", None),
    ("apps/tools/penpot", "pg", "penpot-pg-dump", None),
    ("apps/identity/authentik-db", "pg", "authentik-pg-dump", None),
    ("apps/tools/n8n", "sqlite", "n8n-backup", "database.sqlite"),
    ("apps/tools/uptime-kuma", "sqlite", "uptime-kuma-backup", "kuma.db"),
    ("apps/tools/open-webui", "sqlite", "open-webui-backup", "webui.db"),
]
SENTINEL = "rcsentinel" + secrets.token_hex(8)
LINE = re.compile(r"(OK [a-z-]+ (nightly|presync|-)( [A-Za-z0-9_.-]+=[A-Za-z0-9_.-]+)*|FAIL [a-z-]+ (nightly|presync|-)|RESULT (OK|FAIL) [a-z-]+)")
TERM_OK = re.compile(r"nightly=[a-z0-9-]*[0-9]{8}T[0-9]{6}Z presync=([a-z0-9-]*[0-9]{8}T[0-9]{6}Z|none)")
# the restore's termination message: both set ids and one row total per class (database rows only; no file or sidecar count), `none` for a class without a set
TERM_RESTORE = re.compile(r"nightly=[a-z0-9-]*[0-9]{8}T[0-9]{6}Z presync=([a-z0-9-]*[0-9]{8}T[0-9]{6}Z|none) rows-nightly=[0-9]{1,15} rows-presync=([0-9]{1,15}|none)")
RC_KEYS = {"RC_SCHEDULE", "RC_PREFIX", "RC_TABLES", "RC_KNOWN", "RC_COUNTS", "RC_MANIFEST", "RC_ASSETS", "RC_EXTRA", "RC_EXTENSIONS"}
# the time-of-day expression of the hook scripts; fixture runs replace it with noon UTC so a hook fixture never depends on the clock
CLOCKS = ("int(time.time()) % 86400", "$(( $(date -u +%s) % 86400 ))")
STEP = {"phase": "-"}
count = {"ok": 0, "fail": 0}


def step(name):
    """the fixed test phase a setup failure is reported with"""
    STEP["phase"] = name


def fixed_clock(script):
    if sum(script.count(c) for c in CLOCKS) != 1:
        raise RuntimeError("clock expression of the hook script not found once")
    for c in CLOCKS:
        script = script.replace(c, "43200")
    return script


def say(tier, cond, msg):
    count["ok" if cond else "fail"] += 1
    print(("ok   " if cond else "FAIL ") + tier + " " + msg, flush=True)


def build(path):
    out = subprocess.run(["kustomize", "build", os.path.join(ROOT, path)], check=True, capture_output=True, text=True).stdout
    js = subprocess.run(["yq", "-o=json", "-I=0", "."], input=out, check=True, capture_output=True, text=True).stdout
    return [json.loads(line) for line in js.splitlines() if line.strip()]


class App:
    def __init__(self, path, backend, cname, dbfile):
        self.path, self.backend, self.cname, self.dbfile = path, backend, cname, dbfile
        docs = build(path)
        self.docs = docs
        self.cron = next(d for d in docs if d["kind"] == "CronJob" and d["metadata"]["name"] == cname)
        self.hooks = [d for d in docs if d["kind"] == "Job"]  # none at this stage; a synthetic hook run uses the CronJob's own template
        rcs = [d for d in docs if d["kind"] == "CronJob" and d["metadata"].get("labels", {}).get("homelab.io/restore-check") == "true"]
        self.rc = rcs[0] if len(rcs) == 1 else None
        self.cm = next((d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "restore-check"), None)
        self.pod = self.rc["spec"]["jobTemplate"]["spec"]["template"]["spec"] if self.rc else {}
        self.cfg = dict(self.cm["data"]) if self.cm else {}
        self.prefix = self.cfg.get("RC_PREFIX", "")
        self.tables = [t for t in self.cfg.get("RC_TABLES", "").split(",") if t]
        self.known = self.cfg.get("RC_KNOWN", "")
        self.counts = [s.split("=", 1) for s in self.cfg.get("RC_COUNTS", "").split()]
        self.ns = self.cron["metadata"]["namespace"]

    def env(self, container, **extra):
        e = dict(self.cfg)
        for item in container.get("env", []):
            if "value" in item:
                e[item["name"]] = item["value"]
        e.update({k: str(v) for k, v in extra.items()})
        return e

    def containers(self):
        return self.pod.get("initContainers", []) + self.pod.get("containers", [])


# ---------------------------------------------------------------- STATIC
def schedule_window(sched, start_deadline, active):
    m, h, dom, mon, dow = sched.split()
    start = int(h) * 60 + int(m)
    latest = start + start_deadline // 60 + active // 60
    # a weekly form that stays inside one day and outside the excluded hours, also when started late
    return dom == "*" and mon == "*" and re.fullmatch(r"[0-6]", dow) is not None and start >= 4 * 60 and latest < 25 * 60


def selects(sel, labels):
    """Kubernetes label selector semantics: a missing or empty selector selects every pod of the namespace"""
    sel = sel or {}
    if any(labels.get(k) != v for k, v in (sel.get("matchLabels") or {}).items()):
        return False
    for x in sel.get("matchExpressions") or []:
        k, vals = x.get("key"), x.get("values") or []
        has = k in labels
        ok = {"In": has and labels.get(k) in vals, "NotIn": not has or labels.get(k) not in vals, "Exists": has, "DoesNotExist": not has}.get(x.get("operator"))
        if not ok:  # an unknown operator counts as not selecting: the deny check below then fails
            return False
    return True


def selects_selftest():
    lab = {"a": "1", "b": "2"}
    cases = [(None, True), ({}, True), ({"matchLabels": {}}, True), ({"matchLabels": {"a": "1"}}, True), ({"matchLabels": {"a": "2"}}, False),
             ({"matchExpressions": [{"key": "a", "operator": "In", "values": ["1"]}]}, True),
             ({"matchExpressions": [{"key": "a", "operator": "NotIn", "values": ["1"]}]}, False),
             ({"matchExpressions": [{"key": "c", "operator": "DoesNotExist"}]}, True),
             ({"matchExpressions": [{"key": "c", "operator": "Exists"}]}, False),
             ({"matchExpressions": [{"key": "a", "operator": "Bogus"}]}, False)]
    return all(selects(sel, lab) is want for sel, want in cases)


def mib(q):
    m = re.fullmatch(r"([0-9]+)(Mi|Gi)", str(q))
    if not m:
        return None
    return int(m.group(1)) * (1024 if m.group(2) == "Gi" else 1)


def static_checks(apps):
    scripts = {}
    seen_schedules = set()
    say("STATIC selector:", selects_selftest(), "selector semantics (empty selects all, matchExpressions) self-test")
    for a in apps:
        t = "STATIC " + a.cname + ":"
        say(t, a.rc is not None and a.cm is not None, "one restore-check CronJob and its ConfigMap rendered")
        if a.rc is None or a.cm is None:
            continue
        md, spec, job = a.rc["metadata"], a.rc["spec"], a.rc["spec"]["jobTemplate"]["spec"]
        pod, cron_pod = a.pod, a.cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        say(t, md["name"] == a.cname + "-restore-check" and len(md["name"]) <= 52 and md["namespace"] == a.ns, "name <cronjob>-restore-check in the backup's namespace")
        say(t, "homelab.io/backup" not in md.get("labels", {}) and md["labels"].get("homelab.io/restore-check") == "true", "own label, not the backup label (the backup alert stays exact)")
        say(t, a.cm["metadata"]["namespace"] == a.ns and set(a.cfg) <= RC_KEYS, "ConfigMap in the namespace, known keys only")
        say(t, schedule_window(spec["schedule"], spec["startingDeadlineSeconds"], job["activeDeadlineSeconds"]), f"weekly form, outside the excluded hours also when started late ({spec['schedule']})")
        say(t, spec.get("timeZone") == "Etc/UTC", "schedule in UTC (timeZone declared)")
        say(t, spec["schedule"] not in seen_schedules, "schedule not shared with another check")
        seen_schedules.add(spec["schedule"])
        say(t, spec["concurrencyPolicy"] == "Forbid" and job["backoffLimit"] == 0 and job["activeDeadlineSeconds"] <= 3600 and spec["failedJobsHistoryLimit"] >= 1, "Forbid, no retry, deadline <= 3600 s, a failed Job is kept (KubeJobFailed)")
        say(t, "ttlSecondsAfterFinished" not in job, "no TTL (a failed Job stays until read)")
        say(t, pod.get("automountServiceAccountToken") is False and pod.get("enableServiceLinks") is False and "serviceAccountName" not in pod, "no service account token, no service links, default account")
        say(t, pod.get("nodeSelector") == cron_pod.get("nodeSelector"), "node selector of the backup")
        say(t, pod["restartPolicy"] == "Never" and "hostNetwork" not in pod and "hostPID" not in pod and "hostIPC" not in pod, "no host namespaces")
        psc = pod["securityContext"]
        say(t, psc.get("runAsNonRoot") is True and psc.get("seccompProfile", {}).get("type") == "RuntimeDefault" and "fsGroup" not in psc, "pod: non-root, RuntimeDefault, no fsGroup (no ownership change on the claim)")
        vols = {v["name"]: v for v in pod["volumes"]}
        say(t, vols["backup"]["persistentVolumeClaim"] == {"claimName": next(v for v in cron_pod["volumes"] if v["name"] == "backup")["persistentVolumeClaim"]["claimName"], "readOnly": True}, "the backup's claim, read-only at the source")
        say(t, all(set(v) == {"name", "emptyDir"} or v["name"] == "backup" for v in pod["volumes"]) and all("sizeLimit" in v["emptyDir"] for v in pod["volumes"] if "emptyDir" in v), "only the claim and size-limited emptyDirs (no Secret, ConfigMap or host volume)")
        image = cron_pod["containers"][0]["image"]
        readers = []
        budget = int(a.env(a.pod["containers"][0]).get("RC_SCRATCH_MIB", "0"))
        tmp_mib = mib(vols.get("tmp", {}).get("emptyDir", {}).get("sizeLimit"))
        say(t, tmp_mib is not None and (mib(vols.get("scratch", {}).get("emptyDir", {}).get("sizeLimit")) or 0) >= budget > 0, "scratch size limit covers the scratch budget")
        for c in a.containers():
            ct = f"{t} container {c['name']}:"
            sc = c.get("securityContext", {})
            say(ct, sc.get("allowPrivilegeEscalation") is False and sc.get("readOnlyRootFilesystem") is True and sc.get("capabilities") == {"drop": ["ALL"]} and "privileged" not in sc, "restricted: no escalation, read-only root, all capabilities dropped")
            r = c.get("resources", {})
            say(ct, all(k in r.get("requests", {}) and k in r.get("limits", {}) for k in ("cpu", "memory", "ephemeral-storage")), "cpu, memory and ephemeral-storage requests and limits")
            req, lim = mib(r.get("requests", {}).get("ephemeral-storage")), mib(r.get("limits", {}).get("ephemeral-storage"))
            say(ct, req is not None and lim is not None and req >= budget + (tmp_mib or 0) + 64 and lim >= req, "ephemeral-storage request reserves the scratch budget, /tmp and overhead; limit above it")
            say(ct, c.get("terminationMessagePolicy") == "File", "termination message only from the file")
            say(ct, c["image"] == image and re.search(r":[^@/]+@sha256:[0-9a-f]{64}$", image) is not None, "the backup's pinned image (same engine version)")
            say(ct, not any("valueFrom" in e for e in c.get("env", [])) and c.get("envFrom") == [{"configMapRef": {"name": "restore-check"}}], "no secret reference, settings only from the ConfigMap")
            mounts = {m["name"]: m for m in c.get("volumeMounts", [])}
            if "backup" in mounts:
                readers.append(c)
                say(ct, mounts["backup"].get("readOnly") is True and "subPath" not in mounts["backup"], "claim mounted read-only")
                say(ct, sc.get("runAsUser", psc.get("runAsUser")) == cron_pod["securityContext"]["runAsUser"], "reads as the backup's user")
            say(ct, all(m["name"] in vols for m in mounts.values()), "mounts only pod volumes")
        say(t, len(readers) == 1, "exactly one container mounts the claim")
        if a.backend == "pg":
            say(t, [c["name"] for c in pod["initContainers"]] == ["select"] and [c["name"] for c in pod["containers"]] == ["restore"], "select (init) then restore")
            say(t, pod["initContainers"][0]["args"][0] == pod["containers"][0]["args"][0] and [c["args"][1:] for c in a.containers()] == [["restore-check", "select"], ["restore-check", "restore"]], "both containers run the same script in their mode")
            say(t, pod["containers"][0].get("securityContext", {}).get("runAsUser", psc["runAsUser"]) == 26 and pod["initContainers"][0]["securityContext"].get("runAsGroup") == 26, "restore as the postgres user, hand-off group shared")
            script = pod["containers"][0]["args"][0]
            restores = [x for x in script.splitlines() if re.search(r"\bpg_restore\b.* -d ", x)]
            say(t, len(restores) == 1 and " -U rc_restore " in restores[0] and "--no-owner" in restores[0] and "--no-privileges" in restores[0], "the archive is restored by the restore role only, without owners and privileges")
            say(t, len(restores) == 1 and script.index("phase=lockdown") < script.index(restores[0]), "the superuser login is removed before the archive is read into the server")
        else:
            say(t, "initContainers" not in pod and len(pod["containers"]) == 1, "one container")
            say(t, psc["runAsUser"] == cron_pod["securityContext"]["runAsUser"] and psc["runAsGroup"] == cron_pod["securityContext"]["runAsGroup"], "the backup's user and group")
        scripts.setdefault(a.backend, set()).add(pod["containers"][0]["args"][0])
        labels = a.rc["spec"]["jobTemplate"]["spec"]["template"]["metadata"]["labels"]
        pols = [d for d in a.docs if d["kind"] in ("CiliumNetworkPolicy", "NetworkPolicy")]
        # allow policies of the namespace may select the pods too (an empty selector selects all): a deny rule takes precedence over them
        own = next((p for p in pols if p["metadata"]["name"] == "restore-check" and p["kind"] == "CiliumNetworkPolicy"), None)
        say(t, own is not None and own["metadata"].get("namespace") == a.ns and selects(own["spec"].get("endpointSelector"), labels), "the own deny policy selects the pods")
        say(t, own is not None and own["spec"].get("ingressDeny") == [{"fromEntities": ["all"]}] and own["spec"].get("egressDeny") == [{"toEntities": ["all"]}], "deny policy: all ingress and all egress denied")
        say(t, a.hooks == [] and not any(d["kind"] in ("BackupHookSource", "ServiceAccount", "Role", "RoleBinding") for d in a.docs), "no hook Job and no local-config object renders: the restore check reads the backup hook source only")
    for b, s in scripts.items():
        say("STATIC " + b + ":", len(s) == 1, "one shared script for every application")


# ---------------------------------------------------------------- synthetic data (also run inside helper containers)
def sha_line(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return f"{h.hexdigest()}  {os.path.basename(path)}\n"


def rehash(path):
    with open(path + ".sha256", "w") as f:
        f.write(sha_line(path))


def sqlite_fixture(data, dbfile, tables, extra, sentinel, key):
    """application data directory: the database (WAL mode, as the applications run it) and other files"""
    os.makedirs(data, exist_ok=True)
    con = sqlite3.connect(os.path.join(data, dbfile))
    con.execute("pragma journal_mode=wal")
    for t in tables or ["items"]:
        # rows go into a fixed name first; only the rename carries the identifier of the settings
        con.execute("create table rc_fill (id integer primary key, note text)")
        con.executemany("insert into rc_fill (note) values (?)", [(f"{sentinel} row {i}",) for i in range(3)])
        con.execute(f'alter table rc_fill rename to "{t}"')
    con.commit()
    con.close()
    os.makedirs(os.path.join(data, "files"), exist_ok=True)
    with open(os.path.join(data, "files", sentinel + ".txt"), "w") as f:
        f.write(sentinel + "\n")
    if extra == "n8n-config":
        with open(os.path.join(data, "config"), "w") as f:
            json.dump({"encryptionKey": key}, f)
    if extra == "chroma":
        os.makedirs(os.path.join(data, "vector_db"), exist_ok=True)
        os.makedirs(os.path.join(data, "cache"), exist_ok=True)
        c = sqlite3.connect(os.path.join(data, "vector_db", "chroma.sqlite3"))
        c.execute("create table embeddings (id integer primary key, doc text)")
        c.execute("insert into embeddings (doc) values (?)", (sentinel,))
        c.commit()
        c.close()


def newest(d, prefix, ext):
    sets = sorted(n[: -len(ext) - 1] for n in os.listdir(d) if re.fullmatch(re.escape(prefix) + r"[0-9]{8}T[0-9]{6}Z\." + re.escape(ext), n))
    return sets[-1]


def mutate(op, d, prefix, ext, arg=""):
    """damages the newest set of a directory the way a test case needs it"""
    base = os.path.join(d, newest(d, prefix, ext))
    p = f"{base}.{ext}"
    if op == "wrong-hash":
        with open(p + ".sha256", "w") as f:
            f.write(hashlib.sha256(b"other").hexdigest() + f"  {os.path.basename(p)}\n")
    elif op == "remove":
        os.remove(f"{base}.{arg}")
    elif op == "truncate":
        with open(p, "rb") as f:
            data = f.read()
        with open(p, "wb") as f:
            f.write(data[: len(data) * 6 // 10])
        rehash(p)
    elif op == "corrupt-db":
        with open(p, "rb") as f:
            raw = gzip.decompress(f.read())
        raw = b"not a database!!" + raw[16:]
        with open(p, "wb") as f:
            f.write(gzip.compress(raw))
        rehash(p)
    elif op in ("tar-drop", "tar-badname"):
        buf = io.BytesIO()
        with tarfile.open(p, "r:gz") as src, tarfile.open(fileobj=buf, mode="w:gz") as out:
            for m in src.getmembers():
                if op == "tar-drop" and (m.name == arg or m.name.startswith(arg + "/")):
                    continue
                out.addfile(m, src.extractfile(m) if m.isreg() else None)
            if op == "tar-badname":
                info = tarfile.TarInfo("bad\x01name")
                info.size = 1
                out.addfile(info, io.BytesIO(b"x"))
        with open(p, "wb") as f:
            f.write(buf.getvalue())
        rehash(p)
    elif op == "symlink":
        os.rename(p, p + ".real")
        os.symlink(os.path.basename(p) + ".real", p)
    elif op == "manifest-bad":
        with open(f"{base}.{arg}", "a") as f:
            f.write(hashlib.sha256(b"x").hexdigest() + "  bad\x01name\n")
    elif op == "sidecar":
        with open(f"{base}.{arg}", "w") as f:
            f.write("not a number\n")
    elif op == "age":
        old = os.path.basename(base)
        new = old[: -len("YYYYmmddTHHMMSSZ")] + arg
        for n in sorted(os.listdir(d)):
            if n.startswith(old + "."):
                os.rename(os.path.join(d, n), os.path.join(d, new + n[len(old):]))
                if n.endswith(".sha256"):
                    q = os.path.join(d, new + n[len(old):])
                    with open(q) as f:
                        text = f.read().replace(old, new)
                    with open(q, "w") as f:
                        f.write(text)
    else:
        raise SystemExit("unknown op")


def listing(d):
    return sorted(os.listdir(d)) if os.path.isdir(d) else []


def set_files(d):
    """entries of a claim directory without the hook directory and the backups' lock file"""
    return [n for n in listing(d) if n not in (".presync", ".partial-lock")]


# ---------------------------------------------------------------- result checks shared by HOST and ENGINE
def judge(tier, tag, res, term, want_ok, want_fail=None, expect=()):
    out, err = res["out"], res["err"]
    lines = out.splitlines()
    good = all(LINE.fullmatch(x) for x in lines) and err == ""
    say(tier, good, f"{tag}: only fixed output lines, nothing on stderr")
    leak = any(SENTINEL in s for s in (out, err, term))
    say(tier, not leak, f"{tag}: no synthetic data value in stdout, stderr or termination message")
    last = lines[-1] if lines else ""
    if want_ok:
        say(tier, res["rc"] == 0 and last.startswith("RESULT OK"), f"{tag}: RESULT OK, exit 0")
        for e in expect:
            say(tier, e in lines, f"{tag}: line `{e}`")
    else:
        say(tier, res["rc"] != 0, f"{tag}: nonzero exit ({res['rc']})")
        say(tier, f"FAIL {want_fail}" in lines and last.startswith("RESULT FAIL") and term == f"FAIL {want_fail}", f"{tag}: `FAIL {want_fail}` in output and termination message")


# ---------------------------------------------------------------- HOST: SQLite scripts with the local python3
def host_rewrite(text, t):
    text = text.replace('"/etc/hostname"', f'"{t}/hostname"').replace('"/dev/termination-log"', f'"{t}/term"')
    text = re.sub(r'"/backup', f'"{t}/claim', text)
    for p in ("/data", "/scratch", "/stage"):
        text = text.replace(f'"{p}"', f'"{t}{p}"').replace(f'"{p}/', f'"{t}{p}/')
    return text


def host_run(t, script, env, hostname="x"):
    with open(os.path.join(t, "hostname"), "w") as f:
        f.write(hostname + "\n")
    shutil.rmtree(os.path.join(t, "stage"), ignore_errors=True)
    os.makedirs(os.path.join(t, "stage"))
    if os.path.exists(os.path.join(t, "term")):
        os.remove(os.path.join(t, "term"))
    e = {"PATH": "/usr/bin:/bin", "HOME": t, "LC_ALL": "C"}
    e.update(env)
    p = subprocess.run([sys.executable, "-I", "-c", host_rewrite(script, t)], check=False, env=e, capture_output=True, text=True, timeout=300, cwd=t)
    term = ""
    if os.path.exists(os.path.join(t, "term")):
        with open(os.path.join(t, "term")) as f:
            term = f.read()
    return {"rc": p.returncode, "out": p.stdout, "err": p.stderr}, term


def sqlite_cases(a, run_check, mut, fresh):
    """the case list of one SQLite application; run_check(env) -> (res, term, scratch listing); mut(op, cls, ext, arg)"""
    rows = [f"OK rows nightly {x}=3" for x in a.tables] + [f"OK rows presync {x}=3" for x in a.tables]
    res, term, scr = run_check({})
    judge(a.tier, a.cname + " both classes", res, term, True, expect=rows + ([f"OK known nightly {a.known}=yes"] if a.known else []))
    say(a.tier, TERM_RESTORE.fullmatch(term) is not None and "presync=none" not in term, f"{a.cname} both classes: termination names both sets")
    want_rows = 3 * len(a.tables)
    say(a.tier, term.endswith(f" rows-nightly={want_rows} rows-presync={want_rows}"), f"{a.cname} both classes: termination row totals are the listed tables' rows per class ({want_rows})")
    say(a.tier, scr == [], f"{a.cname} both classes: scratch empty afterwards")
    if a.cfg.get("RC_EXTRA") == "n8n-config":
        say(a.tier, "OK extra nightly config=1" in res["out"], f"{a.cname}: key file found and well-formed (not printed)")
    if a.cfg.get("RC_EXTRA") == "chroma":
        say(a.tier, "OK extra nightly vector-tables=1" in res["out"], f"{a.cname}: vector database extracted and checked")
    if a.cname != "n8n-backup":
        cases = [("wrong-hash", "nightly", "db.gz", "", "checksum nightly", {})]
        if a.cfg.get("RC_EXTRA") == "chroma":
            cases.append(("tar-drop", "nightly", "tar.gz", "vector_db", "extra nightly", {}))
    else:
        cases = [
            ("wrong-hash", "nightly", "db.gz", "", "checksum nightly", {}),
            ("wrong-hash", "presync", "tar.gz", "", "checksum presync", {}),
            ("remove", "nightly", "db.gz", "tar.gz.sha256", "incomplete nightly", {"RC_GRACE_SECONDS": "0"}),
            ("truncate", "nightly", "db.gz", "", "gzip nightly", {}),
            ("truncate", "nightly", "tar.gz", "", "gzip nightly", {}),
            ("corrupt-db", "nightly", "db.gz", "", "sqlite nightly", {}),
            ("tar-drop", "nightly", "tar.gz", "config", "extra nightly", {}),
            ("tar-badname", "nightly", "tar.gz", "", "tar nightly", {}),
            ("age", "nightly", "db.gz", "20200101T000000Z", "stale nightly", {}),
            ("none", "nightly", "db.gz", "", "noset nightly", {}),
        ]
    for op, cls, ext, arg, want, env in cases:
        fresh()
        mut(op, cls, ext, arg)
        res, term, scr = run_check(env)
        judge(a.tier, f"{a.cname} {op} {ext} {cls}", res, term, False, want)
        say(a.tier, scr == [], f"{a.cname} {op} {cls}: scratch empty after the failure")
    # a set that is still being written (newest, incomplete, younger than the grace time) is skipped, the complete one before it is used
    if a.cname == "n8n-backup":
        fresh(extra_nightly=True)
        mut("remove", "nightly", "db.gz", "tar.gz.sha256")
        res, term, scr = run_check({})
        judge(a.tier, f"{a.cname} in-progress newest set", res, term, True, expect=rows[:1])
        fresh(no_presync=True)
        res, term, scr = run_check({})
        judge(a.tier, f"{a.cname} no hook sets", res, term, True, expect=["OK select presync none=1"])
        say(a.tier, TERM_RESTORE.fullmatch(term) is not None and term.endswith(" presync=none rows-nightly=" + str(3 * len(a.tables)) + " rows-presync=none"), f"{a.cname} no hook sets: termination says presync=none and no hook rows")


def host_tests(apps):
    for a in [x for x in apps if x.backend == "sqlite"]:
        a.tier = "HOST"
        t = tempfile.mkdtemp(prefix="rc-host-")
        try:
            host_one(a, t)
        except Exception:  # noqa: BLE001 (reported by its fixed phase only: an exception text can hold data)
            say("HOST", False, f"{a.cname}: setup failed at phase {STEP['phase']}")
        finally:
            shutil.rmtree(t, ignore_errors=True)


def layout_cases(a, t, fresh, run_check, tier):
    """an optional class directory that exists as anything but a directory is a layout failure; a truly absent one only means none"""
    for kind in ("regular file", "symlink to a directory"):
        fresh()
        p = os.path.join(t, "claim", ".presync")
        shutil.rmtree(p)
        if kind == "regular file":
            with open(p, "w") as f:
                f.write("x")
        else:
            os.symlink(os.path.join(t, "claim"), p)
        res, term, scr = run_check({})
        judge(tier, f"{a.cname} hook class entry is a {kind}", res, term, False, "layout presync")
        say(tier, scr == [], f"{a.cname} hook class entry is a {kind}: scratch empty after the failure")


def host_one(a, t):
    key = secrets.token_hex(16) + SENTINEL
    cron_c = a.cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]
    hook_c = cron_c  # the hook run of the producer is a Job copied from the CronJob: same script
    check_c = a.pod["containers"][0]

    def fresh(extra_nightly=False, no_presync=False):
        for d in ("claim", "data", "scratch"):
            shutil.rmtree(os.path.join(t, d), ignore_errors=True)
        os.makedirs(os.path.join(t, "claim"), mode=0o700)
        os.makedirs(os.path.join(t, "scratch"), mode=0o700)
        sqlite_fixture(os.path.join(t, "data"), a.dbfile, a.tables, a.cfg.get("RC_EXTRA"), SENTINEL, key)
        for i in range(2 if extra_nightly else 1):
            if i:
                time.sleep(1.1)  # the next set needs a later second in its name
            step("backup fixture")
            r, _ = host_run(t, fixed_clock(cron_c["args"][0]), {}, hostname=a.cname + "-29000000-abcde")
            if r["rc"] != 0:
                raise RuntimeError("backup script failed in the fixture")
        if not no_presync:
            # the hook creates its own directory below the claim root, after taking the lock
            step("hook fixture")
            r, _ = host_run(t, fixed_clock(hook_c["args"][0]), {}, hostname=a.cname + "-presync-run-abcde")
            if r["rc"] != 0:
                raise RuntimeError("hook script failed in the fixture")

    def mut(op, cls, ext, arg):
        d = os.path.join(t, "claim") if cls == "nightly" else os.path.join(t, "claim", ".presync")
        if op == "none":
            for n in set_files(d):
                os.remove(os.path.join(d, n))
            return
        mutate(op, d, a.prefix, ext, arg)

    def run_check(env):
        res, term = host_run(t, check_c["args"][0], a.env(check_c, **env))
        return res, term, listing(os.path.join(t, "scratch"))

    fresh()
    layout_cases(a, t, fresh, run_check, "HOST")
    fresh()
    say("HOST", set_files(os.path.join(t, "claim")) == sorted(f"{newest(os.path.join(t, 'claim'), a.prefix, 'db.gz')}.{e}" for e in ("db.gz", "db.gz.sha256", "tar.gz", "tar.gz.sha256")), f"{a.cname}: the real backup script wrote one set of the expected names")
    sqlite_cases(a, run_check, mut, fresh)


# ---------------------------------------------------------------- HOST: the select half of the pg_dump check with local bash
GNU = {"date": "gdate", "stat": "gstat", "sha256sum": "gsha256sum", "df": "gdf", "du": "gdu", "cut": "gcut", "paste": "gpaste", "sort": "gsort", "wc": "gwc", "head": "ghead"}


def gnu_shims(t):
    """the script needs GNU coreutils: on Linux the tools themselves, elsewhere the g-prefixed ones"""
    b = os.path.join(t, "bin")
    os.makedirs(b, exist_ok=True)
    for name, g in GNU.items():
        found = shutil.which(name) if sys.platform.startswith("linux") else shutil.which(g)
        if not found:
            return None
        os.symlink(found, os.path.join(b, name))
    return b


def pg_set(d, prefix, stamp, a):
    """a synthetic pg_dump set in the names and formats the backup script writes (the dump content is not a real archive here)"""
    name = f"{prefix}{stamp}"
    with open(f"{d}/{name}.dump", "wb") as f:
        f.write(b"PGDMP" + SENTINEL.encode() + secrets.token_bytes(2048))
    rehash(f"{d}/{name}.dump")
    for ext, _ in a.counts:
        with open(f"{d}/{name}.{ext}", "w") as f:
            f.write("3\n")
    if a.cfg.get("RC_MANIFEST"):
        with open(f"{d}/{name}.{a.cfg['RC_MANIFEST']}", "w") as f:
            f.write("".join(f"{hashlib.sha256(str(i).encode()).hexdigest()}  {SENTINEL} file {i}.png\n" for i in range(2)))
    for n in listing(d):
        if n.startswith(name + "."):
            os.chmod(os.path.join(d, n), 0o600)  # as the backup scripts write them (umask 077)


def host_pg_run(t, a, mode, env):
    c = a.pod["initContainers"][0] if mode == "select" else a.pod["containers"][0]
    script = c["args"][0].replace("/dev/termination-log", t + "/term")
    script = re.sub(r"(?<![\w.])/(backup|scratch)", lambda m: t + ("/claim" if m.group(1) == "backup" else "/scratch"), script)
    if os.path.exists(t + "/term"):
        os.remove(t + "/term")
    e = {"PATH": t + "/bin:/usr/bin:/bin", "HOME": t}
    e.update(a.env(c, **env))
    p = subprocess.run(["bash", "-c", script, "restore-check", mode], check=False, env=e, capture_output=True, text=True, timeout=120, cwd=t)
    term = ""
    if os.path.exists(t + "/term"):
        with open(t + "/term") as f:
            term = f.read()
    return {"rc": p.returncode, "out": p.stdout, "err": p.stderr}, term


def host_pg_one(a, t):
    tier = "HOST"
    if gnu_shims(t) is None:
        say(tier, False, f"{a.cname}: GNU coreutils not found, the select tests did not run")
        return
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())

    def fresh(no_presync=False, older=False):
        for d in ("claim", "scratch"):
            shutil.rmtree(os.path.join(t, d), ignore_errors=True)
        os.makedirs(t + "/claim/.presync", mode=0o700)
        os.makedirs(t + "/scratch", mode=0o700)
        if older:
            pg_set(t + "/claim", a.prefix, "20200101T000000Z", a)
        pg_set(t + "/claim", a.prefix, stamp, a)
        if not no_presync:
            pg_set(t + "/claim/.presync", a.prefix, stamp, a)

    def run_check(env):
        res, term = host_pg_run(t, a, "select", env)
        return res, term, listing(t + "/scratch")

    fresh()
    res, term, scr = run_check({})
    expect = ["RESULT OK select", "OK select presync set=" + a.prefix + stamp + f" age-hours=0 bytes={5 + len(SENTINEL) + 2048}"]
    judge(tier, a.cname + " select both classes", res, term, True, expect=expect)
    hand = sorted(listing(t + "/scratch/in/nightly"))
    say(tier, hand == sorted(["dump", "set", "sha"] + [e for e, _ in a.counts] + (["manifest"] if a.cfg.get("RC_MANIFEST") else [])), f"{a.cname}: hand-off holds the dump copy, its hash and the sidecar values only")
    # the claim's files are 0600; the restore container is another user of the same group
    modes = {n: os.stat(os.path.join(t, "scratch/in/nightly", n)).st_mode & 0o7777 for n in hand}
    dirs = [os.stat(t + "/scratch/in").st_mode & 0o7777, os.stat(t + "/scratch/in/nightly").st_mode & 0o7777]
    say(tier, modes.get("dump") == 0o640 and all(m & 0o040 and not m & 0o007 for m in modes.values()) and dirs == [0o770, 0o770], f"{a.cname}: hand-off group-readable (dump 0640, directories 0770), nothing for others")
    if a.cfg.get("RC_MANIFEST"):
        with open(t + "/scratch/in/nightly/manifest") as f:
            say(tier, f.read() == "2\n", f"{a.cname}: manifest hand-off is a line count, no names")
    say(tier, term == f"nightly={a.prefix}{stamp} presync={a.prefix}{stamp}", f"{a.cname}: termination names both sets")
    cases = [("wrong-hash", "nightly", "", "checksum nightly", {}), ("wrong-hash", "presync", "", "checksum presync", {})]
    if a.cname in ("penpot-pg-dump", "wiki-pg-dump"):
        side = a.counts[0][0]
        cases += [
            ("remove", "nightly", side, "incomplete nightly", {"RC_GRACE_SECONDS": "0"}),
            ("remove", "nightly", "dump.sha256", "incomplete nightly", {"RC_GRACE_SECONDS": "0"}),
            ("sidecar", "nightly", side, "sidecar nightly", {}),
            ("symlink", "nightly", "", "layout nightly", {}),
            ("age", "nightly", "20200101T000000Z", "stale nightly", {}),
            ("none", "nightly", "", "noset nightly", {}),
        ]
    if a.cfg.get("RC_MANIFEST"):
        cases.append(("manifest-bad", "nightly", a.cfg["RC_MANIFEST"], "manifest nightly", {}))
    for op, cls, arg, want, env in cases:
        fresh()
        d = t + "/claim" if cls == "nightly" else t + "/claim/.presync"
        if op == "none":
            for n in set_files(d):
                os.remove(os.path.join(d, n))
        else:
            mutate(op, d, a.prefix, "dump", arg)
        res, term, scr = run_check(env)
        judge(tier, f"{a.cname} select {op} {arg} {cls}", res, term, False, want)
        say(tier, scr == [], f"{a.cname} select {op} {cls}: scratch empty after the failure")
    if a.cname == "penpot-pg-dump":
        # newest set still being written (incomplete, inside the grace time): the complete one before it is used, never after damage
        fresh(older=True)
        mutate("remove", t + "/claim", a.prefix, "dump", "objects")
        res, term, scr = run_check({"RC_MAX_AGE_HOURS": "99999"})
        judge(tier, f"{a.cname} select in-progress newest", res, term, True, expect=[])
        say(tier, term.startswith(f"nightly={a.prefix}20200101T000000Z "), f"{a.cname}: the complete set before the one in progress is used")
        fresh(older=True)
        mutate("wrong-hash", t + "/claim", a.prefix, "dump")
        res, term, scr = run_check({"RC_MAX_AGE_HOURS": "99999"})
        judge(tier, f"{a.cname} select damaged newest with an older good set", res, term, False, "checksum nightly")
        layout_cases(a, t, fresh, run_check, tier)
        fresh(no_presync=True)
        shutil.rmtree(t + "/claim/.presync")
        res, term, scr = run_check({})
        judge(tier, f"{a.cname} select without hook directory", res, term, True, expect=["OK select presync none=1"])
        say(tier, term.endswith(" presync=none"), f"{a.cname}: termination says presync=none")
        shutil.rmtree(t + "/scratch/in")
        res, term = host_pg_run(t, a, "restore", {})
        judge(tier, f"{a.cname} restore without hand-off", res, term, False, "handoff nightly")
        fresh()
        res, term = host_pg_run(t, a, "select", {"RC_PREFIX": "Bad Prefix"})
        judge(tier, f"{a.cname} select with invalid settings", res, term, False, "config -")
        host_pg_restore_stub(a, t, fresh)


# stubs of the server tools for the restore half: they log what the script asks for and refuse what the locked-down server would refuse
STUBS = {
    "initdb": r"""while [ $# -gt 0 ]; do case $1 in -D) mkdir -p "$2"; shift ;; esac; shift; done
echo initdb >>"$STUB_DIR/log"
""",
    "pg_ctl": r"""d="" act=""
while [ $# -gt 0 ]; do case $1 in -D) d=$2; shift ;; -o|-m|-t) shift ;; start|stop|reload) act=$1 ;; esac; shift; done
echo "pg_ctl $act" >>"$STUB_DIR/log"
case $act in
  start) : >"$d/postmaster.pid"; rm -f "$STUB_DIR/reloaded" ;;
  stop) rm -f "$d/postmaster.pid" ;;
  reload) if [ "$(cat "$d/pg_hba.conf")" = "local rc rc_restore trust" ]; then : >"$STUB_DIR/reloaded"; fi ;;
esac
""",
    "psql": r"""u="" d="" c=""
while [ $# -gt 0 ]; do case $1 in -U) u=$2; shift ;; -d) d=$2; shift ;; -c) c=$2; shift ;; esac; shift; done
if [ -f "$STUB_DIR/reloaded" ] && [ -z "${STUB_NO_LOCKDOWN-}" ] && { [ "$u" != rc_restore ] || [ "$d" != rc ]; }; then
  echo "psql $u $d refused" >>"$STUB_DIR/log"; exit 2
fi
echo "psql $u $d ${c%% *}" >>"$STUB_DIR/log"
case $c in
  "select (rolsuper"*) echo 0 ;;
  *coalesce*) echo 9 ;;
  *"from pg_tables where tableowner"*) echo 3 ;;
  *"from pg_extension"*) echo "${STUB_EXTCOUNT:-0}" ;;
  "select exists"*) echo t ;;
  *"is null") echo 2 ;;
  "select count(*) from public."*) echo 3 ;;
  "select 1") echo 1 ;;
esac
""",
    "pg_restore": r"""l=0 list="" u=""
while [ $# -gt 0 ]; do case $1 in -l) l=1 ;; -L) list=$2; shift ;; -U) u=$2; shift ;; esac; shift; done
if [ "$l" = 1 ]; then
  printf '%s\n' ';' '2; 3079 16385 EXTENSION - plpgsql '
  for e in ${STUB_EXTS-}; do printf '%s\n' "3; 3079 16386 EXTENSION - $e "; done
  printf '%s\n' '216; 1259 16466 TABLE public items app'
  exit 0
fi
echo "pg_restore $u ext-lines=$(grep -c EXTENSION "$list")" >>"$STUB_DIR/log"
exit "${STUB_RESTORE_RC:-0}"
""",
}


def host_pg_restore_stub(a, t, fresh):
    """the restore half with stub server tools: order of setup, lockdown and restore, refusals, cleanup after a failure"""
    tier = "HOST"
    sd = t + "/stub"
    for name, body in STUBS.items():
        with open(f"{t}/bin/{name}", "w") as f:
            f.write("#!/bin/bash\nset -u\n" + body)
        os.chmod(f"{t}/bin/{name}", 0o700)

    def go(env, between=None):
        fresh()
        shutil.rmtree(sd, ignore_errors=True)
        os.makedirs(sd)
        open(sd + "/log", "w").close()
        e = {"STUB_DIR": sd, **env}
        r1, term = host_pg_run(t, a, "select", e)
        if r1["rc"] != 0:
            return r1, term, []
        if between:
            between()
        r2, term = host_pg_run(t, a, "restore", e)
        with open(sd + "/log") as f:
            log = f.read().splitlines()
        return {"rc": r2["rc"], "out": r1["out"] + r2["out"], "err": r1["err"] + r2["err"]}, term, log

    res, term, log = go({"STUB_EXTS": "pg_trgm", "STUB_EXTCOUNT": "1", "RC_EXTENSIONS": "uuid-ossp,pg_trgm"})
    judge(tier, f"{a.cname} restore (stub server)", res, term, True, expect=["RESULT OK restore"])
    segs = []  # one server per class
    for x in log:
        if x == "initdb":
            segs.append([])
        if segs:
            segs[-1].append(x)

    def split(seg):
        rl = seg.index("pg_ctl reload") if "pg_ctl reload" in seg else len(seg)
        return seg[:rl], seg[rl:]

    say(tier, len(segs) == 2 and all(pre.count("psql postgres rc create") == 1 and pre.count("psql postgres postgres create") == 2 for pre, _ in map(split, segs)), f"{a.cname}: role, database and the one allowed extension of the dump created by the superuser before the lockdown")
    say(tier, len(segs) == 2 and all(post.count("pg_restore rc_restore ext-lines=0") == 1 and not any(x.startswith("pg_restore") for x in pre) for pre, post in map(split, segs)), f"{a.cname}: archive restored by the restore role, without extension entries, only after the lockdown (one hba line)")
    say(tier, len(segs) == 2 and all("psql postgres rc refused" in post and all(x.endswith(" refused") for x in post if x.startswith(("psql postgres ", "psql rc_restore postgres"))) for _, post in map(split, segs)), f"{a.cname}: no superuser session after the lockdown")
    say(tier, listing(t + "/scratch") == [], f"{a.cname} restore (stub server): scratch empty")

    def tamper():
        with open(t + "/scratch/in/nightly/dump", "ab") as f:
            f.write(b"x")

    for tag, env, between, want in [
        ("extension not allowed", {"STUB_EXTS": "pg_trgm"}, None, "extensions nightly"),
        ("superuser still connects", {"STUB_NO_LOCKDOWN": "1"}, None, "lockdown nightly"),
        ("restore error", {"STUB_RESTORE_RC": "1"}, None, "restore nightly"),
        ("hand-off changed", {}, tamper, "checksum nightly"),
    ]:
        res, term, log = go(env, between)
        judge(tier, f"{a.cname} restore (stub server) {tag}", res, term, False, want)
        say(tier, listing(t + "/scratch") == [] and ("pg_ctl start" not in log or log[-1] == "pg_ctl stop"), f"{a.cname} restore (stub server) {tag}: server stopped, scratch empty")
        if want == "extensions nightly":
            say(tier, not any(x.startswith(("initdb", "psql", "pg_restore rc_restore")) for x in log), f"{a.cname}: a dump with an extension not allowed is refused before any server exists")


def host_pg_tests(apps):
    for a in [x for x in apps if x.backend == "pg"]:
        t = tempfile.mkdtemp(prefix="rc-host-pg-")
        try:
            host_pg_one(a, t)
        except Exception:  # noqa: BLE001 (reported by its fixed phase only)
            say("HOST", False, f"{a.cname}: setup failed at phase {STEP['phase']}")
        finally:
            shutil.rmtree(t, ignore_errors=True)


# ---------------------------------------------------------------- ENGINE: pinned images with docker
LABEL = "homelab-restore-check-test"
BASE = ["--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--pids-limit", "256", "--memory", "1g", "--label", LABEL]
PY_IMAGE = None  # the pinned python image of the SQLite backups; it also runs the helper
CTMP = "/tmp"  # noqa: S108, RUF100 (a path inside the test containers, never on the host)
SENTINEL_LINE = 'SENTINEL = "rcsentinel" + secrets.token_hex(8)'
# notes of the docker client itself about limits the host kernel cannot apply; anything else on stderr counts
DOCKER_NOTE = re.compile(r"WARNING: Your kernel does not support [a-zA-Z ]+ (capabilities|limit)[a-zA-Z ,.-]*")


def docker(*args, check=True, timeout=600, input=None):
    # docker's own output is never printed: a failed command's message can carry a value
    p = subprocess.run(["docker", *args], check=False, capture_output=True, text=True, timeout=timeout, input=input)
    if check and p.returncode != 0:
        raise RuntimeError("docker failed")
    return p


def local_unix(host):
    """a docker endpoint on this machine: a unix socket path, never tcp, ssh, npipe or a relative path"""
    return re.fullmatch(r"unix:///[^\s]+", host or "") is not None


def docker_ok():
    """the engine the tests use: reached through a local unix socket, running Linux (native volume ownership)"""
    try:
        host = os.environ.get("DOCKER_HOST") or docker("context", "inspect", "--format", "{{.Endpoints.docker.Host}}", check=False, timeout=30).stdout.strip()
        if not local_unix(host):
            return False
        return docker("version", "--format", "{{.Server.Os}}", check=False, timeout=30).stdout.strip() == "linux"
    except (OSError, subprocess.TimeoutExpired):
        return False


def image_present(ref):
    """the pinned image is present under its exact digest (only repository@digest names are listed, nothing of its config)"""
    m = re.fullmatch(r"(.+?)(:[^:/@]+)?@(sha256:[0-9a-f]{64})", ref)
    if m is None:
        raise RuntimeError("image reference without digest")
    out = docker("image", "ls", "--digests", "--no-trunc", "--format", "{{.Repository}}@{{.Digest}}", m.group(1)).stdout
    return f"{m.group(1)}@{m.group(3)}" in out.split()


class Engine:
    """volumes, networks and containers of one application's tests, all removed at the end"""

    def __init__(self):
        self.id = "rct-" + secrets.token_hex(4)
        self.vols, self.nets, self.ctrs, self.n = [], [], [], 0
        self.tmp = tempfile.mkdtemp(prefix="rc-engine-")

    def name(self, kind):
        self.n += 1
        return f"{self.id}-{kind}-{self.n}"

    def volume(self, kind, owner, mode):
        """a named local volume whose root gets the owner and mode of this test (a root container that may only chown sets them)"""
        v = self.name(kind)
        docker("volume", "create", "--label", LABEL, v)
        self.vols.append(v)
        c = self.name("setup")
        self.ctrs.append(c)
        docker("run", "--rm", "--name", c, "--network", "none", "--read-only", "--cap-drop", "ALL", "--cap-add", "CHOWN", "--security-opt", "no-new-privileges",
               "--label", LABEL, "--user", "0:0", "--entrypoint", "/bin/sh", "--mount", f"type=volume,src={v},dst=/v", PY_IMAGE,
               "-c", 'chmod "$1" /v && chown "$2" /v', "setup", mode, owner)
        return v

    def drop(self, vols):
        for v in list(vols):
            if docker("volume", "rm", "-f", v, check=False).returncode == 0 and v in self.vols:
                self.vols.remove(v)
        vols.clear()

    def network(self):
        n = self.name("net")
        docker("network", "create", "--internal", "--label", LABEL, n)
        self.nets.append(n)
        return n

    def envfile(self, env):
        p = os.path.join(self.tmp, secrets.token_hex(4) + ".env")
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            for k, v in env.items():
                if "\n" in v:
                    raise RuntimeError("multi-line env value")
                f.write(f"{k}={v}\n")
        return p

    def run(self, image, user, cmd, env=None, mounts=(), tmpfs=(CTMP,), net="none", alias=None, hostname=None, term=True, detach=False, stdin=None):
        """one container: cmd[0] is the entrypoint (as `command` in Kubernetes), only the given env (no host environment)"""
        name = self.name("ctr")
        self.ctrs.append(name)
        args = ["run", "-d" if detach else "--rm", "--name", name, "--network", net, *BASE, "--user", user, "--entrypoint", cmd[0]]
        if stdin is not None:
            args.append("-i")
        if alias:
            args += ["--network-alias", alias]
        for p in tmpfs:
            args += ["--tmpfs", f"{p}:rw,size=256m,mode=1777"]
        if hostname:
            args += ["--hostname", hostname]
        if env:
            args += ["--env-file", self.envfile(env)]
        tf = None
        if term:
            tf = os.path.join(self.tmp, secrets.token_hex(4) + ".term")
            open(tf, "w").close()
            # world-writable on purpose, so no owner mapping of the container user is assumed; it lies in the private 0700 directory of this run
            os.chmod(tf, 0o666)  # noqa: S103, RUF100
            args += ["--mount", f"type=bind,src={tf},dst=/dev/termination-log"]
        for m in mounts:
            args += ["--mount", m]
        p = docker(*args, image, *cmd[1:], check=False, timeout=900, input=stdin)
        termtext = ""
        if tf:
            with open(tf) as f:
                termtext = f.read()
        err = "".join(x + "\n" for x in p.stderr.splitlines() if not DOCKER_NOTE.fullmatch(x))
        return {"rc": p.returncode, "out": p.stdout, "err": err}, termtext

    def close(self):
        failed = [docker(*cmd, check=False).returncode for cmd in [("rm", "-f", c) for c in self.ctrs] + [("volume", "rm", "-f", v) for v in self.vols] + [("network", "rm", n) for n in self.nets]]
        shutil.rmtree(self.tmp, ignore_errors=True)
        if any(failed) or os.path.exists(self.tmp):
            say("ENGINE", False, "cleanup of the test containers, volumes or directory failed")


def vol(v, dst, ro=False, sub=None):
    m = f"type=volume,src={v},dst={dst}"
    if sub:
        m += f",volume-subpath={sub}"
    return m + (",readonly" if ro else "")


def uid(c, pod):
    sc, psc = c.get("securityContext", {}), pod["securityContext"]
    return f"{sc.get('runAsUser', psc['runAsUser'])}:{sc.get('runAsGroup', psc.get('runAsGroup', 0))}"


def helper(e, user, mounts, *args):
    """an operation of this file's helper_main in the pinned python image: the program and the sentinel arrive on stdin, never as arguments"""
    with open(os.path.abspath(__file__)) as f:
        src = f.read()
    src, n = re.subn("(?m)^" + re.escape(SENTINEL_LINE) + "$", lambda _: f"SENTINEL = {SENTINEL!r}", src)
    if n != 1:
        raise RuntimeError("sentinel line not found")
    res, _ = e.run(PY_IMAGE, user, ["python3", "-I", "-", "helper", *args], mounts=mounts, tmpfs=(), term=False, stdin=src)
    if res["rc"] != 0:
        raise RuntimeError("helper failed")
    return res["out"]


def pod_mounts(c, pod, pvcs, writable=()):
    """the container's mounts as in the manifest: claims from pvcs (pod volume name -> test volume, with read-only and subPath), emptyDirs as
    tmpfs; `writable` names claims mounted writable although the manifest says read-only"""
    vols = {v["name"]: v for v in pod["volumes"]}
    mounts, tmpfs = [], []
    for m in c.get("volumeMounts", []):
        v = vols[m["name"]]
        if "emptyDir" in v and "subPath" not in m:
            tmpfs.append(m["mountPath"])
        elif "persistentVolumeClaim" in v and m["name"] in pvcs:
            ro = (m.get("readOnly", False) or v["persistentVolumeClaim"].get("readOnly", False)) and m["name"] not in writable
            mounts.append(vol(pvcs[m["name"]], m["mountPath"], ro, m.get("subPath")))
        else:
            raise RuntimeError("volume of the manifest not provided by the test")
    return mounts, tmpfs


def backup_run(e, a, kind, pvcs, net="none"):
    """one run of the rendered backup (scheduled) or hook script with the manifest's user, mounts and plain env values"""
    pod = a.cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]  # the hook mode runs the same template, only the pod name differs
    c = pod["containers"][0]
    # a running application keeps the -wal and -shm files of its WAL database, which SQLite needs to open it read-only; the stopped
    # fixture has none, so the SQLite data claim is writable for the fixture runs (the claim of the sets stays as in the manifest)
    mounts, tmpfs = pod_mounts(c, pod, pvcs, writable=("data",) if a.backend == "sqlite" else ())
    env = {i["name"]: i["value"] for i in c.get("env", []) if "value" in i}
    host = a.cname + ("-presync-run-abcde" if kind == "hook" else "-29000000-abcde")
    res, _ = e.run(c["image"], uid(c, pod), c["command"] + [fixed_clock(c["args"][0])] + c["args"][1:], env=env, mounts=mounts, tmpfs=tmpfs, net=net, hostname=host)
    if res["rc"] != 0:
        raise RuntimeError("backup script failed in the fixture")


def source_state(e, user, claim):
    """names, modes, owners, sizes and times of the claim's entries (no content)"""
    return helper(e, user, [vol(claim, "/c", True)], "stat", "/c")


def engine_sqlite(a, e):
    cpod = a.cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    cc = cpod["containers"][0]
    user = uid(cc, cpod)
    dmount = next(m for m in cc["volumeMounts"] if m["name"] == "data")
    st, case = {}, []
    step("volumes")
    st["data"] = e.volume("data", user, "0750")
    golden = e.volume("golden", user, "0700")
    step("data fixture")
    helper(e, user, [vol(st["data"], "/w")], "sqlite-fixture", "/w/" + dmount["subPath"] if dmount.get("subPath") else "/w", a.dbfile, ",".join(a.tables), a.cfg.get("RC_EXTRA", "none"))
    step("golden backup")
    backup_run(e, a, "scheduled", {"data": st["data"], "backup": golden})
    step("golden hook")
    backup_run(e, a, "hook", {"data": st["data"], "backup": golden})

    def fresh(extra_nightly=False, no_presync=False):
        e.drop(case)
        step("case copy")
        st["claim"] = e.volume("claim", user, "0700")
        st["scratch"] = e.volume("scratch", "0:0", "0777")  # an emptyDir
        case.extend([st["claim"], st["scratch"]])
        helper(e, user, [vol(golden, "/g", True), vol(st["claim"], "/c")], "copy", "/g", "/c")
        if extra_nightly:
            time.sleep(1.1)  # the next set needs a later second in its name
            step("second backup")
            backup_run(e, a, "scheduled", {"data": st["data"], "backup": st["claim"]})
        if no_presync:
            helper(e, user, [vol(st["claim"], "/c")], "rmtree", "/c/.presync")

    def mut(op, cls, ext, arg):
        step("mutate")
        helper(e, user, [vol(st["claim"], "/c")], "mutate", op, "/c" if cls == "nightly" else "/c/.presync", a.prefix, ext, arg)

    first = [True]

    def run_check(env):
        c = a.pod["containers"][0]
        before = source_state(e, user, st["claim"]) if first[0] else ""
        res, term = e.run(c["image"], uid(c, a.pod), c["command"] + c["args"], env=a.env(c, **env), mounts=[vol(st["claim"], "/backup", True), vol(st["scratch"], "/scratch")])
        if first[0]:
            first[0] = False
            say(a.tier, before == source_state(e, user, st["claim"]) and before.count("\n") >= 8, f"{a.cname}: claim entries, modes and owners unchanged by the check")
        return res, term, helper(e, user, [vol(st["scratch"], "/s", True)], "ls", "/s").split()

    fresh()
    sqlite_cases(a, run_check, mut, fresh)


FILL_GONE = ("insert into public.rc_fill (note, rc_c0) values (:'s', now());", "insert into public.rc_fill (note, rc_c1) values (:'s', now());")


def pg_schema(a):
    """synthetic schema and rows of the tables the check expects; returns (sql, tables, rows, extensions)"""
    tables = list(dict.fromkeys(a.tables + ([a.known] if a.known else []) + [c.split(".")[0] for _, c in a.counts])) or ["items"]
    cols = {}
    for _, c in a.counts:
        t, col = c.split(".")
        cols.setdefault(t, []).append(col)
    exts = [x for x in a.cfg.get("RC_EXTENSIONS", "").split(",") if x]
    sql = [f'create extension if not exists "{x}";' for x in exts]
    # the tables belong to the application's role; rows go into a fixed name first (the sentinel is a psql variable), then the
    # identifiers of the settings are put in place by renames
    sql.append('set role :"u";')
    for t in tables:
        n = len(cols.get(t, []))
        sql.append("create table public.rc_fill (id bigint generated always as identity primary key, note text not null" + "".join(f", rc_c{i} timestamptz" for i in range(n)) + ");")
        sql.append("insert into public.rc_fill (note) select :'s' || ' ' || g from generate_series(1, 3) g;")
        sql.extend(FILL_GONE[i] for i in range(n))
        sql.extend(f'alter table public.rc_fill rename column rc_c{i} to "{c}";' for i, c in enumerate(cols.get(t, [])))
        sql.append(f'alter table public.rc_fill rename to "{t}";')
    sql.append("reset role;")
    rows = {t: 3 + len(cols.get(t, [])) for t in tables}
    return "\n".join(sql), tables, rows, len(exts)


# a second database whose archive needs a superuser (an event trigger): its restore must fail
PG_CRAFTED = r"""
create database rcx owner :"u";
\connect rcx
set role :"u";
create table public.rc_t (id int primary key, note text);
insert into public.rc_t values (1, :'s');
reset role;
create function public.rc_et() returns event_trigger language plpgsql as $$ begin end $$;
create event trigger rc_et on ddl_command_start execute function public.rc_et();
"""

# synthetic source: initialised and filled without a network (the SQL arrives on stdin), served later on the test's internal network;
# no credential exists, the backup script connects without one
PG_INIT = r"""
set -euo pipefail
exec >/dev/null 2>&1
initdb -D /src/data -U postgres -E UTF8 --locale=C --auth-local=trust --auth-host=trust --no-sync
printf 'local all all trust\nhost all all 0.0.0.0/0 trust\nhost all all ::/0 trust\n' >/src/data/pg_hba.conf
pg_ctl -D /src/data -w -t 60 -o "-c listen_addresses='' -c unix_socket_directories=/tmp" start
psql -X -q -v ON_ERROR_STOP=1 -h /tmp -U postgres -d postgres -f -
pg_ctl -D /src/data -w -t 60 -m fast stop
"""
PG_READY = 'for i in $(seq 150); do pg_isready -q -h "$1" -t 1 && exit 0; sleep 0.2; done; exit 1'
PG_CRAFT = 'set -euo pipefail; exec >/dev/null 2>&1; umask 077; cd /backup; n="$1$(date -u +%Y%m%dT%H%M%SZ).dump"; pg_dump -Fc -h "$2" -U "$3" -d rcx -f "$n"; sha256sum "$n" >"$n.sha256"'


def handoff_ok(listing_text, backup_uid):
    """the hand-off as the restore user sees it: written by the backup's user and group 26, group-readable, nothing for others"""
    ent = {}
    for line in listing_text.splitlines():
        rel, mode, u, g = line.split()[:4]
        ent[rel] = (int(mode, 8), u, g)
    files = {k: v for k, v in ent.items() if not v[0] & 0o040000}
    dirs = {k: v for k, v in ent.items() if v[0] & 0o040000}
    return (ent.get("nightly/dump", (0,))[0] & 0o7777 == 0o640 and len(files) >= 3 and len(dirs) >= 2
            and all(u == backup_uid and g == "26" and not m & 0o007 for m, u, g in ent.values())
            and all(m & 0o040 for m, _, _ in files.values()) and all(m & 0o7777 == 0o770 for m, _, _ in dirs.values()))


def engine_pg(a, e):
    cpod = a.cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    cc = cpod["containers"][0]
    image, user = cc["image"], uid(cc, cpod)
    m = re.search(r"pg_dump -Fc -h (\S+) -U (\S+) -d (\S+) ", cc["args"][0])
    if m is None:
        raise RuntimeError("pg_dump line of the backup script not found")
    host, dbuser, db = m.groups()
    sql, tables, rows, ext = pg_schema(a)
    crafted_case = a.cname == "juraticker-pg-dump"
    tier, st, case = "ENGINE", {}, []
    step("source init")
    src = e.volume("src", "26:26", "0700")
    head = f'create role "{dbuser}" login;\ncreate database "{db}" owner "{dbuser}";\n\\connect {db}\n\\set u \'{dbuser}\'\n\\set s \'{SENTINEL}\'\n'
    r, _ = e.run(image, "26:26", ["/bin/bash", "-c", PG_INIT, "pg-init"], mounts=[vol(src, "/src")], term=False, stdin=head + sql + "\n" + (PG_CRAFTED if crafted_case else ""))
    if r["rc"] != 0:
        raise RuntimeError("source init failed")
    step("source start")
    net = e.network()
    e.run(image, "26:26", ["postgres", "-D", "/src/data", "-c", "listen_addresses=*", "-c", "unix_socket_directories=/tmp"], mounts=[vol(src, "/src")], net=net, alias=host, term=False, detach=True)
    server = e.ctrs[-1]
    r, _ = e.run(image, "26:26", ["/bin/bash", "-c", PG_READY, "ready", host], net=net, term=False)
    if r["rc"] != 0:
        raise RuntimeError("source not ready")
    step("golden volumes")
    pvcs = {"backup": e.volume("golden", user, "0700")}
    if any(x["name"] == "data" for x in cc.get("volumeMounts", [])):
        pvcs["data"] = e.volume("data", user, "0750")
        step("files fixture")
        helper(e, user, [vol(pvcs["data"], "/w")], "files-fixture", "/w")
    golden = pvcs["backup"]
    step("golden backup")
    backup_run(e, a, "scheduled", pvcs, net=net)
    step("golden hook")
    backup_run(e, a, "hook", pvcs, net=net)
    crafted = None
    if crafted_case:
        step("crafted set")
        crafted = e.volume("crafted", user, "0700")
        r, _ = e.run(image, user, ["/bin/bash", "-c", PG_CRAFT, "craft", a.prefix, host, dbuser], env={"HOME": CTMP}, mounts=[vol(crafted, "/backup")], net=net, term=False)
        if r["rc"] != 0:
            raise RuntimeError("crafted set failed")
    docker("rm", "-f", server, check=False)

    def fresh(no_presync=False, source=None):
        e.drop(case)
        step("case copy")
        st["claim"] = e.volume("claim", user, "0700")
        st["scratch"] = e.volume("scratch", "0:0", "0777")  # an emptyDir
        case.extend([st["claim"], st["scratch"]])
        helper(e, user, [vol(source or golden, "/g", True), vol(st["claim"], "/c")], "copy", "/g", "/c")
        if no_presync:
            helper(e, user, [vol(st["claim"], "/c")], "rmtree", "/c/.presync")

    def mut(op, cls, ext_, arg):
        step("mutate")
        helper(e, user, [vol(st["claim"], "/c")], "mutate", op, "/c" if cls == "nightly" else "/c/.presync", a.prefix, ext_, arg)

    def run_check(env, between=None):
        init, main = a.pod["initContainers"][0], a.pod["containers"][0]
        res, term = e.run(init["image"], uid(init, a.pod), init["command"] + init["args"], env=a.env(init, **env), mounts=[vol(st["claim"], "/backup", True), vol(st["scratch"], "/scratch")])
        if res["rc"] == 0:
            if between:
                between()
            r2, term = e.run(main["image"], uid(main, a.pod), main["command"] + main["args"], env=a.env(main, **env), mounts=[vol(st["scratch"], "/scratch")])
            res = {"rc": r2["rc"], "out": res["out"] + r2["out"], "err": res["err"] + r2["err"]}
        scr = helper(e, "26:26", [vol(st["scratch"], "/s", True)], "ls", "/s").split()
        return res, term, scr

    fresh()
    seen = {}

    def inspect():
        # select ran as the backup's user, restore runs as 26:26 in another container: the copy must be readable through the group
        seen["handoff"] = helper(e, "26:26", [vol(st["scratch"], "/s", True)], "stat", "/s/in")

    before = source_state(e, user, st["claim"])
    expect = [f"OK rows {c} {t}={rows[t]}" for c in ("nightly", "presync") for t in a.tables]
    expect += [f"OK known {c} {a.known}=yes" for c in ("nightly", "presync") if a.known]
    expect += [f"OK sidecar {c} {s}={rows[t.split('.')[0]] - 1} restored={rows[t.split('.')[0]] - 1} match=yes" for c in ("nightly", "presync") for s, t in a.counts]
    res, term, scr = run_check({}, between=inspect)
    judge(tier, a.cname + " both classes", res, term, True, expect=expect + ["RESULT OK select", "RESULT OK restore"])
    say(tier, handoff_ok(seen.get("handoff", ""), user.split(":")[0]), f"{a.cname}: hand-off from {user.split(':')[0]}:26 readable by 26:26 (dump 0640, directories 0770, nothing for others)")
    say(tier, before == source_state(e, user, st["claim"]), f"{a.cname}: claim entries, modes and owners unchanged by the check")
    rl = [x for x in res["out"].splitlines() if x.startswith("OK restore nightly ")]
    say(tier, len(rl) == 1 and f" tables={len(tables)} rows={sum(rows.values())} extensions={ext} " in rl[0] + " ", f"{a.cname}: restored table, row and extension counts as written")
    say(tier, TERM_RESTORE.fullmatch(term) is not None and "presync=none" not in term, f"{a.cname}: termination names both sets")
    say(tier, term.endswith(f" rows-nightly={sum(rows.values())} rows-presync={sum(rows.values())}"), f"{a.cname}: termination row totals are all restored rows per class ({sum(rows.values())})")
    say(tier, scr == [], f"{a.cname}: scratch empty afterwards")
    if a.cfg.get("RC_MANIFEST"):
        say(tier, "OK assets nightly listed=2 in-set=0" in res["out"], f"{a.cname}: attachment manifest counted, files reported as outside the set")
    cases = [("wrong-hash", "nightly", "", "checksum nightly", {}), ("truncate", "nightly", "", "restore nightly", {})]
    if a.cfg.get("RC_EXTENSIONS"):
        cases.append(("keep", "nightly", "", "extensions nightly", {"RC_EXTENSIONS": ""}))
    if a.cname == "penpot-pg-dump":
        cases += [
            ("remove", "nightly", "objects", "incomplete nightly", {"RC_GRACE_SECONDS": "0"}),
            ("sidecar", "nightly", "count", "sidecar nightly", {}),
            ("truncate", "presync", "", "restore presync", {}),
            ("age", "nightly", "20200101T000000Z", "stale nightly", {}),
        ]
    for op, cls, arg, want, env in cases:
        fresh()
        if op != "keep":
            mut(op, cls, "dump", arg)
        res, term, scr = run_check(env)
        judge(tier, f"{a.cname} {op} {cls}", res, term, False, want)
        say(tier, scr == [], f"{a.cname} {op} {cls}: scratch empty after the failure")
    if a.cname == "penpot-pg-dump":
        # the copy in scratch changes between the two containers: the restore container hashes what it restores
        fresh()
        res, term, scr = run_check({}, between=lambda: helper(e, user.split(":")[0] + ":26", [vol(st["scratch"], "/s")], "tamper", "/s/in/nightly/dump"))
        judge(tier, f"{a.cname} hand-off changed before the restore", res, term, False, "checksum nightly")
        say(tier, scr == [], f"{a.cname} hand-off changed: scratch empty after the failure")
        fresh(no_presync=True)
        res, term, scr = run_check({})
        judge(tier, f"{a.cname} no hook sets", res, term, True, expect=["OK select presync none=1", "OK restore presync none=1"])
    if crafted is not None:
        # an archive whose restore needs a superuser fails: the restore role has none and the superuser cannot connect any more
        fresh(source=crafted)
        res, term, scr = run_check({})
        judge(tier, f"{a.cname} archive that needs a superuser", res, term, False, "restore nightly")
        say(tier, scr == [], f"{a.cname} superuser archive: scratch empty after the failure")
    e.drop(case)


def engine_tests(apps, everything):
    global PY_IMAGE
    PY_IMAGE = next(a for a in everything if a.backend == "sqlite").cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]["image"]
    try:
        step("images")
        for img in sorted({PY_IMAGE} | {a.cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]["image"] for a in apps}):
            if not image_present(img):
                docker("pull", img, timeout=1800)
    except Exception:  # noqa: BLE001 (reported by its fixed phase only)
        say("ENGINE", False, f"setup failed at phase {STEP['phase']}")
        return
    for a in apps:
        a.tier = "ENGINE"
        e = Engine()
        try:
            (engine_pg if a.backend == "pg" else engine_sqlite)(a, e)
        except Exception:  # noqa: BLE001 (reported by its fixed phase only: an exception text can hold data)
            say("ENGINE", False, f"{a.cname}: setup failed at phase {STEP['phase']}")
        finally:
            e.close()


# ---------------------------------------------------------------- helper entry (inside a helper container)
def helper_main(args):
    os.umask(0o077)
    op = args[0]
    if op == "sqlite-fixture":
        data, dbfile, tables, extra = args[1:5]
        # the key is made here and never leaves the container; the sentinel in it shows a leak
        sqlite_fixture(data, dbfile, [t for t in tables.split(",") if t], extra, SENTINEL, secrets.token_hex(16) + SENTINEL)
    elif op == "files-fixture":
        os.makedirs(os.path.join(args[1], "a"), exist_ok=True)
        for n in (SENTINEL + " one.png", "a/" + SENTINEL + " two.pdf"):
            with open(os.path.join(args[1], n), "w") as f:
                f.write(SENTINEL)
    elif op == "copy":
        shutil.copytree(args[1], args[2], symlinks=True, dirs_exist_ok=True)
    elif op == "rmtree":
        shutil.rmtree(args[1])
    elif op == "tamper":
        with open(args[1], "ab") as f:
            f.write(b"x")
    elif op == "mutate":
        if args[1] == "none":
            for n in set_files(args[2]):
                os.remove(os.path.join(args[2], n))
        else:
            mutate(args[1], args[2], args[3], args[4], args[5] if len(args) > 5 else "")
    elif op == "ls":
        print(" ".join(listing(args[1])))
    elif op == "stat":
        for root, dirs, files in os.walk(args[1]):
            for n in sorted(dirs + files):
                p = os.path.join(root, n)
                s = os.lstat(p)
                print(os.path.relpath(p, args[1]), oct(s.st_mode), s.st_uid, s.st_gid, s.st_size, s.st_mtime_ns)
    else:
        raise SystemExit("unknown helper")


def error_class(e):
    """a fixed class name for an uncaught error: its text and traceback can hold data and are never printed"""
    for kind, name in ((subprocess.CalledProcessError, "tool"), (subprocess.TimeoutExpired, "timeout"), (OSError, "os")):
        if isinstance(e, kind):
            return name
    return "check"


def main(argv):
    if argv[:1] == ["helper"]:
        helper_main(argv[1:])
        return 0
    try:
        return run_tests(argv)
    except (OSError, subprocess.SubprocessError, RuntimeError, ValueError, LookupError, AttributeError, TypeError, StopIteration) as e:  # a fixed class and phase only
        print(f"RESULT FAIL uncaught error class={error_class(e)} phase={STEP['phase']}")
        return 1


def run_tests(argv):
    tiers = {x for x in argv if x in ("static", "host", "engine")} or {"static", "host", "engine"}
    names = [x for x in argv if x not in ("static", "host", "engine")]
    everything = [App(*x) for x in APPS]
    apps = [a for a in everything if not names or a.cname in names or os.path.basename(a.path) in names]
    if any(not any(n in (a.cname, os.path.basename(a.path)) for a in everything) for n in names):
        print("RESULT FAIL unknown application name")
        return 2
    if "static" in tiers:
        static_checks(apps)
    if "host" in tiers:
        host_tests(apps)
        host_pg_tests(apps)
    skipped = ""
    if "engine" in tiers:
        if docker_ok():
            engine_tests(apps, everything)
        else:
            say("ENGINE", False, "no Linux docker daemon on a local unix socket: the pinned-image tests did not run")
            skipped = " engine=not-run"
    print(f"RESULT {'OK' if count['fail'] == 0 else 'FAIL'} ok={count['ok']} fail={count['fail']}{skipped}")
    return 0 if count["fail"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
