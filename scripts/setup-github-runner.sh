#!/usr/bin/env bash
#
# homelab/scripts/setup-github-runner.sh — register a self-hosted GitHub
# Actions runner for one app repo, as its own systemd service.
#
# GitHub doesn't support sharing one runner process across multiple
# personal-account repos, so each app repo that wants auto-deploy gets its
# own runner instance (its own directory, its own systemd service) — this
# script is the reusable "one command" version of that setup, so adding
# BabyTracker/Chronicle later doesn't mean re-deriving the steps from
# scratch. Requires: `gh` authenticated with repo access, and enough sudo
# access to install a systemd service (the script will prompt for it).
#
# Usage:
#   scripts/setup-github-runner.sh <owner>/<repo> [runner-name]
#
# Example:
#   scripts/setup-github-runner.sh KarnamV/babytracker homelab-babytracker

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <owner>/<repo> [runner-name]" >&2
  exit 1
fi

REPO="$1"
REPO_SLUG="${REPO//\//-}"                     # KarnamV/nest -> KarnamV-nest
RUNNER_NAME="${2:-homelab-${REPO#*/}}"        # default: homelab-<repo>
RUNNER_DIR="${HOME}/actions-runner-${REPO#*/}"
RUNNER_VERSION="2.336.0"

if [[ -d "$RUNNER_DIR" ]]; then
  echo "setup-github-runner.sh: ${RUNNER_DIR} already exists — remove it first if you're re-registering." >&2
  exit 1
fi

command -v gh >/dev/null 2>&1 || { echo "setup-github-runner.sh: gh CLI not found" >&2; exit 1; }

echo "Downloading actions-runner v${RUNNER_VERSION}..."
mkdir -p "$RUNNER_DIR"
curl -sL -o "${RUNNER_DIR}/actions-runner.tar.gz" \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
tar xzf "${RUNNER_DIR}/actions-runner.tar.gz" -C "$RUNNER_DIR"
rm -f "${RUNNER_DIR}/actions-runner.tar.gz"

echo "Requesting a registration token for ${REPO}..."
TOKEN="$(gh api -X POST "repos/${REPO}/actions/runners/registration-token" --jq '.token')"

echo "Configuring runner '${RUNNER_NAME}'..."
(
  cd "$RUNNER_DIR"
  ./config.sh --url "https://github.com/${REPO}" --token "$TOKEN" \
    --name "$RUNNER_NAME" --labels homelab --work _work --unattended --replace
)

echo
echo "Runner configured at ${RUNNER_DIR}. To install it as a systemd service"
echo "(requires sudo, run these two commands yourself):"
echo
echo "  cd ${RUNNER_DIR} && sudo ./svc.sh install $(whoami)"
echo "  cd ${RUNNER_DIR} && sudo ./svc.sh start"
echo
echo "Verify with: gh api repos/${REPO}/actions/runners --jq '.runners[] | {name, status, busy}'"
