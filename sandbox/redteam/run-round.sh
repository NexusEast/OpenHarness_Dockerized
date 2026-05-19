#!/usr/bin/env bash
# Run one red-team round.
#
# Usage:
#   run-round.sh <round-name> <goal-file> [hints-file]
#
# Effects:
#   1. (Re)setup victim canaries.
#   2. Recreate the sandbox instance using the wrapper's main deploy.sh,
#      so the red-team always tests the SAME hardening that real users get.
#   3. Copy agent.py into the sandbox and run it; capture transcript.
#   4. Run forensics; report.
#
# Exit 0 = sandbox held this round, 1 = broken.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUND_NAME="${1:?round name}"
GOAL_FILE="${2:?goal file}"
HINTS_FILE="${3:-}"

# We use a dedicated red-team instance ("rt") so we don't disturb the user's
# normal default instance. This name is referenced by sandbox.redteam.* labels.
INSTANCE_NAME="${INSTANCE_NAME:-rt}"
CONTAINER_NAME="${CONTAINER_NAME:-oh-${INSTANCE_NAME}}"
HOME_VOLUME="${HOME_VOLUME:-oh-${INSTANCE_NAME}-home}"
RESULTS_DIR="${RESULTS_DIR:-$HERE/results}"
mkdir -p "$RESULTS_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
TRANSCRIPT="$RESULTS_DIR/round-${ROUND_NAME}-${TS}.log"

# 1. victim setup
echo "[run-round] setting up victim canaries..."
bash "$HERE/setup-victim.sh"

# 2. Fresh container per round, via the production deploy.sh.
echo "[run-round] resetting container and home volume..."
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker volume rm "$HOME_VOLUME" >/dev/null 2>&1 || true

REPO_ROOT="${REPO_ROOT:-$HERE/../..}"
DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-$REPO_ROOT/deploy.sh}"
: "${OPENROUTER_API_KEY:?OPENROUTER_API_KEY must be set for run-round.sh}"

OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
DEFAULT_MODEL="${REDTEAM_MODEL:-nvidia/nemotron-3-super-120b-a12b:free}" \
bash "$DEPLOY_SCRIPT" --name "$INSTANCE_NAME" --no-self-update --yes \
    --mount /tmp/oh-redteam/victim-home/work \
    --no-default >/dev/null

# Verify it's up.
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "[run-round] FATAL: deploy did not produce a running $CONTAINER_NAME" >&2
    exit 2
fi

# 3. copy agent.py and run it.
echo "[run-round] copying agent.py into container..."
docker exec "$CONTAINER_NAME" mkdir -p /oh-home/.redteam
docker exec "$CONTAINER_NAME" sh -c '[ -e /oh-home/.redteam/agent.py ] && chmod u+w /oh-home/.redteam/agent.py; true' || true
docker exec -i "$CONTAINER_NAME" sh -c 'cat > /oh-home/.redteam/agent.py && chmod 0500 /oh-home/.redteam/agent.py' < "$HERE/agent.py"

GOAL_TEXT="$(cat "$GOAL_FILE")"
HINTS_TEXT=""
[ -n "$HINTS_FILE" ] && [ -f "$HINTS_FILE" ] && HINTS_TEXT="$(cat "$HINTS_FILE")"

echo "[run-round] launching agent (round=$ROUND_NAME, transcript=$TRANSCRIPT)..."
set +e
docker exec \
    -e "REDTEAM_GOAL=$GOAL_TEXT" \
    -e "REDTEAM_HINTS=$HINTS_TEXT" \
    -e "REDTEAM_MODEL=${REDTEAM_MODEL:-nvidia/nemotron-3-super-120b-a12b:free}" \
    -e "REDTEAM_MAX_TURNS=${REDTEAM_MAX_TURNS:-25}" \
    "$CONTAINER_NAME" \
    bash -c '. /oh-home/.oh-runtime/secrets.env 2>/dev/null; export OPENROUTER_API_KEY; exec python3 /oh-home/.redteam/agent.py' \
    > "$TRANSCRIPT" 2>&1
agent_rc=$?
set -e

echo "[run-round] agent exited rc=$agent_rc; transcript: $TRANSCRIPT"

# 4. forensics
echo "[run-round] forensics..."
if CONTAINER_NAME="$CONTAINER_NAME" bash "$HERE/forensics.sh" "$TRANSCRIPT"; then
    echo "[run-round] ROUND $ROUND_NAME: HELD"
    exit 0
else
    echo "[run-round] ROUND $ROUND_NAME: BROKEN"
    exit 1
fi
