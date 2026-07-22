# Authentik

Self-hosted identity provider (SSO / OAuth2 / SAML / LDAP / forward-auth) for
the homelab.

- **Phase 1** (done): core stack running and reachable at `https://authentik.bitforge`.
- **Phase 2** (done, proof of concept): Traefik forward-auth protecting
  Portainer via Authentik's embedded outpost. See "Phase 2: forward-auth"
  below for how it's wired and how to add another service.

> No existing doc convention existed in `homelab/docs/` (the directory was
> empty) — this file's structure follows the README written for
> [`compose/uptime-kuma-sync`](../compose/uptime-kuma-sync/README.md), the
> only other documented service in this repo.

## Purpose

Authentik centralizes login for homelab services: one account, one MFA
enrollment, one place to revoke access, instead of per-app credentials.
Typical uses once later phases land: Traefik forward-auth in front of
Grafana/Portainer/Uptime Kuma, OAuth2 for apps that support it, and an LDAP
outpost for anything that only speaks LDAP.

## Architecture

```
                  ┌──────────────┐
  Traefik  ─────▶ │ authentik-   │ :9000
  (websecure,     │ server       │
   authentik.     └──────┬───────┘
   bitforge)             │
                          │  proxy + authentik networks
                  ┌───────┴───────┐
                  │  authentik-   │
                  │  postgresql   │  (authentik network only)
                  └───────┬───────┘
                          │
                  ┌───────┴───────┐
                  │  authentik-   │  (authentik network only,
                  │  worker       │   + docker.sock, root)
                  └───────────────┘
```

- **authentik-server** — handles all HTTP traffic (login flows, API, admin
  UI). The only Authentik component on the `proxy` network / reachable
  through Traefik.
- **authentik-worker** — runs background tasks (scheduled jobs, outpost
  management, LDAP/proxy outpost lifecycle if you add them later). Needs
  `/var/run/docker.sock` and runs as root because it can manage Docker-based
  outposts — see Security recommendations below if you don't need that.
- **authentik-postgresql** — the only datastore. **No Redis** — see next
  section.

### Why no Redis

