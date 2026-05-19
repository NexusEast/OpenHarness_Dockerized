# Architecture

## Goals

1. Run OpenHarness (OH / OHMO) inside Docker while the **host experience stays identical to a native install**.
2. File I/O matches native behavior: in-container paths equal host paths; bind mounts write straight to the host filesystem.
3. Support multiple parallel instances, with an explicit default instance and per-call override.
4. Ship no OpenHarness source in this repo - the image installs `openharness-ai` from PyPI at build time.
5. OpenRouter as the only LLM backend.
6. Platform support: macOS / Linux / WSL / Windows PowerShell.

## Key design decisions

### A. Fully-aligned paths: `-v $HOME:$HOME` (\*nix) / `-v C:\Users\foo:/mnt/c/Users/foo` (Windows)

OH is a repo-aware agent (`os.getcwd()` matters). It reads `CLAUDE.md`, writes files, runs tests.
To make `oh` inside an arbitrary host directory behave like the native CLI, the cleanest approach is to **make the container see the exact same paths as the host**.

- **\*nix**: a same-name `-v $HOME:$HOME` bind mount. `cd ~/proj && oh` ends up at `cd /Users/foo/proj` inside the container; paths line up 1:1.
- **Windows / Docker Desktop**:
  - The bind-mount SOURCE must use a Windows-style path like `C:\Users\foo`. (Empirically: passing `/mnt/c/...` as the source makes docker-desktop mount the whole disk as ext4, and the real files become invisible.)
  - The bind-mount DEST uses Linux-style `/mnt/c/Users/foo`.
  - Inside PowerShell with `pwd = D:\foo`, the shim converts it to `/mnt/d/foo` and passes that via `-w`, so `cwd` still matches the host.
