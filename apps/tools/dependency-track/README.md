# Dependency-Track

Dependency-Track 5.2.2 (API server and frontend) in the namespace `dependency-track`, LAN only: `https://dependency-track.lan.chill-town.de`
(`routes.yaml`, `lan` listener, no public name). Login is OpenID Connect against the identity provider (public client, code flow with PKCE).

- `dependency-track.yaml`: the output of the Helm chart `dependency-track` 2.10.0, rendered once and kept as plain manifests (no chart source
  in ArgoCD). Do not edit it by hand: change the values below and render again.
- `frontend-config.json`: `config.json` of the frontend (OIDC settings), mounted over the image's file through a generated ConfigMap, so the
  frontend root file system is read-only (`/tmp` and `/etc/nginx/conf.d` are emptyDirs).
- `cluster.yaml`: the PostgreSQL 18 database (CloudNativePG, database and owner `dtrack`). `pvc.yaml`: the claim of the dump sets.
- `backup/`: a CronJob that dumps the database (`dtrack-<UTC>.dump` with checksum and a project count) and the restore check
  (`apps/_backup-hook`, `apps/_restore-check`). A layer of its own because the backup hook component selects its source CronJob by kind.
- `sbom-upload.yaml`, `sbom-upload.py`: a CronJob that uploads the SBOM reports of the Trivy Operator (one project per namespace and image,
  version = tag, project tag = namespace) and prints counts only; `DRY_RUN=1` makes lookups and validates each report's CycloneDX document (`report.components`) without uploads. The project version is the plain tag: a tag field that holds a reference (`registry/repo:tag`, `repo:tag@sha256:…`) is cut to the part after the last `:` of its last path segment, and with no tag left the digest is used. Read access to the reports:
  `apps/platform/trivy-operator/sbom-reader.yaml`. Self-test: `python3 tools/sbom-upload/test.py`.
- `network-policy.yaml`: default deny plus the rules of each pod.

## Render values

```yaml
database:
  jdbcUrl: "jdbc:postgresql://dependency-track-db-rw:5432/dtrack?reWriteBatchedInserts=true"
  existingSecret:
    name: dependency-track-db-app
nodeSelector:
  kubernetes.io/arch: amd64
fileStorage:
  provider: local
  local:
    size: 2Gi
    storageClassName: local-path
secretManagement:
  provider: env
apiServer:
  image:
    tag: 5.2.2@sha256:cd5bed12ff30fd36980dbee2d6c3b177c37b99c63b60f5a5b15fbca0b31d0f38
  extraEnv:
    - {name: DT_OIDC_ENABLED, value: "true"}
    - {name: DT_OIDC_ISSUER, value: "https://auth.lan.chill-town.de/application/o/dependency-track/"}
    - {name: DT_OIDC_CLIENT_ID, value: dependency-track}
    - {name: DT_OIDC_USERNAME_CLAIM, value: preferred_username}
    - {name: DT_OIDC_USER_PROVISIONING, value: "true"}
    - {name: DT_OIDC_TEAM_SYNCHRONIZATION, value: "true"}
    - {name: DT_OIDC_TEAMS_CLAIM, value: groups}
    - {name: DT_TELEMETRY_SUBMISSION_DEFAULT_ENABLED, value: "false"}
  web:
    resources:
      requests: {cpu: 250m, memory: 2Gi}
      limits: {memory: 2Gi}
frontend:
  image:
    tag: 5.2.2@sha256:fd15b6cdc38692518a703eab0ed2867fa34e1276034cbe00773c61a9975cf719
  securityContext:
    allowPrivilegeEscalation: false
    capabilities: {drop: [ALL]}
    runAsNonRoot: true
    readOnlyRootFilesystem: true
    seccompProfile: {type: RuntimeDefault}
  additionalVolumes:
    - {name: nginx-conf, emptyDir: {}}
    - {name: frontend-config, configMap: {name: dependency-track-frontend-config}}
  additionalVolumeMounts:
    - {name: nginx-conf, mountPath: /etc/nginx/conf.d}
    - {name: frontend-config, mountPath: /opt/owasp/dependency-track-frontend/static/config.json, subPath: config.json}
```

Save the block as `values.yaml` outside the repository and render:

```sh
helm template dependency-track dependency-track --repo https://dependencytrack.github.io/helm-charts --version 2.10.0 \
  -n dependency-track -f values.yaml
```

The output equals `dependency-track.yaml` without its three header lines (`diff <(tail -n +4 dependency-track.yaml) <(helm template …)` is empty).
A chart bump: render with the new version, replace the file, update the header, review the diff.
