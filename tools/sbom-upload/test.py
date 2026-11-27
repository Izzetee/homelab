#!/usr/bin/env python3
"""Self-test of apps/tools/dependency-track/sbom-upload.py: stdlib stubs of the Kubernetes API (SbomReports) and of Dependency-Track.

Cases: CRD-shaped reports (CycloneDX under report.components), dedupe per (namespace, image) by report.updateTimestamp, version from a tag that
holds a full reference, skip when the project is current, upload when it is older, missing or the object was updated after the import, dry-run
makes no POST but still validates the document, unanalysed = no persisted project metrics (a zero-finding project is analysed), redirects are
refused, value-free output, exit codes.
Prints OK on success, FAIL <case> and exit 1 otherwise. No cluster, no credentials.
"""
import datetime
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "apps", "tools", "dependency-track", "sbom-upload.py")
KEY, BEARER = "k" + os.urandom(6).hex(), "t" + os.urandom(6).hex()  # random per run: the test checks they never show up in the output
BOM = {"bomFormat": "CycloneDX", "specVersion": "1.6", "components": [{"name": "x"}]}


def ms(text):
    d = datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    return int(d.timestamp() * 1000)


T0, TM, T1 = "2026-11-27T10:00:00Z", "2026-11-27T11:00:00Z", "2026-11-27T12:00:00Z"


def report(ns, name, registry, repo, tag, created, updated=None, doc=BOM):
    """Shaped like a Trivy Operator 0.36 SbomReport: the CycloneDX document is report.components (there is no report.bom)."""
    return {"metadata": {"namespace": ns, "name": name, "creationTimestamp": created},
            "report": {"updateTimestamp": updated or created, "registry": {"server": registry},
                       "artifact": {"repository": repo, "tag": tag, "digest": "sha256:abc"}, "components": doc}}


# (namespace, object name, registry, repository, tag, created, updated)
REPORTS = [
    report("a", "r1-old", "index.docker.io", "nginx", "1.0", T0),                       # same pair as r1: the newer one wins
    report("a", "r1", "docker.io", "library/nginx", "nginx:1.0@sha256:abc", T1),        # Docker Hub name:tag@digest -> version 1.0
    report("b", "r2", "ghcr.io", "o/current", "ghcr.io/o/current:2", T0),               # registry/repo:tag -> version 2; project current
    report("b", "r3", "ghcr.io", "o/older", "3", T1),                                   # project older than the report: upload
    report("b", "r7", "ghcr.io", "o/updated", "7", T0, T1),                             # created before the import, updated after it: upload again
    report("c", "r4", "quay.io", "o/new", "quay.io/o/new:4@sha256:def", T1),            # no project: upload, version 4
    report("c", "r5", "quay.io", "o/zero", "5", T0),                                    # current, persisted zero-finding metrics: analysed
    report("c", "r6", "quay.io", "o/nometrics", "6", T0),                               # current, no persisted metrics: unanalysed
]
PROJECTS = {  # name/version -> project object as DT returns it
    "a/index.docker.io/library/nginx/1.0": {"uuid": "u1", "lastBomImport": ms(T1), "metrics": {"vulnerabilities": 3}},
    "b/ghcr.io/o/current/2": {"uuid": "u2", "lastBomImport": ms(T1), "metrics": {"vulnerabilities": 2}},
    "b/ghcr.io/o/older/3": {"uuid": "u3", "lastBomImport": ms(T0), "metrics": {"vulnerabilities": 0}},
    "b/ghcr.io/o/updated/7": {"uuid": "u7", "lastBomImport": ms(TM), "metrics": {"vulnerabilities": 1}},
    "c/quay.io/o/zero/5": {"uuid": "u5", "lastBomImport": ms(T1), "metrics": {"vulnerabilities": 0}},
    "c/quay.io/o/nometrics/6": {"uuid": "u6", "lastBomImport": ms(T1)},
}


