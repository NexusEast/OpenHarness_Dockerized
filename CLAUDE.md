# CLAUDE.md

This file is auto-discovered and injected by OpenHarness (`oh`) and any other
Claude-Code-compatible agent that opens this repository. Keep it concise; it
becomes part of the system prompt for every session that runs here.

## What this repo is

A **Dockerized wrapper** around [HKUDS/OpenHarness](https://github.com/HKUDS/OpenHarness).
It does **not** contain any OpenHarness source code. It builds an image that
`pip install openharness-ai`, runs that image as a long-lived container, and
installs host-side shims (`oh`, `ohmo`, `openh`, `openharness`, `oh-ctl`) that
transparently forward to `docker exec`.

End-goal: a host user can type `oh ...` and get behaviour indistinguishable
from a native install, while everything actually runs in a container.

Only **OpenRouter** is supported as the LLM backend.

Supported hosts: macOS, Linux, WSL, Windows PowerShell.

## Repo layout (must-know)

```
deploy.sh / deploy.ps1         interactive wizard (multi-instance aware)
status.sh|.ps1, restart.sh|.ps1, update-oh.sh|.ps1, update-deployer.sh|.ps1, uninstall.sh|.ps1
setup-permissions.sh           chmod +x for everything (Windows clone helper)
Makefile                       *nix convenience targets

docker/
├── Dockerfile                 pip install openharness-ai + ohuser (uid resync at runtime)
├── entrypoint.sh              idle / exec / ohmo-gateway; usermod on start
└── .dockerignore

scripts/
├── oh-ctl.sh / oh-ctl.ps1     multi-instance control: list/set-default/exec/status/...
├── install-shims.sh / Install-Shims.ps1
└── lib/
    ├── common.sh              shared library for *nix scripts
    ├── Common.psm1            shared PowerShell module (mirrors common.sh)
    └── shim_template.{sh,ps1} templates baked into installed shims

docs/ARCHITECTURE.md           design decisions, why things are the way they are
README.md                      user-facing usage
```

## Hard rules / invariants (don't break these)

0. **English-only project.** All commit messages, PR titles/descriptions,
   issue text, code comments, log output and user-visible strings are written
   in **English**. The repo is open-sourced under that assumption; do not
   introduce Chinese (or other localized) text into commits or source files
   even if the user prompts in another language.
1. **No OpenHarness source code in this repo.** The image must always pull
   `openharness-ai` from PyPI via `pip install`. Do not vendor it.
2. **Three-way isolation** (wrapper repo ⟂ OH source ⟂ user workspace):
   - The OH runtime lives **only inside the image** (`/usr/local/lib/.../site-packages/openharness/`).
   - This wrapper repo is **never readable or writable from a container**.
     The deploy wizards automatically overlay a tmpfs at the wrapper repo
     path and at `~/.openharness-docker` when those paths fall inside a
     bind-mount. Do not remove this guard. If you add new bind-mounts
     (e.g. additional `--extra-mount` paths), make sure
     `_is_visible_inside_container` (sh) and `$isInsideMounted` (ps1)
     in `deploy.sh` / `deploy.ps1` consider them as well.
   - The user workspace under `$HOME` (and anything they `--extra-mount`)
     is intentionally R/W shared with the container; that's the
     transparency contract of `oh`.
   - **Per-instance OH state** (`~/.openharness`, `~/.ohmo`) is NOT shared
     between instances. Each container gets its own host-side directory at
     `$HOME/.openharness-instances/<name>/{openharness,ohmo}/` bind-mounted
     ON TOP OF the inherited $HOME mount, at the in-container paths
     `~/.openharness` and `~/.ohmo`. This prevents the second `deploy` from
     overwriting the first instance's provider profile / ohmo memory.
     `oh-ctl rm --purge` deletes that per-instance dir along with the
     container.
3. **Container path == host path** (transparency contract). On *nix it's literal
   (`-v $HOME:$HOME`). On Windows the source must be the **Windows** path
   (`C:\Users\foo`) and the destination must be the **Linux** path
   (`/mnt/c/Users/foo`). Putting `/mnt/c/...` as the bind-mount *source* on
   Docker Desktop is a documented trap — it mounts the entire drive as ext4 and
   the container will not see real files.
3. **All containers carry the label `dev.openharness.dockerized=1`** and a
   second label `dev.openharness.instance=<name>`. Every `docker ps`/`docker rm`
   our scripts run must filter by that label so we never touch unrelated
   containers.
4. **Container naming**: `oh-<instance-name>`. The default instance name is
   `default`, so the first container is typically `oh-default`.
5. **Persistent metadata** lives in `~/.openharness-docker/config.json`
   (Windows: `%USERPROFILE%\.openharness-docker\config.json`). Schema:
   ```json
   {
     "version": 1,
     "default_instance": "<name|null>",
     "instances": {
       "<name>": {
         "image": "...", "container": "oh-<name>", "model": "...",
         "host_home": "...", "mount_source": "...",
         "host_uid": "...", "host_gid": "...",
         "openrouter_key_set": "yes",
         "created_at": "...", "platform": "..."
       }
     }
   }
   ```
6. **User identity inside the container** is `ohuser` baked in at build time.
   The entrypoint resyncs its UID/GID to `HOST_UID`/`HOST_GID` on startup so
   the same image works for any host user (including root with UID 0).
7. **PowerShell stdout gotcha**: PowerShell functions capture external-command
   stdout into the pipeline as return value. Shims must therefore build the
   docker argv inside a function (`Get-OhdExecArgs`) and run `& docker @argv`
   at the **top level** so streams reach the user's console. Don't wrap it
   back inside a function.
8. **CWD fallback**: before `docker exec -w <path>`, probe with
   `docker exec <c> test -d <path>`. If it fails, fall back to `host_home` and
   print a warning telling the user to `--extra-mount` it. Never let docker
   throw the cryptic `chdir failed`.

## Common dev commands

```bash
# Full wizard (interactive)
./deploy.sh                      # *nix
.\deploy.ps1                     # PowerShell

# Non-interactive (CI / testing)
./deploy.sh --name oh-default --openrouter-key sk-or-... --model anthropic/claude-3.5-sonnet --yes
.\deploy.ps1 -Name oh-default -OpenrouterKey sk-or-... -Model anthropic/claude-3.5-sonnet -Yes

# Image-only rebuild
docker build --build-arg HOST_UID=$(id -u) --build-arg HOST_GID=$(id -g) \
             --build-arg HOST_USER=ohuser --build-arg HOST_HOME=$HOME \
             -t openharness-dockerized:latest ./docker

# Inspect / debug
oh-ctl list
oh-ctl status
oh-ctl logs                       # default instance
oh-ctl shell                      # interactive bash in container
oh-ctl exec <name> -- oh provider list
```

## Testing notes (verified on this machine)

E2E was run from both PowerShell (Windows) and WSL Debian against the same
Docker Desktop daemon. Verified:

- two-instance deploy + default-instance switching
- `openh` / `oh` / `ohmo` / `oh-ctl` shims transparent stdout/stderr
- bind-mount read/write both directions
- CWD preservation when in mounted range
- CWD graceful fallback (with warning) when outside mounted range
- OpenRouter provider written and shown `[ready]` by `oh provider list`
- root-host deploy (WSL with HOME=/root, UID 0) works thanks to runtime UID resync

If you change anything in `docker/`, `scripts/lib/`, or the shim templates,
rerun an end-to-end deploy + shim test before claiming it works.

## Don't

- Don't add a `# syntax=docker/dockerfile:1.6` line to the Dockerfile — it
  forces BuildKit to fetch the frontend image, which fails in network-restricted
  environments. The default frontend is enough.
- Don't `Resolve-Path` paths that don't exist yet (e.g. files we are about to
  write). Use `[System.IO.Path]::GetFullPath` instead.
- Don't pass container-side paths to `docker exec --env-file`; the file is read
  by the docker CLI on the **host**, so the host path is required.
- Don't ship a shim literally named `oh` on Windows — it collides with the
  PowerShell built-in `Out-Host` alias. Use `openh` there.
