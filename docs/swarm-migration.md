# Docker Swarm migration (Phase 1)

Why: the target end-state for this homelab is a GitOps pipeline where a
`git push` builds an image, pushes it to GHCR, and rolls it out with
health-checked, auto-rollback deploys. Plain `docker compose` has no
rolling-update or rollback primitive — Docker Swarm does
(`update_config`, `rollback_config`, healthcheck-gated task replacement) —
so Swarm is the prerequisite infrastructure change before any CI/CD wiring
happens. This phase converted the existing Compose environment to Swarm
stacks with (as close as physically possible to) no downtime, and changed
nothing about which images run or how routing is configured beyond what the
migration itself required.

## What changed

- `docker swarm init` — this host is now a single-node Swarm (manager).
  Compose and Swarm coexist fine on one engine; this step alone touched
  nothing running.
- The shared `proxy` network (that Traefik and every app attach to) is now
  an **overlay** network named `proxy-swarm` — Swarm services can't attach
  to a plain bridge network at all, so this couldn't be done in place.
  Stack files still reference it as `networks: { proxy: { external: true,
  name: proxy-swarm } }`, so the internal `networks: [proxy]` lines on
  individual services didn't need to change.
- Every `compose/*/compose.yaml` (or `docker-compose.yml`) is now a Swarm
  stack file: `container_name:` dropped (unsupported/meaningless — Swarm
  generates `<stack>_<service>.<slot>.<task-id>` names), `traefik.*` labels
  moved under `deploy.labels`, `deploy:` blocks added with `replicas`,
  `update_config` (`order: start-first` for stateless services,
  `stop-first` for anything with an exclusive-lock data directory —
  Postgres, Loki), `rollback_config`, and `restart_policy`.
- `docker/monitoring/` (previously **not** under version control) is now
  `homelab/compose/monitoring/` — folded into the repo like every other
  stack, closing a pre-existing IaC gap.
- New: `scripts/stack-deploy.sh <stack-dir> <stack-name> [compose-file]` —
  the reusable deploy wrapper every stack (including Nest) now uses. Its
  only job beyond `docker stack deploy` is exporting the stack directory's
  `.env` into the shell first, since `docker stack deploy` — unlike
  `docker compose` — does not auto-load a sibling `.env` or support
  `env_file:`.
- **Exception: `dnsmasq` stays on plain `docker compose`.** Converting it
  hit a reproducible Swarm bug: `mode: host` publishing port 53 for both
  TCP and UDP in the same task repeatedly failed with "address already in
  use" even with nothing else holding the port, and caused a real, brief
  LAN DNS outage during testing. Since dnsmasq has no dependency on
  Traefik, the overlay network, or the future CI/CD pipeline, it isn't
  worth the risk of continuing to experiment against production DNS —
  `compose/dnsmasq/compose.yaml` is unchanged from before this migration.

## Command translation

| Compose | Swarm equivalent |
|---|---|
| `docker compose up -d` | `scripts/stack-deploy.sh compose/<name> <name>` |
| `docker compose stop` / `start` | `docker service scale <stack>_<service>=0` / `=1` |
| `docker compose ps` | `docker service ps <stack>_<service>` |
| `docker compose logs [-f] <service>` | `docker service logs [-f] <stack>_<service>` |
| `docker compose exec <service> <cmd>` | `docker exec "$(docker ps -q -f name=<stack>_<service>.)" <cmd>` |
| `docker compose down` | `docker stack rm <stack>` |

Stack names match each directory's name (`traefik`, `authentik`, `homepage`,
`portainer`, `uptime-kuma`, `uptime-kuma-sync`, `loki`, `promtail`,
`monitoring`, `nest`) — this was deliberate so existing Docker-managed
volume names (e.g. `monitoring_grafana-data`, `nest_pgdata`) kept resolving
to the same volume with no data migration needed.

## Gotchas hit during this migration (so the next one doesn't repeat them)

