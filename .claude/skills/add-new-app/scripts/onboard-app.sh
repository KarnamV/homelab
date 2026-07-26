#!/usr/bin/env bash
#
# homelab/.claude/skills/add-new-app/scripts/onboard-app.sh — mechanical,
# non-judgment-requiring half of onboarding a new app repo onto the GitOps
# pipeline documented in homelab/docs/gitops-pipeline.md.
#
# Handles: registering a self-hosted runner for the repo, and enabling
# write workflow permissions on it (both required before any CI run of the
# reusable deploy pipeline can succeed — see "Gotchas" in
# docs/gitops-pipeline.md for why each is a hard requirement, not optional
# hardening).
#
# Deliberately does NOT touch the app repo's stack file or write its caller
# workflow — those need someone (or an agent) to actually look at the app's
# services/Dockerfiles and make real decisions, not blind templating. See
# templates/deploy.yml.template in this skill directory for that part.
#
# Usage:
#   onboard-app.sh <owner>/<repo>
#
# Example:
#   onboard-app.sh KarnamV/babytracker

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <owner>/<repo>" >&2
  exit 1
fi

REPO="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
HOMELAB_ROOT="$(cd -- "${SCRIPT_DIR}/../../../.." &>/dev/null && pwd)"

command -v gh >/dev/null 2>&1 || { echo "onboard-app.sh: gh CLI not found" >&2; exit 1; }

echo "=== 1/2: registering a self-hosted runner for ${REPO} ==="
bash "${HOMELAB_ROOT}/scripts/setup-github-runner.sh" "$REPO"

echo
echo "=== 2/2: enabling write workflow permissions on ${REPO} ==="
# Required for any job in the pipeline that requests `packages: write`
# (build-push.yml) — without this, the whole run fails with a bare
# startup_failure and zero job-level detail, before anything even runs.
gh api -X PUT "repos/${REPO}/actions/permissions/workflow" \
  -f default_workflow_permissions=write \
  -F can_approve_pull_request_reviews=false
echo "OK: repos/${REPO}/actions/permissions/workflow -> default_workflow_permissions=write"

echo
echo "=== Mechanical steps done. What's left (needs judgment, not scripted): ==="
echo "1. Install + start the runner as a systemd service (needs sudo, run these"
echo "   two commands yourself — printed above by setup-github-runner.sh)."
echo "2. Point the app's stack file image references at GHCR:"
echo "   ghcr.io/\$(echo \${REPO%/*} | tr A-Z a-z)/<app>-<service>:\${<APP>_VERSION:-latest}"
echo "3. Copy templates/deploy.yml.template (in this skill directory) to"
echo "   <app-repo>/.github/workflows/deploy.yml and fill in the placeholders."
echo "4. Push to main and watch: gh run list --repo ${REPO}"
