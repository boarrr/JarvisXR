#!/usr/bin/env python3
"""One-connection protocol fixture for the Godot WebSocket smoke test."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import socket
import struct
import time


WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def receive_exact(connection: socket.socket, size: int) -> bytes:
    chunks: list[bytes] = []
    remaining = size
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise ConnectionError("client disconnected")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def receive_http_headers(connection: socket.socket) -> dict[str, str]:
    request = bytearray()
    while b"\r\n\r\n" not in request:
        request.extend(connection.recv(4096))
        if len(request) > 65536:
            raise ValueError("upgrade request is too large")
    lines = request.decode("ascii").split("\r\n")
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if ":" not in line:
            continue
        name, value = line.split(":", 1)
        headers[name.strip().lower()] = value.strip()
    return headers


def accept_websocket(connection: socket.socket) -> None:
    headers = receive_http_headers(connection)
    client_key = headers.get("sec-websocket-key", "")
    if not client_key:
        raise ValueError("missing Sec-WebSocket-Key")
    digest = hashlib.sha1((client_key + WEBSOCKET_GUID).encode("ascii")).digest()
    accept_key = base64.b64encode(digest).decode("ascii")
    response = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept_key}\r\n"
        "\r\n"
    )
    connection.sendall(response.encode("ascii"))


def receive_text_frame(connection: socket.socket) -> dict[str, object]:
    first, second = receive_exact(connection, 2)
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", receive_exact(connection, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", receive_exact(connection, 8))[0]
    if opcode != 1 or not masked:
        raise ValueError("expected a masked UTF-8 text frame")
    mask = receive_exact(connection, 4)
    payload = receive_exact(connection, length)
    decoded = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    parsed = json.loads(decoded.decode("utf-8"))
    if not isinstance(parsed, dict):
        raise ValueError("expected a JSON object")
    return parsed


def send_text_frame(connection: socket.socket, payload: dict[str, object]) -> None:
    encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    if len(encoded) < 126:
        header = bytes((0x81, len(encoded)))
    elif len(encoded) <= 65535:
        header = bytes((0x81, 126)) + struct.pack("!H", len(encoded))
    else:
        header = bytes((0x81, 127)) + struct.pack("!Q", len(encoded))
    connection.sendall(header + encoded)


def envelope(event_type: str, event_id: str, session_id: str, payload: dict[str, object]) -> dict[str, object]:
    return {
        "v": 1,
        "type": event_type,
        "event_id": event_id,
        "session_id": session_id,
        "thread_id": "",
        "timestamp": "2026-09-14T12:00:00Z",
        "payload": payload,
    }


def serve(port: int, connection_count: int = 1, ready_file: Path | None = None) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", port))
        listener.listen(connection_count)
        if ready_file is not None:
            ready_file.write_text("ready\n", encoding="utf-8")
        for connection_index in range(connection_count):
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(5.0)
                accept_websocket(connection)
                hello = receive_text_frame(connection)
                if hello.get("v") not in (1, 2) or hello.get("type") != "session.hello":
                    raise ValueError("client did not send a protocol v1/v2 session.hello")
                session_id = (
                    "sess_loopback"
                    if connection_count == 1
                    else f"sess_loopback_{connection_index + 1}"
                )
                send_text_frame(
                    connection,
                    envelope(
                        "session.ready",
                        f"evt_loopback_{connection_index + 1:03d}_ready",
                        session_id,
                        {"server": "fixture", "protocol_version": 2},
                    ),
                )
                connection.settimeout(0.5)
                while True:
                    try:
                        message = receive_text_frame(connection)
                    except (TimeoutError, ConnectionError, ValueError, OSError):
                        break
                    if message.get("session_id") != session_id:
                        continue
                    message_type = message.get("type")
                    if message_type == "thread.list":
                        send_text_frame(
                            connection,
                            envelope(
                                "thread.snapshot",
                                f"evt_loopback_{connection_index + 1:03d}_snapshot",
                                session_id,
                                {"threads": []},
                            ),
                        )
                    elif message_type == "workspace.list":
                        send_text_frame(
                            connection,
                            envelope(
                                "workspace.snapshot",
                                f"evt_loopback_{connection_index + 1:03d}_workspaces",
                                session_id,
                                {"workspaces": []},
                            ),
                        )
                    elif message_type == "tool.catalog":
                        send_text_frame(
                            connection,
                            envelope(
                                "tool.catalog",
                                f"evt_loopback_{connection_index + 1:03d}_tools",
                                session_id,
                                {"tools": [], "mcp_servers": []},
                            ),
                        )
                time.sleep(0.05)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18787)
    parser.add_argument("--connections", type=int, default=1)
    parser.add_argument("--ready-file", type=Path)
    args = parser.parse_args()
    serve(args.port, args.connections, args.ready_file)


if __name__ == "__main__":
    main()
