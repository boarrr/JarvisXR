#!/usr/bin/env python3
"""Fake Codex CLI that stalls, so a mission budget can fire."""
import json
import sys
import time


def emit(payload):
    print(json.dumps(payload), flush=True)


def main():
    emit({"type": "text", "text": "starting long task"})
    time.sleep(30)
    emit({"type": "done"})


if __name__ == "__main__":
    main()
