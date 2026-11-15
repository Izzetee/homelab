# networking

Cluster networking definitions: Cilium load-balancer address pools, layer-2 announcement
policies and network policies. Added together with the cluster definition.

`coredns-custom.yaml` adds a server block for the LAN zone `poecki.local` to CoreDNS (primary resolver first, a second one
only when the first does not answer). CoreDNS reads it on its next restart.
