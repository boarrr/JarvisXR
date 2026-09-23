from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

DEFAULT_CHUNK_BYTES = 192 * 1024


class UpdateError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(slots=True)
class UpdatePackage:
    version: str
    sha256: str
    size_bytes: int
    built_at: str
    apk_path: Path


class UpdateService:
    """Serves the most recently published Quest APK for in-app self-update.

    The manifest is written by ``scripts/quest.sh manifest``; the APK is read in
    bounded chunks so the client can pull it over the authenticated websocket.
    """

    def __init__(self, manifest_path: Path, chunk_bytes: int = DEFAULT_CHUNK_BYTES) -> None:
        self.manifest_path = manifest_path
        self.chunk_bytes = chunk_bytes

    def current(self) -> UpdatePackage | None:
        if not self.manifest_path.exists():
            return None
        try:
            manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        if not isinstance(manifest, dict):
            return None
        apk_name = str(manifest.get("apk", ""))
        if not apk_name:
            return None
        apk_path = (self.manifest_path.parent / "updates" / apk_name).resolve()
        if not apk_path.exists() or not apk_path.is_file():
            return None
        return UpdatePackage(
            version=str(manifest.get("version", "")),
            sha256=str(manifest.get("sha256", "")),
            size_bytes=int(manifest.get("size_bytes", apk_path.stat().st_size)),
            built_at=str(manifest.get("built_at", "")),
            apk_path=apk_path,
        )

    def manifest_payload(self) -> dict:
        package = self.current()
        if package is None:
            return {}
        return {
            "version": package.version,
            "sha256": package.sha256,
            "size_bytes": package.size_bytes,
            "built_at": package.built_at,
            "chunk_bytes": self.chunk_bytes,
        }

    def read_chunk(self, offset: int, length: int) -> tuple[bytes, bool]:
        package = self.current()
        if package is None:
            raise UpdateError("no_update", "No update package is published")
        if offset < 0 or length <= 0:
            raise UpdateError("bad_range", "offset and length must be positive")
        length = min(length, self.chunk_bytes)
        with package.apk_path.open("rb") as handle:
            handle.seek(offset)
            data = handle.read(length)
        eof = offset + len(data) >= package.size_bytes
        return data, eof
