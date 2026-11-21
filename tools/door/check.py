#!/usr/bin/env python3
"""Checks of the publishing door (door.sh).

  check.py commits REPO RANGE_REV... [--all-mode] [--renovate PR_COMMITS.json] [--renovate-merged PROVEN.json] | bot-shas REPO REV... | tree REPO BASE TIP [--all] | text FILE... | ref NAME | merge-paths REPO BASE N | gitleaks REPORT.json
"""
import fnmatch
import json
import os
import posixpath
import re
import shlex
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

PERSONAL = "martin.huesgen@googlemail.com"
OWN = "18075479+izzetee@users.noreply.github.com"
WEBFLOW = "noreply" + "@github.com"
RENOVATE = "29139614+renovate[bot]" + "@users.noreply.github.com"
AUTHORS = {PERSONAL, OWN}
COMMITTERS = {PERSONAL, OWN, WEBFLOW}
OWNER = "Izzetee"
DOMAIN = "chill-town.de"

PATH_DENY = [
    ".env*", "*.tfstate*", "*.tfvars", "kubeconfig*", "*.pem", "*.key", "id_*", "*.dump", "*.sql*",
    "*.age", "*.p12", "*.pfx", "*.kdbx", "*.tar*", "*.tgz", "*.zip", "*.gz", "*.bz2", "*.xz", "*.zst", "*.7z", "*.jar",
]
BINARY_OK = re.compile(r"docs/.+\.(png|jpg|webp)$", re.IGNORECASE)
MAX_BLOB = 1024 * 1024
MAX_TEXT = 256 * 1024
ADDRESS = re.compile(r"(?<![0-9.])(?:10\.[0-9]{1,3}|172\.(?:1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}(?![0-9])")
GUARDED = ("AGENTS.md", ".agents/", "docs/", "tools/")
APP_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")

fails = 0
seen = set()
EXTRA_DOCS = []  # (label, document): what kustomize renders and the JSON resources, judged by the same route rules as the raw manifests


def safe(s):
    return re.sub(r"[^A-Za-z0-9._/@+=,:~-]", "?", s)[:200]


def fail(line):
    global fails
    if line in seen:
        return
    seen.add(line)
    fails += 1
    print("FAIL " + line)


def git(repo, *args, check=True):
    p = subprocess.run(["git", "-C", repo, *args], capture_output=True, check=False)
    if p.returncode != 0 and check:
        raise RuntimeError("git " + args[0] + " failed")
    return p.stdout


def guarded(path):
    return path == "AGENTS.md" or path.startswith(GUARDED[1:])


# ---- commits ---------------------------------------------------------------------------------------------------------------------
def verified_shas(path):
    """SHAs that GitHub reports as verified (`valid`) in the commit list of a PR (REST pulls/<n>/commits)."""
    with open(path, encoding="utf-8") as fh:
        rows = json.load(fh)
    return {r["sha"] for r in rows if isinstance(r, dict) and re.fullmatch(r"[0-9a-f]{40}", str(r.get("sha", "")))
            and ((r.get("commit") or {}).get("verification") or {}).get("verified") is True
            and ((r.get("commit") or {}).get("verification") or {}).get("reason") == "valid"}


def proven_merges(path):
    """sha -> set of merged_by logins of the commits the caller proved from the API (every PR opened by renovate[bot] and merged that carried it)."""
    with open(path, encoding="utf-8") as fh:
        rows = json.load(fh)
    out = {}
    for r in rows:
        if isinstance(r, dict) and re.fullmatch(r"[0-9a-f]{40}", str(r.get("sha", ""))):
            out.setdefault(r["sha"], set()).add(str(r.get("merged_by") or ""))
    return out


def bot_shas(repo, revs):
    """Every commit in revs whose author is the Renovate bot address, whatever the committer."""
    out = git(repo, "log", "--format=%H%x00%ae", *revs).decode("utf-8", "replace")
    return [line.split("\x00")[0] for line in out.splitlines() if line.split("\x00")[1:] and line.split("\x00")[1].strip().lower() == RENOVATE]


