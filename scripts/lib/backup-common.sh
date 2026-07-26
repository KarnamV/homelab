#!/usr/bin/env bash
# homelab/scripts/lib/backup-common.sh
#
# Shared functions for backup.sh and restore.sh. Sourced, never executed
# directly. Keeping this in one place is the point: retention math, the
# helper-container tar trick, checksum verification, and logging only exist
# once, so backup.sh and restore.sh can't drift out of sync with each other.

# Exit codes shared by backup.sh and restore.sh. Documented here once;
# both scripts' --help output and docs/backup-restore.md reference this list
# rather than repeating it.
EXIT_OK=0
EXIT_GENERAL_ERROR=1
EXIT_CONFIG_ERROR=2
EXIT_DISK_SPACE=3
EXIT_PERMISSION=4
EXIT_DOCKER_UNAVAILABLE=5
EXIT_VERIFY_FAILED=6
EXIT_RESTORE_ABORTED=7
EXIT_BAD_ARGS=10

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# log()/die() write to both stdout (so `systemctl status` / interactive runs
# see it) and $LOG_FILE (so history survives after the run). Callers must
# set LOG_FILE before sourcing calls to log()/die(); init_logging() does
# that plus creates LOG_DIR.

init_logging() {
    local prefix="$1"   # "backup" or "restore"
    mkdir -p "$LOG_DIR" || {
        echo "FATAL: cannot create LOG_DIR ($LOG_DIR)" >&2
        exit "$EXIT_PERMISSION"
    }
    LOG_FILE="${LOG_DIR}/${prefix}-$(date +%Y-%m-%d_%H%M%S).log"
    : > "$LOG_FILE" || {
        echo "FATAL: cannot write LOG_FILE ($LOG_FILE)" >&2
        exit "$EXIT_PERMISSION"
    }
}

_log_line() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] [%s] %s\n' "$ts" "$level" "$*" | tee -a "${LOG_FILE:-/dev/null}"
}

log_info()  { _log_line "INFO"  "$*"; }
log_warn()  { _log_line "WARN"  "$*" >&2; }
log_error() { _log_line "ERROR" "$*" >&2; }

# die EXIT_CODE "message..." — log as ERROR and exit with the given code.
die() {
    local code="$1"; shift
    log_error "$*"
    exit "$code"
}

# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

