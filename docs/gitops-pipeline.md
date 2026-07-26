# GitOps CI/CD pipeline (Phase 2)

Builds on `docs/swarm-migration.md`. This phase wires up: `git push` to an
app repo's `main` → GitHub Actions builds the image(s) → pushes to GHCR →
a self-hosted runner on this host redeploys the corresponding Swarm stack
→ Swarm rolling-updates it, auto-rolling-back on a failed healthcheck.
`nest` is the concrete, working example; this doc is what BabyTracker,
Chronicle, or any future app repo follows to adopt the same pipeline.

## Architecture

- **Self-hosted runner, one per app repo.** This homelab has no public
  network exposure, so a GitHub-hosted runner can't reach it — the runner
  makes an outbound connection to GitHub instead, no inbound port needed.
  GitHub doesn't support sharing one runner process across multiple
  personal-account repos, so each app gets its own runner instance/systemd
  service. `scripts/setup-github-runner.sh <owner>/<repo>` handles the
  registration; you still run the two `sudo ./svc.sh ...` commands
  yourself (installing a systemd service needs root, which this
  environment won't grant non-interactively).
- **Reusable workflows live in `homelab`** (`.github/workflows/build-
  push.yml`, `deploy-stack.yml`) since it's public and can be called from
  private app repos. `build-push.yml` builds and pushes to
  `ghcr.io/karnamv/<prefix>-<service>`, tagged both `sha-<short-sha>` and
  `latest`. `deploy-stack.yml` runs on the app's self-hosted runner,
  checks out `homelab` alongside the app repo to get `stack-deploy.sh`,
  copies in the app's real `.env` (never committed — see below), and
  deploys.
- **Rollback is Swarm's, not this pipeline's** — `update_config`/
  `rollback_config` on each service (from Phase 1) already reverts a
  failed healthcheck automatically. Verified end-to-end: deployed a
  deliberately-broken `nest_web` image, watched Swarm detect the failed
  healthcheck and roll back to the last-good image automatically, with
  zero downtime throughout (`start-first` means the old task never stops
  until the new one's healthy).

## Gotchas hit standing this up (so the next one doesn't repeat them)

- **Check the reusable-workflow repo's actual default branch.**
  `homelab`'s is `master`, not `main` — `uses: owner/repo/path@main` fails
  with a silent, no-jobs-created `startup_failure` if the ref doesn't
  exist, and neither the REST nor GraphQL API surfaces a useful error
  message for this; you just see "likely failed because of a workflow
  file issue" with zero check runs.
- **`permissions: packages: write` in a reusable workflow requires the
  calling repo's own default workflow permissions to allow write** (repo
  Settings → Actions → General → Workflow permissions). If the caller repo
  defaults to read-only, requesting `packages: write` anywhere in the call
  chain is rejected *before any job runs* — again a bare `startup_failure`
  with no job-level error to point at. Check via `gh api
  repos/<owner>/<repo>/actions/permissions/workflow`; fix with `gh api -X
  PUT ... -f default_workflow_permissions=write`.
- **Docker/GHCR image names must be all-lowercase.**
  `github.repository_owner` preserves the account's actual casing (e.g.
  `KarnamV`), which `docker buildx build` rejects with "repository name
  must be lowercase" — `build-push.yml` lowercases owner/prefix/service
  name in a dedicated step before constructing tags.
- **The self-hosted runner's job checkout is not `/home/bitforge/<app>`.**
  That's your persistent dev clone (with whatever's currently
  uncommitted) — the deploy job uses its own fresh, ephemeral checkout, so
  it never touches your local edits. Since `.env` isn't committed, the
  deploy step copies the real one in from the fixed host path you pass as
  `env_file_path`.
- **When testing rollback without wanting a full CI round-trip**, you
  don't need to push a real broken commit — `docker service update
  --image <anything, even a local-only tag>` on the live service exercises
  the exact same `update_config`/`rollback_config` Swarm already has
  attached to it.

## Adding a new app (BabyTracker, Chronicle, ...)

Assuming the app already has a Dockerfile per service and a Swarm stack
file (`docs/swarm-migration.md` "Adding a new application stack" covers
that part):

1. **Register a runner**: `scripts/setup-github-runner.sh
   KarnamV/<app>`, then run the two `sudo ./svc.sh install <user>` /
   `sudo ./svc.sh start` commands it prints. Verify: `gh api
   repos/KarnamV/<app>/actions/runners --jq '.runners[] | {name,
   status}'` shows `online`.
2. **Enable write workflow permissions** on the new repo (needed to push
   to GHCR): `gh api -X PUT repos/KarnamV/<app>/actions/permissions/workflow
   -f default_workflow_permissions=write -F can_approve_pull_request_reviews=false`.
3. **Point the stack file's image references at GHCR**:
   `ghcr.io/karnamv/<app>-<service>:${<APP>_VERSION:-latest}` for every
   service that gets built by CI (not the database — that stays a plain
   upstream image tag).
4. **Add the caller workflow**, copying `nest/.github/workflows/deploy.yml`
   almost verbatim: update the `paths:` filter, the `services` JSON (one
   entry per Dockerfile), `image_prefix`, `stack_name`, and
   `env_file_path`.
5. Push to `main` and watch `gh run list` / `gh run view <id>`.

That's the entire "minimal configuration" footprint per app: one runner
registration, one repo setting, and a ~30-line workflow file.
