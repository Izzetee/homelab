# Lessons

Technical lessons that shaped the tools and checks.

- **A restart policy that treats exit 0 as success hides a dead database.** Kubernetes restarts by default; alert on a database that is not ready.
- **A client that resolves its backend once at start fails when the backend is replaced.** Use readiness and startup probes and stable values (never regenerate a secret per deploy).
- **Proxied DNS records answer with address records.** Ask the provider's API instead of inferring from a CNAME query.
- **Delete the CNAME before the record it points to**, or the name can be taken over.
- **DNS-01 propagation checks must use public resolvers**; an in-cluster resolver can answer NXDOMAIN for weeks while certificates silently fail.
- **NFS servers may only serve version 4.0**; check the effective setting, not the supported one, and mount with the version named.
- **Extensions inside a database can lag the image**: run the extension update after an image update and have restore drills accept only a strict upgrade path.
- **`timeout` in uutils coreutils kills only its direct child**; never hand pipes to a timed child, use a kill escalation.
- **Renovate starts in silent mode**; verify an install through its dependency dashboard, not through the absence of pull requests. Stock managers misread some pins: use regex managers and test them locally.
- **An API rebase merge sets the merging user as committer**; an identity rule must allow it.
- **Tokens in URLs leak** into process lists and credential helpers; use a credential helper or SSH keys. Values travel through stdin, pipes or 0600 files, never arguments.
- **`bash -x` prints every value a script loads**; trace only with fixtures and stubs.
- **`docker inspect`, `kubectl get -o yaml`, dumps and vzdump archives contain values**; treat their output as secret material.
- **Dry-run first, and build test fixtures from real output shapes**; tests that match assumptions pass and fail live.
- **Pull backups to their target; do not push them from the source**, and read what a later step needs before cutting its source.
- **Pin `tag@digest`** and check both architectures per image.
