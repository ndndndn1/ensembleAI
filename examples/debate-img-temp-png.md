# Debate — `img/temp.png`

A worked example of running the three subscription CLIs (`codex`, `claude`,
`gemini`) on a single image input and aggregating their answers via the
ensembleAI debate protocol.

- **Topic** — *"Explain what this image shows. Identify the device, label its
  regions/terminals, and list typical applications."*
- **Image** — [`img/temp.png`](../img/temp.png) (cross-section diagram of a
  semiconductor device)

### Tested CLI versions

The fixes and run output below were verified against the following exact
versions on 2026-05-08. Different versions may behave differently — most
notably the env-var list in §3.2 is tied to the Claude Code release that
spawned the orchestrator.

| Component                  | Version                  | Channel                                  |
| -------------------------- | ------------------------ | ---------------------------------------- |
| `@openai/codex`            | `0.129.0` (research preview) | `npm i @openai/codex`                |
| `@google/gemini-cli`       | `0.41.2`                 | `npm install @google/gemini-cli`         |
| `claude` (Claude Code CLI) | `2.1.133`                | `curl -fsSL https://claude.ai/install.sh \| bash` |
| Host environment           | GitHub Codespaces, Linux 6.8.0-1044-azure | non-root user `codespace` |
| Outer agent (which spawned the run) | Claude Code `2.1.133` (so the §3.2 nested-session symptom *was* reproducible here) | — |

`package.json` pins codex/gemini with caret ranges, so a fresh
`npm install` will pick up newer minor versions; if any of the section-3
fixes regress, re-pin to the versions above as a smoke test.

---

## 1. Reference commands (from `README.md`)

These are the canonical one-shot invocations of each CLI in non-interactive
subscription mode with image input:

```sh
# codex (subscription, non-interactive). The trailing `-` reads the prompt
# from stdin so heredoc / pipe input is supported.
echo "explain" | codexe --image img/temp.png -

# gemini (subscription, non-interactive). `@<path>` inside the prompt
# attaches the image to the request.
gemini -p "@img/temp.png explain"

# claude (subscription, non-interactive). The path is included inline; the
# CLI auto-detects local files referenced in the prompt.
claude -p "img/temp.png explain"
```

`codexe`, `gemini`, and `claude` shell shims are defined in the project
README under *commercial subscription AI setting* and ultimately resolve to:

```sh
codexe  -> npx codex exec --yolo "$@"
gemini  -> npx gemini --approval-mode=yolo
claude  -> claude --dangerously-skip-permissions
```

## 2. Orchestrator equivalent

The orchestrator calls each CLI with the same syntax above. Use `--image
PATH` to attach the image to **every** agent prompt across all rounds:

```sh
./ensemble.sh \
    --image img/temp.png \
    --agents codex,claude,gemini \
    --rounds 1 \
    --judge claude \
    -o runs/img-debate \
    "Explain what this image shows. Identify the device, label its regions/terminals, and list typical applications."
```

Internally `lib/agents.sh` routes the image to each CLI with its native
syntax. The two flagged with † use fixes documented in section 3 below:

| Agent  | Effective command (per round)                                                       |
| ------ | ----------------------------------------------------------------------------------- |
| codex  | `printf '%s\n' "$prompt" \| codex exec --yolo --image img/temp.png -`               |
| claude † | `env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID … claude --dangerously-skip-permissions -p "img/temp.png $prompt"` |
| gemini † | `gemini --approval-mode=yolo --skip-trust -p "@img/temp.png $prompt"`             |

## 3. Common runtime issues and fixes

Two environment-specific problems surfaced when reproducing this example
inside a Codespaces / sandbox environment. Both are now handled by
`lib/agents.sh` so the orchestrator works out-of-the-box; this section
documents *what* breaks and *how* the wrapper fixes it, in case the user
hits the same symptoms invoking the CLIs directly.

### 3.1 Gemini — "untrusted folder" refusal

**Symptom** (stderr from `gemini`):

```text
Approval mode overridden to "default" because the current folder is not trusted.
Gemini CLI is not running in a trusted directory. To proceed, either use
`--skip-trust`, set the `GEMINI_CLI_TRUST_WORKSPACE=true` environment
variable, or trust this directory in interactive mode.
```

