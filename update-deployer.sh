#!/usr/bin/env bash
# update-deployer.sh - update THIS wrapper repo (deploy/shim/Dockerfile/scripts).
#
# This pulls the latest version of the OpenHarness_Dockerized repository
# into the current working tree using 'git pull --ff-only'. It does NOT
# touch your OpenHarness runtime image - run update-oh.sh for that.
#
# Usage:
#   ./update-deployer.sh                 # git pull --ff-only origin <current branch>
#   ./update-deployer.sh --remote NAME   # use a different remote (default: origin)
#   ./update-deployer.sh --branch NAME   # check out a specific branch first
#   ./update-deployer.sh --rebase        # use 'git pull --rebase' instead of --ff-only
#
# After pulling, the script:
#   1. Re-applies the executable bit on all *.sh files (helpful on Windows where
#      the working tree's filemode is often dropped).
#   2. Reports whether Dockerfile / entrypoint.sh / shim templates changed, with
#      a hint on what you may want to re-run next.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/scripts/lib/common.sh"

REMOTE="origin"
BRANCH=""
USE_REBASE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --remote) REMOTE="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --rebase) USE_REBASE=1; shift ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown arg: $1" ;;
    esac
done

command -v git >/dev/null 2>&1 || die "git is required for update-deployer."
cd "$HERE"
[ -d .git ] || die "Not a git checkout: $HERE  (did you download a release zip instead of cloning?)"

current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
if [ "$current_branch" = "HEAD" ]; then
    die "Detached HEAD - check out a branch first (e.g. 'git checkout main')."
fi

if [ -n "$BRANCH" ] && [ "$BRANCH" != "$current_branch" ]; then
    info "Switching from '$current_branch' to '$BRANCH'..."
    git checkout "$BRANCH"
    current_branch="$BRANCH"
fi

# Refuse to pull on top of dirty changes - too easy to silently lose work.
if ! git diff --quiet || ! git diff --cached --quiet; then
    err "Working tree has uncommitted changes. Commit/stash them first."
    git status --short
    exit 1
fi

before="$(git rev-parse HEAD)"

info "Fetching from '$REMOTE'..."
git fetch --prune "$REMOTE"

if [ "$USE_REBASE" -eq 1 ]; then
    info "Rebasing onto '$REMOTE/$current_branch'..."
    git pull --rebase "$REMOTE" "$current_branch"
else
    info "Fast-forwarding to '$REMOTE/$current_branch'..."
    git pull --ff-only "$REMOTE" "$current_branch"
fi

after="$(git rev-parse HEAD)"

if [ "$before" = "$after" ]; then
    ok "Already up to date ($after)."
    exit 0
fi

ok "Updated: $before -> $after"

# 1. Re-apply executable bit on shell scripts in the working tree
#    (git already stores them as 100755, but Windows checkouts may need this
#     when the script is run via WSL/bash).
if command -v chmod >/dev/null 2>&1; then
    while IFS= read -r f; do
        [ -f "$f" ] && chmod +x "$f" 2>/dev/null || true
    done < <(git ls-files '*.sh')
fi

# 2. Report whether the runtime / shim layout changed so the user knows what
#    follow-up commands to run.
changed_files="$(git diff --name-only "$before" "$after")"
need_update_oh=0
need_reinstall_shims=0
if printf '%s\n' "$changed_files" | grep -qE '^(docker/Dockerfile|docker/entrypoint\.sh|docker/\.dockerignore)$'; then
    need_update_oh=1
fi
if printf '%s\n' "$changed_files" | grep -qE '^scripts/(lib/(common\.sh|shim_template\.sh)|install-shims\.sh|oh-ctl\.sh)$'; then
    need_reinstall_shims=1
fi

echo
info "Changed files:"
printf '  %s\n' $changed_files
echo

if [ "$need_update_oh" -eq 1 ]; then
    warn "Container runtime files changed."
    info "  -> rebuild image + recreate all instances:  ./update-oh.sh"
fi
if [ "$need_reinstall_shims" -eq 1 ]; then
    warn "Host shim / oh-ctl files changed."
    info "  -> reinstall shims:                          ./scripts/install-shims.sh --repo $HERE"
fi
if [ "$need_update_oh" -eq 0 ] && [ "$need_reinstall_shims" -eq 0 ]; then
    ok "No container or shim files changed; nothing else to do."
fi
