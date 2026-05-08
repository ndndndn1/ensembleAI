#!/usr/bin/env bash
# ensemble.sh — multi-AI deliberation orchestrator.
#
# Runs codex, claude, and gemini (in subscription / non-interactive mode) on
# the same topic, lets them debate across rounds, then aggregates with a
# majority vote and a judge model.
#
# Usage:
#   ./ensemble.sh "topic"             # topic from arg
#   ./ensemble.sh -f topic.md         # topic from file
#   echo "topic" | ./ensemble.sh -    # topic from stdin
#   ./ensemble.sh                     # opens $EDITOR
#
# Options:
#   -f, --file PATH        read topic from file
#   -i, --image PATH       attach an image to every agent prompt (uses each
#                          CLI's native image syntax)
#   -r, --rounds N         number of debate rounds after round 1 (default 1)
#   -a, --agents LIST      comma-separated subset of: codex,claude,gemini
#                          (default: all available)
#   -j, --judge NAME       judge agent: codex|claude|gemini (default: claude)
#   -m, --mode MODE        debate (default) | vote | self-consistency
#       --self-n N         in self-consistency mode, runs per agent (default 3)
#   -o, --out DIR          output directory (default: runs/<timestamp>)
#       --no-judge         skip the judge step
#       --dry-run          print what would happen, but do not call agents
#   -h, --help

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/agents.sh
source "$HERE/lib/agents.sh"
# shellcheck source=lib/voting.sh
source "$HERE/lib/voting.sh"

# -------- defaults --------
ROUNDS=1
AGENTS_INPUT=""
JUDGE="claude"
MODE="debate"
SELF_N=3
OUT_DIR=""
TOPIC_FILE=""
TOPIC_INLINE=""
IMAGE_OPT=""
NO_JUDGE=0
DRY_RUN=0

# -------- usage --------
usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# -------- arg parsing --------
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)    TOPIC_FILE="$2"; shift 2 ;;
    -i|--image)   IMAGE_OPT="$2"; shift 2 ;;
    -r|--rounds)  ROUNDS="$2"; shift 2 ;;
    -a|--agents)  AGENTS_INPUT="$2"; shift 2 ;;
    -j|--judge)   JUDGE="$2"; shift 2 ;;
    -m|--mode)    MODE="$2"; shift 2 ;;
    --self-n)     SELF_N="$2"; shift 2 ;;
    -o|--out)     OUT_DIR="$2"; shift 2 ;;
    --no-judge)   NO_JUDGE=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage 0 ;;
    -)            TOPIC_FILE="/dev/stdin"; shift ;;
    --)           shift; positional+=("$@"); break ;;
    -*)           echo "unknown option: $1" >&2; usage 2 ;;
    *)            positional+=("$1"); shift ;;
  esac
