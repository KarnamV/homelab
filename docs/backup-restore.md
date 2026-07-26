# Backup & Restore

Nightly backup for the whole bitforge homelab stack: `scripts/backup.sh` /
`scripts/restore.sh`, configured by `scripts/backup.conf`, driven by a
systemd timer (or cron — both covered below).

**Status: created and documented, not yet scheduled or run.** Nothing has
executed `backup.sh` for real; there is no backup history yet. See
"Getting started" to run the first one and install the timer.

## Contents

- [What gets backed up](#what-gets-backed-up)
- [Design principles](#design-principles)
- [Directory layout](#directory-layout)
- [Incremental backups (Loki)](#incremental-backups-loki)
- [Retention policy](#retention-policy)
- [Exit codes](#exit-codes)
- [Getting started](#getting-started)
- [Scheduling: systemd timer](#scheduling-systemd-timer)
- [Scheduling: cron (alternative)](#scheduling-cron-alternative)
- [Restore procedures](#restore-procedures)
- [Backup verification](#backup-verification)
- [Troubleshooting / known gotchas](#troubleshooting--known-gotchas)
- [Security notes](#security-notes)
- [Adding a new service](#adding-a-new-service-to-the-backup)
- [Follow-up work](#follow-up-work)

## What gets backed up

| Source | Method | Full/Incremental | Container(s) touched |
|---|---|---|---|
| Authentik Postgres DB | `pg_dump` via `docker exec`, gzip | Full nightly | none (read via exec, no stop) |
| Grafana data (`monitoring_grafana-data` volume) | tar via helper container | Full nightly | none |
| Prometheus data (`monitoring_prometheus-data` volume) | tar via helper container | Full nightly | none |
| Homepage, Portainer, Promtail, uptime-kuma-sync (bind mounts) | tar via helper container | Full nightly | none |
| Authentik app data (media/templates/certs — **not** its Postgres dir) | tar via helper container | Full nightly | none |
| Uptime Kuma | `sqlite3 .backup` (online, consistent) + tar of the rest | Full nightly | none |
| Loki (`data/loki`) | host GNU tar, `--listed-incremental` | **Incremental** (weekly full + daily incrementals) | none |
| `compose/`, `docs/`, `certs/` (this repo, includes `compose/monitoring/`) | host tar | Full nightly | none |

**backup.sh never stops, restarts, or pauses a container.** Every read is
one of: a read-only bind/volume mount into a short-lived helper container, a
`docker exec` of a backup command the app already ships (`pg_dump`,
`sqlite3 .backup`), or a direct host read of a bitforge-owned directory
(Loki, the config paths). `restore.sh` is the opposite — see its own
section below, restoring inherently requires briefly stopping the
component being restored.

Traefik itself has no runtime data to back up (it holds no ACME/Let's
Encrypt state — TLS certs are hand-provisioned via mkcert, see
`.claude/skills/update-cert/`); its config is covered by the
`compose/`+`certs/` archive.

## Design principles

- **Read-only, non-disruptive reads.** See the table above. Named Docker
  volumes (`grafana-data`, `prometheus-data`) and some bind mounts
  (`data/portainer`, `data/uptime-kuma`) are root-owned and unreadable by
  `bitforge` directly — rather than run backup.sh as root (which would need
  sudoers/systemd-root wiring for what's otherwise a plain user-level task),
  every such source is read by handing a short-lived, `--network=none`,
  `--pull=never` Alpine container ( `HELPER_IMAGE` in backup.conf, already
  pulled locally — **the nightly run has zero network dependency**) a
  read-only mount and the single job of tar-ing what it sees. `bitforge`
  only needs Docker socket access (the `docker` group), which it already
  has for everything else in this repo.

- **Why not just tar Postgres's data directory.** `data/authentik/postgres`
  is Postgres's live `PGDATA` — copying it with `tar` while Postgres is
  running does not produce a consistent backup (files can be mid-write,
  WAL/checkpoint state can be torn) unless you stop Postgres first or use a
  filesystem snapshot. Neither fits "don't interrupt running containers", so
  Postgres is *only* ever backed up via `pg_dump` (a proper hot logical
  backup Postgres is explicitly designed to support) and `postgres/` is
  never included in any raw tar. It's also 0700-owned by the container's
  postgres user and unreadable by `bitforge` regardless.

- **Why Grafana's SQLite copy is "best effort".** The `grafana/grafana`
  image doesn't ship the `sqlite3` CLI, so — unlike Uptime Kuma, whose image
  does — there's no way to run an online `.backup` from inside/against it
  without adding an external dependency (installing `sqlite3` via `apk` at
  backup time, which would make a nightly run depend on network access).
  It's backed up as a live file copy instead. Risk is low in practice
  (SQLite's default rollback-journal mode is safe to copy when idle, and
  this data set sees light write activity for a homelab), and it's not the
  sole source of truth anyway — dashboards/datasources are also provisioned
  from `grafana/provisioning` files, captured separately in the config
  archive. If this ever matters more, see "Follow-up work".

- **Why Prometheus is full-nightly, not incremental.** Same reasoning as
  Loki would suggest incremental treatment (TSDB grows daily), but doing it
  correctly needs either GNU tar's `--listed-incremental` (the volume is
  only reachable via a container, and Alpine's busybox `tar` doesn't
  support that flag — installing GNU tar there hits the same
  network-dependency problem as Grafana's sqlite3 above) or Prometheus's
  own admin-API snapshot endpoint (`--web.enable-admin-api`, currently
  disabled — confirmed via `curl -X POST .../api/v1/admin/tsdb/snapshot` →
  405). Full nightly is simple and correct; see "Follow-up work" for
  enabling the admin API later.

## Directory layout

```
homelab/scripts/
├── backup.sh
├── restore.sh
├── backup.conf                  # sourced by both — see inline comments
├── lib/
│   └── backup-common.sh         # shared: logging, checks, checksums, the
│                                 # helper-container tar function
└── systemd/
    ├── homelab-backup.service
    └── homelab-backup.timer

homelab/backups/                 # BACKUP_ROOT — gitignored, this is data
├── logs/
│   ├── backup-2026-07-24_020000.log
│   └── restore-2026-07-25_091500.log
├── state/
│   └── loki.snar                # GNU tar incremental snapshot (persistent)
└── runs/
    └── 2026-07-24/               # one directory per night
        ├── manifest.txt          # what ran, how long, pass/fail per step
        ├── SHA256SUMS            # covers every file in this run dir
        ├── postgres/
        │   └── authentik-2026-07-24.sql.gz
        ├── volumes/
        │   ├── grafana-data-2026-07-24.tar.gz
        │   └── prometheus-data-2026-07-24.tar.gz
        ├── binds/
        │   ├── homepage-2026-07-24.tar.gz
        │   ├── portainer-2026-07-24.tar.gz
        │   ├── promtail-2026-07-24.tar.gz
        │   ├── uptime-kuma-sync-2026-07-24.tar.gz
        │   ├── authentik-app-2026-07-24.tar.gz
        │   ├── uptime-kuma-db-2026-07-24.sqlite.gz
        │   ├── uptime-kuma-data-2026-07-24.tar.gz
        │   └── loki-2026-07-24-full.tar.gz   # or -incr.tar.gz
        └── config/
            ├── homelab-config-2026-07-24.tar.gz
            └── monitoring-config-2026-07-24.tar.gz
```

## Incremental backups (Loki)

Loki is the one source where "incremental" is worth the complexity: it's
the fastest-growing dataset in this stack and its data directory
(`data/loki`) is the one candidate that's both large/growing **and**
directly readable by `bitforge` on the host (`bitforge:bitforge`,
world-readable) — no helper container needed, so GNU tar's
`--listed-incremental` (which Alpine's busybox tar doesn't support) is
available for free.

- Every `LOKI_FULL_DAY` (default `Sun`, `backup.conf`), the persistent
  snapshot state (`backups/state/loki.snar`) is reset and a **full**
  archive is written: `loki-YYYY-MM-DD-full.tar.gz`.
- Every other night, an **incremental** archive is written against that
  state file: `loki-YYYY-MM-DD-incr.tar.gz` (only files that changed since
  the last run).
- Restoring means applying the full archive, then every incremental after
  it up to your target date, in order — `restore.sh --only loki` does this
  automatically (see Restore procedures).
- `tar --listed-incremental` legitimately exits `1` (not `0`) when it
  notices a file changed while being read — expected and harmless for
  Loki's actively-written WAL, `backup.sh` treats exit code `1` as a
  warning and `2+` as a real failure (see `backup_loki_incremental` in
  `backup.sh`).

## Retention policy

Configurable in `backup.conf`:

| Variable | Default | Applies to |
|---|---|---|
| `RETENTION_DAYS` | 14 | Everything except Loki — whole run directories older than N days are pruned (Loki archives inside them are left alone, see below) |
| `RETENTION_CYCLES` | 3 | Loki only — keep the last N full-backup cycles (~N weeks); a full archive is never deleted while a kept incremental still depends on it, even if the run directory it lives in is otherwise past `RETENTION_DAYS` |

Run `backup.sh` prunes on every invocation, after that night's backup
completes (`prune_loki_cycles` then `prune_old_runs`). A run directory that
still holds a Loki full archive being kept by the cycle rule, but whose
other content has aged past `RETENTION_DAYS`, is left partially pruned —
that's intentional, not a bug (see the comments above `prune_old_runs` in
`backup.sh`).

## Exit codes

Both scripts share these (`scripts/lib/backup-common.sh`):

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | General error / at least one step failed |
| 2 | Configuration error (bad/missing `backup.conf`) |
| 3 | Insufficient free disk space |
| 4 | Permission error (can't read a source / write the destination) |
| 5 | Docker daemon unreachable |
| 6 | Archive/checksum verification failed |
| 7 | Restore aborted (checksum failure without `--force-unverified`, or confirmation declined) |
| 10 | Bad command-line arguments |

`backup.sh` runs every configured step regardless of earlier failures (a
broken Loki backup shouldn't stop the Postgres dump from being attempted)
and only decides the final exit code — 0 or 1 — at the end, based on
whether *any* step failed; check `manifest.txt` / the log for which one.
Pre-flight checks (disk space, Docker, missing containers) are the
exception — those abort before anything is written, with their own
specific code (3 or 5).

## Getting started

```bash
cd /home/bitforge/homelab/scripts

# 1. Validate everything without writing anything (safe to run any time —
#    checks paths, permissions, disk space, Docker, that containers/volumes
#    exist; creates nothing under backups/runs/).
./backup.sh --check

# 2. First real backup, run by hand so you can watch it / read the log
#    directly instead of via journalctl.
./backup.sh
# tail -f the resulting backups/logs/backup-*.log in another terminal to
# follow along, or just wait — it prints to stdout too.

# 3. Confirm it worked.
cat backups/runs/$(date +%F)/manifest.txt
./restore.sh --list
```

If `--check` reports a missing container/volume, fix that first — a real
run's pre-flight check aborts (exit 5 or similar) rather than silently
skipping the affected step.

## Scheduling: systemd timer

```bash
sudo cp /home/bitforge/homelab/scripts/systemd/homelab-backup.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now homelab-backup.timer

# Verify
systemctl list-timers homelab-backup.timer
journalctl -u homelab-backup.service -n 100 --no-pager   # after it's run once
```

Runs nightly at 02:00 (`OnCalendar=*-*-* 02:00:00` in the `.timer` file,
plus up to 5 minutes of jitter) as the `bitforge` user — edit the `.timer`
file before installing if you want a different time. `Persistent=true`
means a missed run (machine off at 02:00) executes once at next boot
instead of silently skipping a night.

To run one backup on demand outside the schedule:
`sudo systemctl start homelab-backup.service`.

## Scheduling: cron (alternative)

If you'd rather not use systemd timers:

```bash
crontab -e
# add:
0 2 * * * /home/bitforge/homelab/scripts/backup.sh >> /home/bitforge/homelab/backups/logs/cron.log 2>&1
```

`backup.sh` already writes its own timestamped log under `backups/logs/`
regardless of how it's invoked — the `>>` above is just a fallback capturing
anything printed before logging initializes (e.g. a config error) plus
cron's own error output, since cron mails or discards stdout/stderr
depending on local mail setup, which is easy to lose track of on a
homelab box.

## Restore procedures

**Read this whole section before running `restore.sh` for real.** Unlike
`backup.sh`, restoring **does stop containers** — briefly, only the ones
whose data is being replaced, and only for components you actually select —
because safely overwriting a service's live data files while it's running
isn't generally possible. `restore.sh` always asks for interactive
confirmation first (type `restore` at the prompt) unless you pass `--yes`.

```bash
cd /home/bitforge/homelab/scripts

# See what's available
./restore.sh --list

# Check a backup's integrity without touching anything (safe, no stop/start)
./restore.sh --run-date 2026-07-24 --verify-only

# Restore everything from a given night
./restore.sh --run-date 2026-07-24

# Restore just one or two components
./restore.sh --run-date 2026-07-24 --only postgres,authentik-app

# Restore Postgres into a database that already has (conflicting) data —
# drops and recreates it first, stopping authentik-server/-worker while
# it does (they hold open connections to the DB being dropped)
./restore.sh --run-date 2026-07-24 --only postgres --drop-existing-db
```

### Component notes

- **`postgres`** — loads the `pg_dump` output via `psql` into the running
  `authentik-postgresql` container (the container itself is never
  stopped/recreated — Postgres must already be up). Without
  `--drop-existing-db`, the dump is loaded into whatever's already in the
  `authentik` database and will fail with "already exists" errors unless
  it's empty (e.g. a genuinely fresh install). With `--drop-existing-db`,
  `authentik-server`/`authentik-worker` are stopped first, the database is
  dropped and recreated, the dump is loaded, then both are started again —
  this is what you want for "Authentik's database is corrupted/gone,
  restore it".
- **`grafana` / `prometheus`** — stops the container, replaces the entire
  contents of its named volume with the archive, restarts it.
- **`homepage` / `portainer` / `promtail` / `uptime-kuma-sync`** — same
  pattern against the corresponding bind-mounted directory.
- **`authentik-app`** — stops `authentik-server` and `authentik-worker`,
  replaces `data/authentik/{media,templates,certs}`, restarts both. Does
  **not** touch the Postgres data — combine with `--only
  postgres,authentik-app` (or run both separately) for a full Authentik
  restore.
- **`uptime-kuma`** — stops the container, replaces `data/uptime-kuma`
  entirely with the backed-up uploads/screenshots plus the consistent
  SQLite snapshot (written directly as `kuma.db`, no `-wal`/`-shm` — a
  clean SQLite file doesn't need them), restarts it.
- **`loki`** — stops the `loki` container, applies the full baseline for
  the target date plus every incremental after it in order (see
  "Incremental backups" above), restarts it. If you ask for a date that
  falls inside a week with no incrementals yet (i.e. asking to restore
  *to* the full-backup day itself), only the full archive is applied.
- **`config`** — extracts the compose/docs/certs archive back over
  `homelab/` (this now includes `compose/monitoring/` too — see
  `docs/swarm-migration.md`). Deliberately does **not** restart any
  container or redeploy any stack for you — review what changed (`git diff`
  inside `homelab/`, since `compose/`/`docs/`/`certs/` are tracked) and
  re-apply deliberately, the same way any other config change in this repo
  is applied.

### Disaster-recovery walkthrough (fresh host)

Since Phase 1 of the Swarm migration (`docs/swarm-migration.md`), every
stack except `dnsmasq` runs as a Docker Swarm service rather than a plain
`docker compose` container — the deploy/stop/start commands below reflect
that.

If the whole host is gone and you're rebuilding from an off-host copy of
`backups/` (see "Follow-up work" — this only helps if backups left the
original disk):

1. Reinstall Docker, `docker swarm init --advertise-addr <LAN IP>`, clone
   `homelab/` (or restore it from the `config` component onto a fresh
   checkout), recreate `backups/` from your off-host copy.
2. Create the overlay network: `docker network create -d overlay
   --attachable proxy-swarm`.
3. Bring up just `authentik-postgresql` far enough to be running and
   healthy (`docker service scale authentik_authentik-postgresql=1` after
   an initial `scripts/stack-deploy.sh compose/authentik authentik`, then
   `docker service scale authentik_authentik-server=0
   authentik_authentik-worker=0` to hold the other two back).
4. `./restore.sh --run-date <date> --only postgres --drop-existing-db`.
5. `./restore.sh --run-date <date> --only authentik-app`.
6. `docker service scale authentik_authentik-server=1
   authentik_authentik-worker=1`, then `scripts/stack-deploy.sh` every
   other stack under `compose/*/` (including `compose/monitoring/`), plus
   `docker compose up -d` in `compose/dnsmasq/` (the one stack still on
   plain Compose — see `docs/swarm-migration.md`).
7. `./restore.sh --run-date <date> --only grafana,prometheus,homepage,portainer,promtail,uptime-kuma-sync,uptime-kuma,loki`.
8. Verify each service in a browser; check Authentik SSO end-to-end
   (`docs/authentik.md`) since it's the single point of failure for
   logging into everything else.

## Backup verification

Two layers, both automatic:

1. **Per-archive integrity**, right after it's written (`verify_archive` in
   `backup-common.sh`): `gzip -t` on every `.tar.gz`/`.gz`, confirming the
   compressed stream isn't corrupt. A failure here fails that step.
2. **Checksums**: `backups/runs/<date>/SHA256SUMS` covers every file in the
   run directory, written after all steps complete. `restore.sh` always
   verifies against this before touching anything (`--force-unverified` to
   override, logged loudly).

Neither layer proves the *data inside* an archive is semantically correct
(e.g. that the Postgres dump would actually restore a working Authentik) —
that's what `restore.sh --verify-only` plus a periodic real test-restore
(ideally onto a spare/throwaway host, or at minimum `--only` a low-risk
component like `homepage` against this host) is for. Nothing here does that
automatically yet — see "Follow-up work".

## Troubleshooting / known gotchas

- **`--check` fails on "Helper image not found locally"** — `docker pull
  alpine:latest` once by hand. `backup.sh` runs it with `--pull=never`
  deliberately so a nightly run never depends on network/registry access;
  it will not pull this for you.
- **`backup_loki_incremental` logs a WARN about "files changed while being
  read"** — expected, not a failure (see "Incremental backups" above).
  Only exit codes ≥2 from `tar` are treated as real errors.
- **Postgres restore fails with "already exists" errors** — you didn't
  pass `--drop-existing-db` and the target database already has
  conflicting objects in it. Re-run with that flag if you actually want to
  replace it (it stops `authentik-server`/`-worker` first, see above).
- **A restore step failed partway through** — each `restore_*` function
  independently tries to restart whatever container it stopped, even on
  failure (see the `docker start ... || log_error ...` right before every
  `return` in `restore.sh`) — check `docker ps` and the run's
  `backups/logs/restore-*.log` for which container, if any, didn't come
  back up on its own.
- **Grafana/Uptime Kuma sessions log everyone out after a restore** — 
  expected; restoring their data necessarily replaces session state along
  with everything else.

## Security notes

- **The Postgres dump and Authentik's `media`/`certs` backup contain
  sensitive material** — Authentik's database includes password hashes,
  API tokens, and OAuth client secrets (Grafana's, Portainer's — see
  `docs/authentik.md`); `certs/` in the config archive is TLS private keys.
  `backups/` is `.gitignore`d (never committed) but is **not** encrypted at
  rest. Anyone with read access to `homelab/backups/` on this host can read
  all of that. Restrict host access accordingly, and see "Follow-up work"
  for encrypting archives before they leave this host.
- **The homelab config archive includes `compose/monitoring/.env`**
  — currently just Grafana's OIDC client secret (see `docs/authentik.md`
  Phase 3), same sensitivity class as the rest of this list.
- **`HELPER_IMAGE` runs with `--network=none`** — it only ever tars/extracts
  a mounted path, so it has no legitimate need for network access; this is
  a deliberate hardening choice, not an oversight if you're wondering why
  it's there.

## Adding a new service to the backup

1. Decide bind-mount vs named volume vs "needs its own online-backup
   command" (does it ship a CLI for a consistent live snapshot, like
   Uptime Kuma's `sqlite3`, or does it need `pg_dump`-style tooling?).
2. Bind mount, no special consistency needs → add a `"name:path"` entry to
   `BIND_MOUNTS_FULL` in `backup.conf`; `backup_bind_mounts_full` in
   `backup.sh` picks it up automatically, as does `restore_bind_mount` in
   `restore.sh` (add it to `COMPONENT_ORDER`/`COMPONENT_FUNCS` there,
   pointing at the right owner container to stop/start).
3. Named volume → follow `backup_grafana_volume`/`restore_grafana_volume`
   as a template.
4. Needs an online-backup command → follow `backup_uptime_kuma` as a
   template (stop-free consistent snapshot) rather than a plain live tar,
   if one's available — see "Why Grafana's SQLite copy is best effort"
   above for what to do if it isn't.
5. Large and fast-growing → consider the Loki incremental pattern, but
   only if it's directly host-readable (avoids needing GNU tar inside a
   container — see "Why Prometheus is full-nightly" above for why that's
   the harder path).
6. Update the table at the top of this doc and the manifest/exit-code
   sections if the new source needs anything unusual.

## Follow-up work

Recommended, not yet done:

- **Off-host copy.** `BACKUP_ROOT` is currently on the same physical disk
  as everything it's backing up — good against accidental deletion or a
  bad config push, useless against a disk/host failure. Sync `backups/` to
  a second disk, another machine, or cloud storage (`rclone`/`rsync`) after
  each nightly run.
- **Encrypt backups at rest**, given the Security notes above — e.g. GPG or
  age-encrypt each run directory (or just the `postgres/` and
  `authentik-app` archives) before/instead of an off-host sync in plaintext.
- **Enable Prometheus's admin API** (`--web.enable-admin-api` in
  `compose/monitoring/compose.yaml`, requires redeploying the
  `monitoring_prometheus` service to take effect) and switch
  `backup_prometheus_volume` to use `/api/v1/admin/tsdb/snapshot` — a true
  point-in-time snapshot instead of a live volume copy, and a natural
  place to add real incremental treatment later too.
- **Periodic real test-restore**, ideally onto a spare host or at minimum
  a low-risk `--only` component here, to catch "the backup exists and
  passes checksum but doesn't actually restore a working service" —
  neither verification layer today proves that.
- **Notifications** — nothing currently pages/emails/messages on backup
  failure; you'd only find out via `journalctl -u homelab-backup` or
  `manifest.txt` after the fact. Worth adding once you have a place to send
  it (a webhook, a healthcheck-style ping service, etc.).
