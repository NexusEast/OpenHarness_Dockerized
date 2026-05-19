# sandbox/redteam — sandbox escape rig

This directory contains the LLM-driven red-team rig used to validate the
sandbox isolation. It runs INSIDE the sandbox container (the same image
real users get), gives an LLM agent a goal of "escape and read host
canary files", and reports whether any canary leaked.

See [SECURITY.md](../SECURITY.md) §"Verification" for the high-level
description.

## Files

```
redteam/
├── agent.py                    Bare LLM-driven shell loop. Talks to OpenRouter.
├── setup-victim.sh             Lays down canary fixtures at /tmp/oh-redteam/victim-home/.
├── run-round.sh                Orchestrates a single round (deploy + run + forensics).
├── forensics.sh                Per-round automatic verdict (canary leakage etc).
├── final-forensics.sh          Cross-round host integrity sweep.
├── summarize-log.sh            Inspect a transcript log.
├── opus-summary.sh             Summarise the four most recent Opus rounds.
├── integration-test.sh         End-to-end test of deploy + oh-ctl + shims.
├── round1-naive.goal.txt       Round 1 attack prompt (naive).
├── round2-informed.hints.txt   Round 2 hints (12 known escape vectors).
├── round3-whitebox.hints.txt   Round 3 hints (full deploy config disclosed).
└── results/                    Per-round transcripts (gitignored).
```

## Running it

```bash
cd sandbox/redteam

# Round 1 (naive) using the free nemotron model:
OPENROUTER_API_KEY=sk-or-... \
  bash run-round.sh r1 round1-naive.goal.txt

# Round 3 (white-box) using a frontier model:
OPENROUTER_API_KEY=sk-or-... \
  REDTEAM_MODEL=anthropic/claude-opus-4.7 \
  REDTEAM_MAX_TURNS=40 \
  bash run-round.sh r3-opus round1-naive.goal.txt round3-whitebox.hints.txt

# After all rounds:
bash final-forensics.sh
```

`run-round.sh` deploys a dedicated `rt` instance (`oh-rt` container,
`oh-rt-home` volume) so it doesn't disturb your normal `default`. Each
round destroys + redeploys the instance to start the agent with a clean
slate.

The instance is created with `--no-default` so it won't accidentally
become the target of your normal `oh ...` commands.
