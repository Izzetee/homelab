# blocky

The LAN DNS resolver with ad blocking: [Blocky](https://github.com/0xERR0R/blocky), one pod on every amd64 VM node, behind one load
balancer address. Its whole configuration is `config.yml` in this directory (a generated ConfigMap, so a changed file replaces the pods);
there is no state to back up.

- Address: `192.168.1.4`, UDP and TCP port 53. The Service `blocky-dns` keeps the client's own address (`externalTrafficPolicy: Local`), so
  per-client groups, client metrics and the query log name the real device.
- Metrics: Service `blocky`, port 4000 (`/metrics`); Prometheus scrapes it as job `blocky`.
- Rolling update: one extra pod per node, none unavailable; a new pod answers only after its deny lists are loaded.

## Query path

Blocky answers in this order, and the first step that matches wins:

1. custom records (`customDNS`): everything below `lan.chill-town.de` is answered with the gateway address, also without the internet;
2. blocking (deny and allow lists of the client's groups): a blocked name gets `0.0.0.0` for 1 minute;
3. cache (with prefetching of often asked names, per pod);
4. conditional zones (`conditional`): `poecki.local` and `vault.poecki.de` go to the current LAN resolver, the reverse zone
   `1.168.192.in-addr.arpa` to the router. Conditional names are blocked and cached like any other name;
5. upstreams: public names go over DNS-over-TLS to Cloudflare (`1.1.1.1`, `1.0.0.1`) and Quad9 (`9.9.9.9`, `149.112.112.112`), the two
   answering fastest of the group win.

## Changing the configuration

1. Edit `config.yml` (the file to edit for every change below).
2. Check it: `blocky validate --config config.yml` with the Blocky release of the image tag in `daemonset.yaml`, and
   `kustomize build apps/platform/blocky | kubeconform -strict`.
3. Open a pull request; after the merge, ArgoCD replaces the pods one node at a time (the ConfigMap name suffix changes).
4. Test: `dig @192.168.1.4 example.com` and `dig @192.168.1.4 blocky-canary.chill-town.de` (see Testing).

## Deny lists

`blocking.denylists` maps a group name to a list of sources: a URL, a file, or an inline block. Group `ads` is the StevenBlack unified
hosts list; group `canary` holds one inline name that exists nowhere and is always blocked.

- Add a list: put its URL under a group, **and add the list's host as an exact name** (`matchName`) to the `toFQDNs` rule of
  `network-policy.yaml`: the pods may open HTTPS to the named hosts only.
- Remove a list: delete its line (and the host from the rule when no other list uses it).
- Lists are downloaded when a pod starts and every 4 hours (`loading.refreshPeriod`). A big list needs memory: the limit is in
  `daemonset.yaml`; watch the memory panel of the dashboard after adding one.
- A new group applies to a client only through `clientGroupsBlock` (below).

## Allow lists

`blocking.allowlists` has the same shape. Inside a group an allow entry beats a deny entry, so allowing a name that a list blocks is one
line under the same group. An entry is a plain name (also covers its subdomains), a hosts-style line, a URL or file, or a regex between
slashes (`/^banners?[_.-]/`). If every group of a client has only allow entries, that client may resolve only those names.

## Local records

- `customDNS.mapping`: a name and all its subdomains get fixed addresses (several separated by commas). Types without a mapping (for
  example AAAA) answer empty instead of being forwarded.
- `conditional.mapping`: a zone (and its subdomains) is forwarded to one resolver. Use one resolver per zone: several are asked in
  parallel and their answers (an answer and an NXDOMAIN) mix.
- Reverse lookups of the LAN go to the router through the reverse zone; `clientLookup.upstream` uses the router to name clients.
- A new local name or zone is one line in `config.yml`. A new resolver address needs a matching `toCIDR` entry in the egress rule.

## Per-client groups

`blocking.clientGroupsBlock` maps a client to the groups that apply to it. A client is an address, a CIDR, or a name with wildcards
(`laptop*`); `default` applies to every other client. Example: a device gets no deny lists with

```yaml
clientGroupsBlock:
  default: [ads, canary]
  192.168.1.50: [canary]
```

This works because the load balancer keeps the client's own address.

## Temporarily switching blocking off

Blocky's HTTP API (Service `blocky`, port 4000):

```sh
kubectl -n blocky port-forward svc/blocky 4000:4000
curl 'http://127.0.0.1:4000/api/blocking/disable?duration=10m'   # and /api/blocking/enable
```

The API acts on one pod per call; repeat for every pod (`kubectl -n blocky port-forward pod/<name> …`) or change `config.yml` instead.
Stop the port-forward afterwards. An alert fires when blocking stays off for 15 minutes.

## Upstreams

Group `default` holds four DNS-over-TLS addresses with their certificate names; no plain DNS leaves the cluster. Changing the protocol
or an address also changes the egress rule (`toCIDR` and port) and the upstream probes in `apps/observability/config/probes.yaml`.

## Rebinding protection and DNSSEC

Both are off, as with the previous resolver. Turn them on in `config.yml`: `rebindingProtection.enable: true` (it drops answers from the
internet that point into private ranges; allow split-horizon names under `allowedDomains`, for example `plex.direct`) and
`dnssec.validate: true` (answers with a broken signature turn into SERVFAIL). Test with the LAN names afterwards.

## Testing

```sh
dig @192.168.1.4 healthcheck.blocky              # NOERROR: the resolver is up
dig @192.168.1.4 example.com                      # a normal answer
dig @192.168.1.4 blocky-canary.chill-town.de      # 0.0.0.0: blocking works without a download
dig @192.168.1.4 affine.lan.chill-town.de         # the gateway address
dig @192.168.1.4 -x 192.168.1.1                   # a reverse lookup through the router
```

## Dashboards

Grafana dashboard `dns`: traffic, blocked share, cache hit rate, latency, answers per upstream, per-provider upstream probes, top
clients and the state per pod (replicas, list size and age, memory, restarts). Dashboard `dns-queries`: top queried, blocked and
NXDOMAIN domains, top clients and the filterable query log.

## Alerts

`HomelabDnsDown` (no ready replica, or the LAN probe fails for 2 minutes), `HomelabDnsReplicaDown`, `HomelabDnsUpstreamErrors` (more
than 5 % of the answers are errors), `HomelabDnsListsStale` (a list is older than 12 hours, empty, or its download keeps failing) and
`HomelabDnsBlockingDisabled`. The rules and their tests are in `apps/observability/config/rules/`.

## Query log

Every resolved query is one JSON line on the pod's stdout, collected into Loki like every other log: the query log is in Grafana
(dashboard `dns-queries`). What is logged is the `queryLog` block of `config.yml`.

## Troubleshooting

- A name does not resolve: `dig @192.168.1.4 <name>`; compare with `dig @1.1.1.1 <name>`. The reason of the answer (list, custom record,
  cache, upstream) is in the query log line of that query (dashboard `dns-queries`, filter by domain).
- Wrongly blocked: the line shows `BLOCKED (<group>)`; add the name to an allow list (above).
- No answer at all: `kubectl -n blocky get pods -o wide` (one pod per amd64 node, all ready); a pod that is not ready is not served from.
  `kubectl -n blocky logs ds/blocky` shows list download errors.
- A list does not load: check that its host is in the `toFQDNs` rule of `network-policy.yaml`.
- Probe `blocky-lan` failing while pods are ready: the load balancer address is announced by a node with a ready pod only; check
  `kubectl -n kube-system get lease | grep blocky`.
