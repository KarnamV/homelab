#!/usr/bin/env bash
#
# homelab/scripts/stack-deploy.sh — deploy a Docker Swarm stack from a
# directory containing a stack compose file and an optional .env.
#
# `docker stack deploy` (unlike `docker compose`) does not auto-load a
# sibling .env file, and ignores per-service `env_file:` entirely. This
# wrapper exports the directory's .env into the shell first (if one
# exists), so `${VAR}` interpolation in the stack file resolves from the
# shell environment the same way `docker compose` would have resolved it
# from env_file/.env. Stack files that used to reference `env_file:` are
# expected to use explicit `environment: KEY: ${KEY}` entries instead.
#
# Usage:
#   stack-deploy.sh <stack-dir> <stack-name> [compose-file]
#
# If compose-file is omitted, tries compose.yaml, then docker-compose.yml,
# then docker-compose.production.yml, in that order.
#
# Examples:
#   scripts/stack-deploy.sh compose/authentik authentik
#   scripts/stack-deploy.sh /home/bitforge/nest nest docker-compose.production.yml

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <stack-dir> <stack-name> [compose-file]" >&2
  exit 1
fi

STACK_DIR="$1"
STACK_NAME="$2"
COMPOSE_FILE="${3:-}"

if [[ ! -d "$STACK_DIR" ]]; then
  echo "stack-deploy.sh: no such directory: ${STACK_DIR}" >&2
  exit 1
fi

if [[ -z "$COMPOSE_FILE" ]]; then
  for candidate in compose.yaml docker-compose.yml docker-compose.production.yml; do
    if [[ -f "${STACK_DIR}/${candidate}" ]]; then
      COMPOSE_FILE="$candidate"
      break
    fi
  done
fi

if [[ -z "$COMPOSE_FILE" || ! -f "${STACK_DIR}/${COMPOSE_FILE}" ]]; then
  echo "stack-deploy.sh: no compose.yaml / docker-compose.yml / docker-compose.production.yml found in ${STACK_DIR}" >&2
  exit 1
fi

if [[ -f "${STACK_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${STACK_DIR}/.env"
  set +a
fi

exec docker stack deploy \
  --compose-file "${STACK_DIR}/${COMPOSE_FILE}" \
  --with-registry-auth \
  --detach=false \
  "${STACK_NAME}"