This happens whenever `gemini` is invoked headlessly from a directory it
hasn't been told to trust (CI runners, fresh worktrees under `/tmp`,
codespaces, etc.). YOLO mode alone is not enough — the trust check is
independent of the approval policy.

**Fix.** Pass `--skip-trust`. `lib/agents.sh` now bakes it into the
default `GEMINI_ARGS`:

```sh
: "${GEMINI_ARGS:=--approval-mode=yolo --skip-trust}"
```

Equivalently, exporting `GEMINI_CLI_TRUST_WORKSPACE=true` in the parent
shell also works. `--skip-trust` is preferred because it scopes the
relaxation to the single invocation rather than the whole shell session.

> ⚠️ **Security caveat.** `--skip-trust` declares that you trust the
> contents of the current working directory — including any `.gemini/`
> config, `GEMINI.md` instructions, or other files gemini may auto-read.
> ensembleAI is a user-initiated orchestrator, so the assumption is
> reasonable for repos *you wrote or audited*. **Avoid running this
> orchestrator (or `gemini --skip-trust` directly) inside a freshly
> cloned third-party repo before reviewing what's in it.** If you need
> to debate over an unfamiliar repo, do it from a sibling directory
> with the image copied out, not from the repo root.

### 3.2 Claude — nested-session / silent-exit when running inside Claude Code

**Symptom.** When `claude --dangerously-skip-permissions -p …` is spawned
*from within* an existing Claude Code session (e.g. you ran the
orchestrator from inside a Claude Code terminal), the child process exits
non-zero with **empty stderr** and produces no output. There is no
"please log in" or "permissions denied" message — it just dies quietly.

**Cause.** Claude Code exports a number of session-marker env vars that
the spawned `claude` CLI inherits and treats as "I'm already inside a
session, don't start a new one":

| Env var | Source |
| ------- | ------ |
| `CLAUDECODE=1` | Claude Code main marker |
| `CLAUDE_CODE_SESSION_ID` | UUID of the parent session |
| `CLAUDE_CODE_ENTRYPOINT` | `cli` / `vscode` / etc. |
| `CLAUDE_CODE_EXECPATH` | path of parent CLI binary |
| `CLAUDE_EFFORT` | inherited reasoning level |
| `AI_AGENT` | `claude-code_<ver>_agent` |

(This is a stricter sibling of the *"`--dangerously-skip-permissions`
cannot be used with root/sudo privileges"* error you get when running as
root — same defensive design, different trigger.)

> 🔄 **Version pin.** The marker list above was captured by running
> `env | grep -iE 'claude|anthropic|^AI_AGENT' | cut -d= -f1` from
> inside an active **Claude Code v2.1.133** session (the same release
> used to verify the rest of this document). A future Claude Code
> release may add a new marker; if so, the symptom is the same silent
> non-zero exit and the fix is to add the new variable to
> `_CLAUDE_NESTED_ENV_STRIP` in `lib/agents.sh`.

**Fix.** Strip those variables from the spawned process's environment
using `env -u`. `lib/agents.sh` now does this for every `claude` call:

```sh
# Excerpt — see lib/agents.sh:agent_claude.
_CLAUDE_NESTED_ENV_STRIP=(
  CLAUDECODE
  CLAUDE_CODE_SESSION_ID
  CLAUDE_CODE_ENTRYPOINT
  CLAUDE_CODE_EXECPATH
  CLAUDE_EFFORT
  AI_AGENT
)

strip=()
for v in "${_CLAUDE_NESTED_ENV_STRIP[@]}"; do strip+=(-u "$v"); done

env "${strip[@]}" claude --dangerously-skip-permissions -p "$prompt"
```

The stripped subprocess starts a fresh session, picks up the user's
keychain credentials normally, and returns answers as expected.

> Do **not** use `claude --bare` for this — `--bare` *also* skips the
> keychain (it expects `ANTHROPIC_API_KEY` or `apiKeyHelper`), so a
> subscription-mode user gets a `Not logged in · Please run /login`
> error. Stripping the inherited session env vars is the right fix for
> nested subscription-mode calls.

### 3.3 Quick standalone-CLI smoke tests (after fixes)

Once the wrappers are in place, you can verify each CLI directly:

