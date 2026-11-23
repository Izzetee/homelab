path "sys/policies/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/auth/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/auth" { capabilities = ["read", "list"] }
path "auth/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/mounts/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/mounts" { capabilities = ["read", "list"] }
path "sys/audit*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/storage/raft/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
# Removing an application: list and read the metadata of its store entries and delete them (metadata delete removes every version), below apps/ only.
# No read of any value, no write, nothing outside apps/.
path "secret/metadata/apps/*" { capabilities = ["list", "read", "delete"] }
path "secret/data/apps/*" { capabilities = ["delete"] }
