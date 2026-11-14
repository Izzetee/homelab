path "secret/data/platform/*" {
  capabilities = ["read"]
}
path "secret/data/argocd/*" {
  capabilities = ["read"]
}
path "secret/data/authentik/*" {
  capabilities = ["read"]
}
path "secret/data/cert-manager/*" {
  capabilities = ["read"]
}
path "secret/data/cloudflared/*" {
  capabilities = ["read"]
}
path "secret/data/external-dns/*" {
  capabilities = ["read"]
}
path "secret/data/juraticker/*" {
  capabilities = ["read"]
}
path "secret/data/monitoring/*" {
  capabilities = ["read"]
}
path "secret/data/open-webui/*" {
  capabilities = ["read"]
}
path "secret/data/infisical/*" {
  capabilities = ["deny"]
}
path "secret/data/swarm/*" {
  capabilities = ["deny"]
}