```sh
# codex — works as-is
echo "in one short sentence, what is this?" | codex exec --yolo --image img/temp.png -

# gemini — needs --skip-trust in untrusted dirs
gemini --approval-mode=yolo --skip-trust -p "@img/temp.png in one short sentence, what is this?"

# claude — needs CLAUDECODE et al. unset when called from inside Claude Code
env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT \
    -u CLAUDE_CODE_EXECPATH -u CLAUDE_EFFORT -u AI_AGENT \
    claude --dangerously-skip-permissions -p "img/temp.png in one short sentence, what is this?"
```

All three return a single-sentence identification of the device as a
cross-section of a conventional NPN BJT.

## 4. Verified live run output

After applying the section-3 fixes, all three agents authenticate and
return real answers. The run below was produced from this repo with:

```sh
PATH="$PWD/node_modules/.bin:$PATH" CLAUDE_BIN=claude \
./ensemble.sh \
    --image img/temp.png \
    --agents codex,claude,gemini \
    --rounds 0 \
    --judge claude \
    -o runs/full-test \
    "Explain what this image shows. Identify the device, label its regions/terminals, and list typical applications."
```

(`--rounds 0` runs Round 1 only — a single independent answer per agent
plus the judge. Use `--rounds 1` or higher for actual debate rounds.)

### Per-agent Round-1 conclusions (verbatim)

```
codex:  The image shows a cross-section of a conventional integrated NPN
        bipolar junction transistor with labeled base, emitter, collector,
        isolation, epitaxial, buried-layer, and substrate regions.

claude: The image is a cross-section of a monolithic IC NPN bipolar
        junction transistor showing the standard planar/epitaxial
        structure with junction isolation, a buried n⁺⁺ collector layer,
        and aluminum contacts to the Base, Emitter, and Collector.

gemini: The image shows a cross-sectional view of a conventional NPN
        Bipolar Junction Transistor (BJT) fabricated within an integrated
        circuit environment using a planar process.
```

The vote step reports a 3-way phrasing split (the normalized strings
differ), but the judge correctly recognizes substantive agreement.

### Judge synthesis (excerpt — full text in `runs/full-test/final.md`)

> **Consensus.** All three agents agree on the core identification: the
> image is a **cross-section of a monolithic integrated NPN bipolar
> junction transistor (BJT)** built by a planar epitaxial process. They
> agree on three terminals (B, E, C) with aluminum metallization through
> SiO₂ contact windows; the vertical NPN stack n⁺⁺ emitter / p base /
> n epitaxial collector; an n⁺⁺ buried layer lowering collector series
> resistance; p⁺ isolation diffusions plus the p substrate providing
> junction isolation; and a standard application set (analog amplifiers,
> current mirrors, references, RF/IF, switching, bipolar logic).
>
> The "disagreement" flagged by majority vote is purely surface phrasing.
> Claude's answer is the most precise — it distinguishes the p⁺ surface
> diffusion as the **base ohmic contact** (not the active base), names
> the right-hand n⁺⁺ as a **collector sinker**, and explains *why* the
> buried layer matters (lateral low-resistance path, lower V_CE(sat)).
> Codex and gemini are correct subsets of the same picture.

```
=== FINAL ===
ANSWER: Cross-sectional schematic of a conventional vertical NPN BJT
fabricated in a monolithic silicon IC using a planar epitaxial process
with junction isolation. Terminals B/E/C are aluminum contacts through
SiO2 windows to a p+ base ohmic tap, an n++ emitter diffusion, and an
n++ collector sinker, respectively. Active stack is n++ emitter / p
base / n epi collector with an n++ buried layer providing the low-
resistance return to the C contact; outer p+ ribs plus the p substrate
form the reverse-biased junction-isolation cage. Typical uses: analog
amplifiers, op-amps, current mirrors, bandgap references, RF/IF gain
stages, ECL/TTL logic, and the bipolar element in BiCMOS.
RATIONALE: All three agents reached the same identification; differences
were in level of detail, not correctness. Synthesis adopts claude's
precision (sinker, base ohmic vs. intrinsic base distinction, buried-
layer rationale) layered over the labeling inventory shared by all three.
DISSENTS: none.
CONFIDENCE: high
=== END ===
```

This matches the stand-in deliberation in section 6 below — confirming
that the multimodal-stand-in answer used in earlier revisions of this
document was a faithful preview of the live ensemble output.

