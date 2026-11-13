path "secret/data/platform/*" {
  capabilities = ["read"]
}
path "secret/data/cert-manager/*" {
  capabilities = ["read"]
}
path "secret/data/cloudflared/*" {
  capabilities = ["read"]
}
path "secret/data/monitoring/*" {
  capabilities = ["read"]
}
path "secret/data/infisical/*" {
  capabilities = ["deny"]
}
path "secret/data/swarm/*" {
  capabilities = ["deny"]
}
