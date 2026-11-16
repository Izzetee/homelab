---
name: secrets
description: Get credentials into one command's environment and create app values with the helper tools/bao/homelab-bao, never printing or passing a value. Use whenever a tool needs a token or a key, or an app needs a generated or entered value.
---

# secrets

## Login

`tools/bao/homelab-bao login` opens a browser; the owner completes the sign-in and the consent page. `status` shows the policies and the time left. `logout` revokes the token. `FAIL login needed` means stop and ask the owner.

## Reading

`homelab-bao names` lists the entry names. `homelab-bao check <entry>` shows field names and the version. `homelab-bao run <entry>[,<entry>] -- <command>` runs the command
with the fields as environment variables: `github` (`GH_TOKEN`), `ghcr` (`GHCR_PULL_TOKEN`), `cloudflare-dns` (`CLOUDFLARE_API_TOKEN`), `cloudflare-access`
(`CLOUDFLARE_ACCESS_TOKEN`, `CLOUDFLARE_ACCESS_EMAIL`, `CLOUDFLARE_ACCOUNT_ID`), `door-scan` (`DOOR_SCAN_SSH_KEY`, `DOOR_SCAN_TARGET`, `DOOR_SCAN_KNOWN_HOST`), `renewal-check`,
`wiki-pi` and `wiki-herdr` (`WIKI_TOKEN`). Take only the entries the command needs.

## Creating app values

`homelab-bao put-generated [--dry-run] <app> <name> <key>...` creates random values at `secret/apps/<app>/<name>` (create only: an existing path is `FAIL exists or denied`). Run `--dry-run` first.
`homelab-bao put-entered [--dry-run] <app> <name> <key>` is for a value only the owner has; it needs a terminal, so ask the owner to run it. Changing or deleting a value later is the owner's.

## Rules

Never print a value, never pass one as an argument, never write one to a file that is committed, never use `.env` or another file as a fallback, never run `bash -x` around a call. Renewing
an entry is the owner's.
