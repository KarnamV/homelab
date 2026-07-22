import json
import logging
import sys
import time


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)),
            "level": record.levelname,
            "event": record.getMessage(),
            "logger": record.name,
        }
        extra = getattr(record, "fields", None)
        if extra:
            payload.update(extra)
        if record.exc_info:
            payload["exc_info"] = self.formatException(record.exc_info)
        return json.dumps(payload)


def setup_logging(level: str = "INFO") -> logging.Logger:
    logger = logging.getLogger("uptime-kuma-sync")
    logger.setLevel(level)
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    logger.handlers = [handler]
    logger.propagate = False
    return logger


def log(logger: logging.Logger, level: int, event: str, **fields) -> None:
    logger.log(level, event, extra={"fields": fields})
