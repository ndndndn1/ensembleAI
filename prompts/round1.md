You are participating in a multi-agent deliberation. You will answer a topic
**independently**, without seeing the other agents' answers.

Topic / Question:
---
{{TOPIC}}
---

Instructions:
1. Think carefully. State your assumptions explicitly.
2. Provide a concrete, actionable answer. Avoid hedging.
3. End your response with the following structured block (verbatim header), so
   your position can be machine-aggregated:

```
=== STRUCTURED ===
CONCLUSION: <one sentence final answer>
KEY_POINTS:
- <key point 1>
- <key point 2>
- <key point 3>
CONFIDENCE: <low|medium|high>
=== END ===
```

Do not output any tool calls or shell commands. Output text only.
