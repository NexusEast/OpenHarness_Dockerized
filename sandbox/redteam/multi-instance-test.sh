#!/usr/bin/env bash
# Multi-instance + confusion test suite.
#
# Validates that two co-resident sandbox instances are FULLY ISOLATED:
#   - distinct OpenRouter keys, mount lists, $HOME volumes
#   - removing/modifying one does not affect the other
#   - host-side resolution (default / OH_INSTANCE / --oh-instance) is
#     unambiguous and follows the documented priority
#   - same-basename mount collisions get suffixed (/work/foo, /work/foo-2)
#   - sensitive-path mounts are rejected even via tricky inputs
#     (relative paths, symlinks pointing at sensitive dirs, etc.)
#   - ./uninstall.sh only touches OUR containers (label filter), never
#     unrelated containers running on the same daemon
#
# Pass: every check prints `PASS` and the script exits 0.
# Fail: first check that doesn't match expectation prints `FAIL: ...`,
#       prints captured context, and exits 1.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-/root/oh-deploy-test}"
OPENROUTER_API_KEY_FAKE="${OPENROUTER_API_KEY_FAKE:-sk-or-fake-multi-instance-test-key}"
MODEL="${MODEL:-nvidia/nemotron-3-super-120b-a12b:free}"
PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

GREEN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
PASS=0; FAIL=0; FAILED_CHECKS=()

check() {
    # check "name" actual_value expected_value
    local name="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        printf '%s[PASS]%s %s\n' "$GREEN" "$RST" "$name"
        PASS=$((PASS+1))
    else
        printf '%s[FAIL]%s %s\n  expected: %q\n  actual:   %q\n' "$RED" "$RST" "$name" "$expected" "$actual"
        FAIL=$((FAIL+1))
        FAILED_CHECKS+=("$name")
    fi
}

check_contains() {
    # check_contains "name" "haystack" "needle"
    local name="$1" hay="$2" needle="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        printf '%s[PASS]%s %s\n' "$GREEN" "$RST" "$name"
        PASS=$((PASS+1))
    else
        printf '%s[FAIL]%s %s\n  expected to contain: %q\n  actual: %q\n' "$RED" "$RST" "$name" "$needle" "$hay"
        FAIL=$((FAIL+1))
        FAILED_CHECKS+=("$name")
    fi
}

check_not_contains() {
    local name="$1" hay="$2" needle="$3"
    if [[ "$hay" != *"$needle"* ]]; then
        printf '%s[PASS]%s %s\n' "$GREEN" "$RST" "$name"
        PASS=$((PASS+1))
    else
        printf '%s[FAIL]%s %s\n  expected NOT to contain: %q\n  actual: %q\n' "$RED" "$RST" "$name" "$needle" "$hay"
        FAIL=$((FAIL+1))
        FAILED_CHECKS+=("$name")
    fi
}

# Run a command and expect a non-zero exit (negative test).
expect_fail() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '%s[FAIL]%s %s  (expected non-zero exit, got 0)\n' "$RED" "$RST" "$name"
        FAIL=$((FAIL+1)); FAILED_CHECKS+=("$name")
    else
        printf '%s[PASS]%s %s\n' "$GREEN" "$RST" "$name"
        PASS=$((PASS+1))
    fi
}

section() {
    echo
    printf '%s===== %s =====%s\n' "$YEL" "$1" "$RST"
}

# ----- prep -----
section "PREP: clean slate"
docker rm -f oh-default oh-second oh-third oh-rt 2>/dev/null
docker volume rm oh-default-home oh-second-home oh-third-home oh-rt-home 2>/dev/null
rm -rf "$HOME/.openharness-docker" /tmp/multi-test 2>/dev/null
mkdir -p /tmp/multi-test/dirA /tmp/multi-test/dirB /tmp/multi-test/repoA/proj /tmp/multi-test/repoB/proj
echo "marker_dirA"  > /tmp/multi-test/dirA/marker
echo "marker_dirB"  > /tmp/multi-test/dirB/marker
echo "marker_projA" > /tmp/multi-test/repoA/proj/marker
echo "marker_projB" > /tmp/multi-test/repoB/proj/marker
echo "PREP OK"

# ----- A. per-instance secret + state -----
section "A. PER-INSTANCE ISOLATION (secrets, home, lifecycle)"

cd "$REPO_ROOT"
OPENROUTER_API_KEY="${OPENROUTER_API_KEY_FAKE}__default" \
    ./deploy.sh --name default --model "$MODEL" --no-self-update --yes >/dev/null 2>&1
