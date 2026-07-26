#!/usr/bin/env bash
#
# homelab/scripts/restore.sh — restore from a backup made by backup.sh.
#
# Unlike backup.sh, this SCRIPT WILL STOP CONTAINERS: safely overwriting a
# service's live data files while it's running isn't generally possible, so
# each restore step stops only the container(s) that own the data being
# restored, does the restore, then starts them again. A restore is an
# inherently disruptive, deliberate action — that's expected and different
# from backup.sh's "never interrupt anything" contract.
#
# Usage:
#   restore.sh --list
#   restore.sh -c CONFIG --run-date YYYY-MM-DD [--only NAME[,NAME...]]
#              [--verify-only] [--yes] [--drop-existing-db]
#              [--force-unverified] [-h]
#
#   --list              List available backup run dates and exit.
#   --run-date DATE     Which backup to restore from (see --list).
#   --only NAMES        Comma-separated: postgres,grafana,prometheus,
#                       homepage,portainer,promtail,uptime-kuma-sync,
#                       authentik-app,uptime-kuma,loki,config
#   --verify-only       Verify checksums + archive integrity for the given
#                       run date and exit. Does not stop/start/write
#                       anything — safe to run at any time.
#   --yes               Skip the interactive confirmation prompt (for
#                       scripted/automated use — think carefully before
#                       doing that for something this destructive).
#   --drop-existing-db  Postgres only: DROP + recreate the database before
#                       loading the dump (stops authentik-server/-worker
#                       first). Without this, the dump is loaded into
#                       whatever's already there and will likely fail with
#                       "already exists" errors if it's not empty.
#   --force-unverified  Proceed even if SHA256SUMS verification fails.
#                       Logs loudly. Use only if you've independently
#                       confirmed the specific archive you need is fine.
#
# Exit codes: see scripts/lib/backup-common.sh (EXIT_* constants) and
# docs/backup-restore.md "Exit codes".

set -uo pipefail   # see backup.sh for why not `-e` — same reasoning applies

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/backup.conf"

# shellcheck source=lib/backup-common.sh
. "${SCRIPT_DIR}/lib/backup-common.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

CONFIG_FILE="$DEFAULT_CONFIG"
RUN_DATE=""
ONLY=""
VERIFY_ONLY=0
ASSUME_YES=0
DROP_EXISTING_DB=0
FORCE_UNVERIFIED=0
LIST_ONLY=0

print_help() {
    cat <<'EOF'
Usage: restore.sh --list
       restore.sh [-c CONFIG] --run-date YYYY-MM-DD [--only NAMES]
                  [--verify-only] [--yes] [--drop-existing-db]
                  [--force-unverified] [-h]

  --list               List available backups and exit
  -c, --config PATH    Use PATH instead of scripts/backup.conf
      --run-date DATE  Which backup to restore (see --list)
      --only NAMES     Comma-separated component list (see docs)
      --verify-only    Verify integrity only, restore nothing
      --yes            Skip the confirmation prompt
      --drop-existing-db  Postgres: drop+recreate DB before loading
      --force-unverified  Proceed despite failed checksum verification
  -h, --help           This message

See docs/backup-restore.md for full restore procedures and caveats.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) LIST_ONLY=1; shift ;;
        -c|--config) CONFIG_FILE="$2"; shift 2 ;;
        --run-date) RUN_DATE="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --verify-only) VERIFY_ONLY=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        --drop-existing-db) DROP_EXISTING_DB=1; shift ;;
        --force-unverified) FORCE_UNVERIFIED=1; shift ;;
        -h|--help) print_help; exit "$EXIT_OK" ;;
        *) echo "Unknown argument: $1" >&2; print_help >&2; exit "$EXIT_BAD_ARGS" ;;
    esac
done

load_config "$CONFIG_FILE"
init_logging "restore"

list_runs() {
    if [[ ! -d "$RUNS_DIR" ]]; then
        log_info "No backups found — $RUNS_DIR does not exist yet"
        return 0
    fi
    local d date result
    local found=0
    for d in "$RUNS_DIR"/*/; do
        [[ -d "$d" ]] || continue
        date="$(basename "$d")"
        [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
        found=1
        result="unknown (no manifest.txt)"
        [[ -f "${d}manifest.txt" ]] && result="$(sed -n 's/^result:[[:space:]]*//p' "${d}manifest.txt")"
        printf '%-12s  %-40s  %s\n' "$date" "$result" "$(human_size "$d")"
    done
    [[ $found -eq 1 ]] || log_info "No dated run directories under $RUNS_DIR"
}

if [[ $LIST_ONLY -eq 1 ]]; then
    list_runs
    exit "$EXIT_OK"
