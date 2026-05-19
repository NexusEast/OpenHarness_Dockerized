# CLAUDE.md

This file is auto-discovered and injected by OpenHarness (`oh`) and any
other Claude-Code-compatible agent that opens this repository. Keep it
concise; it becomes part of the system prompt for every session that
runs here.

## What this repo is

A **hardened Docker sandbox** for [HKUDS/OpenHarness](https://github.com/HKUDS/OpenHarness).
It does **not** contain any OpenHarness source code. It builds an image
that `pip install openharness-ai`, runs that image as a long-lived
sandboxed container, and installs host-side shims (`oh`, `ohmo`, `openh`,
`openharness`, `oh-ctl`) that forward to `docker exec`.

End-goal: a host user types `oh ...` and gets a useful agentic
experience — but the agent inside has **no access** to the host
filesystem unless the user explicitly mounts paths into the sandbox.

Only **OpenRouter** is supported as the LLM backend.

Supported hosts: macOS, Linux, WSL2, Windows PowerShell.

## Repo layout (must-know)

```
deploy.sh / deploy.ps1         interactive wizard (multi-instance aware)
status.sh|.ps1, restart.sh|.ps1, update-oh.sh|.ps1, update-deployer.sh|.ps1, uninstall.sh|.ps1
setup-permissions.sh           chmod +x for everything (Windows clone helper)
Makefile                       *nix convenience targets

docker/
├── Dockerfile                 hardened sandbox image (UID 1000 baked in, no sudo)
└── entrypoint.sh              refuses to run as root; loads /oh-home/.oh-runtime/secrets.env

scripts/
├── oh-ctl.sh / oh-ctl.ps1     multi-instance control + `mount add/list/rm`
├── install-shims.sh / Install-Shims.ps1
└── lib/
    ├── common.sh              shared library: blacklist, /work/<name> mapping, exec helper
    ├── Common.psm1            ps1 mirror of common.sh
    └── shim_template.{sh,ps1} forwarder shim, baked into ~/.local/bin/{oh,ohmo,openh,...}

SECURITY.md                    threat model, isolation contract, attack list
docs/ARCHITECTURE.md           design rationale and trade-offs
README.md                      user-facing usage
sandbox/redteam/               LLM-driven escape rig used to validate the design
```

## Hard rules / invariants (don't break these)

0. **English-only project.** All commit messages, PR titles/descriptions,
   issue text, code comments, log output and user-visible strings are
   written in **English**. Do not introduce Chinese (or other localized)
   text into commits or source files even if the user prompts in
   another language.
1. **No OpenHarness source code in this repo.** The image must always
   pull `openharness-ai` from PyPI via `pip install`. Do not vendor it.
2. **The isolation contract** in `SECURITY.md` is the contract for the
   whole project. If you change anything in `docker/`,
   `scripts/lib/common.sh`, `scripts/lib/Common.psm1`, `deploy.sh`, or
   `deploy.ps1`, you MUST keep this list valid:
   - container runs as UID 1000 (`--user 1000:1000`)
   - `--cap-drop=ALL --security-opt=no-new-privileges:true`
   - `--read-only` rootfs; `/tmp` and `/run` are tmpfs `nosuid,nodev,noexec`
   - HOME is a Docker named volume, not a host bind-mount
   - host-side mounts go through `ohd_assert_mount_safe` (sh) /
     `Assert-OhdMountSafe` (ps1); the sensitive-paths list there must
     stay strictly inclusive — adding new sensitive paths is fine,
     removing one needs a SECURITY.md update and a red-team re-run
   - cloud-metadata IPs (`169.254.169.254`, `metadata.*`) blackholed
     via `--add-host`
   - `--pid=host`, `--privileged`, `--network=host`, mounting
     `/var/run/docker.sock` are all REJECTED
   - container hostname / labels stay `dev.openharness.dockerized=1` +
     `dev.openharness.sandbox=1` + `dev.openharness.instance=<name>` so
     `docker ps`/`docker rm` filters never touch unrelated containers
3. **Host paths inside the container** appear at `/work/<basename>`.
   Multiple mounts with the same basename get suffixed `-2`, `-3`. We
   deliberately **do not** mirror host paths (no `/data/proj` ->
   `/data/proj` mapping). This is to:
     - avoid leaking host filesystem layout into the agent's context;
     - prevent users from confusing host paths with in-container paths.
4. **Container naming**: `oh-<instance-name>`. The default instance name
   is `default`, so the first container is typically `oh-default`.
5. **Persistent metadata** lives in `~/.openharness-docker/config.json`
   (Windows: `%USERPROFILE%\.openharness-docker\config.json`). Schema:
   ```json
   {
     "version": 2,
     "default_instance": "<name|null>",
     "instances": {
       "<name>": {
         "image": "...", "container": "oh-<name>",
         "home_volume": "oh-<name>-home",
         "model": "...",
         "network": "bridge|none",
         "openrouter_key_set": "yes",
         "wrapper_repo": "...",
         "created_at": "...",
         "mounts": [
           { "host": "/data/proj", "target": "/work/proj", "readonly": false }
         ]
       }
     }
   }
   ```
6. **User identity inside the container** is `ohuser` (UID 1000) baked
   in at build time. There is no usermod-at-runtime. There is no sudo
   in the image.
7. **PowerShell stdout gotcha**: PowerShell functions capture
   external-command stdout into the pipeline as return value. Shims
   must therefore build the docker argv inside a function
   (`Get-OhdExecArgs`) and run `& docker @argv` at the **top level** so
   streams reach the user's console. Don't wrap it back inside a
   function.
8. **Per-instance HOME isolation**. Each instance has its own
   `oh-<name>-home` Docker named volume. Two instances never share
   `~/.openharness` or `~/.ohmo`. `oh-ctl rm <name> --purge` deletes
   the volume; without `--purge` it survives container recreate.
9. **Secrets land in /oh-home**, not on host disk.
   `OPENROUTER_API_KEY` is written via `docker exec -i ... cat > FILE`
   so the resulting `/oh-home/.oh-runtime/secrets.env` is owned by UID
   1000 mode 0400. We never use `docker cp` for it (because the
   landed-as-root file would then need `chown`, which `cap-drop=ALL`
   makes impossible without rebuilding).

## Common dev commands

```bash
# Full wizard (interactive)
./deploy.sh                          # *nix
.\deploy.ps1                         # PowerShell

# Non-interactive (CI / testing). Prefer the env var for the key, NOT
# --openrouter-key on the command line (it shows up in `ps`).
OPENROUTER_API_KEY=sk-or-... ./deploy.sh \
    --name default --model anthropic/claude-3.5-sonnet --yes

$env:OPENROUTER_API_KEY='sk-or-...'
.\deploy.ps1 -Name default -Model anthropic/claude-3.5-sonnet -Yes

# Image-only rebuild
docker build --build-arg SANDBOX_UID=1000 --build-arg SANDBOX_GID=1000 \
             -t openharness-dockerized:latest ./docker

# Inspect / debug
oh-ctl list
oh-ctl status
oh-ctl logs                          # default instance
oh-ctl shell                         # interactive bash inside the sandbox
oh-ctl exec <name> -- oh provider list
oh-ctl mount add /data/proj          # adds a sandbox mount, recreates container
oh-ctl mount list
oh-ctl mount rm /data/proj
```

## Testing notes

The sandbox has been red-team validated against:

- `nvidia/nemotron-3-super-120b-a12b:free`: three rounds (naive /
  informed / white-box) — all `HELD`, max_turns reached without any
  canary exfiltration.
- `anthropic/claude-opus-4.7`: three rounds — all `HELD`. Rounds 1 and
  2 ended with the model voluntarily emitting `give_up`. Round 3 used
  white-box hints (full deploy config disclosed) and ended at turn 34
  due to OpenRouter budget exhaustion, with 0 escape primitives found.

To rerun: see `sandbox/redteam/run-round.sh` and
`sandbox/redteam/final-forensics.sh`. Always rerun against the highest
model you're willing to pay for after any change to `docker/`,
`scripts/lib/`, or `deploy.{sh,ps1}`.

## Don't

- Don't add a `# syntax=docker/dockerfile:1.6` line to the Dockerfile —
  it forces BuildKit to fetch the frontend image, which fails in
  network-restricted environments. The default frontend is enough.
- Don't `Resolve-Path` paths that don't exist yet (e.g. files we are
  about to write). Use `[System.IO.Path]::GetFullPath` instead.
- Don't `docker cp` files that the in-container UID needs to read.
  The cap-drop layer prevents the post-cp `chown`. Pipe via
  `docker exec -i ... cat > FILE` instead.
- Don't ship a shim literally named `oh` on Windows — it collides with
  the PowerShell built-in `Out-Host` alias. Use `openh` there.
- Don't bind-mount any host path that isn't passed through
  `ohd_assert_mount_safe` (sh) / `Assert-OhdMountSafe` (ps1). If you
  add a new code path that mounts something, it MUST go through that
  guard.
- Don't add a "share-home" mode. There used to be one; it was removed
  for a reason. The agent inside the container is treated as actively
  hostile.