## 5. Test limitations and caveats

What §3 and §4 *do* establish, and what they *don't*. Reading these as
a single "the orchestrator works perfectly on images" is too strong; the
honest scope is narrower.

### 5.1 Verified — each CLI does real vision-based image input

Worry: did `codex --image` actually pass the bytes to a vision model, or
did it just hand the path to a text model that guessed from the
filename `temp.png` plus the prompt's word "device"?

**Verification.** A sanity-check image was generated locally with a
content-free filename and pixel content that no model could plausibly
have memorized:

```sh
# 8x8 random-pixel PNG, deterministic seed unique to this run, named
# canvas.png so the filename gives no semantic hint.
python3 - <<'PY'
import struct, zlib, random
random.seed(20260508); W=H=8; raw=b''
for _ in range(H):
    raw += b'\x00'
    for _ in range(W):
        raw += bytes([random.randint(0,255) for _ in range(3)])
def chunk(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
sig=b'\x89PNG\r\n\x1a\n'
ihdr=struct.pack('>IIBBBBB',W,H,8,2,0,0,0)
open('/tmp/img-blind-test/canvas.png','wb').write(
    sig+chunk(b'IHDR',ihdr)+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b''))
PY
```

Each CLI was then asked: *"Describe what you see in 2 sentences. List
the dominant colors. Do NOT guess from the filename."* The actual
responses (verbatim, single run, 2026-05-08):

| CLI    | Response (key fragments)                                                                                                  | Verdict |
| ------ | ------------------------------------------------------------------------------------------------------------------------- | ------- |
| codex  | *"tiny pixelated square… scattered bright multicolored pixels forming an abstract pattern. Dominant colors: black, red, green, blue, cyan, magenta, yellow, white."* | sees pixel-grid structure |
| claude | *"very small, low-resolution graphic showing a few blocky pixel regions… pink/magenta on the left, black in the middle, green on the right."* | sees blocks + colors |
| gemini | *"soft, out-of-focus blobs of color… abstract, ethereal effect. Dominant colors: dark green, magenta, white, black, teal."* | sees colors (mis-reads resolution) |

The ground-truth pixel set contains greens (e.g. `(25,73,8)`,
`(30,168,43)`), magentas (`(217,10,216)`), near-blacks (`(13,0,21)`),
teals (`(24,182,168)`) and bright whites — every color call across the
three CLIs is consistent with the actual distribution. None of them
could have produced these specific color sets from the filename
"canvas.png" alone.

**Conclusion.** All three CLIs (`codex`, `claude`, `gemini` at the
versions above) genuinely route the image to a vision-capable model.
ensembleAI's `--image` path is not a fallback; it's real multimodal
deliberation.

### 5.2 Not verified — that consensus on `img/temp.png` reflects deliberation

The Round-1 conclusions in §4 all converge on "vertical NPN BJT
cross-section in a junction-isolated bipolar IC process." That's
genuinely what the image shows, but it is *also* one of the most
canonical figures in semiconductor textbooks (Sedra/Smith, Gray/Meyer,
Streetman). The prior probability that any modern multimodal model lands
on this answer with high confidence — independently of the other two —
is very high.

So the §4 run validates **that the orchestrator collects, votes on, and
synthesizes real per-CLI answers**. It does **not** establish that
debate / judge synthesis adds value over a single CLI for *this*
particular image — three confident-and-correct independent answers don't
exercise the disagreement-handling machinery.

A more discriminating test would use an image where the three CLIs
plausibly disagree:

- Ambiguous or low-quality micrographs (SEM/TEM with no scale bar).
- Non-canonical or hand-drawn device cross-sections.
- Multi-object scenes where each agent might foreground a different
  object.
- Charts where the axes/units are missing or unusual.

Such tests are out of scope for this example file; if you add one, drop
a sibling under `examples/` rather than retro-fitting this document so
the *known-easy* case here remains a clean baseline.

### 5.3 Other scope notes

- **Single-run, no statistical significance.** The §4 run was executed
  once. Network blips, model server-side updates, or rate limiting can
  flip individual agents into the "agent failed" fallback path even
  with the §3 fixes applied. Re-run `./ensemble.sh` if any agent
  produces the synthetic block instead of a real STRUCTURED block.
