# Wiki

A small wiki (Outline) for notes and runbooks, reachable only on the LAN at `https://wiki.lan.chill-town.de`. Sign-in is through the
identity provider only; the database runs as a CloudNativePG cluster, a nightly job writes a dump and a manifest of the attachment
volume. Secret values live in the store and are read through `ExternalSecret` objects; nothing is exposed publicly.
