# Penpot

A design tool (Penpot) at `https://penpot.chill-town.de`, signed in through the identity provider (OIDC). Frontend, backend, exporter and
Valkey run together on one Raspberry Pi that carries the node label `homelab.io/penpot=true`; the database is a CloudNativePG cluster, assets
live in the object store, and a CronJob writes a dump set. The route on the `tunnel` listener carries the DNS record. Secret values live in
the store and are read through `ExternalSecret` objects.
