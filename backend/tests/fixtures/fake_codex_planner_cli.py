#!/usr/bin/env python3
"""Fake Codex CLI that acts as a director: returns a JSON array of sub-tasks."""
import json


def emit(payload):
    print(json.dumps(payload), flush=True)


def main():
    emit({"type": "text", "text": json.dumps(["Build the parser", "Write the tests"])})
    emit({"type": "done"})


if __name__ == "__main__":
    main()
