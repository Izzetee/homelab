# ansible

Playbooks and roles that prepare the nodes and install K3s with the
[k3s-ansible](https://github.com/k3s-io/k3s-ansible) collection, pinned in
`requirements.yml`.

Install the requirements once per workstation:

```sh
ansible-galaxy collection install -r ansible/requirements.yml
```

Rules:

- Secret inputs (for example the cluster join token) come only from the environment
  (`lookup('env', ...)`) or from files outside this repository, never from inventory
  variables.
- Inventory files hold hostnames and groups only.
- Every change passes `ansible-lint` in CI.

Playbooks are added together with the cluster definition.
