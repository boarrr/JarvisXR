from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

DEFAULT_CHUNK_BYTES = 32 * 1024


class UpdateError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def parse_byte_range(header: str | None, size: int) -> tuple[int, int] | None:
    """Parse a single HTTP Range header for ``size`` bytes.

    Returns an inclusive ``(start, end)`` tuple, ``None`` when no range is
    requested, or raises :class:`UpdateError` with ``range_not_satisfiable``
    when the range falls outside the resource.
    """
    if not header:
        return None
    header = header.strip()
    if not header.startswith("bytes="):
        raise UpdateError("bad_range", "Only byte ranges are supported")
    spec = header[len("bytes=") :].split(",", 1)[0].strip()
    first, _, last = spec.partition("-")
    first, last = first.strip(), last.strip()
    try:
        if first == "":
            if last == "":
                raise UpdateError("bad_range", "Malformed range")
            count = int(last)
            if count <= 0:
                raise UpdateError("bad_range", "Malformed range")
            start, end = max(0, size - count), size - 1
        else:
            start = int(first)
            end = int(last) if last else size - 1
            if end >= size:
                end = size - 1
    except ValueError as error:
        raise UpdateError("bad_range", "Malformed range") from error
    if size <= 0 or start >= size or start > end:
        raise UpdateError("range_not_satisfiable", "Range not satisfiable")
    return (start, end)


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
            # HTTP(S) path on the daemon's own port (served via process_request).
            "path": f"/update/{package.sha256}.apk",
        }

    def read_range(self, start: int, end: int) -> bytes:
        """Return the inclusive byte range [start, end] of the current APK."""
        package = self.current()
        if package is None:
            raise UpdateError("no_update", "No update package is published")
        if start < 0 or end < start:
            raise UpdateError("bad_range", "Invalid byte range")
        with package.apk_path.open("rb") as handle:
            handle.seek(start)
            return handle.read(end - start + 1)

    def read_chunk(self, offset: int, length: int) -> tuple[bytes, bool]:
        # Legacy websocket chunk path (kept one release for backward compatibility).
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
