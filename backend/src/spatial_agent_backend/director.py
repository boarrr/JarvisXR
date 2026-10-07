from __future__ import annotations

"""Director mode: decompose a goal into sub-tasks for a fleet.

When a harness is available the director runs a planning prompt and parses a
JSON array of sub-tasks; otherwise it falls back to a deterministic split so a
directed mission always produces something runnable.
"""

import json
from typing import Callable, Awaitable


def parse_tasks(text: str, count: int) -> list[str]:
    start = text.find("[")
    end = text.rfind("]")
    if start < 0 or end <= start:
        return []
    try:
        data = json.loads(text[start : end + 1])
    except json.JSONDecodeError:
        return []
    if not isinstance(data, list):
        return []
    tasks = [str(item).strip() for item in data if str(item).strip()]
    if count > 0:
        tasks = tasks[:count]
    return tasks


def fallback_tasks(goal: str, count: int) -> list[str]:
    return [f"{goal} (part {index + 1}/{count})" for index in range(max(1, count))]


async def plan_with_harness(harness, directory: str, goal: str, count: int) -> list[str]:
    session_id = ""
    try:
        session_id = await harness.create_session(directory=directory or ".", title="director")
        await harness.prompt(
            session_id,
            (
                f"Decompose this goal into exactly {count} concrete, independent sub-tasks. "
                f"Reply with ONLY a JSON array of {count} short strings and no other prose.\n\n"
                f"Goal: {goal}"
            ),
        )
        text = ""
        async for event in harness.events(session_id):
            if event.kind == "delta":
                text += event.text
        return parse_tasks(text, count) or fallback_tasks(goal, count)
    except Exception:  # noqa: BLE001 - director falls back to a naive split
        return fallback_tasks(goal, count)
    finally:
        if session_id:
            try:
                await harness.close(session_id)
            except Exception:  # noqa: BLE001
                pass


Planner = Callable[[str, str, int], Awaitable[list[str]]]
