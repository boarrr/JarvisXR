# Spatial Agent backend

Local asyncio WebSocket service for protocol v1. It owns sessions, durable threads, agent runs, provider access, tool policy, approvals, and structured diagnostics. It binds to loopback by default and never sends credentials to the Godot client.

## Setup

```sh
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -e .
cp .env.example .env
```

Run the deterministic provider:

```sh
.venv/bin/spatial-agent-backend
```

The default endpoint is `ws://127.0.0.1:8787/ws`; the default database is `data/spatial_agent.db` relative to this directory.

The `.env` loader accepts literal `KEY=VALUE` pairs and never executes shell expansion. Existing process environment variables take precedence. `.env` is ignored by Git.

## OpenAI, Claude, or Council

Install one hosted SDK or both:

```sh
.venv/bin/python -m pip install -e '.[openai]'
.venv/bin/python -m pip install -e '.[claude]'
# or
.venv/bin/python -m pip install -e '.[hosted]'
```

OpenAI configuration in `.env`:

```dotenv
SPATIAL_AGENT_PROVIDER=openai
OPENAI_API_KEY=your-api-key
OPENAI_MODEL=gpt-6-astra
```

The OpenAI adapter uses the Responses API's async text-delta stream. The default model follows current OpenAI model guidance as of this build and is always overridable. `OPENAI_API_KEY` must be an OpenAI API credential; a ChatGPT/Codex subscription login is not an API key.

Claude configuration:

```dotenv
SPATIAL_AGENT_PROVIDER=claude
ANTHROPIC_API_KEY=your-api-key
ANTHROPIC_MODEL=claude-sonnet-5
```

Start the backend after editing `.env`:

```sh
.venv/bin/spatial-agent-backend
```

Hosted modes send conversation context to the selected provider. Keep `SPATIAL_AGENT_PROVIDER=fake` for fully offline use. Provider SDK objects and credentials never cross the WebSocket boundary.

Both provider keys may coexist in the same `.env`. Single-provider modes construct and call only the selected adapter; Council deliberately constructs and calls both.

To compare both hosted providers explicitly:

```dotenv
SPATIAL_AGENT_PROVIDER=council
OPENAI_API_KEY=your-openai-api-key
ANTHROPIC_API_KEY=your-anthropic-api-key
```

Council runs both provider adapters concurrently against the same eligible conversation context. It presents two labelled perspectives and a disclosure note; it does not silently synthesize or arbitrate a verdict. Both keys are required, prompt data goes to both companies, and usage can be roughly twice that of one provider. Cancellation propagates to both in-flight tasks.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `SPATIAL_AGENT_HOST` | `127.0.0.1` | Bind address |
| `SPATIAL_AGENT_PORT` | `8787` | WebSocket port |
| `SPATIAL_AGENT_DB` | `data/spatial_agent.db` | SQLite path |
| `SPATIAL_AGENT_PROVIDER` | `fake` | `fake`, `openai`, `claude`, or `council` |
| `SPATIAL_AGENT_ENV_FILE` | `.env` | Optional path to a different literal environment file |
| `OPENAI_API_KEY` | none | Backend-only OpenAI API key |
| `OPENAI_MODEL` | `gpt-6-astra` | OpenAI model ID |
| `ANTHROPIC_API_KEY` | none | Backend-only Anthropic API key |
| `ANTHROPIC_MODEL` | `claude-sonnet-5` | Claude model ID |
| `SPATIAL_AGENT_MAX_OUTPUT_TOKENS` | `1024` | Provider output ceiling |
| `SPATIAL_AGENT_MAX_PACKET_BYTES` | `1048576` | Incoming WebSocket frame ceiling |
| `SPATIAL_AGENT_COMMANDS_PER_MINUTE` | `120` | Per-session command limit |
| `SPATIAL_AGENT_FAKE_DELAY` | `0.015` | Fake stream delay per chunk |

Do not expose the service beyond loopback without authentication, TLS termination, origin restrictions, and a deployment-specific rate policy.

## Rev 2: pairing, workspaces, and MCP

- `SPATIAL_AGENT_AUTH_REQUIRED=1` gates sessions behind `session.pair`; codes are
  issued with `spatial-agent-pair` (or printed at startup), single use, and
  stored only as hashes. A non-loopback bind additionally requires
  `SPATIAL_AGENT_TLS_CERT` and `SPATIAL_AGENT_TLS_KEY`.
- `SPATIAL_AGENT_WORKSPACES_FILE` lists repositories; every bound agent run gets
  an isolated `git worktree` on a `spatial/agent-<run_id>` branch. Diffs stream
  to the client and apply/reject decisions are audited.
- `SPATIAL_AGENT_MCP_CONFIG` declares MCP servers (stdio or streamable HTTP).
  Tools are namespaced `mcp.<server>.<tool>`; permissions come from policy,
  then annotations, defaulting to approval-required. Hosted providers gain a
  bounded tool-calling loop; Council stays text-only by design.
- `SPATIAL_AGENT_SHELL_ALLOWLIST` reserves a comma-separated allowlist hook for
  shell command policy; the default is an empty allowlist (every side effect is
  reviewed).

## Tool safety

Three narrow tools are registered:

- `/tool status` reads non-sensitive protocol, transport, tool-count, and uptime telemetry.
- `/tool clock` reads the backend UTC clock.
- `/tool note TEXT` requests the simulated `demo.write_note` action.

The two telemetry tools are `SAFE_READ` and declare no external side effect. The note tool is `WRITE_REVERSIBLE`, cannot run before explicit approval, and is still simulated. No shell, filesystem write, broad system-inspection, or remote integration tool is exposed.

## Tests

```sh
.venv/bin/python -W error::ResourceWarning -m unittest discover -s tests -v
```

The suite covers strict protocol validation, literal `.env` loading, both hosted provider boundaries, Council separation/cancellation, permission policy, safe tools, SQLite persistence, thread CRUD, focused voice-text routing, real WebSocket handshakes, streaming, cancellation, and approval gating. Installed OpenAI and Claude clients are constructed without making API requests.
