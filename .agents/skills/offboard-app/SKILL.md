---
name: offboard-app
description: Remove an application from the cluster with two pull requests (writer stop, then removal of every Git reference) and one owner go that names every deletion and credential revocation. Use when asked to retire, remove or offboard an app.
---

# offboard-app

Removing an app is irreversible once data is deleted. Two pull requests prepare it; the live deletions run only under the owner's go, one line per deletion and per credential, through the operators' door. Nothing is deleted from this repository's tooling and nothing is deleted by hand.

## Steps

1. **Census.** List every object and credential of the app: Application, namespace, claims and volumes, database clusters, `ExternalSecret`s and the store entries they read, object-storage bucket and key, route, Access application, DNS name, network policy and monitoring objects outside the namespace, identity-provider objects, trigger rules for the operators, backup jobs. Each credential gets one revoke line with the step that revokes it and its proof.
2. **Writer stop (PR 1).** `replicas: 0` for every writer workload, inside `apps/tools/<app>/` only. After the merge wait until no writer pod exists. The final backup and its drills are taken from this state, never before it.
3. **Removal (PR 2), branched on PR 1.** PR 1 changes files that PR 2 deletes; two independent branches end in a modify/delete conflict at the rebase merge. Base PR 2 on the head of PR 1, and before asking for the go rehearse the merge of PR 2 onto the state `main` has after PR 1 (a rebase in a scratch clone: no conflict). PR 2 removes every reference in Git: the Application file, the namespace and project destination, the store condition and namespace list entry, routes, network policy entries, probes, rules and guard bindings outside the namespace, identity-provider objects (by the inverse of the pattern that created them: one blueprint that removes them, kept until the objects are gone), and the documentation lines that name the app.
4. **What the merge removes.** The synced objects that the removal drops leave with it, through the sync of the Application that owned them. Objects the sync never deletes (the Application itself, the namespace, claims and database clusters) and all data are removed by the operators' door from a record written before PR 2 is merged. Name in the report every object of the census that neither path removes.
5. **Checks.** `kustomize build` and `kubeconform -strict` for every changed directory, `homelab-door --dry-run <branch>` for both branches, gitleaks, the image and version checks do not apply (nothing is added).
6. **The go.** Ask for one go that lists, in this order: the writer-stop merge `#<n> @ <40-hex head>`; the final backup jobs and pulls; the restore drills of exactly the final sets; the record; the removal merge `#<n> @ <40-hex head>` (it is rebased onto the merged writer stop and merged only with an equal patch-id and a fresh `ci-ok`); one line per live deletion with the hash the inventory printed for it; one revoke line per credential with its proof. Every merge, deletion and revoke line is a hard-stop line.
7. **Order.** Writer stop, final backups, drills (each must pass, each names its exact set), the record, removal merge, then the live deletions through the door: Kubernetes objects, volumes, the route's Access application and name (after the namespace, because the removal refuses while a route names the host), object storage, store entries, the app's local DNS name, the older backup sets. A failure stops the run; a later run continues from the record under a new go.

## Never

A deletion that the go did not name; a deletion by name pattern; a finalizer removal; a direct `kubectl delete`; a drill of "the newest" instead of the named final set; touching another app or a platform namespace.

Then write the changelog entry for each merged pull request and update the operations page (skill `wiki-changelog`).