# load_config PATH — source the config file and sanity-check the variables
# every other function in this file relies on. Exits EXIT_CONFIG_ERROR on
# any problem rather than failing confusingly halfway through a run.
load_config() {
    local conf="$1"
    [[ -f "$conf" ]] || {
        echo "FATAL: config file not found: $conf" >&2
        exit "$EXIT_CONFIG_ERROR"
    }
    # shellcheck source=/dev/null
    . "$conf"

    local required_vars=(
        HOMELAB_ROOT BACKUP_ROOT RUNS_DIR LOG_DIR STATE_DIR
        RETENTION_DAYS RETENTION_CYCLES LOKI_FULL_DAY MIN_FREE_SPACE_MB
        ARCHIVE_EXT GZIP_LEVEL AUTHENTIK_PG_CONTAINER AUTHENTIK_PG_USER
        AUTHENTIK_PG_DB UPTIME_KUMA_CONTAINER GRAFANA_VOLUME
        PROMETHEUS_VOLUME HELPER_IMAGE AUTHENTIK_APP_DATA_DIR LOKI_DATA_DIR
    )
    local missing=()
    local v
    for v in "${required_vars[@]}"; do
        [[ -n "${!v:-}" ]] || missing+=("$v")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "FATAL: config file $conf is missing required variable(s): ${missing[*]}" >&2
        exit "$EXIT_CONFIG_ERROR"
    fi

    [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || {
        echo "FATAL: RETENTION_DAYS must be a positive integer, got: $RETENTION_DAYS" >&2
        exit "$EXIT_CONFIG_ERROR"
    }
    [[ "$RETENTION_CYCLES" =~ ^[0-9]+$ ]] || {
        echo "FATAL: RETENTION_CYCLES must be a positive integer, got: $RETENTION_CYCLES" >&2
        exit "$EXIT_CONFIG_ERROR"
    }
    [[ "$MIN_FREE_SPACE_MB" =~ ^[0-9]+$ ]] || {
        echo "FATAL: MIN_FREE_SPACE_MB must be a positive integer, got: $MIN_FREE_SPACE_MB" >&2
        exit "$EXIT_CONFIG_ERROR"
    }
}

# ---------------------------------------------------------------------------
# Validation (used by backup.sh --check and at the top of every real run)
# ---------------------------------------------------------------------------

# check_docker — confirm the Docker daemon is reachable. Backups don't need
# to touch running containers' lifecycle, but pg_dump/sqlite-backup/volume
# reads all go through `docker exec`/`docker run`, so this is a hard
# requirement.
check_docker() {
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon not reachable (is it running? is \$USER in the docker group?)"
        return "$EXIT_DOCKER_UNAVAILABLE"
    fi
    return "$EXIT_OK"
}

# resolve_container SERVICE_NAME — print the container ID of the currently
# running task for a Docker Swarm service (e.g. "authentik_authentik-postgresql"),
# or nothing if none is running. Swarm-managed containers get generated
# names (<service>.<slot>.<task-id>), never the fixed name a plain `docker
# run`/compose container would have, so every docker exec/stop/start target
# in these scripts is resolved through this instead of a literal name.
resolve_container() {
    local service="$1"
    docker ps -q -f "name=^${service}\." | head -1
}

# service_scale SERVICE_NAME REPLICAS — scale a Swarm service and block until
# it converges. Used in place of `docker stop`/`docker start` for
# Swarm-managed containers: stopping one directly just gets it replaced by
# the orchestrator to maintain the desired replica count, so "stop" here
# means scale to 0 and "start" means scale back to 1.
service_scale() {
    local service="$1" replicas="$2"
    docker service scale "${service}=${replicas}" --detach=false 1>>"${LOG_FILE:-/dev/null}" 2>&1
}

# container_running SERVICE_NAME — 0 if a task is currently running, 1
# otherwise. Callers decide whether that's fatal (Postgres: yes) or just
# skip-with-a-warning (nothing currently treated as optional, but this keeps
# that decision in one place if that changes).
container_running() {
    local service="$1"
    [[ -n "$(resolve_container "$service")" ]]
}

# check_disk_space PATH MIN_MB — free space on the filesystem containing
# PATH (created first if it doesn't exist yet, so a fresh BACKUP_ROOT can be
# checked before anything is written under it).
check_disk_space() {
    local path="$1" min_mb="$2"
    mkdir -p "$path" 2>/dev/null
    if [[ ! -d "$path" ]]; then
        log_error "check_disk_space: $path does not exist and could not be created"
        return "$EXIT_PERMISSION"
    fi
    local avail_mb
    avail_mb="$(df -Pm "$path" | awk 'NR==2 {print $4}')"
    if [[ -z "$avail_mb" ]]; then
        log_error "check_disk_space: could not determine free space for $path"
        return "$EXIT_GENERAL_ERROR"
    fi
    log_info "Free space on $(df -P "$path" | awk 'NR==2 {print $6}'): ${avail_mb}MB (need >= ${min_mb}MB)"
    if (( avail_mb < min_mb )); then
        log_error "Insufficient free space: ${avail_mb}MB available, ${min_mb}MB required (MIN_FREE_SPACE_MB in backup.conf)"
        return "$EXIT_DISK_SPACE"
    fi
    return "$EXIT_OK"
}

# check_path_readable PATH — used during --check to validate every
# configured source path actually exists and is readable *by whatever will
# read it*: for bitforge-owned paths that's this process directly; for
# root-owned bind mounts (portainer, uptime-kuma) and named volumes
# (grafana/prometheus), actual reads always happen inside a container (see
# tar_via_helper / docker exec below), so this only checks existence there,
# not host-level readability.
check_path_exists() {
    local path="$1" label="$2"
    if [[ ! -e "$path" ]]; then
        log_error "Source path missing: $label ($path)"
        return 1
    fi
    log_info "OK: $label exists ($path)"
    return 0
}

check_path_writable() {
    local path="$1" label="$2"
    mkdir -p "$path" 2>/dev/null
    if [[ ! -w "$path" ]]; then
        log_error "Destination not writable: $label ($path)"
        return 1
    fi
    log_info "OK: $label writable ($path)"
    return 0
}

# ---------------------------------------------------------------------------
# The helper-container trick
# ---------------------------------------------------------------------------
# Several sources this script backs up are not readable by bitforge directly
# on the host: root-owned bind mounts (data/portainer is 700/600, owned by
# root) and Docker-managed named volumes (grafana/prometheus data lives
# under /var/lib/docker/volumes/*/_data, root-only). Rather than requiring
# backup.sh to run as root (and needing sudo/systemd-root wiring for what is
# otherwise a plain user-level task), every such source is read by handing a
# short-lived, network-disabled, read-only-mounted HELPER_IMAGE container the
# single job of tar-ing its own view of the data. bitforge only needs Docker
# socket access (the `docker` group), which it already has for docker
# exec/inspect elsewhere in these scripts.
#
# tar_via_helper MOUNT_SPEC DEST_TARBALL [EXTRA_TAR_ARGS...]
#   MOUNT_SPEC: a `docker run -v` argument, e.g.
#     "/home/bitforge/homelab/data/portainer:/source:ro"  (bind mount)
#     "monitoring_grafana-data:/source:ro"                (named volume)
tar_via_helper() {
    local mount_spec="$1" dest="$2"; shift 2
    local dest_dir dest_file
    dest_dir="$(dirname "$dest")"
    dest_file="$(basename "$dest")"
    mkdir -p "$dest_dir"
    docker run --rm \
        --pull=never \
        --network=none \
        -v "${mount_spec}" \
        -v "${dest_dir}:/backup" \
        "$HELPER_IMAGE" \
        tar czf "/backup/${dest_file}" -C /source "$@" . \
        1>>"${LOG_FILE:-/dev/null}" 2>&1
}

# ---------------------------------------------------------------------------
# Checksums / archive verification
# ---------------------------------------------------------------------------

# verify_archive PATH — structural integrity check (not a full data
# comparison — that's what restore --verify-only / a periodic test-restore
# is for). gzip -t decompresses and checks the CRC; for .tar.gz that also
# implicitly walks the whole tar stream.
verify_archive() {
    local path="$1"
    if [[ ! -s "$path" ]]; then
        log_error "verify_archive: $path is missing or empty"
        return 1
    fi
    case "$path" in
        *.tar.gz|*.tgz)
            if ! gzip -t "$path" 2>>"${LOG_FILE:-/dev/null}"; then
                log_error "verify_archive: gzip integrity check FAILED for $path"
                return 1
            fi
            ;;
        *.gz)
            if ! gzip -t "$path" 2>>"${LOG_FILE:-/dev/null}"; then
                log_error "verify_archive: gzip integrity check FAILED for $path"
                return 1
            fi
            ;;
        *)
            log_warn "verify_archive: no integrity check defined for extension of $path, skipping"
            ;;
    esac
    log_info "Verified OK: $path"
    return 0
}

