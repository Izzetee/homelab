# Endpoint and API token come from PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN; TLS is verified
# against the CA bundle in SSL_CERT_FILE. No credential or state lives in this repository. The apply
# wrapper replaces this file with its own copy of the same empty block, so a branch cannot point the
# provider anywhere else.
provider "proxmox" {}
