# offboard-test

A throwaway application that exists only to rehearse removing an application (skill `offboard-app`). It serves one static page, keeps one
table with one row in a CloudNativePG cluster, one object in its own Garage bucket and one dump set on the NFS volume, and has an
identity-provider client that nothing uses. Nothing here is real data and nothing depends on it; the whole directory is removed by the
rehearsal itself.

- LAN name `offboard-test.lan.chill-town.de`; a second route for `offboard-test.chill-town.de` through the tunnel, behind an access policy.
- Secret values live in the store; the pods read them through `ExternalSecret` objects.