# write_checksums DIR — (re)writes DIR/SHA256SUMS covering every regular
# file in DIR (non-recursive into itself, i.e. it won't checksum a
# SHA256SUMS from a previous run). Called once per run directory, after all
# archives for that run have been written.
write_checksums() {
    local dir="$1"
    local sums_file="${dir}/SHA256SUMS"
    # The temp file must live OUTSIDE $dir: if it were e.g. $dir/SHA256SUMS.tmp,
    # `find` and the shell's redirection setup race each other (the
    # redirect can create the empty temp file before `find` finishes
    # scanning, which then lists and tries to hash itself — intermittent
    # "No such file or directory" from sha256sum). mktemp elsewhere sidesteps
    # that entirely.
    local tmp_sums
    tmp_sums="$(mktemp)" || { log_error "write_checksums: mktemp failed"; return 1; }
    (
        cd "$dir" || exit "$EXIT_GENERAL_ERROR"
        find . -type f ! -name 'SHA256SUMS' -print0 \
            | sort -z \
            | xargs -0 sha256sum
    ) > "$tmp_sums"
    mv "$tmp_sums" "$sums_file"
    log_info "Wrote checksums: $sums_file"
}

# verify_checksums DIR — used by restore.sh before touching anything.
# Returns non-zero and logs every mismatch/missing file if verification
# fails.
verify_checksums() {
    local dir="$1"
    local sums_file="${dir}/SHA256SUMS"
    if [[ ! -f "$sums_file" ]]; then
        log_error "verify_checksums: no SHA256SUMS in $dir"
        return 1
    fi
    (
        cd "$dir" || exit "$EXIT_GENERAL_ERROR"
        sha256sum -c "SHA256SUMS" --quiet
    )
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

human_size() {
    local path="$1"
    du -sh "$path" 2>/dev/null | awk '{print $1}'
}

# require_cmd NAME... — die with EXIT_CONFIG_ERROR listing every missing
# tool at once, rather than failing on the first one 40 minutes into a run.
require_cmds() {
    local missing=()
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "$EXIT_CONFIG_ERROR" "Required command(s) not found on PATH: ${missing[*]}"
    fi
}