- **One outer agent type tested.** The §3.2 nested-session fix was
  verified specifically when the orchestrator is launched from inside
  Claude Code itself. A different parent agent runtime (e.g. an OpenAI
  Codex-driven shell, or a plain SSH session with the CLAUDECODE env
  vars intentionally set) was *not* tested.
- **Non-root user only.** All runs were as the unprivileged
  `codespace` user. The earlier *"`--dangerously-skip-permissions`
  cannot be used with root/sudo"* error path is documented in §3.2 but
  not re-verified.
- **English prompts only.** The topic was English. Behaviour with
  non-English prompts (especially CJK) on the same image was not
  evaluated.

## 6. Stand-in deliberation (multimodal, Claude Opus 4.7) — historical

> **Note.** This section is kept as a worked illustration of the debate
> / judge protocol with a *single* multimodal model standing in for all
> three agents. It was written when the live CLIs could not be
> authenticated in the sandbox; with the section-3 fixes applied the
> live ensemble now runs (see section 4 above), and section 5 documents
> what that run does and does not establish. Treat this section as
> protocol-walkthrough material, not as the canonical answer.

### Round 1 — independent answers

#### Agent: codex (stand-in)

The image is a labelled cross-sectional schematic of a **conventional
vertical NPN bipolar junction transistor (BJT)** as fabricated in a
junction-isolated bipolar IC process.

Reading top-down from the surface, I identify:

- **B / E / C** — three top-side wire bonds (Base, Emitter, Collector).
- **Aluminum** — metal contacts dropping through openings in the SiO2
  passivation to reach the doped silicon underneath.
- **Isolation SiO2** — surface oxide; provides electrical isolation
  between metal lines and acts as the contact mask.
- **p⁺** ribs at the left and right — diffused isolation walls that
  isolate this device from neighbouring transistors on the same substrate.
- **n⁺⁺** under the emitter contact — heavily doped emitter region.
- **p⁺** in the centre — the **base** diffusion (between emitter and
  collector contacts).
- **n** — the lightly doped **epitaxial** collector body.
- **n⁺⁺ buried layer** — low-resistance current path from the active
  collector region back up to the collector contact, reducing series
  resistance.
- **p** silicon substrate at the bottom.

The current flow is: emitter (n⁺⁺) → base (p⁺) → collector (n epi) → buried
layer (n⁺⁺) → collector contact. Operation is *vertical*; isolation is
*lateral*.

```
=== STRUCTURED ===
CONCLUSION: The image is a labelled cross-section of a conventional vertical NPN bipolar junction transistor as built in a junction-isolated bipolar IC process.
KEY_POINTS:
- Three terminals B/E/C contact aluminum lines through openings in the SiO2 passivation.
- The vertical NPN stack is n++ emitter → p+ base → n epitaxial collector, with the n++ buried layer providing low-resistance return to the collector contact.
- p+ sidewalls and the p substrate provide junction isolation from neighbouring devices.
CONFIDENCE: high
=== END ===
```

#### Agent: claude (stand-in)

This is a textbook cross-sectional view of a **planar, junction-isolated
NPN bipolar transistor**, the kind taught in introductory device-physics
and analog-IC courses. The caption literally says *"Conventional npn
transistor"*.

Functional regions (current-carrying):

| Region     | Doping | Role                                                |
| ---------- | ------ | --------------------------------------------------- |
| Emitter    | n⁺⁺    | Injects electrons into the base under forward bias  |
| Base       | p⁺     | Thin p-type region; controls electron transport     |
| Collector  | n epi  | Lightly doped collector for high BV<sub>CEO</sub>   |
| Buried lyr | n⁺⁺    | Reduces R<sub>C</sub> by routing current to contact |
| Substrate  | p      | Mechanical support and isolation                    |

Auxiliary regions:

- **Isolation SiO2** — surface dielectric and contact mask.
- **p⁺ sidewalls** — diffused-down isolation that joins the substrate to
  form a reverse-biased p–n cage around the device, giving it a separate
  collector from its neighbours.
- **Aluminum** — interconnect metal landing on n⁺⁺/p⁺ contacts.

Typical applications:

1. Discrete small-signal amplifiers (audio, RF preamps).
2. Analog ICs (op-amps, references, current mirrors, bandgap circuits).
3. Power output stages (when scaled up).
4. ECL/TTL logic gates (historic).
5. RF/HF where high cut-off frequency is needed (modern variants =
   SiGe HBT but the topology is the same).

