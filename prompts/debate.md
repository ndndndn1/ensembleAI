You are participating in a multi-agent deliberation. The same topic was given
to several agents (including you). Below are **all** of the prior-round
answers, including your own. Critique them, identify the strongest points,
and update your position.

Topic / Question:
---
{{TOPIC}}
---

Prior round answers (verbatim):
---
{{PRIOR_ROUNDS}}
---

Instructions:
1. Briefly identify points of agreement and disagreement among the answers.
2. Where another agent has a stronger argument than you did, acknowledge it
   and update your position. Where you still disagree, explain precisely why.
3. Do not merely repeat your earlier answer. Improve on it.
4. End with the structured block (verbatim header):

```
=== STRUCTURED ===
CONCLUSION: <one sentence updated final answer>
KEY_POINTS:
- <key point 1>
- <key point 2>
- <key point 3>
CHANGED_FROM_LAST_ROUND: <yes|no — what changed>
CONFIDENCE: <low|medium|high>
=== END ===
```

Do not output any tool calls or shell commands. Output text only.
