from __future__ import annotations

import json
import logging
from typing import Any


LOGGER = logging.getLogger("spatial_agent_backend")


def configure_logging() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")


def log_record(record_type: str, **fields: Any) -> None:
    safe_fields = {key: value for key, value in fields.items() if value not in (None, "")}
    LOGGER.info(json.dumps({"record_type": record_type, **safe_fields}, separators=(",", ":")))
