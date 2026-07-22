import json
import os
import tempfile
from typing import Any, Dict


class SyncState:
    """Persists container_id -> monitor_id/hash mappings so re-runs stay idempotent
    even if a container's uptime.* labels (and therefore its monitor name) change."""

    def __init__(self, path: str):
        self.path = path
        self.monitors: Dict[str, Dict[str, Any]] = {}
        self.groups: Dict[str, int] = {}
        self._load()

    def _load(self) -> None:
        if not os.path.exists(self.path):
            return
        with open(self.path, "r") as f:
            data = json.load(f)
        self.monitors = data.get("monitors", {})
        self.groups = data.get("groups", {})

    def save(self) -> None:
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        payload = {"monitors": self.monitors, "groups": self.groups}
        fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(self.path))
        try:
            os.fchmod(fd, 0o644)
            with os.fdopen(fd, "w") as f:
                json.dump(payload, f, indent=2, sort_keys=True)
            os.replace(tmp_path, self.path)
        finally:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)
