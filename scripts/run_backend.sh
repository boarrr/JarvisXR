#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root/backend"
export PYTHONPATH="$project_root/backend/src${PYTHONPATH:+:$PYTHONPATH}"
exec .venv/bin/python -m spatial_agent_backend "$@"