The task this stack was built from asked for Postgres *and* Redis, matching
older Authentik deployment guides. As of authentik 2025.8 background tasks
moved off Redis, and as of **2025.10 Redis was removed entirely** — caching,
the embedded outpost, and inter-process pub/sub all moved to PostgreSQL. We're
deploying `2026.5.5` (current latest stable, well past that change), whose
own [reference compose file](https://docs.goauthentik.io/compose.yml) has no
Redis service and no `AUTHENTIK_REDIS__*` variables. Adding one anyway would
be a dead, unused container — omitted, deliberately, contra the literal
request. ([authentik blog: "We removed Redis"](https://goauthentik.io/blog/2025-11-13-we-removed-redis/))

## Directory layout

```
homelab/compose/authentik/
├── compose.yaml       # the stack: postgresql, server, worker
├── .env.example       # placeholder values, safe to commit
└── .env                # real secrets — created by you, git-ignored, NOT committed

homelab/data/authentik/
├── postgres/           # Postgres data directory (bind mount)
├── media/              # user-uploaded media (avatars, branding) — shared by server + worker
├── templates/           # custom email/flow templates — shared by server + worker
└── certs/               # certs the worker needs when managing outposts
```

Matches the rest of the repo: bind mounts under `../../data/<service>/...`
rather than named Docker volumes (see `compose/loki`, `compose/promtail`,
`compose/uptime-kuma-sync`), one `compose.yaml` per service directory, `proxy`
declared `external: true` in every file that needs it.

## Required environment variables

Set these in `homelab/compose/authentik/.env` (copy from `.env.example`):

| Variable                | Required | Default      | Notes                                                        |
|--------------------------|----------|---------------|----------------------------------------------------------------|
| `PG_DB`                  | no       | `authentik`  | Postgres database name.                                        |
| `PG_USER`                | no       | `authentik`  | Postgres user.                                                  |
| `PG_PASS`                | **yes**  | —             | Postgres password. Compose fails fast (`:?required`) if unset. |
| `AUTHENTIK_SECRET_KEY`   | **yes**  | —             | Signs sessions/cookies. Compose fails fast if unset. Never rotate casually — it invalidates all sessions. |
| `AUTHENTIK_BOOTSTRAP_EMAIL` / `AUTHENTIK_BOOTSTRAP_PASSWORD` | no | — | Auto-create the initial `akadmin` account on first boot. Prefer `AUTHENTIK_BOOTSTRAP_PASSWORD_HASH` instead (see Security recommendations). |
| `AUTHENTIK_ERROR_REPORTING__ENABLED` | no | unset (defaults to authentik's own default) | Set `false` to opt out of anonymous error reporting. |

Generate the two required secrets:

```bash
cd /home/bitforge/homelab/compose/authentik
cp .env.example .env
echo "PG_PASS=$(openssl rand -base64 36 | tr -d '\n')" >> .env
echo "AUTHENTIK_SECRET_KEY=$(openssl rand -base64 60 | tr -d '\n')" >> .env
# then edit .env to remove the placeholder PG_PASS/AUTHENTIK_SECRET_KEY lines
# above the generated ones, or just overwrite them by hand.
```

## Startup instructions

Not run as part of this change — bring it up yourself when ready:

```bash
cd /home/bitforge/homelab/compose/authentik
docker compose up -d
docker compose logs -f authentik-server   # first boot runs DB migrations, takes a minute or two
```

Then visit `https://authentik.bitforge/if/flow/initial-setup/` within the
first day of the first boot to set the `akadmin` password (that flow
disables itself once a password has been set). **Do not use
`AUTHENTIK_BOOTSTRAP_EMAIL`/`AUTHENTIK_BOOTSTRAP_PASSWORD_HASH`** on this
version — see Troubleshooting below, it crash-loops `authentik-server` on a
from-scratch install.

## Verification steps

1. `docker compose ps` — all three containers should be `Up`/`healthy`
   (`authentik-postgresql` has a healthcheck; `server`/`worker` don't define
   one in the upstream image, so check their logs instead).
2. `docker compose logs authentik-server | tail -50` — look for
   `"Starting authentik"` / listener bound to `0.0.0.0:9000` without repeated
   Postgres connection errors.
3. From the server: `curl -sk -o /dev/null -w 'HTTP %{http_code}\n' -H 'Host: authentik.bitforge' https://127.0.0.1/` — expect `200` (or `302` to a login/setup flow).
4. From a browser on the LAN: `https://authentik.bitforge` — expect either
   the initial-setup flow or the login page, and (once the cert is updated —
   see Manual steps) no certificate warning.
5. `docker compose logs authentik-worker | tail -50` — look for the worker
   announcing scheduled tasks, no repeated DB connection errors.

## Troubleshooting

**Certificate warning on `https://authentik.bitforge`** — expected until you
regenerate the mkcert cert to include `authentik.bitforge` in its SAN (see
Manual steps below). Traefik will still route the request correctly; only
the TLS trust is affected, same class of issue documented in
`compose/uptime-kuma-sync/README.md`.

**`authentik-server` restarting / crash-looping right after `docker compose up`**
— almost always `AUTHENTIK_SECRET_KEY` or `PG_PASS` missing/empty; compose
should have refused to start in that case (`:?required` syntax) rather than
passing an empty string, but double-check `.env` actually has real values,
not the `changeme` placeholders.

**`authentik-postgresql` never becomes healthy** — check
`docker compose logs authentik-postgresql`; usually a permissions issue on
the bind-mounted `../../data/authentik/postgres` directory (must be writable
by the container's postgres user) or a leftover data directory from a failed
previous attempt with mismatched `PG_USER`/`PG_PASS`. If you're certain no
real data is at stake, `rm -rf` that directory and let Postgres re-init.

**Worker can't manage outposts / permission denied on `/var/run/docker.sock`**
— the worker mounts the socket read-write and runs as `user: root`
specifically for this; if you locked down `/var/run/docker.sock` permissions
further at the host level, the worker needs the same access Traefik and
`uptime-kuma-sync` already have.

**Initial-setup flow says it's expired** — that flow is only available for a
limited window after first boot with no `akadmin` password set. Recreate the
`akadmin` user's password via `docker compose exec authentik-server ak changepassword akadmin`.

**`authentik-server` crash-loops with `Worker (pid:...) exited with code 3` /
`Reason: Worker failed to boot.` every ~9 seconds, while `docker compose ps`
still shows it `healthy`** — this is a confirmed bug hit on this exact
deployment (authentik `2026.5.5`, fresh install): setting
`AUTHENTIK_BOOTSTRAP_EMAIL`/`AUTHENTIK_BOOTSTRAP_PASSWORD_HASH` makes every
worker boot run a startup signal (`authentik/core/setup/signals.py:post_startup_setup_bootstrap`)
that fails with `EntryInvalidError: KeyOf: failed to find entry with id of
'admin-group'`. Confirmed via direct DB query
(`docker exec authentik-postgresql psql -U authentik -d authentik -c "SELECT status FROM authentik_blueprints_blueprintinstance WHERE path='system/bootstrap.yaml';"`)
— that blueprint shows `status = error` while all 27 other built-in
blueprints apply successfully; the real admin group exists in
`authentik_core_group` as `authentik Admins`, just not under whatever
internal reference `system/bootstrap.yaml` expects. It's fatal on
`authentik-server` (crashes the whole worker boot) but only logged as
non-fatal on `authentik-worker`, which is why the healthcheck kept passing —
it just caught brief live windows between restarts.

Fix: don't set those two bootstrap vars; use the `/if/flow/initial-setup/`
wizard instead (this code path only runs when the vars are present, so
leaving them unset avoids it entirely). If you already hit this,
comment them out in `.env` and run `docker compose up -d` (not `restart`
— that doesn't reload `.env`) to recreate `authentik-server`/`authentik-worker`.
Postgres data isn't affected either way.

## Manual steps required after this change

1. **Create `.env`** — `cp .env.example .env` and fill in real
   `PG_PASS` / `AUTHENTIK_SECRET_KEY` (and optionally the bootstrap vars).
   This wasn't done for you; secrets are never generated or committed by
   this change.
2. **Regenerate the TLS cert to include `authentik.bitforge`** — the current
   cert's SAN is `bitforge, portainer.bitforge, uptime.bitforge,
   homepage.bitforge, grafana.bitforge, cadvisor.bitforge, prometheus.bitforge`
   (no `authentik.bitforge` yet). On your PC, with the same mkcert CA as
   before:
   ```
   mkcert bitforge portainer.bitforge uptime.bitforge homepage.bitforge \
     grafana.bitforge cadvisor.bitforge prometheus.bitforge authentik.bitforge
   ```
   Copy both output files to `/tmp` on the server, then run
   `homelab/.claude/skills/update-cert/scripts/apply-cert.sh` (or ask for it
   to be run) — same procedure used when `grafana.bitforge` and friends were
   added to the SAN.
3. **`docker compose up -d`** in `compose/authentik/` — not run as part of
   this change per instructions.
4. **Set the `akadmin` password** via the initial-setup flow or bootstrap
   vars (see Startup instructions).
5. **DNS**: nothing to do — `dnsmasq` wildcards all of `*.bitforge` to the
   server already (`compose/dnsmasq/config/dnsmasq.conf`), so
   `authentik.bitforge` resolves as soon as Traefik picks up the container's
   labels.

## Phase 2: forward-auth (proof of concept — Portainer)

Portainer now sits behind Authentik's forward-auth: hitting
`https://portainer.bitforge` unauthenticated redirects to an Authentik login
first. Uses authentik's **embedded outpost** (ships built into
`authentik-server`, confirmed running — no separate outpost container
needed for this scale).

### How it's wired

- **Authentik side**: a Proxy Provider (`mode=forward_single`, `external_host=https://portainer.bitforge`)
  plus an Application ("Portainer", group "Infrastructure") pointing at it,
  with that provider attached to the embedded outpost's `providers` list.
- **Traefik side** (`compose/authentik/compose.yaml`, on `authentik-server`'s labels):
  - middleware `authentik-forwardauth`: forwards every request through
    `http://authentik-server:9000/outpost.goauthentik.io/auth/traefik` before
    it reaches the backend.
  - router `authentik-outpost-portainer`: `Host(portainer.bitforge) && PathPrefix(/outpost.goauthentik.io/)`,
    priority 15 (must outrank the app's own router) — routes Authentik's own
    login-callback requests (which land on `portainer.bitforge`, not
    `authentik.bitforge`) to `authentik-server` instead of to Portainer.
  - `compose/portainer/compose.yaml`: its router gets
    `traefik.http.routers.portainer.middlewares=authentik-forwardauth@docker`
    and an explicit `priority=10` (lower than the outpost router above).

This is authentik's documented "single application" forward-auth pattern —
one router pair per protected host. See
[docs.goauthentik.io: Traefik](https://docs.goauthentik.io/add-secure-apps/providers/proxy/server_traefik)
for the "domain-level" alternative (one shared wildcard router covering
every `*.bitforge` host) if this gets extended to many services later.

### How the Provider/Application were created

There's no docker-compose-native way to create Authentik objects (they live
in its database, configured via UI or API/blueprints, not env vars). This
was done via `authentik`'s REST API using a temporary admin API token
(created via `docker exec authentik-server ak shell`, deleted again
immediately after). To add another service the same way:

```bash
TOKEN=<generate one the same way, or use the web UI instead — Admin interface > Applications>

# 1. Create the proxy provider (forward_single mode)
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{
    "name": "<Service>",
    "authorization_flow": "509403a2-24be-41a3-a4de-9fa7b41f1c80",
    "invalidation_flow": "6fca3312-ace8-450c-b9d7-4fd8d0342536",
    "external_host": "https://<service>.bitforge",
    "mode": "forward_single"
  }' \
  http://authentik-server:9000/api/v3/providers/proxy/
# note the returned "pk"

# 2. Create the application, linking to that provider's pk
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name": "<Service>", "slug": "<service>", "provider": <pk>, "meta_launch_url": "https://<service>.bitforge", "group": "Infrastructure"}' \
  http://authentik-server:9000/api/v3/core/applications/

# 3. Attach the new provider pk to the embedded outpost's provider list
# (fetch current list first and append — PATCH replaces the whole list)
curl -s -X PATCH -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"providers": [1, <new pk>]}' \
  http://authentik-server:9000/api/v3/outposts/instances/079ff7fc-287f-4aac-9e4b-d4cb6e81d611/
```

Then add matching Traefik labels: reuse the existing
`authentik-forwardauth@docker` middleware (it's not host-specific), add one
new `authentik-outpost-<service>` router (same pattern as
`authentik-outpost-portainer` above, just swap the `Host()`), and attach the
middleware + a `priority=10` to the new service's own router.

### Two bugs hit and fixed while setting this up

**Embedded outpost redirected to `http://localhost/...` instead of
`https://authentik.bitforge/...`** — the outpost's `config.authentik_host`
and `config.authentik_host_browser` were both empty strings by default, so
Authentik fell back to `localhost` when building the OAuth authorize
redirect URL. A real browser would fail to load that. Fixed by patching the
outpost config:
```bash
curl -s -X PATCH -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"config": {"authentik_host": "https://authentik.bitforge", "authentik_host_browser": "https://authentik.bitforge"}}' \
  http://authentik-server:9000/api/v3/outposts/instances/079ff7fc-287f-4aac-9e4b-d4cb6e81d611/
```

**`akadmin` could log in but had no admin permissions** — a direct
consequence of the Phase 1 bootstrap-blueprint bug above: the `authentik
Admins` group was created, and `akadmin` was correctly added to it, but the
group's `is_superuser` flag was left `false` (should be `true`), so every
admin API call returned 403 despite a valid session/token. Confirmed via
`SELECT name, is_superuser FROM authentik_core_group;` in Postgres, fixed
via Django ORM (`Group.objects.get(name='authentik Admins'); g.is_superuser
= True; g.save()`) rather than raw SQL. **If you ever recreate the `akadmin`
user from scratch via the initial-setup flow, check this flag** — it's not
obviously broken from the login screen alone, only admin-only actions fail.

### Verification steps (Phase 2)

1. `curl -sk -H 'Host: portainer.bitforge' https://127.0.0.1/ -D - -o /dev/null`
   — expect `302` with `location: https://authentik.bitforge/application/o/authorize/...`
   (not `http://localhost/...`).
2. In a browser: visiting `https://portainer.bitforge` should redirect to an
   Authentik login page; logging in as `akadmin` should land back on
   Portainer, now actually showing its UI.
3. `docker exec authentik-postgresql psql -U authentik -d authentik -c "SELECT name, is_superuser FROM authentik_core_group;"`
   — `authentik Admins` should show `is_superuser = t`.

## Security recommendations

- **Use `AUTHENTIK_BOOTSTRAP_PASSWORD_HASH` instead of `AUTHENTIK_BOOTSTRAP_PASSWORD`**
  if you use the bootstrap vars at all — the plaintext variant leaves the
  admin password sitting in `.env` and in the container's environment
  indefinitely. Generate the hash with
  `docker compose run --rm authentik-server hash_password 'your-password'`
  and quote it in single quotes in `.env`.
- **`authentik-worker`'s Docker socket mount is read-write and the container
  runs as root** — required for Authentik to manage Docker-based outposts
  (embedded reverse-proxy/LDAP outposts). If you don't plan to use that
  feature in Phase 1, consider removing the `/var/run/docker.sock` mount and
  `user: root` from the worker entirely, or at minimum mount it `:ro`
  (note: `:ro` still exposes the full Docker API for reads, which is enough
  to enumerate every container's environment variables/secrets on this host
  — the same trust boundary already accepted for Traefik and
  `uptime-kuma-sync`, but worth being deliberate about for an identity
  provider specifically).
- **`AUTHENTIK_SECRET_KEY` rotation invalidates every active session** —
  back it up somewhere outside `.env` (a password manager), not just on this
  server.
- **Postgres is not exposed on the `proxy` network** — only `authentik`
  (internal-only) — keep it that way; nothing outside the Authentik stack
  needs to reach it directly.
- Once Authentik is live, treat it as more sensitive than the other services
  in this stack — it will eventually be the single point of failure for
  logging into everything else. Back up `../../data/authentik/postgres`
  before any Authentik upgrade.

## Phase 2b: real SSO into Portainer (OAuth2/OIDC)

Phase 2's forward-auth gate (above) only guards whether a request reaches
Portainer — it doesn't log you into Portainer's own app-level session, so
you'd hit Authentik's login *and then* Portainer's own separate login.
Phase 2b closes that gap: Portainer is now configured (Settings →
Authentication → OAuth) to delegate its own login to Authentik, so one
Authentik login is enough. Portainer CE supports this natively; it's a
second, independent integration from the forward-auth Proxy Provider, using
a **separate OAuth2/OpenID Provider** and a second (hidden, `meta_hide:
true`) Application (`portainer-oidc`) so it doesn't create a duplicate tile
in Authentik's app launcher.

Portainer's OAuth settings, for reference (see `docs.goauthentik.io`'s
[Traefik integration page](https://docs.goauthentik.io/add-secure-apps/providers/proxy/server_traefik)
for the forward-auth half; there's no equivalent authentik doc for the
Portainer-specific OAuth half, this was worked out from Portainer's own
source):

| Field | Value | Why |
|---|---|---|
| Authorization URL | `https://authentik.bitforge/application/o/authorize/` | Browser-facing — must be the public HTTPS host (browser trusts the mkcert CA). |
| Access token URL | `http://authentik-server:9000/application/o/token/` | Server-to-server (Portainer's own backend calls this directly) — **must** be the internal container address, not `https://authentik.bitforge`, see bug #1 below. Trailing slash required, see bug #2. |
| Resource URL | `http://authentik-server:9000/application/o/userinfo/` | Same reasoning as Access token URL. |
| Redirect URL | `https://portainer.bitforge` | Must exactly match a `redirect_uris` entry on the Authentik OAuth2 Provider (both with- and without-trailing-slash variants are registered, since Portainer's exact form wasn't predictable in advance). |
| Logout URL | `https://authentik.bitforge/application/o/portainer-oidc/end-session/` | Browser-facing. |
| User identifier | `email` | Matches the OAuth2 Provider's `sub_mode=user_email` and the attached `email` scope mapping. |
| Scopes | `openid email profile` | Provider's attached property mappings only emit claims for these three scopes — don't add scopes without also attaching their mappings, or the claims won't appear. |
| Auth Style | In Header (HTTP Basic) | Works; untested against "In Params". |

### Three separate bugs hit getting from "configured" to "actually works"

Each one produced a different, equally unhelpful symptom. In order encountered:

**1. TLS trust — Portainer can't verify the mkcert CA.**
First attempt used `https://authentik.bitforge/...` for *all* four URLs.
Portainer's error: `tls: failed to verify certificate: x509: certificate
signed by unknown authority`. The browser trusts the mkcert CA (installed
on your PC); Portainer's *container* doesn't. Only the browser-facing URLs
(Authorization, Logout) need to stay on the public HTTPS hostname — the two
server-to-server calls (Access token URL, Resource URL) were switched to
`http://authentik-server:9000/...`, plain HTTP over the shared `proxy`
Docker network, sidestepping TLS entirely. Same class of fix as the
`uptime-kuma-sync` → Grafana monitor and the DNS issue that started this
whole project.

**2. Trailing slash changes which Django view gets hit.**
After fix #1: `oauth2: cannot fetch token: 405 Method Not Allowed`. Reflex
assumption was "someone dropped a trailing slash" — user confirmed both
URLs had them. **Turned out to be real, but for a different reason**: the
actual root cause (bug #3 below) crashes Authentik's token view with an
unhandled exception, which Authentik's own error handling maps to a bare
`405` response instead of a proper OAuth error — which happens to look
*exactly* like hitting the wrong (slash-less) URL. Verified `/application/o/token`
(no slash) vs `/application/o/token/` (with slash) both directly with curl
to confirm the 405 signature — genuinely identical either way, which is
what made this a red herring rather than a real second bug. Lesson: a
matching symptom isn't proof of the hypothesized cause — check
`docker logs authentik-server` for the actual exception before trusting a
plausible-looking pattern match.

**3. The real bug: Authentik crashes comparing a corrupted client secret.**
`docker logs authentik-server` (not the summary/filtered view —
`docker compose logs -f` with a grep filter was actively hiding this;
pulling the raw unfiltered log for the exact failure timestamp is what
surfaced it) showed:
```
TypeError: comparing strings with non-ASCII characters is not supported
```
at `authentik/providers/oauth2/views/token.py:181`, inside
`compare_digest(self.provider.client_secret, self.client_secret)` — Python's
`hmac`-backed constant-time string comparison refuses to run if either side
has a non-ASCII character. Authentik's own stored secret was confirmed pure
ASCII via the API (`"all ASCII: True"`). So the *incoming* value from
Portainer had a stray non-ASCII character in it — almost certainly a
copy-paste artifact from pasting a 128-character secret out of a rendered
markdown table in chat. Fixed by generating a shorter (48 hex char)
replacement secret and re-issuing it in a plain code block instead of a
table cell, and re-entering it in Portainer. **If you hit this again with a
different service: don't assume the config is wrong — grep
`docker logs authentik-server` for `system_exception` around the failure
timestamp first.**

**4. (Not a bug — Portainer's own access-control design.) 403 after the
secret was fixed.** Once bug #3 was fixed, the token exchange started
returning real `200`s — but Portainer's `/api/auth/oauth/validate` still
403'd, silently (no error log line at all, since Portainer's own code
treats this as an expected/handled case, not an exception — see
`api/http/handler/auth/authenticate_oauth.go` in Portainer's source,
version 2.39.5 was running here). Portainer refuses to log in an OAuth user
unless either (a) a Portainer user with a **username exactly matching the
identifier claim** (here, the `email` claim value) already exists, or
(b) `OAuthAutoCreateUsers` ("Automatic user provisioning" in the UI) is
enabled, in which case it silently creates a new **Standard** (non-admin)
Portainer user on first login. Resolved by doing both: pre-creating a
Portainer user with username `karnamv@hotmail.com` (matching `akadmin`'s
Authentik email) via Portainer's original password-based admin account, and
also enabling automatic provisioning for any future Authentik users who
reach Portainer.

### Adding OIDC SSO to another service — checklist

1. Confirm the target app supports OIDC/OAuth2 login natively (Portainer
   does; not every self-hosted app does — some only support forward-auth
   header trust, which is a different, app-specific integration).
2. Create an OAuth2/OpenID Provider in Authentik (`client_type=confidential`,
   `mode` doesn't apply to this provider type — that's Proxy-Provider-only).
   **Explicitly set `grant_types` and `property_mappings`** — both come back
   empty by default from a bare `POST /api/v3/providers/oauth2/`, unlike the
   Proxy Provider which auto-populates sane defaults. Missing
   `property_mappings` means claims silently don't appear in the userinfo
   response; missing `grant_types` means the token endpoint rejects the
   grant type entirely.
3. Create a second, `meta_hide: true` Application linked to it (keep the
   forward-auth Application from Phase 2 too, if you want the network-level
   gate in addition to app-level SSO — they're independent).
4. Register both trailing-slash variants of the redirect URI defensively.
5. Point the app's own OAuth settings at the internal `http://authentik-server:9000/...`
   for any server-to-server calls, public `https://authentik.bitforge/...`
   for anything browser-facing.
6. Pre-create a matching user in the target app (or enable its equivalent
   of auto-provisioning) — assume every app enforces *some* form of this,
   since Portainer did and it's a reasonable default for any app that
   distinguishes user roles/permissions.
