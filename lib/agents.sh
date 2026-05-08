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
: "${CLAUDE_ARGS:=--dangerously-skip-permissions -p}"
# `--skip-trust` lets gemini run in untrusted/headless directories (e.g. CI,
# /tmp, codespaces) without prompting; equivalent to GEMINI_CLI_TRUST_WORKSPACE=1.
: "${GEMINI_ARGS:=--approval-mode=yolo --skip-trust}"

: "${AGENT_TIMEOUT:=600}"  # per-call timeout in seconds

# Env vars set by an outer Claude Code session that, if inherited by the
# spawned `claude` subprocess, cause it to fail silently / refuse to start a
# new session. We strip them on every claude invocation (idempotent — no
# effect if they aren't set).
#
# This list was verified against Claude Code v2.1.133 (2026-05-08) by
# running `env | grep -iE 'claude|anthropic|^AI_AGENT' | cut -d= -f1` from
# inside an active Claude Code session. If a future Claude Code release
# adds a new session-marker variable, add it here. Symptom of a missed
# marker: `claude` exits non-zero with empty stderr when invoked from
# inside Claude Code.
_CLAUDE_NESTED_ENV_STRIP=(
  CLAUDECODE
  CLAUDE_CODE_SESSION_ID
  CLAUDE_CODE_ENTRYPOINT
  CLAUDE_CODE_EXECPATH
  CLAUDE_EFFORT
  AI_AGENT
)

# IMAGE_PATH: if set, the runners attach the image to the agent's input using
# each CLI's native syntax:
#   - codex:  --image <PATH> ; prompt is piped via stdin (using `-`)
#   - gemini: @<PATH> prefix in the -p prompt
#   - claude: <PATH> prefix in the positional prompt (auto-detected)
: "${IMAGE_PATH:=}"

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
  if [[ -n "$IMAGE_PATH" ]]; then
    # `--image` attaches the image; `-` reads the prompt from stdin.
    printf '%s\n' "$prompt" \
      | _run_with_timeout "$AGENT_TIMEOUT" "$CODEX_BIN" $CODEX_ARGS --image "$IMAGE_PATH" -
  else
    _run_with_timeout "$AGENT_TIMEOUT" "$CODEX_BIN" $CODEX_ARGS "$prompt"
  fi
}

agent_claude() {
  local prompt
  prompt="$(cat)"
  # Strip any inherited Claude Code session env vars before invoking the CLI.
  # Without this, a nested `claude` spawned from inside Claude Code exits
  # silently (empty stderr, non-zero rc) instead of starting a fresh session.
  local strip=()
  local v
  for v in "${_CLAUDE_NESTED_ENV_STRIP[@]}"; do
    strip+=(-u "$v")
  done
  # The prompt is the trailing positional argument.
  if [[ -n "$IMAGE_PATH" ]]; then
    # claude auto-detects local file paths in the prompt (no special flag).
    _run_with_timeout "$AGENT_TIMEOUT" env "${strip[@]}" "$CLAUDE_BIN" $CLAUDE_ARGS "$IMAGE_PATH $prompt"
  else
    _run_with_timeout "$AGENT_TIMEOUT" env "${strip[@]}" "$CLAUDE_BIN" $CLAUDE_ARGS "$prompt"
  fi
}

agent_gemini() {
  local prompt
  prompt="$(cat)"
  # `-p` must come last so its value (the prompt) is not stolen by another flag.
  if [[ -n "$IMAGE_PATH" ]]; then
    # gemini uses the `@<path>` prefix inside the prompt to attach files.
    _run_with_timeout "$AGENT_TIMEOUT" "$GEMINI_BIN" $GEMINI_ARGS -p "@$IMAGE_PATH $prompt"
  else
    _run_with_timeout "$AGENT_TIMEOUT" "$GEMINI_BIN" $GEMINI_ARGS -p "$prompt"
  fi
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
