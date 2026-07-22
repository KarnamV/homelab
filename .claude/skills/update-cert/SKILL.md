---
name: update-cert
description: Swap a newly-copied mkcert TLS cert/key into Traefik on this homelab box (bitforge), restart Traefik, and verify the new cert is actually being served for every hostname in its SAN. Use when the user says they've copied a new cert to the server, asks to "update the cert", "renew the cert", "swap in the new cert", or runs `/update-cert` — typically after generating a new mkcert cert locally (e.g. to add a new *.bitforge subdomain to the SAN list) and dropping it in /tmp on this server.
---

# /update-cert — install a new mkcert cert into Traefik

Context: this homelab (host `bitforge`, `192.168.0.165`) uses Traefik as a
reverse proxy terminating TLS for internal `*.bitforge` services, with a
mkcert-issued cert whose SAN lists every hostname explicitly (a wildcard
`*.bitforge` was tried first and rejected by the browser — see project
history). Whenever a new service is added, the cert must be regenerated with
mkcert (on the user's PC) to include the new hostname in its SAN, then copied
to this server — that's where this skill picks up.

## Preconditions

The user (or their PC-side agent) has already:
1. Run `mkcert bitforge portainer.bitforge uptime.bitforge ... ` (same CA as
   before) to produce a new `<name>.pem` / `<name>-key.pem` pair.
2. Copied both files to `/tmp` on this server.

If the user mentions a different drop location, pass it explicitly (see
below) — don't assume /tmp.

## Step 1 — run the script

The script `apply-cert.sh` ships alongside this SKILL.md under `scripts/`. It
does everything mechanically:

```bash
<skill-dir>/scripts/apply-cert.sh [/path/to/new-cert.pem]
```

- With no argument, it picks the newest `*.pem` in `/tmp` that isn't a
  `*-key.pem` file (matching mkcert's naming: `foo+2.pem` / `foo+2-key.pem`).
- It derives the matching key path by swapping the `.pem` suffix for
  `-key.pem` — this is mkcert's convention, not a guess.
- It resolves the **current** certFile/keyFile from
  `compose/traefik/config/dynamic.yml` and maps the container path
  (`/certs/...`) to its real host path via `docker inspect` on the running
  Traefik container's mounts — it does not hardcode the host path, so it
  keeps working if the mount changes.
- It backs up the existing cert/key to `.bak` before overwriting.
- It preserves the **existing file's permission bits** on the new files
  (reads them with `stat` first) rather than assuming a fixed mode — the
  previous cert/key were `664`, not `600`, because Traefik's container reads
  the bind-mounted key via the group/other bit, not as the owning uid. Do not
  hardcode `600` here even if that looks like the "secure" default.
- It restarts the Traefik container. (Confirmed in this project: the file
  provider's `watch: true` does **not** reliably hot-reload a cert swap —
  `s_client` kept showing the old cert until Traefik was restarted.)
- It verifies the swap by querying `openssl s_client -servername <host>` for
  **every** hostname in the new cert's SAN (not just one), and only cleans up
  the `/tmp` source files if every single one matches.

## Step 2 — read the output, don't just check the exit code

Report to the user, for each hostname the script checked: the SAN and issuer
Traefik is now serving. This mirrors how the cert swap was validated
originally — the failure mode to watch for is Traefik silently continuing to
serve the *old* cert (stale hot-reload, or a second cert entry / default-cert
override elsewhere), which the script catches per-host, not just once.

If the script exits non-zero: it deliberately left the `/tmp` files in place
and did **not** silently retry. Read its output to see which host failed
verification, and check for a second `tls.stores.default.defaultCertificate`
or a competing `certFile` entry before re-running — don't just re-run it
blindly.

## Step 3 — summarize

Tell the user:
- Which hostnames are now covered.
- Where the previous cert/key were backed up (`<path>.bak`), in case of
  rollback.
- That the `/tmp` source files were shredded (or, if verification failed,
  that they were deliberately left in place).
