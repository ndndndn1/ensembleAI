# Debate — `img/temp.png`

A worked example of running the three subscription CLIs (`codex`, `claude`,
`gemini`) on a single image input and aggregating their answers via the
ensembleAI debate protocol.

- **Topic** — *"Explain what this image shows. Identify the device, label its
  regions/terminals, and list typical applications."*
- **Image** — [`img/temp.png`](../img/temp.png) (cross-section diagram of a
  semiconductor device)

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
syntax:

| Agent  | Effective command (per round)                                         |
| ------ | --------------------------------------------------------------------- |
| codex  | `printf '%s\n' "$prompt" \| codex exec --yolo --image img/temp.png -` |
| claude | `claude --dangerously-skip-permissions -p "img/temp.png $prompt"`     |
| gemini | `gemini --approval-mode=yolo -p "@img/temp.png $prompt"`              |

## 3. Live run output (this sandbox)

This sandbox has the CLIs installed via `npm install` (`@openai/codex`,
`@google/gemini-cli`, plus `claude` from the official installer) but **no
subscription credentials** are available, so all three agents fail at the
auth step. The orchestrator handles this gracefully — each agent's slot is
filled with a synthetic `STRUCTURED` block reading "agent failed", the
majority vote degenerates to a 3-way tie, and the judge step likewise
fails, so `final.md` is emitted as a vote-only fallback.

Captured stderr from `runs/img-debate/round1/`:

```text
# codex.err
OpenAI Codex v0.129.0 (research preview)
ERROR: unexpected status 401 Unauthorized: Missing bearer or basic
authentication in header, url: https://api.openai.com/v1/responses

# gemini.err
Please set an Auth method in your /root/.gemini/settings.json or specify
one of the following environment variables before running: GEMINI_API_KEY,
GOOGLE_GENAI_USE_VERTEXAI, GOOGLE_GENAI_USE_GCA

# claude.err
--dangerously-skip-permissions cannot be used with root/sudo privileges
for security reasons
```

When the user re-runs the same command on a workstation where all three
CLIs are logged in (and not running as root for `claude`), the same
`runs/<timestamp>/` layout will be produced with real per-agent answers,
a real majority vote, and a real judge synthesis.

## 4. Stand-in deliberation (multimodal, Claude Opus 4.7)

Because the three live CLIs cannot authenticate in this environment, the
following debate is performed by a **single multimodal model** taking on
each agent role in sequence, with the same Round 1 / Debate / Judge
protocol the orchestrator would use. This is *not* a substitute for the
real ensemble — it is provided so the example file is informative rather
than empty.

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

## 5. How to reproduce

```sh
# 1. Install the three subscription CLIs once.
npm i @openai/codex
npm install @google/gemini-cli
curl -fsSL https://claude.ai/install.sh | bash

# 2. Log in interactively to each one (subscription mode, no API keys).
codex   # follow prompts
gemini  # follow prompts
claude  # follow prompts

# 3. Run the orchestrator on the image.
./ensemble.sh \
    --image img/temp.png \
    --agents codex,claude,gemini \
    --rounds 1 \
    --judge claude \
    "Explain what this image shows. Identify the device, label its regions/terminals, and list typical applications."

# Final answer + per-round transcripts land in runs/<timestamp>/.
```
