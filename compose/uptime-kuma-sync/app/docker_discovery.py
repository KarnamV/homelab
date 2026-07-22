import socket
from dataclasses import dataclass
from typing import List, Optional
from urllib.parse import urlsplit

import docker
from docker.models.containers import Container


@dataclass(frozen=True)
class MonitorSpec:
    container_id: str
    container_name: str
    name: str
    type: str  # "http" | "keyword" | "port" | "ping"
    url: Optional[str]
    hostname: Optional[str]
    port: Optional[int]
    keyword: Optional[str]
    group: Optional[str]
    interval: int


class LabelConfigError(ValueError):
    pass


def _parse_host_port(raw: str) -> tuple:
    value = raw.strip()
    if "://" not in value:
        value = f"//{value}"
    split = urlsplit(value)
    if not split.hostname:
        raise LabelConfigError(f"could not parse hostname from uptime.url={raw!r}")
    return split.hostname, split.port


def _normalize_type(raw_type: str, has_keyword: bool) -> str:
    raw_type = raw_type.strip().lower()
    if raw_type in ("", "http", "https"):
        return "keyword" if has_keyword else "http"
    if raw_type in ("tcp", "port"):
        return "port"
    if raw_type in ("ping", "icmp"):
        return "ping"
    raise LabelConfigError(f"unsupported uptime.type={raw_type!r} (expected http, tcp, or ping)")


def build_spec(container: Container, default_interval: int) -> MonitorSpec:
    labels = container.labels
    url = (labels.get("uptime.url") or "").strip() or None
    keyword = (labels.get("uptime.keyword") or "").strip() or None
    group = (labels.get("uptime.group") or "").strip() or None
    name = (labels.get("uptime.name") or "").strip() or container.name
    monitor_type = _normalize_type(labels.get("uptime.type", ""), keyword is not None)

    raw_interval = labels.get("uptime.interval")
    if raw_interval:
        try:
            interval = int(raw_interval)
        except ValueError:
            raise LabelConfigError(f"uptime.interval must be an integer, got {raw_interval!r}")
    else:
        interval = default_interval

    hostname = None
    port = None

    if monitor_type in ("http", "keyword"):
        if not url:
            raise LabelConfigError("uptime.url is required when uptime.type is http (or unset)")
        if monitor_type == "keyword" and not keyword:
            raise LabelConfigError("uptime.keyword is required when uptime.type=keyword")
    else:
        if not url:
            raise LabelConfigError(f"uptime.url is required to derive host/port for uptime.type={monitor_type}")
        hostname, port = _parse_host_port(url)
        if monitor_type == "port" and port is None:
            raise LabelConfigError(f"uptime.url must include a port for uptime.type=tcp, got {url!r}")

    return MonitorSpec(
        container_id=container.id,
        container_name=container.name,
        name=name,
        type=monitor_type,
        url=url if monitor_type in ("http", "keyword") else None,
        hostname=hostname,
        port=port,
        keyword=keyword,
        group=group,
        interval=interval,
    )


def get_self_container_id(client: docker.DockerClient) -> Optional[str]:
    """Docker sets a container's hostname to its short ID unless overridden;
    our compose file intentionally leaves `hostname:` unset to rely on this."""
    try:
        return client.containers.get(socket.gethostname()).id
    except docker.errors.NotFound:
        return None


def discover_containers(client: docker.DockerClient, self_id: Optional[str]) -> List[Container]:
    containers = client.containers.list(filters={"status": "running"})
    result = []
    for container in containers:
        if self_id and container.id == self_id:
            continue
        if (container.labels.get("uptime.enable") or "").strip().lower() != "true":
            continue
        result.append(container)
    return result