OPENROUTER_API_KEY="${OPENROUTER_API_KEY_FAKE}__second" \
    ./deploy.sh --name second --model "$MODEL" --no-self-update --yes --no-default >/dev/null 2>&1

# A1: distinct OpenRouter keys land in distinct containers
key_default=$(docker exec oh-default cat /oh-home/.oh-runtime/secrets.env 2>/dev/null | grep '^OPENROUTER_API_KEY=' | head -1)
key_second=$(docker exec oh-second  cat /oh-home/.oh-runtime/secrets.env 2>/dev/null | grep '^OPENROUTER_API_KEY=' | head -1)
check "A1.default has __default key"  "$key_default" "OPENROUTER_API_KEY=${OPENROUTER_API_KEY_FAKE}__default"
check "A1.second  has __second  key"  "$key_second"  "OPENROUTER_API_KEY=${OPENROUTER_API_KEY_FAKE}__second"

# A2: distinct home volumes -- write a marker in each, look from the other.
docker exec oh-default sh -c 'echo HELLO_FROM_DEFAULT > /oh-home/marker_default'
docker exec oh-second  sh -c 'echo HELLO_FROM_SECOND  > /oh-home/marker_second'
default_sees_second=$(docker exec oh-default sh -c 'cat /oh-home/marker_second 2>&1' | head -1)
second_sees_default=$(docker exec oh-second  sh -c 'cat /oh-home/marker_default 2>&1' | head -1)
check_contains "A2.default cannot read second's home volume" "$default_sees_second" "No such file"
check_contains "A2.second  cannot read default's home volume" "$second_sees_default" "No such file"

# A3: rm second --purge does not affect default's home volume
oh-ctl rm second --purge >/dev/null 2>&1
default_marker=$(docker exec oh-default cat /oh-home/marker_default 2>&1)
check "A3.default's marker_default still present after second --purge" "$default_marker" "HELLO_FROM_DEFAULT"
default_key_after=$(docker exec oh-default cat /oh-home/.oh-runtime/secrets.env 2>/dev/null | grep '^OPENROUTER_API_KEY=' | head -1)
check "A3.default's secret survives second --purge" "$default_key_after" "OPENROUTER_API_KEY=${OPENROUTER_API_KEY_FAKE}__default"
# second should be completely gone
expect_fail "A3.oh-second container is gone" docker inspect oh-second
expect_fail "A3.oh-second-home volume is gone" docker volume inspect oh-second-home

# Re-create second for the rest of the tests.
OPENROUTER_API_KEY="${OPENROUTER_API_KEY_FAKE}__second" \
    ./deploy.sh --name second --model "$MODEL" --no-self-update --yes --no-default >/dev/null 2>&1

# ----- B. per-instance mount lists -----
section "B. PER-INSTANCE MOUNT LISTS"

oh-ctl mount add /tmp/multi-test/dirA default >/dev/null 2>&1
oh-ctl mount add /tmp/multi-test/dirB second  >/dev/null 2>&1

# B1: default sees /work/dirA, NOT /work/dirB; second sees /work/dirB, NOT /work/dirA
default_dirA=$(docker exec oh-default cat /work/dirA/marker 2>&1)
default_dirB=$(docker exec oh-default cat /work/dirB/marker 2>&1)
second_dirA=$(docker exec  oh-second  cat /work/dirA/marker 2>&1)
second_dirB=$(docker exec  oh-second  cat /work/dirB/marker 2>&1)
check          "B1.default reads /work/dirA"           "$default_dirA" "marker_dirA"
check_contains "B1.default does NOT see /work/dirB"    "$default_dirB" "No such file"
check_contains "B1.second  does NOT see /work/dirA"    "$second_dirA"  "No such file"
check          "B1.second  reads /work/dirB"           "$second_dirB"  "marker_dirB"

# B2: same host path can be mounted to BOTH instances independently
oh-ctl mount add /tmp/multi-test/repoA/proj default >/dev/null 2>&1
oh-ctl mount add /tmp/multi-test/repoA/proj second  >/dev/null 2>&1
default_proj=$(docker exec oh-default cat /work/proj/marker 2>&1)
second_proj=$(docker  exec oh-second  cat /work/proj/marker 2>&1)
check "B2.default sees shared host path /work/proj" "$default_proj" "marker_projA"
check "B2.second  sees shared host path /work/proj" "$second_proj"  "marker_projA"

