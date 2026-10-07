#!/usr/bin/env python3
"""Fake Codex CLI that reports usage/cost, then stalls (for cost budgets)."""
import json
import time


def emit(payload):
    print(json.dumps(payload), flush=True)


def main():
    emit({"type": "text", "text": "working"})
    emit({"type": "usage", "cost": 0.6, "tokens": 1200})
    time.sleep(30)


if __name__ == "__main__":
    main()