def check_commits(repo, revs, all_mode, verified=None, proven=None):
    out = git(repo, "log", "--format=%H%x00%ae%x00%ce%x00%B%x1e", *revs).decode("utf-8", "replace")
    n = 0
    for c in out.split("\x1e"):
        if not c.strip():
            continue
        sha, ae, ce, msg = c.lstrip("\n").split("\x00", 3)
        n += 1
        a, cm = ae.strip().lower(), ce.strip().lower()
        # Renovate mode (a PR opened by renovate[bot], decided by the caller): the bot address as author only with the web-flow committer
        # and a commit GitHub reports as verified; every other commit keeps the strict rule
        bot_ok = verified is not None and a == RENOVATE and cm == WEBFLOW and sha in verified
        # all-mode (`--check --all`): the bot address as author only with API provenance for that commit (a PR opened by renovate[bot] and
        # merged): a bot or web-flow committer needs the merge by renovate[bot] itself, a personal or own committer any merge (the owner's)
        mergers = (proven or {}).get(sha) if all_mode and a == RENOVATE else None
        proven_ok = bool(mergers) and ((cm in (RENOVATE, WEBFLOW) and "renovate[bot]" in mergers) or cm in (PERSONAL, OWN))
        if not (proven_ok or (cm in COMMITTERS and (a in AUTHORS or bot_ok))):
            fail(f"identity {sha[:7]}")
        if ADDRESS.search(msg):
            fail(f"text {sha[:7]} address")
    for sha in git(repo, "rev-list", "--merges", *revs).decode().split():
        fail(f"merge {sha[:7]}")
    patch = git(repo, "log", "-p", "-U0", "--root", "--no-color", "--no-ext-diff", "--no-textconv", "--format=@@@%H", *revs).decode("utf-8", "replace")
    cur, prev = None, ""
    for line in patch.split("\n"):
        if line.startswith("+++ ") and prev.startswith("--- "):
            cur = line[4:].removeprefix("b/")
        elif line.startswith("+") and cur and cur != "/dev/null" and guarded(cur) and ADDRESS.search(line[1:]):
            fail(f"text {safe(cur)} address")
        prev = line
    for sha in git(repo, "rev-list", *revs).decode().split():
        base = ("diff-tree", "-r", "--root", "--no-renames", "--diff-filter=ACMR", "--no-commit-id")
        toks = git(repo, *base, "-z", sha).split(b"\x00")
        entries = []
        i = 0
        while i + 1 < len(toks) and toks[i]:
            entries.append((toks[i].decode().split()[3], toks[i + 1].decode("utf-8", "replace")))
            i += 2
        for _blob, path in entries:
            low = [p.lower() for p in path.split("/")]
            if "inventory" in low[:-1] or any(fnmatch.fnmatch(low[-1], pat) for pat in PATH_DENY):
                fail(f"path {safe(path)}")
        if entries:
            sizes = subprocess.run(["git", "-C", repo, "cat-file", "--batch-check=%(objectsize)"], input="\n".join(b for b, _ in entries).encode() + b"\n",
                                   capture_output=True, check=False).stdout.split()
            for (_b, path), sz in zip(entries, sizes, strict=False):
                if sz.isdigit() and int(sz) > MAX_BLOB:
                    fail(f"size {safe(path)}")
        for rec in git(repo, *base, "--numstat", "-z", sha).split(b"\x00"):
            f = rec.decode("utf-8", "replace").split("\t")
            if len(f) == 3 and f[0] == "-" and f[1] == "-" and not BINARY_OK.search(f[2]):
                fail(f"binary {safe(f[2])}")
    print(f"STAT commits={n}")


