#!/usr/bin/env bash
#
# homelab/scripts/backup.sh — nightly backup for the bitforge homelab stack.
#
# Backs up (see docs/backup-restore.md for full detail on each):
#   - Authentik's Postgres database   (pg_dump, not a raw file copy)
#   - Grafana's / Prometheus's Docker-managed volumes
#   - Homepage, Portainer, Promtail, uptime-kuma-sync bind-mounted data
#   - Authentik's own bind-mounted data (media/templates/certs; NOT its
#     Postgres data dir — see backup_authentik_app below)
#   - Uptime Kuma (SQLite online backup + its other bind-mounted data)
#   - Loki (the one incremental source: weekly full + daily incrementals)
#   - This repo's compose/ + docs/ + certs/, and the external (non-git)
#     monitoring stack's compose file + .env
#
# Never stops, restarts, or pauses any container. Every read is either a
# read-only bind/volume mount into a short-lived helper container, a
# `docker exec` of a backup-specific command the target app already
# supports (pg_dump, sqlite3 .backup), or a direct host-filesystem read of
# a bitforge-owned directory (Loki, config/).
#
# Usage:
#   backup.sh [-c CONFIG] [--check] [--only NAME[,NAME...]] [--force-full] [-h]
#
#   --check        Validate configuration, paths, permissions, disk space,
#                   and Docker connectivity, then exit — no backup is run,
#                   nothing is written under BACKUP_ROOT/runs.
#   --only NAMES   Comma-separated step names to run (see --help for the
#                   list). Mainly useful for testing one step at a time.
#   --force-full   Force today's Loki backup to be a full baseline instead
#                   of an incremental, regardless of LOKI_FULL_DAY.
#
# Exit codes: see scripts/lib/backup-common.sh (EXIT_* constants) and
# docs/backup-restore.md "Exit codes".

# Deliberately NOT using `set -e`/an ERR trap: this script's whole point is
# to keep going after one step fails (a broken Loki backup shouldn't stop
# the Postgres dump from being attempted) and reserve a nonzero exit for
# "at least one step failed", decided explicitly at the end. errexit's
# interaction with functions-called-as-conditions is a well-known bash
# footgun that makes "continue past a guarded failure" hard to reason about
# correctly — every command whose failure matters is checked explicitly
# below instead. `-u` (nounset) and `-o pipefail` are both safe/predictable
# and kept on.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/backup.conf"

# shellcheck source=lib/backup-common.sh
. "${SCRIPT_DIR}/lib/backup-common.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

CONFIG_FILE="$DEFAULT_CONFIG"
CHECK_ONLY=0
ONLY_STEPS=""
FORCE_FULL=0

print_help() {
    cat <<'EOF'
Usage: backup.sh [-c CONFIG] [--check] [--only NAME[,NAME...]] [--force-full] [-h]

  -c, --config PATH   Use PATH instead of scripts/backup.conf
      --check         Validate everything, run nothing, exit
      --only NAMES    Comma-separated: postgres,grafana,prometheus,binds,
                       authentik-app,uptime-kuma,loki,config
      --force-full    Force a full (not incremental) Loki backup today
  -h, --help          This message

Exit codes: 0 ok, 1 general error, 2 config error, 3 low disk space,
4 permission error, 5 Docker unavailable, 6 archive verification failed,
10 bad arguments. See docs/backup-restore.md for details.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) CONFIG_FILE="$2"; shift 2 ;;
        --check) CHECK_ONLY=1; shift ;;
        --only) ONLY_STEPS="$2"; shift 2 ;;
        --force-full) FORCE_FULL=1; shift ;;
        -h|--help) print_help; exit "$EXIT_OK" ;;
        *) echo "Unknown argument: $1" >&2; print_help >&2; exit "$EXIT_BAD_ARGS" ;;
    esac
done

load_config "$CONFIG_FILE"
init_logging "backup"

RUN_START_EPOCH=$(date +%s)
RUN_DATE="$(date +%F)"
RUN_DIR="${RUNS_DIR}/${RUN_DATE}"

log_info "=== homelab backup starting (run date: $RUN_DATE, config: $CONFIG_FILE) ==="

# ---------------------------------------------------------------------------
# Pre-flight validation — shared by --check and every real run. A real run
# treats failures here as fatal (abort before writing anything); --check
# reports them and continues through the rest of the list so you see every
# problem in one pass instead of fixing them one at a time.
# ---------------------------------------------------------------------------