- **Traefik's Swarm provider reads `deploy.labels`, not top-level
  `labels:`** — it inspects Swarm services, not containers. Custom
  non-Traefik labels (e.g. `uptime-kuma-sync`'s `uptime.*` labels, which
  that tool reads directly off *containers* via the Docker socket) stay on
  the regular top-level `labels:` block instead — both can coexist on the
  same service.
- **Cross-service middleware references need `@swarm`, not `@docker`** —
  e.g. `authentik-forwardauth@docker` (the old Docker-provider suffix)
  silently 404s every router using it under the Swarm provider; it must be
  `authentik-forwardauth@swarm`.
- **Some images ship no shell or `wget` at all** (Portainer, Loki,
  Promtail) — a `healthcheck:` referencing either fails every attempt with
  "executable file not found in $PATH", and since `docker stack deploy`
  waits for a task to report healthy before considering the deploy
  converged, this manifests as the deploy command hanging/timing out
  rather than an obvious error. These three intentionally have no
  healthcheck (matching their pre-migration state — none of them were
  health-checked before either).
- **Stack-internal networks can collide with the still-running old bridge
  network of the same default name** during the parallel cutover window
  (e.g. `authentik_authentik`, `nest_internal`) — give them an explicit
  different `name:` for the duration, since two networks can't share a
  name regardless of driver.
- **`docker stack deploy` rejects the top-level Compose Spec `name:`
  field** ("(root) Additional property name is not allowed") — the stack
  name is already the CLI argument, so this line is just removed.
- **`build:` and `env_file:` aren't supported** by `docker stack deploy` —
  see `scripts/stack-deploy.sh` above for the `env_file:` replacement
  pattern; `build:` sections are simply dropped in favor of referencing an
  already-built image tag (this is also exactly what the future GHCR/CI
  pipeline will do).

## Backup/restore script changes

`scripts/backup.sh` / `scripts/restore.sh` used to `docker exec`/`docker
stop`/`docker start` fixed container names (`authentik-postgresql`,
`uptime-kuma`, `loki`, plus per-bind-mount owner containers like `grafana`,
`homepage`). Swarm-managed containers don't have fixed names, and stopping
one directly just gets it replaced by the orchestrator — so:

- `lib/backup-common.sh` gained `resolve_container SERVICE_NAME` (looks up
  the current task's container ID by service-name prefix) and
  `service_scale SERVICE_NAME REPLICAS` (the stop/start replacement).
- `backup.conf`'s `AUTHENTIK_PG_CONTAINER` / `UPTIME_KUMA_CONTAINER` /
  `LOKI_CONTAINER` now hold **Swarm service names**
  (`authentik_authentik-postgresql`, etc.), not container names.
- Every `docker exec`/`stop`/`start` call site in both scripts was updated
  accordingly. Verified with `backup.sh --check` and a real `--only
  postgres,uptime-kuma` run against the live migrated stack.
- `MONITORING_ROOT` / `CONFIG_PATHS_MONITORING` are gone — monitoring's
  config now lives under `compose/monitoring/`, already covered by
  `CONFIG_PATHS_HOMELAB`.

## Adding a new application stack

Not yet templated end-to-end (that's Phase 2+, once CI/CD and GHCR are
wired up), but the pattern any new app stack should already follow, based
on Nest's `docker-compose.production.yml`:

1. No `build:` — reference an image tag, built by CI or by hand.
2. `deploy.labels` for `traefik.*`, not top-level `labels:`.
3. `deploy.update_config.order: start-first` + `healthcheck:` +
   `deploy.rollback_config` + `deploy.restart_policy` on every service.
4. `deploy.replicas: ${SOME_VAR:-1}` if it might ever need more than one
   instance (stateless services only — see Nest's `NEST_WEB_REPLICAS`).
5. Deploy with `scripts/stack-deploy.sh <dir> <stack-name>`.