done
if [[ ${#positional[@]} -gt 0 ]]; then
  TOPIC_INLINE="${positional[*]}"
fi

# -------- read topic --------
read_topic() {
  if [[ -n "$TOPIC_INLINE" ]]; then
    printf '%s\n' "$TOPIC_INLINE"
  elif [[ -n "$TOPIC_FILE" ]]; then
    cat -- "$TOPIC_FILE"
  elif [[ ! -t 0 ]]; then
    cat
  else
    # Open $EDITOR for interactive entry.
    local tmp
    tmp="$(mktemp -t ensembleAI.XXXXXX.md)"
    : > "$tmp"
    "${EDITOR:-vi}" "$tmp"
    cat "$tmp"
    rm -f "$tmp"
  fi
}

TOPIC="$(read_topic)"
if [[ -z "${TOPIC//[[:space:]]/}" ]]; then
  echo "error: empty topic" >&2
  exit 2
fi

# Validate and export the image path so the agent runners pick it up.
if [[ -n "$IMAGE_OPT" ]]; then
  if [[ ! -r "$IMAGE_OPT" ]]; then
    echo "error: image not readable: $IMAGE_OPT" >&2
    exit 2
  fi
  export IMAGE_PATH="$IMAGE_OPT"
fi

# -------- decide agents --------
ALL_AGENTS=(codex claude gemini)
if [[ -n "$AGENTS_INPUT" ]]; then
  IFS=',' read -r -a AGENTS <<<"$AGENTS_INPUT"
else
  AGENTS=()
  for a in "${ALL_AGENTS[@]}"; do
    if agent_available "$a"; then
      AGENTS+=("$a")
    else
      echo "warn: agent '$a' not on PATH — skipping" >&2
    fi
  done
fi

if [[ ${#AGENTS[@]} -lt 2 && "$MODE" != "self-consistency" ]]; then
  echo "error: need at least 2 agents for $MODE mode (have: ${AGENTS[*]:-none})" >&2
  exit 2
fi

# -------- output dir --------
ts="$(date +%Y%m%d-%H%M%S)"
: "${OUT_DIR:=$HERE/runs/$ts}"
mkdir -p "$OUT_DIR"
printf '%s\n' "$TOPIC" > "$OUT_DIR/topic.md"
{
  echo "mode: $MODE"
  echo "agents: ${AGENTS[*]}"
  echo "rounds: $ROUNDS"
  echo "judge: $JUDGE"
  echo "self_n: $SELF_N"
  echo "image: ${IMAGE_PATH:-}"
} > "$OUT_DIR/run.meta"

echo ">>> ensembleAI run: $OUT_DIR" >&2
echo ">>> mode=$MODE  agents=${AGENTS[*]}  rounds=$ROUNDS  judge=$JUDGE  image=${IMAGE_PATH:-none}" >&2

# -------- prompt builders --------
render() {
  # render <template> [KEY=VAL ...]
  # Substitutes {{KEY}} placeholders. Values are read from environment-style
  # KEY=VAL args; the value may itself contain newlines.
  local tpl="$1"; shift
  local content
  content="$(cat "$tpl")"
  for kv in "$@"; do
    local k="${kv%%=*}"
    local v="${kv#*=}"
    # Use awk for safe multi-line substitution.
    content="$(awk -v k="{{$k}}" -v v="$v" '
      BEGIN { n = length(k) }
      {
        line = $0
        out = ""
        while ( (i = index(line, k)) > 0 ) {
          out = out substr(line, 1, i-1) v
          line = substr(line, i+n)
        }
        print out line
      }' <<<"$content")"
  done
  printf '%s\n' "$content"
}

# -------- run a single round in parallel --------
# run_round <round_idx> <prior_rounds_text>
run_round() {
  local idx="$1"
  local prior="$2"
  local round_dir="$OUT_DIR/round$idx"
  mkdir -p "$round_dir"
  echo ">>> round $idx (agents: ${AGENTS[*]})" >&2

  local pids=()
  for a in "${AGENTS[@]}"; do
    (
      local prompt
      if [[ "$idx" -eq 1 ]]; then
        prompt="$(render "$HERE/prompts/round1.md" "TOPIC=$TOPIC")"
      else
        prompt="$(render "$HERE/prompts/debate.md" "TOPIC=$TOPIC" "PRIOR_ROUNDS=$prior")"
      fi
      local out="$round_dir/$a.md"
      local err="$round_dir/$a.err"
      printf '%s\n' "$prompt" > "$round_dir/$a.prompt"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] $a would receive prompt at $round_dir/$a.prompt" > "$out"
      else
        if ! printf '%s\n' "$prompt" | agent_run "$a" > "$out" 2> "$err"; then
          echo "warn: agent '$a' failed in round $idx (see $err)" >&2
          {
            echo "=== STRUCTURED ==="
            echo "CONCLUSION: (agent $a failed)"
            echo "KEY_POINTS:"
            echo "- agent did not return a usable answer"
            echo "CONFIDENCE: low"
            echo "=== END ==="
          } >> "$out"
        fi
      fi
    ) &
    pids+=("$!")
  done
  for p in "${pids[@]}"; do wait "$p" || true; done
}

# -------- assemble prior-rounds text --------
prior_rounds_text() {
  # Concatenates round1..roundN outputs in a labeled, readable form for the
  # debate prompt.
  local upto="$1"
  local out=""
  for ((r=1; r<=upto; r++)); do
    local rd="$OUT_DIR/round$r"
    [[ -d "$rd" ]] || continue
    out+="### Round $r"$'\n\n'
    for a in "${AGENTS[@]}"; do
      local f="$rd/$a.md"
      [[ -f "$f" ]] || continue
      out+="#### Agent: $a"$'\n'
      out+="$(cat "$f")"$'\n\n'
    done
  done
  printf '%s' "$out"
}

# -------- modes --------
run_debate() {
  run_round 1 ""
  for ((r=2; r<=ROUNDS+1; r++)); do
    local prior
    prior="$(prior_rounds_text "$((r-1))")"
    run_round "$r" "$prior"
  done
}

run_vote_only() {
  run_round 1 ""
}

run_self_consistency() {
  # Each selected agent answers N times independently. Treat each (agent,run)
  # as a separate voter. Useful when you only have one model available, or
  # want to dampen single-model variance.
  local round_dir="$OUT_DIR/round1"
  mkdir -p "$round_dir"
  echo ">>> self-consistency: $SELF_N runs per agent (${AGENTS[*]})" >&2
  local pids=()
  for a in "${AGENTS[@]}"; do
    for ((i=1; i<=SELF_N; i++)); do
      (
        local prompt
        prompt="$(render "$HERE/prompts/round1.md" "TOPIC=$TOPIC")"
        local out="$round_dir/${a}-${i}.md"
        local err="$round_dir/${a}-${i}.err"
        if [[ "$DRY_RUN" -eq 1 ]]; then
          echo "[dry-run] $a (#$i)" > "$out"
        else
          if ! printf '%s\n' "$prompt" | agent_run "$a" > "$out" 2> "$err"; then
            echo "warn: $a #$i failed" >&2
          fi
        fi
      ) &
      pids+=("$!")
    done
  done
  for p in "${pids[@]}"; do wait "$p" || true; done
}

case "$MODE" in
  debate)            run_debate ;;
  vote)              run_vote_only ;;
  self-consistency)  run_self_consistency ;;
  *) echo "unknown mode: $MODE" >&2; exit 2 ;;
esac

# -------- aggregation --------
last_round_dir() {
  ls -d "$OUT_DIR"/round* 2>/dev/null | sort -V | tail -n1
}

VOTE_DIR="$(last_round_dir)"
{
  echo "# Vote summary — $(basename "$VOTE_DIR")"
  echo
  majority_vote "$VOTE_DIR"
} > "$OUT_DIR/vote.md"

echo >&2
echo ">>> vote summary:" >&2
sed 's/^/    /' "$OUT_DIR/vote.md" >&2

# -------- judge --------
final_path="$OUT_DIR/final.md"

if [[ "$NO_JUDGE" -eq 1 || "$MODE" == "vote" || "$MODE" == "self-consistency" ]]; then
  # Skip judge: produce a final.md from the vote winner.
  {
    echo "# Final answer (no judge)"
    echo
    echo "## Vote summary"
    cat "$OUT_DIR/vote.md"
    echo
    echo "## Per-agent last-round answers"
    for f in "$VOTE_DIR"/*.md; do
      [[ -f "$f" ]] || continue
      echo "### $(basename "$f" .md)"
      echo
      cat "$f"
      echo
    done
  } > "$final_path"
else
  if ! agent_available "$JUDGE"; then
    echo "warn: judge '$JUDGE' not available, falling back to first agent: ${AGENTS[0]}" >&2
    JUDGE="${AGENTS[0]}"
  fi
  echo ">>> judge: $JUDGE" >&2
  TRANSCRIPT="$(prior_rounds_text "$(ls -d "$OUT_DIR"/round* | wc -l | tr -d ' ')")"
  VOTE_SUMMARY="$(cat "$OUT_DIR/vote.md")"
  judge_prompt="$(render "$HERE/prompts/judge.md" \
      "TOPIC=$TOPIC" \
      "TRANSCRIPT=$TRANSCRIPT" \
      "VOTE_SUMMARY=$VOTE_SUMMARY")"
  printf '%s\n' "$judge_prompt" > "$OUT_DIR/judge.prompt"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] judge $JUDGE would be invoked" > "$final_path"
  else
    if ! printf '%s\n' "$judge_prompt" | agent_run "$JUDGE" > "$final_path" 2> "$OUT_DIR/judge.err"; then
      echo "warn: judge '$JUDGE' failed (see $OUT_DIR/judge.err) — emitting vote-only fallback" >&2
      {
        echo "# Final answer (judge failed; vote-only)"
        echo
        cat "$OUT_DIR/vote.md"
      } > "$final_path"
    fi
  fi
fi

# -------- print final answer --------
echo >&2
echo ">>> FINAL ANSWER ($final_path):" >&2
echo >&2
cat "$final_path"
