path "sys/policies/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/auth/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/auth" { capabilities = ["read", "list"] }
path "auth/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/mounts/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/mounts" { capabilities = ["read", "list"] }
path "sys/audit*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/storage/raft/*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