preflight() {
    local problems=0

    # Checked inline (not via require_cmds, which hard-exits) so --check
    # reports every problem in one pass instead of stopping at the first.
    local missing_cmds=() c
    for c in docker tar gzip sha256sum du df date; do
        command -v "$c" >/dev/null 2>&1 || missing_cmds+=("$c")
    done
    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        log_error "Required command(s) not found on PATH: ${missing_cmds[*]}"
        problems=1
    fi

    if check_docker; then
        log_info "OK: Docker daemon reachable"
    else
        problems=1
    fi

    for c in "$AUTHENTIK_PG_CONTAINER" "$UPTIME_KUMA_CONTAINER"; do
        if container_running "$c"; then
            log_info "OK: container running: $c"
        else
            log_error "Container not running: $c"
            problems=1
        fi
    done

    if docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1; then
        log_info "OK: helper image present locally: $HELPER_IMAGE"
    else
        log_error "Helper image not found locally: $HELPER_IMAGE (pull it once by hand: docker pull $HELPER_IMAGE — backup.sh itself never pulls, by design)"
        problems=1
    fi

    for vol in "$GRAFANA_VOLUME" "$PROMETHEUS_VOLUME"; do
        if docker volume inspect "$vol" >/dev/null 2>&1; then
            log_info "OK: volume exists: $vol"
        else
            log_error "Docker volume not found: $vol"
            problems=1
        fi
    done

    check_path_exists "$AUTHENTIK_APP_DATA_DIR" "authentik app data dir" || problems=1
    check_path_exists "$LOKI_DATA_DIR" "loki data dir" || problems=1
    [[ -r "$LOKI_DATA_DIR" ]] || { log_error "Loki data dir not readable by $(whoami): $LOKI_DATA_DIR"; problems=1; }

    local entry name path
    for entry in "${BIND_MOUNTS_FULL[@]}"; do
        name="${entry%%:*}"; path="${entry#*:}"
        check_path_exists "$path" "bind mount: $name" || problems=1
    done

    for path in "${CONFIG_PATHS_HOMELAB[@]}"; do
        check_path_exists "$path" "homelab config path" || problems=1
    done

    check_path_writable "$BACKUP_ROOT" "BACKUP_ROOT" || problems=1
    check_disk_space "$BACKUP_ROOT" "$MIN_FREE_SPACE_MB" || problems=1

    return $problems
}

if [[ $CHECK_ONLY -eq 1 ]]; then
    if preflight; then
        log_info "=== --check: all validations passed ==="
        exit "$EXIT_OK"
    else
        log_error "=== --check: one or more validations FAILED (see above) ==="
        exit "$EXIT_GENERAL_ERROR"
    fi
fi

if ! preflight; then
    die "$EXIT_GENERAL_ERROR" "Pre-flight validation failed, aborting before writing anything. Run with --check for full detail."
fi

if find "$RUN_DIR" -mindepth 2 -type f 2>/dev/null | grep -q .; then
    log_warn "Run directory $RUN_DIR already has content from an earlier run today — files with matching names will be overwritten"
fi
mkdir -p "${RUN_DIR}/postgres" "${RUN_DIR}/volumes" "${RUN_DIR}/binds" "${RUN_DIR}/config" \
    || die "$EXIT_PERMISSION" "Could not create run directory structure under $RUN_DIR"

# ---------------------------------------------------------------------------
# Backup steps
# ---------------------------------------------------------------------------

backup_postgres() {
    local dest="${RUN_DIR}/postgres/authentik-${RUN_DATE}.sql.gz"
    local container; container="$(resolve_container "$AUTHENTIK_PG_CONTAINER")"
    if [[ -z "$container" ]]; then
        log_error "backup_postgres: no running container for service $AUTHENTIK_PG_CONTAINER"
        return 1
    fi
    if ! docker exec "$container" pg_dump -U "$AUTHENTIK_PG_USER" -d "$AUTHENTIK_PG_DB" --no-password \
            2>>"${LOG_FILE}" | gzip -"$GZIP_LEVEL" > "$dest"; then
        log_error "backup_postgres: pg_dump | gzip failed"
        rm -f "$dest"
        return 1
    fi
    verify_archive "$dest" || return 1
    log_info "Postgres backup OK: $dest ($(human_size "$dest"))"
}

backup_grafana_volume() {
    local dest="${RUN_DIR}/volumes/grafana-data-${RUN_DATE}.tar.gz"
    if ! tar_via_helper "${GRAFANA_VOLUME}:/source:ro" "$dest"; then
        log_error "backup_grafana_volume: tar_via_helper failed (see log above for container output)"
        return 1
    fi
    verify_archive "$dest" || return 1
    log_info "Grafana volume backup OK: $dest ($(human_size "$dest")) — note: SQLite copied live (no sqlite3 CLI in the grafana image to do an online .backup); see docs for why this is acceptable here"
}