# ---- YAML (through yq: no YAML library on the machines this runs on) ---------------------------------------------------------------
def yaml_docs(data, fmt="yaml"):
    cmd = shlex.split(os.environ.get("DOOR_YQ", "")) or ["yq"]
    try:
        p = subprocess.run(cmd + [f"-p={fmt}", "-o=json", "-I=0", "."], input=data, capture_output=True, check=False)
    except OSError as e:
        raise RuntimeError("yq missing") from e
    if p.returncode != 0:
        raise RuntimeError("yq failed")
    return [d for d in (json.loads(x) for x in p.stdout.decode("utf-8", "replace").split("\n") if x.strip()) if isinstance(d, dict)]


def tree_files(repo, rev):
    return [n for n in git(repo, "ls-tree", "-r", "--name-only", rev).decode("utf-8", "replace").split("\n") if n]


def blob(repo, rev, path):
    return subprocess.run(["git", "-C", repo, "show", f"{rev}:{path}"], capture_output=True, check=False).stdout


# ---- apps/tools/<app>/ rules -------------------------------------------------------------------------------------------------------
def app_of(path):
    m = re.match(r"^apps/tools/([^/]+)/", path)
    return m.group(1) if m else None


def app_destination(repo, tip, app):
    """Destination namespace of the Application of apps/tools/<app> at TIP (apps/_argocd/<app>.yaml), else None."""
    data = blob(repo, tip, f"apps/_argocd/{app}.yaml")
    if not data:
        return None
    for d in yaml_docs(data):
        if d.get("kind") == "Application":
            return ((d.get("spec") or {}).get("destination") or {}).get("namespace")
    return None


def load_exceptions():
    """(file, store key) pairs of tools/door/exceptions.txt: exact lines `<file> <key>`; a malformed line is an error, not an exception."""
    pairs = set()
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "exceptions.txt"), encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split()
                if len(parts) != 2:
                    raise RuntimeError("exceptions")
                pairs.add((parts[0], parts[1]))
    except OSError:
        pass
    return pairs


def ref_keys(spec):
    keys = []
    for item in spec.get("data") or []:
        if "sourceRef" in item:
            return None
        k = (item.get("remoteRef") or {}).get("key")
        if k is not None:
            keys.append(k)
    for item in spec.get("dataFrom") or []:
        if "find" in item or "sourceRef" in item:
            return None
        k = (item.get("extract") or {}).get("key")
        if k is not None:
            keys.append(k)
    return keys


def check_externalsecret(path, doc, app, ns):
    """ns is the destination namespace of the app's Application, never what the manifest says; a manifest that names another namespace is refused."""
    kind = doc.get("kind")
    if kind in ("ClusterExternalSecret", "PushSecret", "SecretStore", "ClusterSecretStore"):
        fail(f"externalsecret {safe(path)} scope")
        return
    meta_ns = (doc.get("metadata") or {}).get("namespace")
    if meta_ns and meta_ns != ns:
        fail(f"externalsecret {safe(path)} scope")
        return
    spec = doc.get("spec") or {}
    store = spec.get("secretStoreRef") or {}
    if store.get("kind") != "ClusterSecretStore" or store.get("name") != "openbao":
        fail(f"externalsecret {safe(path)} scope")
        return
    keys = ref_keys(spec)
    if keys is None:
        fail(f"externalsecret {safe(path)} scope")
        return
    ok_prefixes = tuple(p for p in (f"{ns}/" if ns else None, f"apps/{app}/") if p)
    if not keys and not (spec.get("data") or spec.get("dataFrom")):
        return
    allowed = load_exceptions()
    for k in keys:
        if not isinstance(k, str) or ".." in k or not (k.startswith(ok_prefixes) or (path, k) in allowed):
            fail(f"externalsecret {safe(path)} scope")
            return


KUST_LIST_KEYS = ("resources", "components", "bases", "crds", "generators", "transformers", "validators", "patchesStrategicMerge")


def inside(d, ref):
    """A kustomization reference that stays inside the directory d (no URL, no absolute path, no `..` leaving it)."""
    if not isinstance(ref, str) or "://" in ref or ref.startswith(("/", "~", "git@", "github.com", "gitlab.com")):
        return False
    norm = posixpath.normpath(posixpath.join(d, ref))
    return norm == d or norm.startswith(d + "/")


