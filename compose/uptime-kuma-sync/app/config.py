import os
from dataclasses import dataclass


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _require(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


@dataclass(frozen=True)
class Config:
    uptime_url: str
    uptime_username: str
    uptime_password: str
    sync_interval: int
    prune_orphaned: bool
    default_interval: int
    log_level: str
    state_path: str

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            uptime_url=_require("UPTIME_URL"),
            uptime_username=_require("UPTIME_USERNAME"),
            uptime_password=_require("UPTIME_PASSWORD"),
            sync_interval=int(os.environ.get("SYNC_INTERVAL", "300")),
            prune_orphaned=_env_bool("UPTIME_PRUNE_ORPHANED", True),
            default_interval=int(os.environ.get("UPTIME_DEFAULT_INTERVAL", "60")),
            log_level=os.environ.get("LOG_LEVEL", "INFO"),
            state_path=os.environ.get("STATE_PATH", "/app/state/state.json"),
        )