```
=== STRUCTURED ===
CONCLUSION: It is a labelled cross-section of a conventional vertical NPN bipolar junction transistor in a junction-isolated bipolar IC technology.
KEY_POINTS:
- Active stack is emitter (n++) over base (p+) over collector (n epi), with an n++ buried layer to lower collector resistance.
- p+ sidewall and p substrate form a reverse-biased junction-isolation cage around the device.
- Used in analog ICs, op-amp / bandgap / current-mirror designs, RF/audio amplifiers, and as the bipolar element in BiCMOS.
CONFIDENCE: high
=== END ===
```

#### Agent: gemini (stand-in)

Diagram caption: *"Conventional npn transistor"* — so the device class is
fixed. What the diagram shows is a **junction-isolated, vertical NPN BJT
fabricated on a p-type silicon substrate with an n-type epitaxial layer
over an n⁺⁺ buried-layer subcollector**.

Layer-by-layer (bottom up):

1. **p substrate** — bulk Si wafer, p-type.
2. **n⁺⁺ buried layer** — diffused into the substrate before epitaxy;
   acts as a low-resistance subcollector.
3. **n epitaxial layer** — the active collector body; lightly doped to
   sustain V<sub>CB</sub>.
4. **p⁺ isolation walls** — diffused down from the surface to meet the
   substrate, partitioning the epi into device tubs.
5. **p⁺ base** — diffused into the epi tub, just under the surface.
6. **n⁺⁺ emitter** — diffused into the base.
7. **n⁺⁺ collector contact (right)** — sinker that connects the surface
   collector contact to the buried layer.
8. **SiO2 passivation** with windows for **aluminium** contacts to B, E,
   C.

Things worth noting about *this* drawing:

- It's a *teaching* figure — it labels every region but does not draw the
  collector sinker as a separate diffusion (the right-hand n⁺⁺ region
  serves both as the buried layer and as the collector contact reach-up).
- The asymmetry of the p⁺ regions ("base" in the middle vs. the two
  outer p⁺ isolation walls) is a common source of student confusion.

```
=== STRUCTURED ===
CONCLUSION: A teaching cross-section of a vertical NPN BJT in a junction-isolated bipolar IC process, with n++ buried layer, n epi collector, p+ base and n++ emitter.
KEY_POINTS:
- Substrate is p-type Si; an n++ buried layer under an n epi forms the low-resistance collector path.
- Active stack is n++ emitter / p+ base / n collector, contacted top-side via SiO2 windows and aluminium.
- The outer p+ ribs are isolation diffusions (not part of the active device); they merge with the substrate to electrically partition this transistor from neighbouring ones.
CONFIDENCE: high
=== END ===
```

### Round 2 — debate

After reading each other's Round 1 answers the three stand-in agents
agree on the device identification and disagree only on **emphasis**:

- *codex* originally underweighted what the **diagram itself** is for
  (a teaching figure). After seeing *gemini*'s point about the figure
  being didactic, it adopts that framing.
- *claude* added a richer applications list. *codex* and *gemini* concede
  the applications belong in the final answer.
- *gemini* flagged that this drawing conflates the buried layer and the
  collector sinker (they are commonly drawn as separate diffusions). The
  others concur this is a simplification, not an error.

Updated, converged structured outputs (all three):

```
=== STRUCTURED ===
CONCLUSION: A labelled cross-section of a conventional vertical NPN bipolar junction transistor (BJT) as fabricated in a junction-isolated bipolar IC process.
KEY_POINTS:
- Active stack is emitter (n++) → base (p+) → collector (n epi) with an n++ buried layer providing the low-resistance path to the surface collector contact.
- p+ sidewall diffusions plus the p substrate form a reverse-biased junction-isolation cage around the device.
- Typical uses: discrete and IC analog amplifiers, op-amps, bandgap references, current mirrors, RF/audio gain stages, and the bipolar element in BiCMOS.
CHANGED_FROM_LAST_ROUND: yes — converged on the device identification and added applications + the note that this is a teaching cross-section.
CONFIDENCE: high
=== END ===
```

### Vote summary

