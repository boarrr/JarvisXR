#!/usr/bin/env python3
"""Fake Codex CLI for tests: emits normalized JSONL and exits."""
import json
import sys


def emit(payload):
    print(json.dumps(payload), flush=True)


def main():
    prompt = sys.argv[1] if len(sys.argv) > 1 else ""
    emit({"type": "text", "text": f"working on: {prompt}"})
    emit({"type": "tool", "name": "shell", "command": "ls"})
    emit({"type": "text", "text": " done."})
    emit({"type": "done"})


if __name__ == "__main__":
    main()