backup_prometheus_volume() {
    local dest="${RUN_DIR}/volumes/prometheus-data-${RUN_DATE}.tar.gz"
    if ! tar_via_helper "${PROMETHEUS_VOLUME}:/source:ro" "$dest"; then
        log_error "backup_prometheus_volume: tar_via_helper failed"
        return 1
    fi
    verify_archive "$dest" || return 1
    log_info "Prometheus volume backup OK: $dest ($(human_size "$dest")) — full snapshot, not incremental; see docs for why (admin API / tsdb snapshot not enabled)"
}

backup_bind_mounts_full() {
    local rc=0 entry name path dest
    for entry in "${BIND_MOUNTS_FULL[@]}"; do
        name="${entry%%:*}"; path="${entry#*:}"
        dest="${RUN_DIR}/binds/${name}-${RUN_DATE}.tar.gz"
        if ! tar_via_helper "${path}:/source:ro" "$dest"; then
            log_error "backup_bind_mounts_full: tar failed for $name ($path)"
            rc=1
            continue
        fi
        if ! verify_archive "$dest"; then
            rc=1
            continue
        fi
        log_info "Bind-mount backup OK: $name -> $dest ($(human_size "$dest"))"
    done
    return $rc
}

# Authentik's data dir mixes plain files (media/templates/certs, safe to
# tar directly) with a live Postgres data directory (postgres/, NOT safe —
# see docs "Why not just tar Postgres's data dir"). Rather than trust an
# --exclude flag in whatever tar implementation HELPER_IMAGE happens to
# ship, only media/templates/certs are ever bind-mounted into the helper
# container in the first place — postgres/ never enters its mount
# namespace, so there's nothing to accidentally include.
backup_authentik_app() {
    local dest="${RUN_DIR}/binds/authentik-app-${RUN_DATE}.tar.gz"
    local dest_dir; dest_dir="$(dirname "$dest")"
    if ! docker run --rm --pull=never --network=none \
            -v "${AUTHENTIK_APP_DATA_DIR}/media:/source/media:ro" \
            -v "${AUTHENTIK_APP_DATA_DIR}/templates:/source/templates:ro" \
            -v "${AUTHENTIK_APP_DATA_DIR}/certs:/source/certs:ro" \
            -v "${dest_dir}:/backup" \
            "$HELPER_IMAGE" \
            tar czf "/backup/$(basename "$dest")" -C /source . \
            1>>"${LOG_FILE}" 2>&1; then
        log_error "backup_authentik_app: tar failed"
        return 1
    fi
    verify_archive "$dest" || return 1
    log_info "Authentik app-data backup OK (media/templates/certs; postgres/ handled separately via pg_dump): $dest ($(human_size "$dest"))"
}

backup_uptime_kuma() {
    local rc=0
    local tmp_in_container="/app/data/.backup-${RUN_DATE}.db"
    local tmp_local="${RUN_DIR}/binds/.uptime-kuma-${RUN_DATE}.db"
    local db_dest="${RUN_DIR}/binds/uptime-kuma-db-${RUN_DATE}.sqlite.gz"

    local container; container="$(resolve_container "$UPTIME_KUMA_CONTAINER")"
    if [[ -z "$container" ]]; then
        log_error "backup_uptime_kuma: no running container for service $UPTIME_KUMA_CONTAINER"
        return 1
    fi

    if docker exec "$container" sqlite3 /app/data/kuma.db ".backup '${tmp_in_container}'" \
            1>>"${LOG_FILE}" 2>&1; then
        if docker cp "${container}:${tmp_in_container}" "$tmp_local" 1>>"${LOG_FILE}" 2>&1; then
            gzip -"$GZIP_LEVEL" -c "$tmp_local" > "$db_dest"
            rm -f "$tmp_local"
        else
            log_error "backup_uptime_kuma: docker cp of sqlite backup out of the container failed"
            rc=1
        fi
        docker exec "$container" rm -f "$tmp_in_container" 1>>"${LOG_FILE}" 2>&1 \
            || log_warn "backup_uptime_kuma: could not remove temp backup file inside the container (harmless, but check disk usage there)"
    else
        log_error "backup_uptime_kuma: 'sqlite3 .backup' failed inside the container"
        rc=1
    fi
    if [[ $rc -eq 0 ]]; then
        verify_archive "$db_dest" || rc=1
    fi

    local data_dest="${RUN_DIR}/binds/uptime-kuma-data-${RUN_DATE}.tar.gz"
    if ! tar_via_helper "${HOMELAB_ROOT}/data/uptime-kuma:/source:ro" "$data_dest" \
            --exclude='./kuma.db' --exclude='./kuma.db-shm' --exclude='./kuma.db-wal'; then
        log_error "backup_uptime_kuma: data tar failed"
        rc=1
    else
        verify_archive "$data_dest" || rc=1
    fi

    [[ $rc -eq 0 ]] && log_info "Uptime Kuma backup OK: $db_dest (consistent SQLite snapshot) + $data_dest (uploads/screenshots)"
    return $rc
}

