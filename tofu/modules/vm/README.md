# vm module

Contract of the VM module (implemented together with the cluster definition):

- Creates virtual machines from a cloud image in a dedicated resource pool.
- Refuses to manage a guest it did not create, and refuses to touch guests outside that
  pool.
- Refuses unconditionally to create, change or destroy the guest with VMID 100, whatever the
  pool or ownership checks say.
- Checks host capacity before it creates anything, so new VMs cannot starve the guests that
  already run there.
- Takes no credentials as variables; provider authentication comes from the environment.