def check_kustomization(path, doc, app, dest=None):
    d = posixpath.dirname(path)
    refs = []
    if doc.get("namespace") and doc.get("namespace") != dest:
        fail(f"kustomize {safe(path)} namespace")
    for k in KUST_LIST_KEYS:
        v = doc.get(k)
        if isinstance(v, list):
            refs += [x for x in v if isinstance(x, str) or k == "patchesStrategicMerge"]
    for p in doc.get("patches") or []:
        if isinstance(p, dict) and "path" in p:
            refs.append(p["path"])
    for p in doc.get("patchesJson6902") or []:
        if isinstance(p, dict) and "path" in p:
            refs.append(p["path"])
    for gen in (doc.get("configMapGenerator") or []) + (doc.get("secretGenerator") or []):
        for f in (gen or {}).get("files") or []:
            refs.append(f.split("=", 1)[-1])
        refs += (gen or {}).get("envs") or []
    if (doc.get("openapi") or {}).get("path"):
        refs.append(doc["openapi"]["path"])
    if doc.get("helmCharts") or doc.get("helmGlobals"):
        fail(f"kustomize {safe(path)} reference")
    for r in refs:
        if not inside(d, r):
            fail(f"kustomize {safe(path)} reference")
            return


def render_app(repo, tip, app):
    """The documents `kustomize build` produces for apps/tools/<app> at TIP (inline patches and replacements included); None when it cannot be built."""
    with tempfile.TemporaryDirectory(prefix="door-render.") as d:
        arch = subprocess.run(["git", "-C", repo, "archive", tip, "--", f"apps/tools/{app}"], capture_output=True, check=False)
        if arch.returncode != 0 or subprocess.run(["tar", "-x", "-C", d], input=arch.stdout, capture_output=True, check=False).returncode != 0:
            return None
        cmd = shlex.split(os.environ.get("DOOR_KUSTOMIZE", "")) or ["kustomize"]
        try:
            p = subprocess.run(cmd + ["build", os.path.join(d, "apps", "tools", app)], capture_output=True, check=False)
        except OSError:
            return None
        if p.returncode != 0:
            return None
        try:
            return yaml_docs(p.stdout)
        except RuntimeError:
            return None


KUST_NAMES = ("kustomization.yaml", "kustomization.yml", "Kustomization")


def tip_files_all(repo, tip):
    return tree_files(repo, tip)


def route_hosts(docs):
    out = []
    for dct in docs:
        if dct.get("kind") == "HTTPRoute":
            out += [h for h in ((dct.get("spec") or {}).get("hostnames") or []) if isinstance(h, str)]
    return out


def check_app_routes(repo, base, tip, path, doc, app, base_hosts):
    spec = doc.get("spec") or {}
    hosts = [h for h in (spec.get("hostnames") or []) if isinstance(h, str)]
    own = f"{app}.lan.{DOMAIN}"
    new = [h for h in hosts if h not in base_hosts]
    if not new:
        return
    # a public name is allowed only as an opted-in route: its exact host and the live Access application are judged by the route rules of the tree
    if OPT_IN in ((doc.get("metadata") or {}).get("annotations") or {}):
        return
    sections = [ref.get("sectionName") for ref in (spec.get("parentRefs") or [])]
    if any(h != own for h in new) or any(s != "lan" for s in sections) or not sections:
        fail(f"route {safe(path)} hostname")


