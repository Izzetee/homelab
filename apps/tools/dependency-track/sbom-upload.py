#!/usr/bin/env python3
"""Upload the SBOM reports of the Trivy Operator to Dependency-Track (stdlib only).

One DT project per (namespace, image): name `<namespace>/<registry>/<repository>`, version = tag, project tag = namespace.
A report (its CycloneDX document is `report.components`, validated in both modes) is uploaded only when its `report.updateTimestamp`
(else creationTimestamp) is newer than the project's `lastBomImport`. Every run reconciles all pairs and prints counts only:
  reports   distinct (namespace, image) pairs of the SbomReports
  projects  pairs that have a DT project
  uploaded  uploads made (0 in dry-run: nothing is posted)
  skipped   pairs whose project is already current
  failed    pairs or lookups that failed (exit 1)
  missing   pairs without a project whose lastBomImport is >= the report time (in dry-run these are the uploads that would be made)
  unanalysed  projects without persisted metrics (zero findings is a valid analysis)
  findings  sum of the vulnerabilities of the persisted metrics
The API key and the service-account token are never printed. Settings come from the environment (names only):
DT_URL, DT_API_KEY, DRY_RUN, KUBE_API, KUBE_TOKEN_FILE, KUBE_CA_FILE, TERMINATION_LOG.
"""
import datetime
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

