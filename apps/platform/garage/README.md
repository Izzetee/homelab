# garage

An S3-compatible object store (Garage) for the LAN and for workloads in the cluster: one node, path-style addressing, region `garage`.

- Endpoint for the LAN: `https://s3.lan.chill-town.de` (the exact path `/health` answers the health check). In the cluster use
  `http://garage.garage.svc:3900`.
- `buckets.json` lists the buckets, their size and object limits, the key names and what each key may do on which bucket
  (`read`, `write`; no key owns a bucket or creates buckets). It holds names only, never a key value. `budgetBytes` is the upper bound of
  the sum of the bucket sizes.
- Key values come from the secret store through `ExternalSecret`s; this repository holds references only.
- A CronJob copies the buckets with a read-only key and checks the copy.
- Image `dxflrs/garage` is AGPL-3.0 licensed and used unmodified.
