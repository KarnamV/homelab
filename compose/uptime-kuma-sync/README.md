# uptime-kuma-sync

Watches the Docker socket and keeps Uptime Kuma monitors in sync with running
containers. Containers opt in with labels; the service creates, updates, and
(optionally) removes the corresponding monitors every `SYNC_INTERVAL` seconds.
No manual monitor management, no duplicates on re-run.

## How it works

1. Lists running containers via the Docker API, skips itself and anything
   without `uptime.enable=true`.
2. Builds a desired monitor spec per container from its `uptime.*` labels.
3. Logs into Uptime Kuma over its Socket.IO API (via the
   [`uptime-kuma-api`](https://github.com/lucasheld/uptime-kuma-api) Python
   client) and diffs desired state against a local record of what it created
   last run (`state.json`, keyed by container ID — not by name, so renaming a
   container's labels updates the existing monitor instead of orphaning it).
4. Creates missing monitors, updates changed ones, leaves unchanged ones
   alone, and (if enabled) deletes monitors whose container disappeared.
5. Sleeps, repeats.

## Labels

Add these to any container you want tracked. Only `uptime.enable` is
required — everything else has a sensible default.

| Label             | Required | Default            | Notes                                                                 |
|-------------------|----------|---------------------|------------------------------------------------------------------------|
| `uptime.enable`   | yes      | —                   | Must be exactly `"true"` to opt in.                                    |
| `uptime.name`     | no       | container name      | Display name in Uptime Kuma.                                           |
| `uptime.url`      | usually  | —                   | Full URL for `http`/`keyword` types; `host` or `host:port` for `tcp`/`ping`. |
| `uptime.group`    | no       | none                | Groups monitors under a parent (created automatically if missing).     |
| `uptime.interval` | no       | `60` (seconds)      | Check interval. Minimum enforced by Uptime Kuma is 20s.                |
| `uptime.keyword`  | no       | —                   | If set and type is `http`, monitor type becomes `keyword` automatically.|
| `uptime.type`     | no       | `http`              | One of `http`, `tcp`, `ping`.                                          |

Example — HTTP check via Traefik:

```yaml
labels:
  - uptime.enable=true
  - uptime.name=Grafana
  - uptime.url=https://grafana.bitforge
  - uptime.group=Infrastructure
```

Example — TCP port check:

```yaml
labels:
  - uptime.enable=true
  - uptime.name=Postgres
  - uptime.type=tcp
  - uptime.url=postgres:5432
```

Example — ping check:

```yaml
labels:
  - uptime.enable=true
  - uptime.type=ping
  - uptime.url=192.168.0.1
```

## Configuration

Environment variables (set in `compose.yaml` / `.env`):

| Variable                 | Required | Default | Description                                              |
|---------------------------|----------|---------|------------------------------------------------------------|
| `UPTIME_URL`               | yes      | —       | Base URL of Uptime Kuma, e.g. `http://uptime-kuma:3001`.  |
| `UPTIME_USERNAME`          | yes      | —       | Uptime Kuma login username.                                |
| `UPTIME_PASSWORD`          | yes      | —       | Uptime Kuma login password.                                |
| `SYNC_INTERVAL`            | no       | `300`   | Seconds between sync runs.                                 |
| `UPTIME_PRUNE_ORPHANED`    | no       | `true`  | Delete monitors whose container no longer exists.          |
| `UPTIME_DEFAULT_INTERVAL`  | no       | `60`    | Default monitor check interval when `uptime.interval` unset.|
| `LOG_LEVEL`                | no       | `INFO`  | Python logging level.                                      |

Credentials go in a `.env` file next to `compose.yaml` (copy `.env.example`),
which is git-ignored:

```bash
cp .env.example .env
$EDITOR .env   # set UPTIME_USERNAME / UPTIME_PASSWORD
```

## Deployment

```bash
cd /home/bitforge/homelab/compose/uptime-kuma-sync
docker compose up -d --build
```

The service joins the existing external `proxy` network and reaches Uptime
Kuma directly by container name (`http://uptime-kuma:3001`) — no Traefik or
TLS involved for that connection. `/var/run/docker.sock` is mounted
read-only; the container never writes to it, only lists/inspects containers.

State (`state.json`) persists in `../../data/uptime-kuma-sync`, bind-mounted
so it survives container rebuilds.

## Troubleshooting

**Monitor never appears** — check `docker compose logs -f uptime-kuma-sync`.
An `invalid_labels` log entry means the container's `uptime.*` labels
couldn't be parsed (e.g. missing `uptime.url` for an `http` monitor).

**`getaddrinfo ENOTFOUND` / connection errors from the monitor itself in
Uptime Kuma, not from this service** — likely a DNS or TLS issue unrelated
to sync, common in this homelab because `.bitforge` names only resolve via
the internal `dnsmasq` resolver and Traefik terminates TLS with an mkcert
local dev certificate. Two fixes:
  - Point `uptime.url` at the container's internal address instead of the
    public `*.bitforge` hostname (e.g. `http://grafana:3000` instead of
    `https://grafana.bitforge`) — works over the shared `proxy` network
    without touching DNS or TLS.
  - Or import `homelab/certs/bitforge.pem`'s issuing CA (mkcert) into
    whatever is validating the connection; Uptime Kuma does not trust it by
    default. This tool doesn't currently expose a `uptime.ignore_tls` label
    — add one to `docker_discovery.py` / `kuma_sync.py` if you need it.

**Duplicate monitors after editing labels** — shouldn't happen; matching is
by container ID via `state.json`, not by name, so renaming a service via
`uptime.name` updates its existing monitor. The exception is groups, which
are matched by name if `state.json` doesn't have a record — safe to dedupe
automatically. If `state.json` itself is deleted or corrupted, the next run
has no record of previously created (non-group) monitors and will create
fresh ones; delete the stale duplicates manually in that case.

**Login fails** — verify `UPTIME_USERNAME`/`UPTIME_PASSWORD` in `.env` match
an actual Uptime Kuma account. 2FA-enabled accounts are not supported.

**Dependency note** — `uptime-kuma-api` (the Python client this service
depends on) has had no releases since late 2023 and no commits since April
2024, though its documented compatibility covers the Uptime Kuma 1.23.x line
we run (1.23.17). The monitor CRUD Socket.IO events it wraps have been
stable across that line. If Uptime Kuma is later upgraded to 1.24+ and this
service starts failing, that library is the first suspect — check its
GitHub issues, or fall back to calling the Socket.IO events directly (see
its source for the exact event names/payloads: `add`, `editMonitor`,
`deleteMonitor`, `monitorList`).

## Adding new monitored services

1. Add `uptime.enable=true` plus whatever optional labels apply to the
   service's `labels:` block in its own `compose.yaml`/`docker-compose.yml`.
2. `docker compose up -d` that service (labels only take effect on
   container recreation, not a live container).
3. Wait up to `SYNC_INTERVAL` seconds, or manually trigger a run:
   `docker compose restart uptime-kuma-sync` (it syncs once immediately on
   startup, then every `SYNC_INTERVAL` seconds).
4. Confirm the monitor shows up in Uptime Kuma.
