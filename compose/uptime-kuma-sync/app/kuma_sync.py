import hashlib
import json
import logging
from typing import Dict, List, Optional

from uptime_kuma_api import UptimeKumaApi, MonitorType

from app.docker_discovery import MonitorSpec
from app.logging_setup import log
from app.state import SyncState

_TYPE_MAP = {
    "http": MonitorType.HTTP,
    "keyword": MonitorType.KEYWORD,
    "port": MonitorType.PORT,
    "ping": MonitorType.PING,
}


def _spec_fields(spec: MonitorSpec, parent_id: Optional[int]) -> dict:
    fields = {
        "type": _TYPE_MAP[spec.type],
        "name": spec.name,
        "interval": spec.interval,
        "parent": parent_id,
    }
    if spec.type in ("http", "keyword"):
        fields["url"] = spec.url
    if spec.type == "keyword":
        fields["keyword"] = spec.keyword
    if spec.type in ("port", "ping"):
        fields["hostname"] = spec.hostname
    if spec.type == "port":
        fields["port"] = spec.port
    return fields


def _spec_hash(spec: MonitorSpec, parent_id: Optional[int]) -> str:
    fields = _spec_fields(spec, parent_id)
    fields["type"] = fields["type"].value
    return hashlib.sha256(json.dumps(fields, sort_keys=True).encode()).hexdigest()


class KumaSync:
    def __init__(self, url: str, username: str, password: str, state: SyncState, logger: logging.Logger):
        self.url = url
        self.username = username
        self.password = password
        self.state = state
        self.logger = logger
        self.api: Optional[UptimeKumaApi] = None
        self._monitors_by_id: Dict[int, dict] = {}

    def __enter__(self) -> "KumaSync":
        self.api = UptimeKumaApi(self.url)
        self.api.login(self.username, self.password)
        self._refresh_monitors()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if self.api is not None:
            self.api.disconnect()

    def _refresh_monitors(self) -> None:
        self._monitors_by_id = {m["id"]: m for m in self.api.get_monitors()}

    def ensure_group(self, name: str) -> int:
        existing_id = self.state.groups.get(name)
        if existing_id is not None:
            monitor = self._monitors_by_id.get(existing_id)
            if monitor and monitor.get("type") == MonitorType.GROUP.value:
                return existing_id

        for monitor in self._monitors_by_id.values():
            if monitor.get("type") == MonitorType.GROUP.value and monitor.get("name") == name:
                self.state.groups[name] = monitor["id"]
                return monitor["id"]

        result = self.api.add_monitor(type=MonitorType.GROUP, name=name)
        group_id = result["monitorID"]
        self.state.groups[name] = group_id
        self._refresh_monitors()
        log(self.logger, logging.INFO, "group_created", group=name, monitor_id=group_id)
        return group_id

    def upsert_monitor(self, spec: MonitorSpec) -> None:
        parent_id = self.ensure_group(spec.group) if spec.group else None
        desired_hash = _spec_hash(spec, parent_id)
        record = self.state.monitors.get(spec.container_id)

        if record and record["monitor_id"] in self._monitors_by_id:
            if record.get("hash") == desired_hash:
                log(self.logger, logging.DEBUG, "monitor_unchanged",
                    container=spec.container_name, name=spec.name, monitor_id=record["monitor_id"])
                return
            monitor_id = record["monitor_id"]
            self.api.edit_monitor(monitor_id, **_spec_fields(spec, parent_id))
            self.state.monitors[spec.container_id] = {
                "monitor_id": monitor_id, "hash": desired_hash, "name": spec.name,
            }
            log(self.logger, logging.INFO, "monitor_updated",
                container=spec.container_name, name=spec.name, monitor_id=monitor_id)
            self._refresh_monitors()
            return

        result = self.api.add_monitor(**_spec_fields(spec, parent_id))
        monitor_id = result["monitorID"]
        self.state.monitors[spec.container_id] = {
            "monitor_id": monitor_id, "hash": desired_hash, "name": spec.name,
        }
        log(self.logger, logging.INFO, "monitor_created",
            container=spec.container_name, name=spec.name, monitor_id=monitor_id, type=spec.type)
        self._refresh_monitors()

    def prune(self, desired_container_ids: List[str], prune_orphaned: bool) -> None:
        stale_ids = [cid for cid in self.state.monitors if cid not in desired_container_ids]
        for container_id in stale_ids:
            record = self.state.monitors[container_id]
            monitor_id = record["monitor_id"]
            if not prune_orphaned:
                log(self.logger, logging.INFO, "monitor_orphaned_kept",
                    name=record.get("name"), monitor_id=monitor_id)
                continue
            if monitor_id in self._monitors_by_id:
                self.api.delete_monitor(monitor_id)
                log(self.logger, logging.INFO, "monitor_deleted",
                    name=record.get("name"), monitor_id=monitor_id)
            del self.state.monitors[container_id]
