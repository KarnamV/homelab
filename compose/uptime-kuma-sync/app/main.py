import logging
import signal
import threading
import time

import docker

from app.config import Config
from app.docker_discovery import LabelConfigError, build_spec, discover_containers, get_self_container_id
from app.kuma_sync import KumaSync
from app.logging_setup import log, setup_logging
from app.state import SyncState

shutdown_event = threading.Event()


def _handle_signal(signum, frame) -> None:
    shutdown_event.set()


def run_sync(config: Config, logger: logging.Logger) -> None:
    docker_client = docker.from_env()
    self_id = get_self_container_id(docker_client)

    containers = discover_containers(docker_client, self_id)

    specs = []
    for container in containers:
        try:
            specs.append(build_spec(container, config.default_interval))
        except LabelConfigError as exc:
            log(logger, logging.ERROR, "invalid_labels", container=container.name, error=str(exc))

    state = SyncState(config.state_path)

    try:
        with KumaSync(config.uptime_url, config.uptime_username, config.uptime_password, state, logger) as kuma:
            for spec in specs:
                try:
                    kuma.upsert_monitor(spec)
                except Exception as exc:
                    log(logger, logging.ERROR, "monitor_sync_failed",
                        container=spec.container_name, name=spec.name, error=str(exc))

            desired_ids = [spec.container_id for spec in specs]
            kuma.prune(desired_ids, config.prune_orphaned)
    finally:
        state.save()

    log(logger, logging.INFO, "sync_complete", monitors=len(specs))


def main() -> None:
    config = Config.from_env()
    logger = setup_logging(config.log_level)

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    log(logger, logging.INFO, "sync_service_starting", interval_seconds=config.sync_interval)

    while not shutdown_event.is_set():
        try:
            run_sync(config, logger)
        except Exception as exc:
            log(logger, logging.ERROR, "sync_run_failed", error=str(exc))
        shutdown_event.wait(config.sync_interval)

    log(logger, logging.INFO, "sync_service_stopped")


if __name__ == "__main__":
    main()
