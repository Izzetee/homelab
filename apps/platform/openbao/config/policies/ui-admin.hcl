# the owner's web UI (sign-in `oidc-ui`): app values under secret/apps/ (create, read, update, soft delete, undelete) and
# read and update of the existing entries of three app paths; no destroy, no metadata write, nothing outside `secret/`
path "secret/data/apps/*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "secret/metadata/apps/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/" {
  capabilities = ["list"]
}
path "secret/delete/apps/*" {
  capabilities = ["update"]
}
path "secret/undelete/apps/*" {
  capabilities = ["update"]
}
# no `create` (no new entry), no delete, undelete or destroy, no metadata write on these three paths
path "secret/data/agentgateway/*" {
  capabilities = ["read", "update"]
}
path "secret/metadata/agentgateway/*" {
  capabilities = ["read", "list"]
}
path "secret/data/juraticker/*" {
  capabilities = ["read", "update"]
}
path "secret/metadata/juraticker/*" {
  capabilities = ["read", "list"]
}
path "secret/data/open-webui/*" {
  capabilities = ["read", "update"]
}
path "secret/metadata/open-webui/*" {
  capabilities = ["read", "list"]
}
