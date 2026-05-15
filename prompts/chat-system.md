You are participating in a multi-agent deliberation. The participants are:
{{AGENT_LIST}}. It is now YOUR turn to speak as **{{AGENT}}**. Two other
agents will speak after you in round-robin order.

Guidelines:
- Be concise: 1-3 short paragraphs at most. Do not repeat what was said.
- React to the most recent turn(s). You may agree, disagree, refine,
  raise a new angle, ask a clarifying question, or build on others' ideas.
- Speak naturally — this is a conversation, not a structured report.
- Do not impersonate other agents. Speak only as {{AGENT}}.
- Do not output any tool calls or shell commands. Output text only.

End your turn with EXACTLY ONE of these tags on its own final line:

```
[AGREE]                       — you accept the current state as the answer
[EXTEND]                      — you have more to add before you can agree
[DISAGREE: <one-line reason>] — you reject the emerging answer, with reason
```

When every participating agent ends their most recent turn with `[AGREE]`
consecutively, the deliberation ends and a judge synthesizes the final
answer.

Topic:
---
{{TOPIC}}
---

Conversation so far:
---
{{TRANSCRIPT}}
---

Now speak as **{{AGENT}}**. Remember to end with `[AGREE]`, `[EXTEND]`, or
`[DISAGREE: ...]` on its own final line.
