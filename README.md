# ensembleAI

Make `codex`, `claude`, and `gemini` deliberate on the same topic via their
**subscription CLIs** in non-interactive mode, then aggregate their answers
with majority voting and a judge model to produce a single optimal conclusion.

No API keys. No sandbox. Just the three CLIs you already log into:


## commercial subscription AI setting
```
npm i @openai/codex
npm install @google/gemini-cli
curl -fsSL https://claude.ai/install.sh | bash

codexe () {
  npx codex exec --yolo "$@"
}
alias gemini="npx gemini --approval-mode=yolo"
alias claude="claude --dangerously-skip-permissions"

echo "explain" | codexe --image img/temp.png -
gemini -p "@img/temp.png explain"
claude -p "img/temp.png explain"

/exit
/exit
exit
```
## commercial AI docs
- codex [cli,img](https://developers.openai.com/codex/cli/reference#codex-exec)
- gemini [img](https://geminicli.com/docs/cli/tutorials/file-management/#how-to-modify-code) [cli](https://geminicli.com/docs/cli/cli-reference/#cli-commands)
- claude [cli](https://code.claude.com/docs/en/cli-reference#cli-commands) img tag needless

## Protocol

```
[Topic]
   │
   ▼
Round 1 — independent answers           ← self-consistency
   │     (each agent answers in parallel,
   │      not seeing the others)
   ▼
Round 2..N — debate                     ← debate protocol
   │     (each agent sees all prior
   │      answers and revises)
   ▼
Aggregation
   ├── Majority vote on CONCLUSION      ← majority voting
   └── Judge synthesizes final answer   ← judge model
   ▼
[Final answer]
```

Each agent ends every round with a structured block:

```
=== STRUCTURED ===
CONCLUSION: <one sentence>
KEY_POINTS: ...
CONFIDENCE: <low|medium|high>
=== END ===
```

The orchestrator extracts `CONCLUSION` from each agent, groups them by
normalized text, and computes a plurality. The judge sees the full
transcript plus the vote summary and writes the final answer.

## Install

Clone, then make sure the three CLIs are on `PATH` and already logged in
(subscription mode). The orchestrator is plain Bash — no extra deps beyond
`awk`, `sed`, `timeout`.

```
git clone <this-repo> ensembleAI
cd ensembleAI
chmod +x ensemble.sh
```

## Usage

Topic input is flexible:

```
./ensemble.sh "Should we use Rust or Go for the ingest service?"   # arg
./ensemble.sh -f examples/topic.md                                  # file
echo "Topic" | ./ensemble.sh -                                      # stdin
./ensemble.sh                                                       # opens $EDITOR
```

Common flags:

| Flag                        | Default          | Meaning                                               |
| --------------------------- | ---------------- | ----------------------------------------------------- |
| `-i, --image PATH`          | none             | attach an image to every agent prompt (codex `--image`, gemini `@PATH`, claude inline path) |
| `-r, --rounds N`            | `1`              | debate rounds **after** round 1                       |
| `-a, --agents LIST`         | auto-detect      | comma-separated subset of `codex,claude,gemini`       |
| `-j, --judge NAME`          | `claude`         | which agent acts as judge                             |
| `-m, --mode MODE`           | `debate`         | `debate` \| `vote` \| `self-consistency` \| `chat`    |
| `--self-n N`                | `3`              | runs per agent in `self-consistency` mode             |
| `--max-turns N`             | `9`              | hard cap on total turns in `chat` mode                |
| `-o, --out DIR`             | `runs/<ts>`      | where transcripts and the final answer are written    |
| `--no-judge`                | off              | skip the judge step (fall back to vote-only output)   |
| `--dry-run`                 | off              | print prompts but do not call any agent               |

Examples:

```
# 3 agents, 2 debate rounds, gemini as judge
./ensemble.sh -r 2 -j gemini "Design an event log schema for IoT telemetry."

# Cheap mode: just vote, no debate, no judge
./ensemble.sh -m vote --no-judge -f examples/topic.md

# Self-consistency: claude answers 5 times in parallel and we vote
./ensemble.sh -m self-consistency -a claude --self-n 5 "Estimate Q3 churn risk drivers."

# Image input: all three CLIs reason about the same picture
./ensemble.sh --image img/temp.png "Explain what this image shows."

# Chat: free-form turn-by-turn dialogue, no per-topic prompt file
./ensemble.sh -m chat "Should we use Rust or Go for the ingest service?"
```

A worked image-debate example with the exact reference commands and the
captured transcript is in [`examples/debate-img-temp-png.md`](examples/debate-img-temp-png.md).

## Output

Every run lands in `runs/<timestamp>/`:

```
runs/20260508-153012/
├── topic.md            # the topic given to the agents
├── run.meta            # mode/agents/rounds/judge
├── round1/
│   ├── codex.md        # codex's round-1 answer
│   ├── codex.prompt    # exact prompt sent
│   ├── claude.md
│   └── gemini.md
├── round2/             # debate round (if --rounds >= 1)
│   └── ...
├── vote.md             # majority-vote summary on final round
├── judge.prompt        # judge prompt
└── final.md            # ← the optimal conclusion
```

The path to `final.md` is also printed to stderr and the answer to stdout at
the end of the run, so you can pipe it:

```
./ensemble.sh "..." | tee answer.md
```

## Configuration

Override CLI invocations with env vars (e.g. for non-default flags or alt
binaries):

```
CODEX_BIN=codex      CODEX_ARGS="exec --yolo"
CLAUDE_BIN=claude    CLAUDE_ARGS="-p --dangerously-skip-permissions"
GEMINI_BIN=gemini    GEMINI_ARGS="-p --approval-mode=yolo"
AGENT_TIMEOUT=600    # seconds, per-call
```

## Modes at a glance

- **`debate`** (default) — round 1 independent + N debate rounds + judge.
  Best quality, highest cost.
- **`vote`** — round 1 only, then majority vote (+ optional judge).
  Cheap and fast for objective questions where the agents are likely to
  converge.
- **`self-consistency`** — single agent (or subset) answers `--self-n` times
  in parallel and we vote on the conclusions. Useful when only one CLI is
  available, or to quantify variance.
- **`chat`** — turn-by-turn conversation rather than synchronized rounds.
  Each agent in turn sees the full running transcript and adds one short
  message ending with `[AGREE]`, `[EXTEND]`, or `[DISAGREE: ...]`. The
  deliberation ends as soon as every agent's most recent turn is `[AGREE]`
  consecutively, or at `--max-turns` (default 9). A short, fixed system
  prompt is used for every turn — no per-topic prompt files. The judge
  then synthesizes a `final.md` from the transcript.

### `chat` mode protocol

```
[Topic + small system prompt]
         │
         ▼
   ┌─→ turn N — agent A speaks (sees full transcript) ──┐
   │                                                     │
   │   turn N+1 — agent B speaks (sees full transcript)  │
   │                                                     │
   └── turn N+2 — agent C speaks (sees full transcript) ─┘
         │
         ▼  (if last len(agents) turns are all [AGREE])
   Judge synthesizes final.md
```

Chat-mode outputs land under `runs/<ts>/`:

```
runs/<ts>/
├── topic.md
├── run.meta
├── chat/
│   ├── turn-01-codex.md         # codex's first turn (free-form)
│   ├── turn-01-codex.prompt     # exact prompt sent
│   ├── turn-02-claude.md
│   └── ...
├── chat.md                      # running transcript (the "memory")
├── chat.signals                 # last per-agent signal (AGREE/EXTEND/...)
├── chat.termination             # "converged ..." or "max-turns reached"
├── judge.prompt                 # judge prompt over the full transcript
└── final.md                     # ← the optimal conclusion
```

## Notes

- Agents are run **in parallel** within each round (background processes).
  Round N waits for all of round N-1 to finish before starting.
- If an agent fails (timeout, crash, not logged in), its slot is filled with
  a synthetic "agent failed" structured block so voting and judging still
  work. The stderr from the failing agent is preserved at
  `round<N>/<agent>.err`.
- The judge sees the **full** transcript across all rounds plus the vote
  summary. It is explicitly instructed to override the majority when the
  minority is correct.