fi

[[ -n "$RUN_DATE" ]] || { echo "--run-date is required (or use --list)" >&2; print_help >&2; exit "$EXIT_BAD_ARGS"; }
[[ "$RUN_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "--run-date must be YYYY-MM-DD" >&2; exit "$EXIT_BAD_ARGS"; }

RUN_DIR="${RUNS_DIR}/${RUN_DATE}"
[[ -d "$RUN_DIR" ]] || die "$EXIT_GENERAL_ERROR" "No backup found for $RUN_DATE (looked in $RUN_DIR — see --list)"

log_info "=== restore starting (run date: $RUN_DATE, config: $CONFIG_FILE) ==="

log_info "Verifying checksums for $RUN_DIR ..."
if verify_checksums "$RUN_DIR"; then
    log_info "Checksums OK"
elif [[ $FORCE_UNVERIFIED -eq 1 ]]; then
    log_warn "Checksum verification FAILED for $RUN_DIR but --force-unverified was given — proceeding anyway"
else
    die "$EXIT_RESTORE_ABORTED" "Checksum verification FAILED for $RUN_DIR — refusing to restore from a backup that may be corrupt. Investigate (see $LOG_FILE), or pass --force-unverified if you've independently confirmed the specific archive you need is fine."
fi

if [[ $VERIFY_ONLY -eq 1 ]]; then
    log_info "--verify-only: checking archive integrity for every file in $RUN_DIR"
    fail=0
    while IFS= read -r -d '' f; do
        verify_archive "$f" || fail=1
    done < <(find "$RUN_DIR" -type f \( -name '*.tar.gz' -o -name '*.gz' \) -print0)
    if [[ $fail -eq 0 ]]; then
        log_info "=== --verify-only: all archives OK ==="
        exit "$EXIT_OK"
    else
        log_error "=== --verify-only: one or more archives FAILED verification ==="
        exit "$EXIT_VERIFY_FAILED"
    fi
fi

# ---------------------------------------------------------------------------
# Confirmation — restoring stops containers and overwrites live data.
# ---------------------------------------------------------------------------

confirm_or_abort() {
    if [[ $ASSUME_YES -eq 1 ]]; then
        log_warn "Skipping confirmation (--yes given)"
        return 0
    fi
    if [[ ! -e /dev/tty ]]; then
        die "$EXIT_RESTORE_ABORTED" "No controlling terminal to confirm on and --yes not given. Refusing to restore non-interactively without explicit consent."
    fi
    echo "About to restore from ${RUN_DIR} (components: ${ONLY:-all}). This will:"
    echo "  - stop each affected container while its data is replaced, then start it again"
    echo "  - PERMANENTLY OVERWRITE current data for those components"
    [[ $DROP_EXISTING_DB -eq 1 ]] && echo "  - DROP AND RECREATE the Authentik Postgres database (--drop-existing-db)"
    local reply
    read -r -p "Type exactly 'restore' to proceed, anything else aborts: " reply < /dev/tty
    [[ "$reply" == "restore" ]] || die "$EXIT_RESTORE_ABORTED" "Restore aborted (confirmation not given)"
}

confirm_or_abort

# ---------------------------------------------------------------------------
# Restore functions
# ---------------------------------------------------------------------------

restore_postgres() {
    local src="${RUN_DIR}/postgres/authentik-${RUN_DATE}.sql.gz"
    [[ -f "$src" ]] || { log_error "restore_postgres: no dump found at $src"; return 1; }
    verify_archive "$src" || return 1

    if ! container_running "$AUTHENTIK_PG_CONTAINER"; then
        log_error "restore_postgres: $AUTHENTIK_PG_CONTAINER is not running — start it first (this loads INTO a running Postgres, it does not start the container)"
        return 1
    fi

    local stopped_deps=() dep
    if [[ $DROP_EXISTING_DB -eq 1 ]]; then
        log_warn "restore_postgres: --drop-existing-db — stopping authentik-server/authentik-worker (they hold connections to the DB being dropped)"
        for dep in authentik_authentik-server authentik_authentik-worker; do
            if container_running "$dep"; then
                service_scale "$dep" 0 && stopped_deps+=("$dep")
            fi
        done
    fi

    local rc=0
    local pg_container; pg_container="$(resolve_container "$AUTHENTIK_PG_CONTAINER")"
    if [[ -z "$pg_container" ]]; then
        log_error "restore_postgres: no running container for service $AUTHENTIK_PG_CONTAINER"
        return 1
    fi
    if [[ $DROP_EXISTING_DB -eq 1 ]]; then
        if ! docker exec -i "$pg_container" psql -v ON_ERROR_STOP=1 -U "$AUTHENTIK_PG_USER" -d postgres \
                -c "DROP DATABASE IF EXISTS \"${AUTHENTIK_PG_DB}\";" \
                -c "CREATE DATABASE \"${AUTHENTIK_PG_DB}\" OWNER \"${AUTHENTIK_PG_USER}\";" \
                1>>"${LOG_FILE}" 2>&1; then
            log_error "restore_postgres: DROP/CREATE DATABASE failed"
            rc=1
        fi
    fi

    if [[ $rc -eq 0 ]] && ! gunzip -c "$src" | docker exec -i "$pg_container" psql -v ON_ERROR_STOP=1 -U "$AUTHENTIK_PG_USER" -d "$AUTHENTIK_PG_DB" \
            1>>"${LOG_FILE}" 2>&1; then
        log_error "restore_postgres: psql load failed (see $LOG_FILE). If the database already had conflicting objects and --drop-existing-db was not given, that's almost certainly why."
        rc=1
    fi

    for dep in "${stopped_deps[@]}"; do
        log_info "restore_postgres: restarting $dep"
        service_scale "$dep" 1 || log_error "restore_postgres: failed to restart $dep — start it manually"
    done

    [[ $rc -eq 0 ]] && log_info "restore_postgres: OK — loaded $src into ${AUTHENTIK_PG_CONTAINER}:${AUTHENTIK_PG_DB}"
    return $rc
}

# restore_into_target OWNER_CONTAINER MOUNT_SPEC ARCHIVE
#   Stops OWNER_CONTAINER (if running), clears the mounted target directory,
#   extracts ARCHIVE into it via HELPER_IMAGE (so root-owned targets like
#   portainer's work without restore.sh itself running as root), restarts
#   OWNER_CONTAINER if it was running. MOUNT_SPEC is a `docker run -v`
#   argument ending in :rw, e.g. "monitoring_grafana-data:/target:rw".
restore_into_target() {
    local owner_container="$1" mount_spec="$2" archive="$3"
    [[ -f "$archive" ]] || { log_error "restore_into_target: archive not found: $archive"; return 1; }
    verify_archive "$archive" || return 1

    local was_running=0
    if container_running "$owner_container"; then
        was_running=1
        log_info "Stopping $owner_container for restore"
        service_scale "$owner_container" 0 || { log_error "restore_into_target: could not stop $owner_container"; return 1; }
    fi

    local archive_dir archive_file rc=0
    archive_dir="$(dirname "$archive")"; archive_file="$(basename "$archive")"
    if ! docker run --rm --pull=never --network=none \
            -v "${mount_spec}" \
            -v "${archive_dir}:/backup:ro" \
            "$HELPER_IMAGE" \
            sh -c "set -e; rm -rf /target/* /target/.[!.]* 2>/dev/null || true; tar xzf /backup/${archive_file} -C /target" \
            1>>"${LOG_FILE}" 2>&1; then
        log_error "restore_into_target: extraction failed for $archive"
        rc=1
    fi

    if [[ $was_running -eq 1 ]]; then
        log_info "Starting $owner_container back up"
        service_scale "$owner_container" 1 || log_error "restore_into_target: failed to restart $owner_container — start it manually"
    fi
    [[ $rc -eq 0 ]] && log_info "restore_into_target: OK ($archive -> $mount_spec)"
    return $rc
}

restore_grafana_volume() {
    restore_into_target monitoring_grafana "${GRAFANA_VOLUME}:/target:rw" "${RUN_DIR}/volumes/grafana-data-${RUN_DATE}.tar.gz"
}

restore_prometheus_volume() {
    restore_into_target monitoring_prometheus "${PROMETHEUS_VOLUME}:/target:rw" "${RUN_DIR}/volumes/prometheus-data-${RUN_DATE}.tar.gz"
}

# restore_bind_mount NAME OWNER_CONTAINER — NAME must match a "name:path"
# entry in BIND_MOUNTS_FULL (backup.conf).
restore_bind_mount() {
    local name="$1" owner_container="$2"
    local entry path=""
    for entry in "${BIND_MOUNTS_FULL[@]}"; do
        [[ "${entry%%:*}" == "$name" ]] && path="${entry#*:}"
    done
    [[ -n "$path" ]] || { log_error "restore_bind_mount: unknown name $name (not in BIND_MOUNTS_FULL)"; return 1; }
    restore_into_target "$owner_container" "${path}:/target:rw" "${RUN_DIR}/binds/${name}-${RUN_DATE}.${ARCHIVE_EXT}"
}

restore_authentik_app() {
    local archive="${RUN_DIR}/binds/authentik-app-${RUN_DATE}.tar.gz"
    [[ -f "$archive" ]] || { log_error "restore_authentik_app: archive not found: $archive"; return 1; }
    verify_archive "$archive" || return 1

    local stopped=() dep
    for dep in authentik_authentik-server authentik_authentik-worker; do
        if container_running "$dep"; then
            service_scale "$dep" 0 && stopped+=("$dep")
        fi
    done

    local rc=0
    if ! docker run --rm --pull=never --network=none \
            -v "${AUTHENTIK_APP_DATA_DIR}/media:/target/media:rw" \
            -v "${AUTHENTIK_APP_DATA_DIR}/templates:/target/templates:rw" \
            -v "${AUTHENTIK_APP_DATA_DIR}/certs:/target/certs:rw" \
            -v "$(dirname "$archive"):/backup:ro" \
            "$HELPER_IMAGE" sh -c "set -e; rm -rf /target/media/* /target/templates/* /target/certs/*; tar xzf /backup/$(basename "$archive") -C /target" \
            1>>"${LOG_FILE}" 2>&1; then
        log_error "restore_authentik_app: extraction failed"
        rc=1
    fi

    for dep in "${stopped[@]}"; do
        service_scale "$dep" 1 || log_error "restore_authentik_app: failed to restart $dep — start it manually"
    done
    [[ $rc -eq 0 ]] && log_info "restore_authentik_app: OK (media/templates/certs restored — this does NOT touch the Postgres data; use --only postgres for that)"
    return $rc
}

restore_uptime_kuma() {
    local data_archive="${RUN_DIR}/binds/uptime-kuma-data-${RUN_DATE}.tar.gz"
    local db_archive="${RUN_DIR}/binds/uptime-kuma-db-${RUN_DATE}.sqlite.gz"
    [[ -f "$data_archive" ]] || { log_error "restore_uptime_kuma: missing $data_archive"; return 1; }
    [[ -f "$db_archive" ]] || { log_error "restore_uptime_kuma: missing $db_archive"; return 1; }
    verify_archive "$data_archive" || return 1
    verify_archive "$db_archive" || return 1

    local was_running=0
    if container_running "$UPTIME_KUMA_CONTAINER"; then
        was_running=1
        service_scale "$UPTIME_KUMA_CONTAINER" 0 || { log_error "restore_uptime_kuma: could not stop container"; return 1; }
    fi

    local rc=0
    if ! docker run --rm --pull=never --network=none \
            -v "${HOMELAB_ROOT}/data/uptime-kuma:/target:rw" \
            -v "${RUN_DIR}/binds:/backup:ro" \
            "$HELPER_IMAGE" sh -c "set -e; rm -rf /target/* /target/.[!.]* 2>/dev/null || true; tar xzf /backup/$(basename "$data_archive") -C /target; gunzip -c /backup/$(basename "$db_archive") > /target/kuma.db" \
            1>>"${LOG_FILE}" 2>&1; then
        log_error "restore_uptime_kuma: restore into target failed"
        rc=1
    fi

    if [[ $was_running -eq 1 ]]; then
        service_scale "$UPTIME_KUMA_CONTAINER" 1 || log_error "restore_uptime_kuma: failed to restart container — start it manually"
    fi
    [[ $rc -eq 0 ]] && log_info "restore_uptime_kuma: OK"
    return $rc
}

# restore_loki — applies the most recent full backup at-or-before RUN_DATE,
# then every incremental after it up to and including RUN_DATE, in order.
# This is GNU tar's documented incremental-restore procedure: extract each
# archive in the chain with --listed-incremental=/dev/null (the archives
# carry their own incremental metadata; /dev/null just means "don't persist
# restore-side state", which extraction doesn't need).
restore_loki() {
    local all_archives=()
    while IFS= read -r -d '' f; do all_archives+=("$f"); done < \
        <(find "$RUNS_DIR" -type f -name 'loki-*.tar.gz' -print0 2>/dev/null | sort -z)

    local full_path="" chain=() f base date_part mode
    for f in "${all_archives[@]}"; do
        base="$(basename "$f")"
        date_part="$(sed -E 's/^loki-([0-9-]+)-(full|incr)\.tar\.gz$/\1/' <<<"$base")"
        mode="$(sed -E 's/^loki-([0-9-]+)-(full|incr)\.tar\.gz$/\2/' <<<"$base")"
        [[ "$date_part" > "$RUN_DATE" ]] && continue
        if [[ "$mode" == "full" ]]; then
            full_path="$f"
            chain=("$f")
        elif [[ -n "$full_path" ]]; then
            chain+=("$f")
        fi
    done

    if [[ -z "$full_path" ]]; then
        log_error "restore_loki: no full baseline found at or before $RUN_DATE"
        return 1
    fi
    log_info "restore_loki: chain for $RUN_DATE (${#chain[@]} archive(s)): $(printf '%s ' "${chain[@]##*/}")"
    for f in "${chain[@]}"; do
        verify_archive "$f" || return 1
    done

    local was_running=0
    if container_running "$LOKI_CONTAINER"; then
        was_running=1
        service_scale "$LOKI_CONTAINER" 0 || { log_error "restore_loki: could not stop loki container"; return 1; }
    fi

    local rc=0
    rm -rf "${LOKI_DATA_DIR:?}"/* "${LOKI_DATA_DIR:?}"/.[!.]* 2>/dev/null || true
    for f in "${chain[@]}"; do
        log_info "restore_loki: applying $(basename "$f")"
        if ! tar --listed-incremental=/dev/null -xzf "$f" -C "$(dirname "$LOKI_DATA_DIR")" 1>>"${LOG_FILE}" 2>&1; then
            log_error "restore_loki: failed applying $(basename "$f")"
            rc=1
            break
        fi
    done

    if [[ $was_running -eq 1 ]]; then
        service_scale "$LOKI_CONTAINER" 1 || log_error "restore_loki: failed to restart loki container — start it manually"
    fi
    [[ $rc -eq 0 ]] && log_info "restore_loki: OK (applied ${#chain[@]} archive(s))"
    return $rc
}

# restore_config — extracts config archives back over their source trees.
# Deliberately does NOT stop any container or run `docker compose up -d`:
# these are just files, and re-applying compose/env changes to running
# services is a separate, deliberate step you should review before doing
# (see docs/backup-restore.md).
restore_config() {
    local rc=0
    local a1="${RUN_DIR}/config/homelab-config-${RUN_DATE}.tar.gz"
    # Older backups (pre Swarm-migration) also have a separate
    # monitoring-config-*.tar.gz — monitoring/ now lives under
    # homelab/compose/ and is covered by $a1, so that second archive no
    # longer exists in new runs and is intentionally not restored here.
    if [[ -f "$a1" ]]; then
        verify_archive "$a1" || return 1
        log_warn "restore_config: extracting $a1 over $HOMELAB_ROOT (compose/docs/certs) — does NOT restart or reconfigure any container"
        tar xzf "$a1" -C "$HOMELAB_ROOT" 1>>"${LOG_FILE}" 2>&1 || { log_error "restore_config: extracting $a1 failed"; rc=1; }
    else
        log_error "restore_config: $a1 not found"; rc=1
    fi
    [[ $rc -eq 0 ]] && log_info "restore_config: OK"
    return $rc
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

COMPONENT_ORDER=(postgres grafana prometheus homepage portainer promtail uptime-kuma-sync authentik-app uptime-kuma loki config)
declare -A COMPONENT_FUNCS=(
    [postgres]="restore_postgres"
    [grafana]="restore_grafana_volume"
    [prometheus]="restore_prometheus_volume"
    [homepage]="restore_bind_mount homepage homepage_homepage"
    [portainer]="restore_bind_mount portainer portainer_portainer"
    [promtail]="restore_bind_mount promtail promtail_promtail"
    [uptime-kuma-sync]="restore_bind_mount uptime-kuma-sync uptime-kuma-sync_uptime-kuma-sync"
    [authentik-app]="restore_authentik_app"
    [uptime-kuma]="restore_uptime_kuma"
    [loki]="restore_loki"
    [config]="restore_config"
)

declare -a RESTORED_OK=()
declare -a RESTORED_FAILED=()

for name in "${COMPONENT_ORDER[@]}"; do
    if [[ -n "$ONLY" ]] && [[ ",${ONLY}," != *",${name},"* ]]; then
        continue
    fi
    spec="${COMPONENT_FUNCS[$name]}"
    log_info "--- restoring: $name ---"
    # shellcheck disable=SC2086
    if $spec; then
        log_info "--- restore OK: $name ---"
        RESTORED_OK+=("$name")
    else
        log_error "--- restore FAILED: $name ---"
        RESTORED_FAILED+=("$name")
    fi
done

log_info "Restored OK: ${RESTORED_OK[*]:-none}"
if [[ ${#RESTORED_FAILED[@]} -gt 0 ]]; then
    log_error "=== restore FINISHED WITH FAILURES: ${RESTORED_FAILED[*]} ==="
    exit "$EXIT_GENERAL_ERROR"
fi

log_info "=== restore completed successfully ==="
exit "$EXIT_OK"
