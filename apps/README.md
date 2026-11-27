# apps

One directory per application, each a kustomization or a Helm values set that ArgoCD
syncs from `main`.

Conventions:

- Images are pinned `tag@digest` and available for `linux/amd64` and `linux/arm64`, or the
  pod is pinned to one architecture with a `kubernetes.io/arch` node selector.
- Secrets are `ExternalSecret` references by key name, never values.
- The Raspberry Pi agents carry the taint `homelab.io/pi=true:NoSchedule`. A workload that tolerates it (DaemonSets aside) must be
  allowlisted, stateless (no PVC, `nfs` or `hostPath` volume), multi-arch, require `homelab.io/link NotIn [wifi]` and
  `kubernetes.io/hostname NotIn [pi4-1]`, only prefer `homelab.io/node-class In [pi]`, and have an egress policy that allows no
  private range except cluster DNS (its pods leave with the node's LAN address).
- Penpot's pods require the node label `homelab.io/penpot=true`, set in the Ansible host variables.
- Dependency-Track is rendered once from its Helm chart into plain manifests (`tools/dependency-track/README.md` holds the values and the command): a chart bump is a re-render and a reviewed diff.
- `kustomize build <dir> | kubeconform -strict` passes locally and in CI.

Layout:

- `root.yaml` is the root app-of-apps. It deploys the Applications in `_argocd/` (one file each, ordered by
  `argocd.argoproj.io/sync-wave`: -3 Gateway API CRDs, -2 Cilium, -1 cert-manager, csi-driver-nfs, CloudNativePG and the
  storage classes, 0 load balancer pool and L2 policy, certificate issuers and the gateway, 1 cloudflared and ArgoCD itself).
  The Application health check in `platform/argocd/values.yaml` makes the root wait for a wave before it creates the next.
- `platform/<name>/` holds the values file of a chart, or the manifests of an application that is not a chart.
- The load balancer pool and the L2 policy live in `../networking/`.
- Namespaces carry an explicit Pod Security `enforce` label: `restricted` everywhere (including `cilium-secrets`, which the Cilium chart creates and which holds no pod) except `csi-driver-nfs`
  (`privileged`: the node plugin mounts volumes through host paths), `node-exporter` (`privileged`: host metrics need the host
  network, the host PID namespace and read-only host paths; it holds only the node-exporter DaemonSet) and `kube-system`
  (exempt cluster-wide: Cilium).
- Every Application, the root included, syncs automatically with self-heal and without pruning: a manifest removed from Git
  shows as out of sync until the object is removed by hand (see below).

Removing the platform. The child Applications have no deletion finalizer, so deleting the root with a cascade or
without removes only the Application objects, never their workloads, and a child deleted without a cascade is left
behind with its objects. Work from the top while ArgoCD still runs:

1. `argocd app delete --core root --cascade=false`: the children stay.
2. Workload children, in reverse wave order, each with `argocd app delete --core <app> --cascade` and waiting until it is
   gone before the next: `cloudflared`; then `gateway`, `cert-manager-issuers`, `networking`; then `cert-manager`,
   `csi-driver-nfs`, `cloudnative-pg` (first make sure no Certificate, no PVC of the NFS class and no database cluster
   still depends on them).
3. Without a cascade (`--cascade=false`): `storage` (the StorageClasses and the `Retain` volumes stay), `gateway-api`
   and every CRD-only part (the CRDs stay), and `cilium` (it is the node network; removing it is part of resetting the
   nodes).
4. Only when every Application above is gone: `argocd app delete --core argocd --cascade=false`, then
   `helm uninstall argocd -n argocd` (the release is `argocd`, the chart `argo-cd`).
5. CRDs, StorageClasses, `Retain` volumes and their data stay until they are removed by hand, and only after no object of
   that kind is left.

## Object storage

`platform/garage/` is a single-node Garage (S3-compatible object store, Application `garage`, wave 4, namespace `garage`): StatefulSet on
the node that holds its two local volumes, Services of type `ClusterIP`, an `HTTPRoute` on the `lan` listener only, network policies
with default deny, `ExternalSecret`s for the key pair of the copy job and the RPC secret, and a CronJob that copies the buckets.
`buckets.json` is the list of buckets, limits, key names and grants; see its README.

## Observability

`observability/` holds the metrics, logs, traces, alerts and dashboards. Its Applications belong to the AppProject
`observability` (this repository and three pinned chart repositories as sources, the namespaces `monitoring` and `node-exporter`
as destinations):

| Application | Wave | Content |
|---|---|---|
| `observability-base` | 2 | the two namespaces, the `grafana-sidecar` Role, the ingress policy of `monitoring`, the egress policies of the SNMP exporter and Prometheus (the second Prometheus policy allows the host exporters), the `ExternalSecret`s of the NAS SNMPv3 login and the Home Assistant token |
| `kube-prometheus-stack` | 3 | Prometheus Operator and CRDs, Prometheus (30 days, local volume), Alertmanager (Discord), kube-state-metrics, node-exporter, Grafana |
| `loki`, `tempo`, `alloy`, `blackbox-exporter`, `snmp-exporter` | 4 | Loki (14 days), Tempo (7 days), Alloy (pod logs and events through the API, OTLP), blackbox exporter, SNMP exporter (NAS over SNMPv3) |
| `observability-config` | 5 | ServiceMonitors, probes, the scrape configs of the NAS, Home Assistant and the hosts outside the cluster, alert rules, the overview, NAS, Home Assistant, hosts and host detail dashboards, the Grafana route |

- Values files live next to the Application name (`observability/<application>/values.yaml`); every image is `tag@digest`.
- Grafana is stateless: datasources and dashboards come from this repository (ConfigMaps with the label `grafana_dashboard`),
  edits in the UI are lost on a restart. It is served at `grafana.lan.chill-town.de` through the `lan` listener of the gateway. Its admin
  account and the Alertmanager Discord webhook come from the Secrets `grafana-admin` and `alertmanager-receiver`, which `ExternalSecret`s in
  `observability/base/` fill from the store (see "Secret store"); Alertmanager reads the webhook URL from a file of that Secret.
- The NAS is scraped over SNMPv3 through the SNMP exporter (job `nas`, one 60 s scrape); its user and passwords are environment variables
  of the exporter from the Secret `nas-snmp` (the config holds only `${…}` markers). Home Assistant's metrics endpoint is scraped
  with a bearer token from the Secret `home-assistant-token` (job `home-assistant`); the token is the Home Assistant user's own long-lived
  token and can call every Home Assistant service, so it belongs to a non-administrator account that may log in only from the local network.
- Alert rules: `observability/config/rules/homelab-rules.yaml`, unit tests in `observability/config/rules/tests/` (promtool,
  outside the kustomization). Dashboards of the chart are the defaults for the scraped components; `homelab-overview` is ours.
- Traces: send OTLP to `alloy.monitoring.svc:4317` (gRPC) or `:4318` (HTTP); Alloy forwards them to Tempo.
- A first sync of the stack on a new cluster is done by hand, wave by wave: `argocd app diff --core <app>`, namespaces first, then the
  CRDs of `kube-prometheus-stack` (wait until they are `Established`), then the rest of each Application; the Applications sync
  automatically from then on.

Removing the observability stack. Work from the top while ArgoCD still runs, so that nothing re-creates what is deleted:

1. `argocd app set --core root --sync-policy none`, then the same for every observability Application that syncs automatically.
2. In reverse wave order, each with `argocd app delete --core <app> --cascade` and waiting until it is gone:
   `observability-config`; `loki`, `tempo`, `alloy`, `blackbox-exporter`, `snmp-exporter`; `kube-prometheus-stack` (the Prometheus Operator CRDs go
   with it); `observability-base` (the namespaces and the volumes in them go with it).
3. Merge a revert of the change that added the Applications and the AppProject; delete the AppProject by hand if it stays behind
   (the `argocd` Application does not prune).
4. Delete the Secrets that the `ExternalSecret`s of `observability/base/` keep with `creationPolicy: Orphan` if their namespace still exists, then restore the
   sync policy of the root (`apps/root.yaml`) and check that every remaining Application is `Synced` and `Healthy`.

## Secret store

`platform/openbao/` (three servers, integrated storage, TLS from cert-manager, static unseal key), `platform/external-secrets/` (the
operator) and `platform/secret-store/` (the `ClusterSecretStore` named `openbao`) belong to the AppProject `platform`. Waves: `external-secrets`
-1, `openbao` 0, `secret-store` 1. A first sync on a new cluster is by hand after `argocd app diff --core <app>`, the
CRDs of `external-secrets` first (wait until they are `Established`), then the rest; the Applications sync automatically from then on
(self-heal, no pruning).

- Secrets are read through `ExternalSecret` objects that name `ClusterSecretStore/openbao` and a key path; the store serves the
  namespaces listed in `platform/secret-store/cluster-secret-store.yaml` only.
- `platform/openbao/config/` holds the policies, the Kubernetes auth roles and the namespace list that the operations tooling applies
  to a running store. They contain no values.
- A renewed serving certificate is read at the next start: `kubectl -n openbao rollout restart statefulset openbao`.
