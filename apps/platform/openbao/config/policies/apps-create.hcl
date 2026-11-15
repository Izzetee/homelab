# new values only: no read, update or delete, so no other app's value can be read or overwritten
path "secret/data/apps/+/*" {
  capabilities = ["create"]
}
