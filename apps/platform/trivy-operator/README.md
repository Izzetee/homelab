# Trivy Operator

Image vulnerability, configuration audit and SBOM reports for the running workloads. Application `trivy-operator` (project
`platform`, wave 4, namespace `trivy-system`): chart `trivy-operator` from `https://aquasecurity.github.io/helm-charts` with the
values in `values.yaml`, plus the manifests of this directory.

- **Mode**: client/server. The chart's Trivy server (`trivy-server`, database in an emptyDir) holds the vulnerability database; scan
  jobs run in `trivy-system` on the amd64 agents, two at a time (`scanJobsConcurrentLimit`).
- **Reports**: `VulnerabilityReport`, `ConfigAuditReport` and `SbomReport` (and the cluster-scoped SBOM cache) of `aquasecurity.github.io`.
  A report expires after `operator.scannerReportTTL`; the operator then deletes it and scans the workload again, reusing the cached SBOM.
- **Metrics**: the ServiceMonitor, the alert rules and the `Vulnerabilities` dashboard are in `apps/observability/config/`; the
  Alertmanager route of the image alert is in `apps/observability/kube-prometheus-stack/values.yaml`.
- `network-policy.yaml`: default deny plus the rules of the operator, the Trivy server and the scan pods (label
  `app.kubernetes.io/component=scan-job`, set by `trivyOperator.scanJobPodTemplateLabels`).
- `job-policy.yaml`: a ValidatingAdmissionPolicy that admits Job create and delete requests of ServiceAccounts of `trivy-system` only in `trivy-system`.

A chart bump: change `targetRevision` in `apps/_argocd/trivy-operator.yaml`, check the rendered diff, keep the image pins in `values.yaml`
(`tag@digest`) in step with the chart's `appVersion`.