# B3: oh-ctl mount rm only affects the targeted instance
oh-ctl mount rm /tmp/multi-test/repoA/proj default >/dev/null 2>&1
default_proj_after=$(docker exec oh-default cat /work/proj/marker 2>&1)
second_proj_after=$(docker  exec oh-second  cat /work/proj/marker 2>&1)
check_contains "B3.default no longer sees /work/proj after rm" "$default_proj_after" "No such file"
check          "B3.second  STILL sees /work/proj after default rm" "$second_proj_after" "marker_projA"

# ----- C. same-basename collision -----
section "C. SAME-BASENAME COLLISION HANDLING"

# default already has /work/dirA. Add /tmp/multi-test/repoB/proj to default.
# Then add another path with basename 'proj' -- expect /work/proj-2 (or similar).
oh-ctl mount add /tmp/multi-test/repoB/proj default >/dev/null 2>&1
# Now default already had repoA/proj REMOVED in B3. So now there's only one /work/proj for default.
# Add a SECOND path also named 'proj':
mkdir -p /tmp/multi-test/repoC/proj
echo "marker_projC" > /tmp/multi-test/repoC/proj/marker
oh-ctl mount add /tmp/multi-test/repoC/proj default >/dev/null 2>&1
mounts_json=$(oh-ctl info default | sed -n '/"mounts"/,/]/p')
# Quick visual inspection; precise check is via `oh-ctl mount list`.
list_out=$(oh-ctl mount list default)
check_contains "C.default has /work/proj"   "$list_out" "/work/proj"
check_contains "C.default has /work/proj-2" "$list_out" "/work/proj-2"
# Verify both readable inside the container with distinct content.
proj1=$(docker exec oh-default cat /work/proj/marker 2>&1)
proj2=$(docker exec oh-default cat /work/proj-2/marker 2>&1)
# We can't predict order (depends on jq + insertion order), but the SET of
# values must be {marker_projB, marker_projC}.
sorted=$(printf '%s\n%s\n' "$proj1" "$proj2" | sort | tr '\n' '|' | sed 's/|$//')
check "C.both /work/proj* contain {projB, projC}" "$sorted" "marker_projB|marker_projC"

# ----- D. instance resolution priority -----
section "D. INSTANCE RESOLUTION PRIORITY (shim / oh-ctl exec)"

# Probe: print OH_INSTANCE inside the container -- entrypoint forwards env.
# We test resolution via oh-ctl exec for determinism (the shim adds cwd
# probe; oh-ctl exec doesn't ask cwd questions).
# default is the default; second is not.
# Run oh-ctl exec from a directory that is NOT in any sandbox mount, and
# explicitly redirect stderr (the cwd-not-in-mount warnings would otherwise
# pollute stdout-captured output).
cd /tmp
out=$(oh-ctl exec default -- printenv OH_INSTANCE 2>/dev/null)
out="${out#$'\n'}"  # strip optional leading newline (cwd warning produces one)
check "D1.oh-ctl exec default -> OH_INSTANCE=default" "$out" "default"

out=$(oh-ctl exec second -- printenv OH_INSTANCE 2>/dev/null)
out="${out#$'\n'}"
check "D2.oh-ctl exec second  -> OH_INSTANCE=second"  "$out" "second"
cd "$REPO_ROOT"

# Shim resolution: with default set, no env, no flag -> default.
# Use an empty argv on the shim and inspect docker logs / printenv via oh-ctl exec
# instead, because the shim invokes 'oh' which talks to OpenRouter. We test
# resolve logic directly by sourcing common.sh.
out=$(bash -c '. "'$REPO_ROOT'/scripts/lib/common.sh"; ohd_resolve_instance "" 2>&1')
check "D3.resolve with no override -> default" "$out" "default"
out=$(OH_INSTANCE=second bash -c '. "'$REPO_ROOT'/scripts/lib/common.sh"; ohd_resolve_instance "" 2>&1')
check "D4.resolve with OH_INSTANCE=second -> second" "$out" "second"
out=$(OH_INSTANCE=second bash -c '. "'$REPO_ROOT'/scripts/lib/common.sh"; ohd_resolve_instance "default" 2>&1')
check "D5.explicit arg overrides OH_INSTANCE env" "$out" "default"

# Ambiguous: clear default, ask resolve with no hint, expect non-zero exit.
oh-ctl unset-default >/dev/null 2>&1
set +e
( bash -c '. "'$REPO_ROOT'/scripts/lib/common.sh"; ohd_resolve_instance "" >/dev/null 2>&1' )
rc=$?
set -e
check "D6.no default + multiple instances => resolve fails" "$rc" "3"
oh-ctl set-default default >/dev/null 2>&1

# ----- E. mount-input confusion / negative tests -----
section "E. MOUNT-INPUT CONFUSION (negative tests)"