def check_tree_apps(repo, base, tip, whole):
    changed = None
    if not whole:
        changed = {n.decode("utf-8", "replace") for n in git(repo, "diff", "--name-only", "-z", "--no-renames", "--diff-filter=ACMR", base, tip).split(b"\x00") if n}
    tip_files = [n for n in tree_files(repo, tip) if n.startswith("apps/tools/")]
    files = [n for n in tip_files if changed is None or n in changed]
    base_files = tree_files(repo, base)
    ns_cache = {}
    touched = {app_of(n) for n in files if app_of(n)}
    kust_dirs = {posixpath.dirname(n) for n in tip_files if posixpath.basename(n) in KUST_NAMES}

    def dest_of(app):
        if app not in ns_cache:
            ns_cache[app] = app_destination(repo, tip, app)
        return ns_cache[app]

    def base_hosts_of(app):
        hosts = []
        for bf in base_files:
            if bf.startswith(f"apps/tools/{app}/") and bf.lower().endswith((".yaml", ".yml")):
                try:
                    hosts += route_hosts(yaml_docs(blob(repo, base, bf)))
                except RuntimeError:
                    pass
        return hosts

    for n in files:
        app = app_of(n)
        if app is None or not APP_RE.match(app):
            continue
        low = n.lower()
        base_name = posixpath.basename(n)
        if low.endswith((".jsonnet", ".libsonnet")):
            fail(f"apps {safe(n)} format")
            continue
        if not (low.endswith((".yaml", ".yml", ".json")) or base_name in KUST_NAMES):
            continue
        try:
            docs = yaml_docs(blob(repo, tip, n), "json" if low.endswith(".json") else "yaml")
        except RuntimeError:
            fail(f"yaml {safe(n)} unreadable")
            continue
        bh = base_hosts_of(app)
        for d in docs:
            kind = d.get("kind")
            if kind in ("ExternalSecret", "ClusterExternalSecret", "PushSecret", "SecretStore", "ClusterSecretStore"):
                check_externalsecret(n, d, app, dest_of(app))
            elif kind == "HTTPRoute":
                check_app_routes(repo, base, tip, n, d, app, bh)
            elif base_name in KUST_NAMES and (kind is None or str(d.get("apiVersion", "")).startswith("kustomize.config.k8s.io")):
                check_kustomization(n, d, app, dest_of(app))
    # what kustomize renders is what is applied: inline patches, replacements and JSON resources cannot hide a reference; the rendered documents of
    # every app (a build that fails is an error only for an app of this change) and every JSON manifest of the tree join the route rules
    for n in tip_files_all(repo, tip):
        if n.lower().endswith(".json") and n.startswith(("apps/", "networking/")):
            try:
                EXTRA_DOCS.extend((n, d) for d in yaml_docs(blob(repo, tip, n), "json"))
            except RuntimeError:
                fail(f"yaml {safe(n)} unreadable")
    for d in sorted(kust_dirs):
        app = d.split("/")[2] if d.count("/") >= 2 else None
        if app is None or not APP_RE.match(app) or d != f"apps/tools/{app}":
            continue
        rendered = render_app(repo, tip, app)
        label = f"{d}/kustomization.yaml"
        if rendered is None:
            if app in touched:
                fail(f"kustomize {safe(label)} build")
            continue
        EXTRA_DOCS.extend((label, r) for r in rendered)
        if app not in touched:
            continue
        bh = base_hosts_of(app)
        for r in rendered:
            kind = r.get("kind")
            if kind in ("ExternalSecret", "ClusterExternalSecret", "PushSecret", "SecretStore", "ClusterSecretStore"):
                check_externalsecret(label, r, app, dest_of(app))
            elif kind == "HTTPRoute":
                check_app_routes(repo, base, tip, label, r, app, bh)


# ---- HTTPRoute rules for the whole tree: public DNS opt-in only behind a live Access application, tunnel routes with exact hosts ---------------------
OPT_IN = "homelab.io/public-dns"
PUBLIC_LABEL = "homelab.io/public"
MARKER_RE = r"homelab\.io/public-dns[\s'\"\\]*:|sectionName[\s'\"\\]*:[\s'\"\\]*tunnel"
EXTDNS_KEY = re.compile(r"^external-dns\.(?:alpha\.)?kubernetes\.io/")
EXTDNS_HOSTNAME_RE = r"external-dns\.(?:alpha\.)?kubernetes\.io/hostname[\s'\"\\]*:"
ROUTE_KEY = re.compile(r"^(route|routes|httproute|httproutes|ingress)$", re.IGNORECASE)