SA = "/var/run/secrets/kubernetes.io/serviceaccount"
API = "/apis/aquasecurity.github.io/v1alpha1/"


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect is a failure: the key and the token never follow one."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def http(url, headers, data=None, timeout=60, ctx=None):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect, urllib.request.HTTPSHandler(context=ctx))
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if data is not None else "GET")
    try:
        with opener.open(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        e.read()
        return e.code, b""


def norm_image(registry, repository):
    """Registry and repository as the verifier normalizes them (Docker Hub: index.docker.io, library/ for one segment)."""
    registry = registry or "index.docker.io"
    if registry == "docker.io":
        registry = "index.docker.io"
    if registry == "index.docker.io" and "/" not in repository:
        repository = "library/" + repository
    return registry, repository


def plain_version(tag, digest):
    """The project version: the plain tag. A tag field may hold a full reference (`registry/repo:tag`, `repo:tag@sha256:...`):
    the registry/repository prefix and the `@sha256:...` part are dropped; with no tag left the digest is used."""
    tag = tag or ""
    ref = "/" in tag or ":" in tag or "@" in tag
    tag = tag.split("@", 1)[0]
    if ref:
        last = tag.rsplit("/", 1)[-1]
        tag = last.split(":", 1)[1] if ":" in last else ""
    return tag or (digest or "")


def pair_of(item):
    rep = item.get("report") or {}
    art = rep.get("artifact") or {}
    registry, repo = norm_image((rep.get("registry") or {}).get("server"), art.get("repository") or "")
    return registry, repo, plain_version(art.get("tag"), art.get("digest"))


def valid_bom(item):
    """Trivy writes the CycloneDX document under report.components."""
    doc = (item.get("report") or {}).get("components")
    return isinstance(doc, dict) and doc.get("bomFormat") == "CycloneDX"


def ts_ms(text):
    """RFC 3339 UTC time, seconds or fractions, to epoch milliseconds."""
    text = text.split(".", 1)[0].rstrip("Z")
    d = datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
    return int(d.timestamp() * 1000)


def report_time(item):
    """When the report was made: report.updateTimestamp, else the object's creationTimestamp."""
    return ts_ms((item.get("report") or {}).get("updateTimestamp") or item["metadata"]["creationTimestamp"])


def multipart(fields, name, filename, content):
    b = uuid.uuid4().hex
    out = b""
    for k, v in fields.items():
        out += ('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n' % (b, k, v)).encode()
    out += ('--%s\r\nContent-Disposition: form-data; name="%s"; filename="%s"\r\nContent-Type: application/json\r\n\r\n' % (b, name, filename)).encode()
    out += content + ("\r\n--%s--\r\n" % b).encode()
    return "multipart/form-data; boundary=" + b, out


def main():
    dt = env("DT_URL", "http://dependency-track-api-server.dependency-track.svc:8080").rstrip("/")
    key = env("DT_API_KEY", "")
    dry = env("DRY_RUN", "") not in ("", "0")
    kube = env("KUBE_API", "https://kubernetes.default.svc").rstrip("/")
    tokfile = env("KUBE_TOKEN_FILE", SA + "/token")
    ctx = ssl.create_default_context(cafile=env("KUBE_CA_FILE", SA + "/ca.crt")) if kube.startswith("https") else None
    if not key:
        print("FAIL no api key")
        return 1
    with open(tokfile) as f:
        kh = {"Authorization": "Bearer " + f.read().strip(), "Accept": "application/json"}
    dh = {"Accept": "application/json"}
    dh["X-Api-Key"] = key

    # pass 1: one report per request (a BOM is large), keep only the newest report per pair and whether its document is valid
    newest = {}
    cont = ""
    while True:
        q = "?limit=1" + ("&continue=" + urllib.parse.quote(cont) if cont else "")
        st, body = http(kube + API + "sbomreports" + q, kh, ctx=ctx)
        if st != 200:
            print("FAIL list reports http=%d" % st)
            return 1
        page = json.loads(body)
        for it in page.get("items", []):
            md = it["metadata"]
            ts = report_time(it)
            p = (md["namespace"],) + pair_of(it)
            if not p[2] or not p[3]:
                print("FAIL report without image ns=%s" % md["namespace"])
                newest[("", "", "", md["name"])] = None
                continue
            if p not in newest or (newest[p] and ts > newest[p][0]):
                newest[p] = (ts, md["namespace"], md["name"], valid_bom(it))
        cont = (page.get("metadata") or {}).get("continue") or ""
        if not cont:
            break

    reports = uploaded = skipped = failed = missing = unanalysed = findings = projects = 0
    for p, hit in sorted(newest.items()):
        if hit is None:
            failed += 1
            continue
        reports += 1
        ns, registry, repo, version = p
        name = "%s/%s/%s" % (ns, registry, repo)
        ts, _, rname, valid = hit
        if not valid:
            print("FAIL report has no CycloneDX document ns=%s" % ns)
            failed += 1
            continue
        st, body = http(dt + "/api/v1/project/lookup?" + urllib.parse.urlencode({"name": name, "version": version}), dh)
        proj = None
        if st == 200:
            proj = json.loads(body)
            projects += 1
        elif st != 404:
            print("FAIL lookup http=%d ns=%s" % (st, ns))
            failed += 1
            continue
        current = bool(proj) and (proj.get("lastBomImport") or 0) >= ts
        if current:
            skipped += 1
        else:
            missing += 1
            if not dry:
                st, body = http(kube + API + "namespaces/%s/sbomreports/%s" % (ns, rname), kh, ctx=ctx)
                if st != 200:
                    print("FAIL read report http=%d ns=%s" % (st, ns))
                    failed += 1
                    continue
                doc = json.loads(body)
                if not valid_bom(doc):
                    print("FAIL report has no CycloneDX document ns=%s" % ns)
                    failed += 1
                    continue
                bom = json.dumps(doc["report"]["components"]).encode()
                fields = {"projectName": name, "projectVersion": version, "autoCreate": "true", "isLatest": "true", "projectTags": ns}
                ctype, data = multipart(fields, "bom", "bom.json", bom)
                st, _ = http(dt + "/api/v1/bom", dict(dh, **{"Content-Type": ctype}), data=data, timeout=120)
                if st not in (200, 201, 202):
                    print("FAIL upload http=%d ns=%s" % (st, ns))
                    failed += 1
                    continue
                uploaded += 1
        if proj:
            # analysed = the project holds persisted metrics (a zero-finding result is a real result); absent metrics = not analysed yet
            m = proj.get("metrics")
            if isinstance(m, dict) and m:
                findings += int(m.get("vulnerabilities") or 0)
            else:
                unanalysed += 1

    line = ("RESULT sbom-upload mode=%s reports=%d projects=%d uploaded=%d skipped=%d failed=%d missing=%d unanalysed=%d findings=%d"
            % ("dry-run" if dry else "upload", reports, projects, uploaded, skipped, failed, missing, unanalysed, findings))
    print(line)
    try:
        with open(env("TERMINATION_LOG", "/dev/termination-log"), "w") as f:
            f.write(line)
    except OSError:
        pass
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
