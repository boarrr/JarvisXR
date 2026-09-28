from __future__ import annotations

"""Voice transcription for the Spatial Agent daemon.

The headset streams microphone PCM to the daemon; the daemon writes a WAV and
asks a local ``whisper-server`` (whisper.cpp) to transcribe it. Only the final
text crosses back to the client.
"""

from dataclasses import dataclass
import io
import json
import struct
import urllib.error
import urllib.request
import uuid
import wave

DEFAULT_WHISPER_SERVER_URL = "http://127.0.0.1:8081"
DEFAULT_SAMPLE_RATE = 16000
MAX_UTTERANCE_BYTES = 16 * 1024 * 1024  # ~8 minutes of 16 kHz mono int16


class VoiceError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(slots=True)
class Utterance:
    sample_rate: int = DEFAULT_SAMPLE_RATE
    channels: int = 1
    thread_id: str = ""
    pcm: bytearray = None  # type: ignore[assignment]

    def __post_init__(self) -> None:
        if self.pcm is None:
            self.pcm = bytearray()

    def append(self, chunk: bytes) -> None:
        if len(self.pcm) + len(chunk) > MAX_UTTERANCE_BYTES:
            raise VoiceError("utterance_too_large", "Voice utterance exceeded the size limit")
        self.pcm.extend(chunk)


def pcm_to_wav(pcm: bytes, sample_rate: int, channels: int) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(max(1, channels))
        handle.setsampwidth(2)
        handle.setframerate(max(8000, sample_rate))
        handle.writeframes(pcm)
    return buffer.getvalue()


def _multipart(field: str, filename: str, data: bytes) -> tuple[bytes, str]:
    boundary = "----spatialagent%s" % uuid.uuid4().hex
    body = b"".join(
        [
            ("--%s\r\n" % boundary).encode(),
            ('Content-Disposition: form-data; name="%s"; filename="%s"\r\n' % (field, filename)).encode(),
            b"Content-Type: application/octet-stream\r\n\r\n",
            data,
            b"\r\n",
            ("--%s--\r\n" % boundary).encode(),
        ]
    )
    return body, "multipart/form-data; boundary=%s" % boundary


class WhisperTranscriber:
    def __init__(
        self,
        server_url: str = DEFAULT_WHISPER_SERVER_URL,
        *,
        timeout_seconds: float = 20.0,
        language: str = "en",
    ) -> None:
        self.server_url = server_url.rstrip("/")
        self.timeout_seconds = timeout_seconds
        self.language = language

    def transcribe(self, utterance: Utterance) -> str:
        if not utterance.pcm:
            return ""
        wav = pcm_to_wav(bytes(utterance.pcm), utterance.sample_rate, utterance.channels)
        body, content_type = _multipart("file", "utterance.wav", wav)
        request = urllib.request.Request(
            self.server_url + "/inference",
            data=body,
            method="POST",
            headers={"Content-Type": content_type},
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                raw = response.read().decode("utf-8", errors="replace")
        except urllib.error.URLError as error:
            raise VoiceError("asr_unreachable", "Speech recognizer is unavailable") from error
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as error:
            raise VoiceError("asr_bad_response", "Speech recognizer returned invalid data") from error
        text = payload.get("text", "")
        return str(text).strip() if isinstance(text, str) else ""


def normalize_samples(pcm: bytes) -> bytes:
    """Down-mix interleaved int16 stereo to mono (defensive; client sends mono)."""
    if len(pcm) % 4 != 0:
        return pcm
    samples = struct.unpack("<%dh" % (len(pcm) // 2), pcm)
    mono = bytearray()
    for index in range(0, len(samples) - 1, 2):
        mixed = (samples[index] + samples[index + 1]) // 2
        mono.extend(struct.pack("<h", mixed))
    return bytes(mono)
