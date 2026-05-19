#!/usr/bin/env bash
# Integration test of the new sh deploy + oh-ctl + shims.
set -euo pipefail
export PATH="/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

mkdir -p /tmp/oh-testproj
echo "hello world" > /tmp/oh-testproj/readme.txt

echo "============================================================"
echo " A. oh-ctl list"
echo "============================================================"
oh-ctl list

echo
echo "============================================================"
echo " B. oh-ctl info default"
echo "============================================================"
oh-ctl info default

echo
echo "============================================================"
echo " C. NEGATIVE: oh-ctl mount add /root      (must reject)"
echo "============================================================"
if oh-ctl mount add /root 2>&1 | tail -5; then :; fi
echo "(returned exit=$?)"

echo
echo "============================================================"
echo " D. NEGATIVE: oh-ctl mount add /var/run/docker.sock  (must reject)"
echo "============================================================"
if oh-ctl mount add /var/run/docker.sock 2>&1 | tail -5; then :; fi
echo "(returned exit=$?)"

echo
echo "============================================================"
echo " E. NEGATIVE: oh-ctl mount add /home  (must reject -- ancestor of $HOME)"
echo "============================================================"
if oh-ctl mount add /home 2>&1 | tail -5; then :; fi
echo "(returned exit=$?)"

echo
echo "============================================================"
echo " F. POSITIVE: oh-ctl mount add /tmp/oh-testproj"
echo "============================================================"
oh-ctl mount add /tmp/oh-testproj 2>&1 | tail -15

echo
echo "============================================================"
echo " G. oh-ctl mount list"
echo "============================================================"
oh-ctl mount list default

echo
echo "============================================================"
echo " H. cd into the mount and run a command via oh-ctl exec"
echo "============================================================"
cd /tmp/oh-testproj
oh-ctl exec default -- ls -la /work/oh-testproj/
oh-ctl exec default -- cat /work/oh-testproj/readme.txt

echo
echo "============================================================"
echo " I. The shim resolves cwd correctly when inside a mounted dir"
echo "    (we simulate with: cd into mount, run a sandboxed bash)"
echo "============================================================"
# Use "oh-ctl exec" with a pwd query rather than the shim itself, since the
# shim invokes `oh` which talks to OpenRouter; we just want to validate the
# cwd-mapping.
cd /tmp/oh-testproj
docker exec -w /work/oh-testproj oh-default oh-entrypoint exec -- pwd
docker exec -w /work/oh-testproj oh-default oh-entrypoint exec -- ls

echo
echo "============================================================"
echo " J. Sensitive-path defense still active inside container"
echo "============================================================"
docker exec oh-default sh -c 'ls /root 2>&1; ls /var/run/docker.sock 2>&1; cat /proc/self/status | grep CapBnd'

echo
echo "============================================================"
echo " K. oh-ctl mount rm /tmp/oh-testproj"
echo "============================================================"
oh-ctl mount rm /tmp/oh-testproj 2>&1 | tail -5
oh-ctl mount list default

echo
echo "ALL DONE."