expect_fail "E1.relative path with ..  (rejected via canonicalization)" \
    oh-ctl mount add /tmp/multi-test/../../etc default

# Symlink pointing at a sensitive dir -- the blacklist rejects symlinks.
ln -sf /etc /tmp/multi-test/sym_to_etc
expect_fail "E2.symlink mount source rejected" \
    oh-ctl mount add /tmp/multi-test/sym_to_etc default

# Mounting a path that already exists on the instance: rejected.
expect_fail "E3.duplicate mount add rejected" \
    oh-ctl mount add /tmp/multi-test/dirA default

# Mounting a non-existent path: rejected.
expect_fail "E4.non-existent host path rejected" \
    oh-ctl mount add /tmp/this/does/not/exist default

# A file (not directory): rejected.
touch /tmp/multi-test/regular_file
expect_fail "E5.regular file (not dir) rejected" \
    oh-ctl mount add /tmp/multi-test/regular_file default

# Sensitive paths.
expect_fail "E6./root rejected"                 oh-ctl mount add /root default
expect_fail "E7./var/run/docker.sock rejected"  oh-ctl mount add /var/run/docker.sock default
expect_fail "E8./home rejected (would expose all home dirs)" oh-ctl mount add /home default
expect_fail "E9./etc rejected"                  oh-ctl mount add /etc default
expect_fail "E10.\$HOME rejected"               oh-ctl mount add "$HOME" default
expect_fail "E11.\$HOME/.ssh rejected"          oh-ctl mount add "$HOME/.ssh" default
# The wrapper repo itself.
expect_fail "E12.wrapper repo root rejected"    oh-ctl mount add "$REPO_ROOT" default

# ----- F. label filtering: uninstall.sh / oh-ctl don't touch unrelated containers -----
section "F. LABEL FILTER (don't touch unrelated containers)"

# Spawn an unrelated container and make sure no OH operation hits it.
# Pull busybox first to avoid first-run race; remove any leftover from a
# prior partial run.
docker rm -f unrelated-busybox-multi-test 2>/dev/null
docker run -d --name unrelated-busybox-multi-test busybox sleep 600 >/dev/null 2>&1
sleep 1
unrelated_running_before=$(docker ps --filter name=unrelated-busybox-multi-test -q | wc -l)
check "F1.unrelated container is running before test" "$unrelated_running_before" "1"

# oh-ctl status must NOT list it
status_out=$(oh-ctl status 2>&1)
check_not_contains "F2.oh-ctl status does NOT mention unrelated container" "$status_out" "unrelated-busybox-multi-test"

# uninstall.sh would remove ALL OH containers. We'll test the intent by
# DRY-RUN listing only the labeled ones (the script itself uses
# --filter label=$OHD_LABEL).
labeled_only=$(docker ps -aq --filter label=dev.openharness.dockerized=1 | wc -l)
all_ctns=$(docker ps -aq | wc -l)
[ "$all_ctns" -gt "$labeled_only" ] \
    && printf '%s[PASS]%s F3.label filter is strictly narrower (labeled=%d total=%d)\n' "$GREEN" "$RST" "$labeled_only" "$all_ctns" \
    || { printf '%s[FAIL]%s F3.label filter not narrower (labeled=%d total=%d)\n' "$RED" "$RST" "$labeled_only" "$all_ctns"; FAIL=$((FAIL+1)); FAILED_CHECKS+=("F3"); }
[ "$all_ctns" -gt "$labeled_only" ] && PASS=$((PASS+1))

# Now actually remove ALL OH containers via oh-ctl rm and confirm the
# unrelated one is untouched. We read instance names directly from the
# config to avoid awk-parsing the human-formatted `oh-ctl list` output.
for n in $(jq -r '.instances | keys[]' "$HOME/.openharness-docker/config.json" 2>/dev/null); do
    [ -z "$n" ] && continue
    oh-ctl rm "$n" >/dev/null 2>&1 || true
done
unrelated_running_after=$(docker ps --filter name=unrelated-busybox-multi-test -q | wc -l)
check "F4.unrelated container still running after oh-ctl rm-all" "$unrelated_running_after" "1"

# Cleanup.
docker rm -f unrelated-busybox-multi-test >/dev/null 2>&1 || true
docker volume rm oh-default-home oh-second-home oh-third-home >/dev/null 2>&1 || true

# ----- summary -----
section "SUMMARY"
total=$((PASS+FAIL))
echo "  pass=$PASS  fail=$FAIL  total=$total"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed checks:"
    for c in "${FAILED_CHECKS[@]}"; do echo "  - $c"; done
    exit 1
fi
exit 0