class Stub(BaseHTTPRequestHandler):
    posts = []
    fail_post = False
    redirect = ""      # "dt": the project lookup answers 302; "kube": the report list answers 302
    leaked = []        # headers seen on the redirect target
    bad_doc = False    # the report r3 carries a document that is not CycloneDX

    def log_message(self, format, *args):  # noqa: A002
        pass

    def send(self, code, obj=None, location=""):
        body = json.dumps(obj).encode() if obj is not None else b""
        self.send_response(code)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def reports(self):
        out = [json.loads(json.dumps(r)) for r in REPORTS]
        if Stub.bad_doc:
            out[3]["report"]["components"] = {"bomFormat": "other"}
        return out

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/leak":
            Stub.leaked.append(self.headers.get("X-Api-Key") or self.headers.get("Authorization") or "-")
            return self.send(200, {})
        if u.path.endswith("/sbomreports") and u.path.startswith("/apis/"):
            if Stub.redirect == "kube":
                return self.send(302, location="/leak")
            if self.headers.get("Authorization") != "Bearer " + BEARER:
                return self.send(401)
            items = self.reports()
            i = int(q.get("continue", ["0"])[0])
            nxt = str(i + 1) if i + 1 < len(items) else ""
            return self.send(200, {"metadata": {"continue": nxt}, "items": [items[i]]})
        if u.path.startswith("/apis/") and "/sbomreports/" in u.path:
            parts = u.path.split("/")
            for r in self.reports():
                if r["metadata"]["namespace"] == parts[-3] and r["metadata"]["name"] == parts[-1]:
                    return self.send(200, r)
            return self.send(404)
        if self.headers.get("X-Api-Key") != KEY:
            return self.send(401)
        if u.path == "/api/v1/project/lookup":
            if Stub.redirect == "dt":
                return self.send(302, location="/leak")
            p = PROJECTS.get(q["name"][0] + "/" + q["version"][0])
            return self.send(200, p) if p else self.send(404)
        if u.path.startswith("/api/v1/metrics/project/"):
            return self.send(200, {"vulnerabilities": 0})  # the synthesized zero object: must never count as an analysis
        self.send(404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(n)
        if self.headers.get("X-Api-Key") != KEY or self.path != "/api/v1/bom":
            return self.send(401)
        Stub.posts.append(data.decode())
        self.send(500 if Stub.fail_post else 200, {"uuid": "u"})


def run(srv, *pairs):  # pairs: (environment name, value)
    d = tempfile.mkdtemp()
    tok, term = os.path.join(d, "token"), os.path.join(d, "term")
    with open(tok, "w") as f:
        f.write(BEARER + "\n")
    url = f"http://127.0.0.1:{srv.server_port}"
    env = {"PATH": os.environ.get("PATH", ""), "DT_URL": url, "KUBE_API": url, "KUBE_TOKEN_FILE": tok,
           "TERMINATION_LOG": term}
    env["DT_API_KEY"] = KEY
    env.update(dict(pairs))
    p = subprocess.run([sys.executable, SCRIPT], env=env, capture_output=True, text=True, timeout=60)
    return p.returncode, p.stdout + p.stderr, open(term).read() if os.path.exists(term) else ""


def main():
    srv = HTTPServer(("127.0.0.1", 0), Stub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    bad = []

    def check(case, cond):
        if not cond:
            bad.append(case)

    # upload mode: 7 pairs (r1/r1-old deduped), 3 uploads (older project, updated after the import, no project), 4 skipped,
    # 1 existing project without persisted metrics (the synthesized zero object of the stub must not count), findings 3+2+0+1+0
    Stub.posts.clear()
    rc, out, term = run(srv)
    want = "RESULT sbom-upload mode=upload reports=7 projects=6 uploaded=3 skipped=4 failed=0 missing=3 unanalysed=1 findings=6"
    check("upload counts: " + out, rc == 0 and term == want and want in out)
    check("three posts", len(Stub.posts) == 3)
    check("post: project name, tag and version 4 from a full reference", any('name="projectName"\r\n\r\nc/quay.io/o/new' in b and 'name="projectTags"\r\n\r\nc' in b
                                                                          and 'name="projectVersion"\r\n\r\n4\r\n' in b for b in Stub.posts))
    check("post: the updated object is uploaded again", any("b/ghcr.io/o/updated" in b for b in Stub.posts))
    check("post carries report.components", all('"CycloneDX"' in b and '"specVersion"' in b for b in Stub.posts))
    check("output is value-free", KEY not in out + term and BEARER not in out + term)

    # dry-run: same reconciliation, no POST
    Stub.posts.clear()
    rc, out, term = run(srv, ("DRY_RUN", "1"))
    want = "RESULT sbom-upload mode=dry-run reports=7 projects=6 uploaded=0 skipped=4 failed=0 missing=3 unanalysed=1 findings=6"
    check("dry-run counts: " + out, rc == 0 and term == want)
    check("dry-run makes no POST", Stub.posts == [])
    check("DRY_RUN=0 is not a dry run", "mode=upload" in run(srv, ("DRY_RUN", "0"))[2])

    # a report without a CycloneDX document fails in both modes and is never posted
    Stub.bad_doc = True
    for extra, mode in (((), "upload"), ((("DRY_RUN", "1"),), "dry-run")):
        Stub.posts.clear()
        rc, out, term = run(srv, *extra)
        want = "RESULT sbom-upload mode=%s reports=7 projects=5 uploaded=%d skipped=4 failed=1 missing=2 unanalysed=1 findings=6" % (mode, 0 if mode == "dry-run" else 2)
        check("invalid document (%s): %s" % (mode, out), rc == 1 and term == want and not any("o/older" in b for b in Stub.posts))
    Stub.bad_doc = False

    # a redirect is a failure: neither key nor token reaches the redirect target
    for where, expect in (("dt", "FAIL lookup http=302"), ("kube", "FAIL list reports http=302")):
        Stub.redirect = where
        Stub.leaked.clear()
        rc, out, _ = run(srv)
        check("redirect %s fails: %s" % (where, out), rc == 1 and expect in out)
        check("redirect %s not followed" % where, Stub.leaked == [])
    Stub.redirect = ""

    # failures: upload refused -> exit 1; no key -> exit 1; wrong token -> exit 1
    Stub.fail_post = True
    rc, out, term = run(srv)
    Stub.fail_post = False
    check("failed upload exits 1: " + out, rc == 1 and "failed=3" in term and "uploaded=0" in term)
    rc, out, _ = run(srv, ("DT_API_KEY", ""))
    check("no key exits 1", rc == 1 and KEY not in out)
    d = tempfile.mkdtemp()
    with open(os.path.join(d, "t"), "w") as f:
        f.write("wrong")
    rc, out, _ = run(srv, ("KUBE_TOKEN_FILE", os.path.join(d, "t")))
    check("bad token exits 1", rc == 1 and "FAIL list reports http=401" in out)
    rc, out, _ = run(srv, ("DT_API_KEY", "other"))
    check("bad key exits 1 without the key in the output", rc == 1 and "other" not in out)

    srv.shutdown()
    if bad:
        for b in bad:
            print("FAIL " + b)
        return 1
    print("OK sbom-upload self-test")
    return 0


if __name__ == "__main__":
    sys.exit(main())
