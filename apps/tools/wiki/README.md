# Wiki

A small wiki (Outline) for notes and runbooks at `https://wiki.lan.chill-town.de`. Sign-in is through the identity provider only; the
database runs as a CloudNativePG cluster, and a job writes a dump and a manifest of the attachment volume. Secret values live in the
store and are read through `ExternalSecret` objects.