def route_unsafe(node, path=()):
    """Fail closed: below a key named route/routes/httproute/ingress the switch `enabled` may be absent or the YAML boolean false, nothing else;
    `parentRefs`, `hosts` and `hostnames` may not appear at all."""
    if isinstance(node, dict):
        inside_route = any(ROUTE_KEY.match(str(k)) for k in path)
        for k, v in node.items():
            ks = str(k)
            if inside_route and ((ks == "enabled" and v is not False) or ks in ("parentRefs", "hosts", "hostnames")):
                return True
            if ROUTE_KEY.match(ks) and not isinstance(v, (dict, list)) and v is not False:
                return True
        return any(route_unsafe(v, (*path, k)) for k, v in node.items())
    if isinstance(node, list):
        return any(route_unsafe(v, path) for v in node)
    return False


def access_hosts():
    """Domains of the live Access applications named k3s-access-<domain>; None when they cannot be read."""
    tok, acct = os.environ.get("CLOUDFLARE_ACCESS_TOKEN", ""), os.environ.get("CLOUDFLARE_ACCOUNT_ID", "")
    if not tok or not re.fullmatch(r"[0-9a-f]{32}", acct):
        return None
    api = os.environ.get("DOOR_CF_API", "https://api.cloudflare.com/client/v4") if os.environ.get("HOMELAB_DOOR_TEST") == "1" else "https://api.cloudflare.com/client/v4"
    req = urllib.request.Request(f"{api}/accounts/{acct}/access/apps?per_page=1000", headers={"Authorization": f"Bearer {tok}"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            doc = json.loads(r.read())
    except (OSError, ValueError, urllib.error.URLError):
        return None
    if not (doc.get("success") is True and isinstance(doc.get("result"), list)) or (doc.get("result_info") or {}).get("total_pages", 1) > 1:
        return None
    return {a.get("domain") for a in doc["result"] if a.get("name") == f"k3s-access-{a.get('domain')}" and isinstance(a.get("domain"), str)}


def check_routes(repo, tip):
    names = [n for n in tree_files(repo, tip) if n.lower().endswith((".yaml", ".yml")) and not n.startswith((".github/", "ci/"))]
    docs = []
    for n in names:
        data = blob(repo, tip, n)
        if len(data) > MAX_BLOB:
            if re.search(rb"HTTPRoute|" + re.escape(OPT_IN.encode()) + rb"|sectionName\"?:\s*\"?tunnel", data):
                fail(f"routes {safe(n)} too large to check")
            continue
        if not re.search(rb"HTTPRoute|" + re.escape(PUBLIC_LABEL.encode()) + rb"|sectionName|external-dns\.|kind: Application|^namespace:", data, re.MULTILINE):
            continue
        try:
            for d in yaml_docs(data):
                docs.append((n, d))
                if d.get("kind") != "HTTPRoute" and re.search(EXTDNS_HOSTNAME_RE, json.dumps(d)):
                    fail(f"routes {safe(n)} external-dns hostname annotation outside a plain HTTPRoute manifest")
                if d.get("kind") != "HTTPRoute" and re.search(MARKER_RE, json.dumps(d)):
                    fail(f"routes {safe(n)} opt-in or tunnel route outside a plain HTTPRoute manifest")
        except RuntimeError:
            fail(f"routes {safe(n)} unreadable")
    docs.extend(EXTRA_DOCS)
    public_ns, app_paths, kust_ns = set(), [], {}
    for n, d in docs:
        kind, md = d.get("kind"), d.get("metadata") or {}
        if kind == "Namespace" and (md.get("labels") or {}).get(PUBLIC_LABEL) == "true":
            public_ns.add(md.get("name"))
        elif kind == "Application":
            spec = d.get("spec") or {}
            dest = (spec.get("destination") or {}).get("namespace")
            if ((spec.get("syncPolicy") or {}).get("managedNamespaceMetadata") or {}).get("labels", {}).get(PUBLIC_LABEL) == "true":
                public_ns.add(dest)
            for src in ([spec["source"]] if spec.get("source") else []) + (spec.get("sources") or []):
                if src.get("path"):
                    app_paths.append((src["path"].rstrip("/"), dest))
        elif kind is None and d.get("namespace") and posixpath.basename(n).startswith("kustomization"):
            kust_ns[posixpath.dirname(n)] = d["namespace"]

    def namespace_of(path, md):
        if md.get("namespace"):
            return md["namespace"]
        d = posixpath.dirname(path)
        while True:
            if d in kust_ns:
                return kust_ns[d]
            if d in ("", "."):
                break
            d = posixpath.dirname(d)
        best = [(len(p), ns) for p, ns in app_paths if path == p or path.startswith(p + "/")]
        return max(best)[1] if best else None

    for path, d in docs:
        if d.get("kind") != "Application":
            continue
        spec = d.get("spec") or {}
        dest = (spec.get("destination") or {}).get("namespace")
        if dest not in public_ns:
            continue
        trees = []
        for src in ([spec["source"]] if spec.get("source") else []) + (spec.get("sources") or []):
            helm = src.get("helm") or {}
            if isinstance(helm.get("valuesObject"), dict):
                trees.append(helm["valuesObject"])
            if isinstance(helm.get("values"), str) and helm["values"].strip():
                try:
                    trees += yaml_docs(helm["values"].encode())
                except RuntimeError:
                    fail(f"routes {safe(path)} inline values unreadable")
            for prm in helm.get("parameters") or []:
                if not isinstance(prm, dict):
                    continue
                segs = [x for x in re.split(r"[.\[\]]+", str(prm.get("name", ""))) if x]
                if any(ROUTE_KEY.match(x) for x in segs) and not (segs[-1] == "enabled" and str(prm.get("value")).lower() == "false" and not prm.get("forceString")):
                    fail(f"routes {safe(path)} chart route or ingress set by a Helm parameter in the public namespace {safe(dest)}; use a plain HTTPRoute manifest")
            for vf in helm.get("valueFiles") or []:
                m = re.match(r"^\$[A-Za-z0-9_-]+/([A-Za-z0-9_./-]+)$", str(vf))
                if m and ".." not in m.group(1):
                    data = blob(repo, tip, m.group(1))
                    try:
                        trees += yaml_docs(data) if data else []
                    except RuntimeError:
                        fail(f"routes {safe(m.group(1))} unreadable")
        if any(route_unsafe(t) for t in trees):
            fail(f"routes {safe(path)} chart route or ingress not strictly disabled (absent or boolean false) in the public namespace {safe(dest)}; use a plain HTTPRoute manifest")
    optin = [(p, d) for p, d in docs if d.get("kind") == "HTTPRoute" and OPT_IN in ((d.get("metadata") or {}).get("annotations") or {})]
    access = None
    if optin:
        access = access_hosts()
        if access is None:
            fail("public-dns access unreadable")
    for path, d in docs:
        if d.get("kind") != "HTTPRoute":
            continue
        md, spec = d.get("metadata") or {}, d.get("spec") or {}
        ns = namespace_of(path, md)
        label = f"{safe(ns or '?')}/{safe(md.get('name') or '?')}"
        hosts = [h for h in (spec.get("hostnames") or []) if isinstance(h, str)]
        for ak in (md.get("annotations") or {}):
            if EXTDNS_KEY.match(str(ak)):
                fail(f"public-dns {label} external-dns annotation on a route")
        if OPT_IN in (md.get("annotations") or {}):
            if not hosts:
                fail(f"public-dns {label} no hostname")
            for h in hosts:
                if "*" in h:
                    fail(f"public-dns {safe(h)} wildcard")
                elif access is not None and h not in access:
                    fail(f"public-dns {safe(h)} no access")
        attaches = False
        for ref in spec.get("parentRefs") or []:
            sec = ref.get("sectionName")
            if sec == "tunnel" or (not sec and (ns is None or ns in public_ns)):
                attaches = True
        if attaches:
            if not hosts:
                fail(f"tunnel-route {label} no hostname")
            elif any("*" in h for h in hosts):
                fail(f"tunnel-route {label} wildcard")
    print(f"STAT routes={sum(1 for _, d in docs if d.get('kind') == 'HTTPRoute')}")


# ---- merge allowlist -------------------------------------------------------------------------------------------------------------------
def merge_allowed(repo, base, n, paths):
    apps = set()
    for p in paths:
        m = re.match(r"^apps/tools/([a-z0-9][a-z0-9-]*)/[^/].*$", p)
        if not m or ".." in p.split("/") or p.startswith("/"):
            return False
        apps.add(m.group(1))
    if len(apps) != 1:
        return False
    app = apps.pop()
    if not APP_RE.match(app) or not git(repo, "ls-tree", "-r", "--name-only", base, f"apps/tools/{app}/", check=False).strip():
        return False
    data = blob(repo, base, f"apps/_argocd/{app}.yaml")
    if not data:
        return False
    try:
        docs = yaml_docs(data)
    except RuntimeError:
        return False
    for d in docs:
        if d.get("kind") != "Application":
            continue
        spec = d.get("spec") or {}
        srcs = ([spec["source"]] if spec.get("source") else []) + (spec.get("sources") or [])
        if spec.get("project") in ("apps", "apps-store") and any((s.get("path") or "").rstrip("/") == f"apps/tools/{app}" for s in srcs):
            return True
    return False


def gitleaks_report(path):
    try:
        with open(path, encoding="utf-8") as fh:
            findings = json.load(fh) or []
    except (OSError, ValueError):
        print("FAIL gitleaks report")
        return 1
    for fd in findings:
        fail(f"gitleaks {safe(str(fd.get('File', '?')))}:{fd.get('StartLine', 0)} {safe(str(fd.get('RuleID', '?')))}")
    return 1 if fails else 0


def main(argv):
    if len(argv) < 2:
        print("FAIL check usage")
        return 2
    cmd, rest = argv[1], argv[2:]
    try:
        if cmd == "commits" and len(rest) >= 2:
            all_mode = "--all-mode" in rest
            args = rest[1:]
            verified = proven = None
            if "--renovate-merged" in args:
                i = args.index("--renovate-merged")
                proven = proven_merges(args[i + 1])
                del args[i : i + 2]
            if "--renovate" in args:
                i = args.index("--renovate")
                verified = verified_shas(args[i + 1])
                del args[i : i + 2]
            check_commits(rest[0], [r for r in args if r != "--all-mode"], all_mode, verified, proven)
        elif cmd == "bot-shas" and len(rest) >= 2:
            print("\n".join(bot_shas(rest[0], rest[1:])))
        elif cmd == "tree" and len(rest) >= 3:
            whole = "--all" in rest[3:]
            check_tree_apps(rest[0], rest[1], rest[2], whole)
            check_routes(rest[0], rest[2])
        elif cmd == "text" and rest:
            for f in rest:
                with open(f, "rb") as fh:
                    data = fh.read()
                if not data.strip():
                    fail("text empty")
                if len(data) > MAX_TEXT:
                    fail("text too large")
                if ADDRESS.search(data.decode("utf-8", "replace")):
                    fail("text address")
        elif cmd == "ref" and len(rest) == 1:
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", rest[0]) or ".." in rest[0] or rest[0].endswith((".lock", "/", ".")):
                fail("ref name")
        elif cmd == "merge-paths" and len(rest) == 3:
            paths = [ln.strip() for ln in sys.stdin.read().split("\n") if ln.strip()]
            if paths and merge_allowed(rest[0], rest[1], rest[2], paths):
                print(f"OK merge {rest[2]} allowed")
                return 0
            print(f"FAIL merge {rest[2]} owner")
            return 1
        elif cmd == "gitleaks" and len(rest) == 1:
            return gitleaks_report(rest[0])
        else:
            print("FAIL check usage")
            return 2
    except (RuntimeError, OSError, ValueError, IndexError):
        print("FAIL check could not run")
        return 1
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