```
Per-agent CONCLUSION lines (after Round 2):
  - codex:  Conventional vertical NPN BJT, junction-isolated bipolar IC process.
  - claude: Conventional vertical NPN BJT, junction-isolated bipolar IC process.
  - gemini: Conventional vertical NPN BJT, junction-isolated bipolar IC process.

Vote groups (normalized): 3 × "conventional vertical npn bjt junction
isolated bipolar ic process"

Plurality: 3/3 agents agree.
```

### Judge — final answer

> The image is a **labelled cross-section of a conventional vertical NPN
> bipolar junction transistor (BJT)** built in a junction-isolated bipolar
> integrated-circuit process.
>
> **Terminals.** Three top-side wire bonds — *B* (Base), *E* (Emitter),
> *C* (Collector) — drop through openings in the **SiO2 passivation** onto
> **aluminium** contacts that land on heavily doped silicon below.
>
> **Active vertical stack** (from the emitter contact down to the
> collector return path):
>
> 1. **n⁺⁺ emitter** — heavily doped, diffused into the base.
> 2. **p⁺ base** — narrow base diffusion under the central emitter window.
> 3. **n epitaxial collector** — lightly doped collector body grown on
>    the substrate; supports the collector–base depletion region under
>    reverse bias.
> 4. **n⁺⁺ buried layer** — predeposited subcollector that gives a low
>    resistance path from the active collector region back up to the
>    surface collector contact on the right.
>
> **Isolation.** The two outer **p⁺** ribs are diffused isolation walls
> that join the **p Si substrate** to form a reverse-biased p–n cage
> around the device, electrically separating it from neighbouring
> transistors on the same chip.
>
> **What this drawing is for.** It is a teaching/handbook figure, not a
> process datasheet — it labels every region but lumps the collector
> sinker into the buried layer for clarity.
>
> **Typical applications.** Discrete small-signal amplifiers (audio, RF
> preamps); analog ICs — op-amps, bandgap references, current mirrors,
> log/translinear circuits; RF gain stages (the same topology scales to
> SiGe HBTs); ECL/TTL logic gates historically; the bipolar device in
> BiCMOS.

```
=== FINAL ===
ANSWER: A labelled cross-section of a conventional vertical NPN bipolar junction transistor (BJT) in a junction-isolated bipolar IC process. Active stack is n++ emitter / p+ base / n epitaxial collector, with an n++ buried subcollector providing a low-resistance path to the surface collector contact on the right; the two outer p+ ribs plus the p substrate form the reverse-biased junction-isolation cage. Typical uses are analog IC building blocks (op-amps, bandgaps, current mirrors), RF/audio amplifier stages, and the bipolar element in BiCMOS.
RATIONALE: All three stand-in agents converged on the same identification and on the same labelling of regions; the only Round-1 disagreements were about emphasis and were resolved in debate.
DISSENTS: none.
CONFIDENCE: high
=== END ===
```

## 7. How to reproduce

```sh
# 1. Install the three subscription CLIs once.
npm i @openai/codex
npm install @google/gemini-cli
curl -fsSL https://claude.ai/install.sh | bash

# 2. Log in interactively to each one (subscription mode, no API keys).
codex   # follow prompts
gemini  # follow prompts
claude  # follow prompts

# 3. Run the orchestrator on the image. The wrappers in lib/agents.sh
#    already apply the section-3 fixes (gemini --skip-trust + claude
#    nested-session env-strip), so this works as-is from inside Claude
#    Code, codespaces, /tmp worktrees, CI runners, etc.
./ensemble.sh \
    --image img/temp.png \
    --agents codex,claude,gemini \
    --rounds 1 \
    --judge claude \
    "Explain what this image shows. Identify the device, label its regions/terminals, and list typical applications."

# Final answer + per-round transcripts land in runs/<timestamp>/.
```

If a CLI is on a non-default path, override it via env vars:

```sh
CODEX_BIN="$(npm root)/.bin/codex" \
GEMINI_BIN="$(npm root)/.bin/gemini" \
CLAUDE_BIN=/home/codespace/.local/bin/claude \
./ensemble.sh --image img/temp.png …
```

The same env-var hooks (`CODEX_ARGS`, `CLAUDE_ARGS`, `GEMINI_ARGS`) let
you adjust flags per CLI without editing the wrapper.
