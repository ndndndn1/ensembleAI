#!/usr/bin/env bash
# Agent CLI wrappers. Each function:
#   - takes a prompt on stdin
#   - writes the agent's textual answer to stdout
#   - returns non-zero on failure
#
# All agents are invoked in non-interactive subscription mode. No API keys.
# These commands are configurable via env vars so users can override flags
# without editing the script.

: "${CODEX_BIN:=codex}"
: "${CLAUDE_BIN:=claude}"
: "${GEMINI_BIN:=gemini}"

: "${CODEX_ARGS:=exec --yolo}"
: "${CLAUDE_ARGS:=-p --dangerously-skip-permissions}"
: "${GEMINI_ARGS:=-p --approval-mode=yolo}"

: "${AGENT_TIMEOUT:=600}"  # per-call timeout in seconds

# -------- helpers --------

_have() { command -v "$1" >/dev/null 2>&1; }

_run_with_timeout() {
  # _run_with_timeout <secs> <cmd...>
  local t="$1"; shift
  if _have timeout; then
    timeout --foreground "${t}s" "$@"
  else
    "$@"
  fi
}

# -------- agent runners --------

agent_codex() {
  local prompt
  prompt="$(cat)"
  # codex exec reads the prompt as a positional argument.
  _run_with_timeout "$AGENT_TIMEOUT" "$CODEX_BIN" $CODEX_ARGS "$prompt"
}

agent_claude() {
  local prompt
  prompt="$(cat)"
  # claude -p accepts the prompt as a positional argument.
  _run_with_timeout "$AGENT_TIMEOUT" "$CLAUDE_BIN" $CLAUDE_ARGS "$prompt"
}

agent_gemini() {
  local prompt
  prompt="$(cat)"
  # gemini -p accepts the prompt as a flag value.
  _run_with_timeout "$AGENT_TIMEOUT" "$GEMINI_BIN" $GEMINI_ARGS "$prompt"
}

# Dispatcher: agent_run <name>
agent_run() {
  case "$1" in
    codex)  agent_codex ;;
    claude) agent_claude ;;
    gemini) agent_gemini ;;
    *) echo "unknown agent: $1" >&2; return 2 ;;
  esac
}

# Probe whether an agent is installed (does not invoke it).
agent_available() {
  case "$1" in
    codex)  _have "$CODEX_BIN" ;;
    claude) _have "$CLAUDE_BIN" ;;
    gemini) _have "$GEMINI_BIN" ;;
    *) return 2 ;;
  esac
}