backup_loki_incremental() {
    mkdir -p "$STATE_DIR"
    local snapshot_file="${STATE_DIR}/loki.snar"
    local mode="incr"
    if [[ "$(date +%a)" == "$LOKI_FULL_DAY" || ! -f "$snapshot_file" || "$FORCE_FULL" == "1" ]]; then
        mode="full"
        rm -f "$snapshot_file"
    fi
    local dest="${RUN_DIR}/binds/loki-${RUN_DATE}-${mode}.tar.gz"

    local tar_rc=0
    tar --listed-incremental="$snapshot_file" -czf "$dest" \
        -C "$(dirname "$LOKI_DATA_DIR")" "$(basename "$LOKI_DATA_DIR")" \
        1>>"${LOG_FILE}" 2>&1 || tar_rc=$?

    if (( tar_rc >= 2 )); then
        log_error "backup_loki_incremental: tar failed with a fatal error (exit $tar_rc, mode=$mode)"
        rm -f "$dest"
        return 1
    elif (( tar_rc == 1 )); then
        log_warn "backup_loki_incremental: tar reported files changed while being read (exit 1, mode=$mode) — expected for Loki's active WAL, archive is still used"
    fi
    verify_archive "$dest" || return 1
    log_info "Loki backup OK (mode=$mode): $dest ($(human_size "$dest"))"
}

