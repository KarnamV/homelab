---
name: add-new-app
description: Onboard a new application repo onto this homelab's GitOps CI/CD pipeline (push to main -> build -> push to GHCR -> Docker Swarm deploy with rolling update + auto-rollback), following the same pattern already working for Nest. Use when the user asks to add a new app to the deployment pipeline, wants CI/CD set up for BabyTracker/Chronicle/another app, says "add this app to the pipeline", "onboard <app> for deployment", "set up auto-deploy for <app>", or runs `/add-new-app`.
---

# /add-new-app — onboard a new app onto the homelab GitOps pipeline

Context: this homelab has no public network exposure, so deploys run
through a self-hosted GitHub Actions runner on the homelab host itself,
building images on GitHub-hosted runners and pushing to GHCR, then
redeploying via `docker stack deploy` on Docker Swarm (`start-first`
rolling updates, healthcheck-gated auto-rollback). The full architecture,
every gotcha hit standing it up, and the reasoning behind each piece are
in `docs/gitops-pipeline.md` and `docs/swarm-migration.md` — read those if
anything below is unclear, don't guess. `nest` is the first, currently
working example of everything this skill produces; when in doubt, diff
against its real files rather than reconstructing from memory:
`/home/bitforge/nest/docker-compose.production.yml` and
`/home/bitforge/nest/.github/workflows/deploy.yml`.

## Preconditions

- The app already has its own GitHub repo (private is fine) with a
  Dockerfile per service that needs building.
- If the app isn't on Docker Swarm yet at all, get it there first following
  `docs/swarm-migration.md`'s "Adding a new application stack" section —
  this skill assumes a working Swarm stack file already exists (or is
  being written as part of this), not a plain `docker-compose.yml`.
- `gh` CLI authenticated with `repo` + `workflow` scopes (already true on
  this host).

## Step 1 — gather the app's shape

Ask the user (or inspect the app repo directly) for:
- `owner/repo` (e.g. `KarnamV/babytracker`)
- Stack name (usually the repo name)
- Every service that needs building: name, build context, Dockerfile path
- Which services exist but should **not** be built/deployed by CI (Postgres,
  other stock images — those stay on whatever tag they already use)
- Path to the app's real `.env` on this host (usually
  `/home/bitforge/<app>/.env` — the one with real secrets, never committed)
- The image-tag variable name(s) the stack file uses per service (Nest
  shares one `NEST_VERSION` across both its services; a different app might
  need one per service — that's fine, `env_overrides` takes
  space-separated `KEY=VALUE` pairs)

## Step 2 — run the mechanical onboarding script

```bash
<skill-dir>/scripts/onboard-app.sh <owner>/<repo>
```

This registers a self-hosted runner for the repo (its own systemd service —
GitHub can't share one runner process across personal-account repos) and
sets the repo's default workflow permissions to write. Both are required
before any CI run of the reusable deploy pipeline can succeed; skipping
either produces a `startup_failure` with **zero job-level detail** — see
"If it fails" below.

**The script prints two `sudo ./svc.sh ...` commands it cannot run itself**
(installing a systemd service needs root, which this environment doesn't
grant non-interactively). Tell the user to run those two commands
themselves, then verify before moving on:

```bash
gh api repos/<owner>/<repo>/actions/runners --jq '.runners[] | {name, status}'
```

Don't proceed to Step 5 (pushing) until this shows `"status":"online"`.

## Step 3 — update the app's stack file (judgment required, don't skip)

For every service that gets built by CI:
- Point its `image:` at
  `ghcr.io/<owner, lowercased>/<stack>-<service>:${<VERSION_VAR>:-latest}`
  (GHCR requires lowercase image names even though GitHub preserves account
  casing — this bit us once already, see `docs/gitops-pipeline.md`).
- Confirm it has (or add): `deploy.labels` for `traefik.*` — not top-level
  `labels:`, Traefik's Swarm provider only reads service labels —
  `deploy.update_config.order: start-first` (or `stop-first` for anything
  with an exclusive-lock data directory, like a database), `healthcheck:`,
  `deploy.rollback_config`, `deploy.restart_policy`.
- Leave stock-image services (Postgres, etc.) untouched — they're not part
  of this pipeline.

## Step 4 — write the caller workflow

Copy `templates/deploy.yml.template` (in this skill's directory) to
`<app-repo>/.github/workflows/deploy.yml` and fill in every
`{{PLACEHOLDER}}`. Compare against Nest's real, working
`.github/workflows/deploy.yml` if anything's ambiguous.

## Step 5 — commit, then STOP for confirmation before pushing

Commit the stack file change and the new workflow file locally. Pushing to
the app repo's `main` immediately triggers a real build and deploy against
the live stack — same as Nest's rollout, this is the one step here that
isn't easily reversible. Pause and get explicit go-ahead before `git push`,
don't push as part of the same turn that wrote the files.

## Step 6 — verify

After pushing: `gh run list --repo <owner>/<repo> --limit 1`, then
`gh run view <run-id> --repo <owner>/<repo>` until it completes. Confirm
`docker service ps <stack>_<service>` shows the new task running the
just-built `sha-<...>` tag and healthy, and that the app's route still
responds.

## If it fails

Check, in this order — these are the three real failures hit building this
pipeline the first time, and all three manifest as an opaque
`startup_failure` or build error with little/no useful detail in the
GitHub UI:

1. **Does the caller workflow's `uses: KarnamV/homelab/...@<ref>` actually
   match homelab's default branch?**
   `gh api repos/KarnamV/homelab --jq '.default_branch'` — it's `master`,
   not `main`. A run with `"referenced_workflows": []` and zero jobs means
   this reference never resolved.
2. **Is `default_workflow_permissions` really `write` on the app repo?**
   `gh api repos/<owner>/<repo>/actions/permissions/workflow`. A run with
   `"conclusion": "startup_failure"` and `gh api
   repos/.../actions/runs/<id>/jobs` returning `"total_count": 0` — i.e.
   not even one job got scheduled — means this, not a YAML problem. Don't
   spend time re-reading the workflow file before checking this.
3. **Is every image reference lowercase?** The actual build error for this
   one is clear enough on its own ("repository name must be lowercase"),
   found via `gh api repos/<owner>/<repo>/actions/jobs/<job-id>/logs`.

If auto-rollback itself ever needs re-verifying without a real broken
commit: `docker service update --image <anything, even a local-only tag>
<stack>_<service>` exercises the exact same `update_config`/
`rollback_config` already attached to the live service — no need to push
a deliberately broken commit through CI.