- User-level configs `~/.openharness`, `~/.ohmo`, `~/.claude`, `~/.codex` are shared automatically because they live under the mounted `$HOME`.
- If `cwd` is outside `$HOME` (typical Windows case: project lives on `D:\` but only `C:\Users\xxx` is mounted), the shim **does not let docker raise a cryptic error**:
  - First it probes with `docker exec ... test -d "$cwd_in_container"` to see whether the path is visible.
  - If not visible -> fall back to the instance's `host_home`, print a warning, and suggest re-deploying with `--extra-mount`.
- To support paths outside `$HOME`, add `--extra-mount /path` (\*nix) or `-ExtraMount D:\path` (PS) when running `deploy`.

### B. UID/GID alignment: adjusted in entrypoint at runtime

At build time the image only ships a fixed `ohuser` (uid 1000). At container start the entrypoint reconciles UID/GID against the `HOST_UID` / `HOST_GID` env vars:

- If `HOST_UID` already maps to another user (typical: root with UID 0), switch `HOST_USER` to that existing user.
- Otherwise run `usermod -u $HOST_UID ohuser` + `groupmod -g $HOST_GID ohuser`.

This way the same image is reusable by any host user, including root or UID != 1000. The sudoers file pre-authorizes `ohuser`, `root`, and `%sudo`.

### C. Transparent passthrough: host `oh` == `docker exec` into the container

The host-side shims are all the same script (dispatched by `argv[0]`). Internally each shim:

1. Resolves `--oh-instance` or the `OH_INSTANCE` env var.
2. Otherwise reads `default_instance` from `~/.openharness-docker/config.json`.
3. Otherwise, if exactly one instance exists, uses it; if multiple, fails with a helpful message.
4. Resolves the current `pwd`, converts to the in-container path, and passes it as `docker exec -w`.
5. Probes path visibility; falls back and warns if invisible.
6. `docker exec -i[t] <container> oh-entrypoint exec -- oh "$@"`.

`docker exec` is used to reuse a long-running container (`docker run -d ... idle`), avoiding the few-hundred-millisecond cold start every invocation - which keeps the CLI feel close to "native".

#### PowerShell specifics

PowerShell function semantics differ from bash: **stdout from any external command invoked inside a function is captured into the pipeline as the function's return value**. The module therefore only exports a function that *constructs* the docker argv array (`Get-OhdExecArgs`); the shim runs `& docker @argv` at the **top level**, so stdout streams directly to the user's terminal.

### D. Multiple instances & default-instance mechanic

- Instance state lives at `~/.openharness-docker/config.json` (Windows: `%USERPROFILE%\.openharness-docker\config.json`).
- Each instance corresponds to one container (`oh-<name>`) carrying the label `dev.openharness.dockerized=1`.
- During `deploy`:
  - The first instance is automatically set as the default.
  - Subsequent instances **ask** whether to become the default (or use `--set-default`/`--no-default` to force; PowerShell: `-SetDefault`/`-NoDefault`).
- `oh-ctl list / set-default / exec / status / restart / logs / shell / rm` cover instance management.
- Use `oh --oh-instance NAME ...` or `OH_INSTANCE=NAME oh ...` (PowerShell: `$env:OH_INSTANCE=...`) for a one-shot override.

### E. OpenRouter configuration

OpenRouter is wired in via OH's OpenAI-compatible provider profile:

```
oh provider add openrouter \
    --label "OpenRouter" \
    --provider openai \
    --api-format openai \
    --auth-source openai_api_key \
    --base-url "https://openrouter.ai/api/v1" \
    --model <user-chosen>
```

The wizard runs this command inside the container. The API key is staged via `--env-file` (so it never appears in `ps`) and the file is removed once the profile is created.
OH credentials live under `~/.openharness/` (shared between host and container), so restarting the container does not require reconfiguration.

### F. No OpenHarness source in this repo

`docker/Dockerfile` only runs `pip install openharness-ai`. The total source of this repo is under 1500 lines of Bash/PowerShell plus a single Dockerfile.
To upgrade OH, run `./update-oh.sh` or `.\update-oh.ps1` to rebuild the image. To update this wrapper repo itself (deploy/shim/Dockerfile/scripts), run `./update-deployer.sh` or `.\update-deployer.ps1` (it is a thin `git pull --ff-only` wrapper that also reports which follow-up command, if any, you should run next).

## Directory layout

```
.
├── README.md
├── deploy.sh            # deployment wizard
├── status.sh            # = oh-ctl status
├── restart.sh           # = oh-ctl restart
├── update-oh.sh         # upgrade OH image + rebuild containers
├── update-deployer.sh   # update THIS wrapper repo (git pull --ff-only)
├── uninstall.sh         # uninstall (user data is preserved)
├── setup-permissions.sh # one-shot chmod +x
├── Makefile
├── docker/
│   ├── Dockerfile
│   ├── entrypoint.sh    # container PID 1 (idle / exec / ohmo-gateway)
│   └── .dockerignore
├── docs/
│   └── ARCHITECTURE.md  # this file
└── scripts/
    ├── oh-ctl.sh        # multi-instance management CLI (invoked by the host-side oh-ctl)
    ├── install-shims.sh # installs host-side oh / ohmo / openh / openharness / oh-ctl
    └── lib/
        ├── common.sh          # shared lib: logging, config IO, container probing
        └── shim_template.sh   # oh/ohmo shim template
```

## Data persistence

The container itself is stateless. All persistent data lives on the host:

- `$HOME/.openharness/` - provider profiles, credentials, skills, plugins, memory (project-level CLAUDE.md/MEMORY.md still live next to the project).
- `$HOME/.ohmo/` - the ohmo personal-agent workspace.
- `$HOME/.claude/`, `$HOME/.codex/` - subscription-bridge credentials (this project only uses OpenRouter, but mounting them is harmless).

`./uninstall.sh` never touches these.

## Security boundary

- The in-container user has the **same UID/GID as the host user**; this is not an isolation sandbox: any file under the bind-mounted `$HOME` is readable and writable by OH.
- This is **intentional** - OH is a coding agent; it needs that level of access to be useful.
- For stronger isolation, use OH's own `sandbox.backend=docker` sub-capability (out of scope for this project).
- The OpenRouter key is staged via `--env-file` and removed right after the provider profile is created.
- The shims accept no network input; they are pure argv passthrough.

## Common maintenance operations

| Need                        | Command                                       |
| --------------------------- | --------------------------------------------- |
| Upgrade OH to latest        | `./update-oh.sh`                              |
| Upgrade to a specific ver.  | `./update-oh.sh --version 0.1.9`              |
| Update this wrapper repo    | `./update-deployer.sh`                        |
| Add a second instance       | `./deploy.sh --name oh-work`                  |
| Switch default instance     | `oh-ctl set-default oh-work`                  |
| Tail the default logs       | `oh-ctl logs -f`                              |
| Drop into the container     | `oh-ctl shell`                                |
| Wipe everything             | `./uninstall.sh --all`                        |