backup_config() {
    local rc=0

    local dest1="${RUN_DIR}/config/homelab-config-${RUN_DATE}.tar.gz"
    local rel=()
    local p
    for p in "${CONFIG_PATHS_HOMELAB[@]}"; do
        [[ -e "$p" ]] && rel+=("${p#"${HOMELAB_ROOT}"/}")
    done
    if [[ ${#rel[@]} -gt 0 ]] && tar czf "$dest1" -C "$HOMELAB_ROOT" "${rel[@]}" 1>>"${LOG_FILE}" 2>&1; then
        verify_archive "$dest1" || rc=1
        log_info "Homelab config backup OK: $dest1 ($(human_size "$dest1"))"
    else
        log_error "backup_config: homelab compose/docs/certs tar failed"
        rc=1
    fi

    return $rc
}

# ---------------------------------------------------------------------------
# Retention
# ---------------------------------------------------------------------------

# Delete non-Loki content from run directories older than RETENTION_DAYS.
# Loki archives are deliberately left alone here — see prune_loki_cycles.
prune_old_runs() {
    [[ -d "$RUNS_DIR" ]] || return 0
    local now_epoch cutoff_epoch run_dir dir_date dir_epoch
    now_epoch=$(date +%s)
    cutoff_epoch=$(( now_epoch - RETENTION_DAYS * 86400 ))
    for run_dir in "$RUNS_DIR"/*/; do
        [[ -d "$run_dir" ]] || continue
        dir_date="$(basename "$run_dir")"
        [[ "$dir_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
        dir_epoch=$(date -d "$dir_date" +%s 2>/dev/null) || continue
        if (( dir_epoch < cutoff_epoch )); then
            log_info "Retention: pruning non-Loki content from $run_dir (older than ${RETENTION_DAYS}d)"
            find "$run_dir" -type f -not -name 'loki-*.tar.gz' -delete 2>>"${LOG_FILE}" || true
            find "$run_dir" -mindepth 1 -type d -empty -delete 2>>"${LOG_FILE}" || true
            rmdir "$run_dir" 2>/dev/null || true
        fi
    done
}

# Keep the last RETENTION_CYCLES Loki full-backup cycles (a cycle = one
# full archive plus the incrementals that depend on it); delete older
# cycles entirely. Never deletes a full archive while a kept incremental
# still needs it, regardless of how old the containing run directory is.
prune_loki_cycles() {
    local fulls=()
    while IFS= read -r -d '' f; do fulls+=("$f"); done < \
        <(find "$RUNS_DIR" -type f -name 'loki-*-full.tar.gz' -print0 2>/dev/null | sort -z)
    local count=${#fulls[@]}
    if (( count <= RETENTION_CYCLES )); then
        log_info "Retention (Loki): $count full cycle(s) on disk, within RETENTION_CYCLES=$RETENTION_CYCLES, keeping all"
        return 0
    fi
    local keep_from=$(( count - RETENTION_CYCLES ))
    local i
    for (( i=0; i<keep_from; i++ )); do
        local full_date next_date
        full_date="$(basename "${fulls[$i]}" | sed -E 's/^loki-([0-9-]+)-full\.tar\.gz$/\1/')"
        if (( i+1 < count )); then
            next_date="$(basename "${fulls[$((i+1))]}" | sed -E 's/^loki-([0-9-]+)-full\.tar\.gz$/\1/')"
        else
            next_date="9999-99-99"
        fi
        log_info "Retention (Loki): pruning cycle [$full_date, $next_date) — superseded, beyond RETENTION_CYCLES=$RETENTION_CYCLES"
        find "$RUNS_DIR" -type f \( -name "loki-${full_date}-full.tar.gz" -o -name 'loki-*-incr.tar.gz' \) -print0 2>/dev/null \
            | while IFS= read -r -d '' f; do
                local d
                d="$(basename "$f" | sed -E 's/^loki-([0-9-]+)-(full|incr)\.tar\.gz$/\1/')"
                if [[ "$d" > "$full_date" || "$d" == "$full_date" ]] && [[ "$d" < "$next_date" ]]; then
                    log_info "Retention (Loki): removing $f"
                    rm -f "$f"
                fi
            done
    done
    # Clean up any run directories left empty by the loop above.
    find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Run everything
# ---------------------------------------------------------------------------

ALL_STEPS=(
    "postgres:backup_postgres"
    "grafana:backup_grafana_volume"
    "prometheus:backup_prometheus_volume"
    "binds:backup_bind_mounts_full"
    "authentik-app:backup_authentik_app"
    "uptime-kuma:backup_uptime_kuma"
    "loki:backup_loki_incremental"
    "config:backup_config"
)

declare -a FAILED_STEPS=()
declare -a RAN_STEPS=()

run_step() {
    local name="$1" fn="$2"
    local t0 t1
    t0=$(date +%s)
    log_info "--- step: $name ---"
    if "$fn"; then
        t1=$(date +%s)
        log_info "--- step OK: $name ($((t1 - t0))s) ---"
        RAN_STEPS+=("$name:OK")
    else
        t1=$(date +%s)
        log_error "--- step FAILED: $name ($((t1 - t0))s) ---"
        RAN_STEPS+=("$name:FAILED")
        FAILED_STEPS+=("$name")
    fi
}

for step in "${ALL_STEPS[@]}"; do
    step_name="${step%%:*}"
    step_fn="${step#*:}"
    if [[ -n "$ONLY_STEPS" ]] && [[ ",${ONLY_STEPS}," != *",${step_name},"* ]]; then
        continue
    fi
    run_step "$step_name" "$step_fn"
done

prune_loki_cycles
prune_old_runs

# ---------------------------------------------------------------------------
# Manifest + summary
# ---------------------------------------------------------------------------

RUN_END_EPOCH=$(date +%s)
{
    echo "homelab backup manifest"
    echo "run date:    $RUN_DATE"
    echo "started:     $(date -d "@${RUN_START_EPOCH}" '+%F %T')"
    echo "finished:    $(date -d "@${RUN_END_EPOCH}" '+%F %T')"
    echo "duration:    $(( RUN_END_EPOCH - RUN_START_EPOCH ))s"
    echo "host:        $(hostname)"
    echo "config:      $CONFIG_FILE"
    echo "steps:"
    for s in "${RAN_STEPS[@]}"; do
        echo "  - ${s%%:*}: ${s#*:}"
    done
    echo "result:      $([[ ${#FAILED_STEPS[@]} -eq 0 ]] && echo SUCCESS || echo "PARTIAL FAILURE (${#FAILED_STEPS[@]} step(s))")"
} > "${RUN_DIR}/manifest.txt"
write_checksums "$RUN_DIR"   # covers every archive plus manifest.txt itself

log_info "Manifest: ${RUN_DIR}/manifest.txt"
log_info "Run directory size: $(human_size "$RUN_DIR")"

if [[ ${#FAILED_STEPS[@]} -gt 0 ]]; then
    log_error "=== homelab backup FINISHED WITH FAILURES: ${FAILED_STEPS[*]} ==="
    exit "$EXIT_GENERAL_ERROR"
fi

log_info "=== homelab backup completed successfully ==="
exit "$EXIT_OK"
