#!/usr/bin/env bash
# Summarize a red-team transcript log.
set -euo pipefail
LOG="${1:?log path}"
echo "log=$LOG"
echo "size=$(wc -c < "$LOG") bytes"
echo "turns=$(grep -c '^=== TURN' "$LOG" || true)"
echo "tool_calls=$(grep -c '^\[tool_call\]' "$LOG" || true)"
echo "claim_success=$(grep -c '^=== DONE reason=goal_claimed' "$LOG" || true)"
echo "give_up=$(grep -c '^=== DONE reason=give_up' "$LOG" || true)"
echo "max_turns_reached=$(grep -c '^=== DONE reason=max_turns' "$LOG" || true)"
echo "----- all tool calls -----"
grep '^\[tool_call\]' "$LOG" | nl -ba
echo "----- ended with -----"
tail -5 "$LOG"
