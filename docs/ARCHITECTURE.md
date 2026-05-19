# Architecture

## Goals

1. Run OpenHarness (`oh`) inside Docker as a **hardened sandbox** the agent
   cannot escape from to read or modify host files.
2. Keep the host-side UX close to a native install: `oh ...` should "just
   work" inside paths the user has explicitly mounted.
3. Support multiple parallel instances, each with its own openharness
   profile, conversation history, and mount list, so different projects
   don't bleed state.
4. Ship no OpenHarness source in this repo — the image installs
   `openharness-ai` from PyPI at build time.
5. OpenRouter as the only LLM backend.
6. Platform support: macOS / Linux / WSL2 / Windows PowerShell.

## Non-goals

- **Replicating the user's host experience verbatim.** That requires
  exposing host paths to the container, which is the exact thing we are
  defending against. The user trades transparency for safety, and the
  trade is not negotiable per-deployment.
- **Defending against kernel / Docker engine 0-days.** See `SECURITY.md`.
- **Multi-tenant isolation between mutually distrusting users on the same
  Docker daemon.** Anyone with `docker` access already has root on the host.

## Key design decisions

### A. The container has no host filesystem access by default

The single most important decision: `deploy.sh` does **not** bind-mount
`$HOME` (or any other host path) into the container by default.

Instead:

- `$HOME` inside the container points at `/oh-home`, a Docker named volume
  (`oh-<instance>-home`). The host doesn't see it without `docker volume
  inspect` / `docker exec`.
- The user adds host directories explicitly via `oh-ctl mount add <path>`,
  which goes through a sensitive-paths blacklist (`ohd_assert_mount_safe`
  in `scripts/lib/common.sh`).
- Mounts surface inside the container at `/work/<basename>`. The host
  directory layout is **not** mirrored.
- Adding or removing a mount recreates the container. The HOME named
  volume is preserved, so the openharness profile and conversation
  history survive the recreate.

This is the architectural change vs. earlier sketches that had
`-v $HOME:$HOME`. We removed `-v $HOME:$HOME` because, with a process
that's executing arbitrary LLM-driven shell commands inside, sharing
`$HOME` is equivalent to handing the agent your shell account.

### B. Hardening flags are mandatory and centralized

Every container start (and every ephemeral cwd-mount run) goes through
`docker run` argv built in one place (`deploy.sh` / `Common.psm1`'s
`Get-OhdExecArgs` — for cwd auto-mount). The flags are:

```
--user 1000:1000                    non-root inside the container
--read-only                         rootfs is immutable
--tmpfs /tmp:nosuid,nodev,noexec    only writable scratch is /tmp,/run
--tmpfs /run:nosuid,nodev,noexec
-v <home_volume>:/oh-home           HOME = named volume, NOT host bind-mount
--cap-drop=ALL                      0 capabilities (CapBnd, CapEff = 0)
--security-opt=no-new-privileges    setuid bits are dead, no caps regained
--pids-limit 512                    fork-bomb cap
--memory 4g --cpus 2                resource caps
--add-host metadata.*:127.0.0.1     blackhole cloud-metadata IPs
--add-host 169.254.169.254:127.0.0.1
```

There is no `--privileged`, `--pid=host`, `--network=host`, or
`/var/run/docker.sock` mount — and the deploy scripts refuse arguments
that would introduce any of these.

The image (`docker/Dockerfile`) ships:

- no `sudo` binary,
- no `/etc/sudoers.d/oh-runtime`,
- no openssh-client, no nodejs/npm, no build-essential (smaller attack
  surface),
- a fixed UID 1000 user (`ohuser`), with both `! command -v sudo` and
  `! test -e /etc/sudoers.d/oh-runtime` asserted at build time so a
  regression in the Dockerfile fails the build.

### C. Path mapping inside the container

Host paths surface at `/work/<basename>`:

```
host /data/proj          -> container /work/proj
host /data/docs          -> container /work/docs
host /opt/foo/proj       -> container /work/proj-2   (basename collision)
```

This is deliberately **not** a host-path mirror. Two reasons:

1. The agent should not be able to infer the host's directory layout
   from inside.
2. Users get an obvious mental model: anything under `/work/` is "real",
   anything else is "container-only".

### D. The `[y/N]` prompt for ad-hoc cwd mounting

If the user runs `oh` from a host directory that isn't in the saved
mount list, the shim asks before exposing it:

```
[!] About to expose host path inside the sandbox:
[!]     /home/me/proj
[!] The agent will be able to read AND WRITE everything under it.
? Mount it for this command? [y/N]
```

If the user accepts, the shim spawns a one-shot `docker run --rm`
container with the same hardening flags **plus** that single bind
mount. The long-lived idle container is unaffected. After the command
exits, the mount is gone.

The default is **N**, and the answer cannot be implicit-yes in
non-interactive shells (CI, scripts) — those default to **N** as well.
Setting `OH_AUTO_MOUNT_CWD=1` skips the prompt in interactive sessions
when the user has explicitly opted in.

If the cwd is on the blacklist (e.g. you `cd ~/.ssh` and run `oh`), the
shim refuses outright and runs the command from `/oh-home` instead.

### E. Per-instance HOME on a Docker named volume

Earlier designs put per-instance state in
`$HOME/.openharness-instances/<name>/`, then bind-mounted that on top of
a shared `$HOME` mount. This is no longer needed — without `-v
$HOME:$HOME`, there's no shared HOME to overlay on. Each instance's
`/oh-home` is its own Docker named volume:

| Volume name        | Contents                                                    |
| ------------------ | ----------------------------------------------------------- |
| `oh-default-home`  | `~/.openharness/`, `~/.ohmo/`, `~/.cache/`, `~/.oh-runtime/` |
| `oh-work-home`     | …same, but for the "work" instance                         |
| `oh-personal-home` | …                                                          |

Instances cannot see each other's volumes (`docker run` doesn't mount
them). `oh-ctl rm <name> --purge` removes the volume; without `--purge`
the volume survives, and a re-deploy reuses it.

### F. Secrets injection

The OpenRouter key needs to be readable by the in-container UID 1000
process. We do not use `docker cp` for it, because:

- `docker cp` lands files owned by docker-daemon root inside the container.
- Fixing ownership afterwards needs `chown`, which `--cap-drop=ALL`
  prevents (yes, even via `docker exec -u 0`).

So we pipe the secret in:

```bash
docker exec -i $cname sh -c 'cat > /oh-home/.oh-runtime/secrets.env && chmod 0400 /oh-home/.oh-runtime/secrets.env' < $tmpfile
```

The file lands owned by UID 1000 mode 0400 in one shot. The host-side
temp file is shredded immediately. The named-volume location means the
secret survives container recreate (we don't re-prompt every redeploy)
but never lives on the host's home directory.

Accepted residual risk: the agent inside the container can read the
secret. See `SECURITY.md`. Mitigation: per-instance OpenRouter sub-key
with budget cap.

### G. Shims and PowerShell stdout

The host-side shims (`oh`, `ohmo`, `openh`, `openharness`) are all the
same script (dispatched by `argv[0]`). Internally each shim:

1. Resolves `--oh-instance` or the `OH_INSTANCE` env var.
2. Otherwise reads `default_instance` from
   `~/.openharness-docker/config.json`.
3. Otherwise, if exactly one instance exists, uses it; if multiple,
   fails with a helpful message.
4. Computes the in-container path of the host CWD (or triggers the
   `[y/N]` ephemeral-mount flow).
5. Runs `docker exec` (or `docker run --rm` for the ephemeral case),
   streaming stdin/stdout/stderr.

PowerShell function semantics differ from bash: stdout from any external
command invoked inside a function is captured into the pipeline as the
function's return value. The PowerShell helpers therefore only export
a function that *constructs* the docker argv array (`Get-OhdExecArgs`);
the shim runs `& docker @argv` at the top level so stdout streams to
the user's terminal.

### H. Multi-instance & default-instance mechanic

- Instance state lives at `~/.openharness-docker/config.json` (Windows:
  `%USERPROFILE%\.openharness-docker\config.json`).
- Each instance has one container (`oh-<name>`) and one HOME volume
  (`oh-<name>-home`), labeled `dev.openharness.dockerized=1` +
  `dev.openharness.sandbox=1` + `dev.openharness.instance=<name>` so
  filtering operations never touch unrelated containers.
- During `deploy`:
  - First instance is automatically set as the default.
  - Subsequent instances ask, or use `--set-default`/`--no-default`.
- `oh-ctl list / set-default / exec / status / restart / logs / shell / rm /
  mount` cover instance management.
- Per-call override: `OH_INSTANCE=NAME oh ...` or `oh --oh-instance NAME
  ...`.

### I. OpenRouter configuration

OpenRouter is wired via OH's OpenAI-compatible provider profile:

```
oh provider add openrouter \
    --label "OpenRouter" \
    --provider openai \
    --api-format openai \
    --auth-source openai_api_key \
    --base-url "https://openrouter.ai/api/v1" \
    --model <user-chosen>
```

The wizard runs this inside the container after secrets are injected.
The provider profile lives in the named volume HOME, so it persists
across container recreates without re-prompting for the key.

### J. No OpenHarness source in this repo

`docker/Dockerfile` only runs `pip install openharness-ai`. The total
source of this wrapper is under ~2500 lines of Bash/PowerShell plus a
small Dockerfile. To upgrade `openharness-ai`, run `./update-oh.sh` or
`.\update-oh.ps1`. To update this wrapper itself, run
`./update-deployer.sh` or `.\update-deployer.ps1`.

## Directory layout

```
.
├── README.md, SECURITY.md
├── CLAUDE.md                # auto-loaded by oh; project conventions
├── deploy.sh, deploy.ps1
├── status.sh|.ps1, restart.sh|.ps1
├── update-oh.sh|.ps1        # rebuild image + recreate every instance
├── update-deployer.sh|.ps1  # git pull --ff-only this wrapper
├── uninstall.sh|.ps1
├── setup-permissions.sh
├── Makefile
├── docker/
│   ├── Dockerfile           # hardened sandbox image
│   └── entrypoint.sh        # refuses to run as root; loads secrets.env
├── docs/
│   └── ARCHITECTURE.md      # this file
├── scripts/
│   ├── oh-ctl.sh, oh-ctl.ps1
│   ├── install-shims.sh, Install-Shims.ps1
│   └── lib/
│       ├── common.sh        # blacklist, mount helpers, exec helper
│       ├── Common.psm1      # ps1 mirror
│       ├── shim_template.sh
│       └── shim_template.ps1
└── sandbox/redteam/         # LLM escape rig + canaries + forensics
```

## Data persistence

The container is otherwise stateless. All persistent state for one
instance lives in:

- `oh-<name>-home` Docker volume — openharness profile, conversation
  history, ohmo memory, secrets.env. Survives container recreate.
- `~/.openharness-docker/config.json` — instance metadata (image, model,
  network mode, mounts list, default-instance pointer).

`./uninstall.sh` removes the containers and shims by default; pass
`--volumes` to also wipe the named volumes (DESTROYS state).

## Security boundary

See `SECURITY.md` for the full threat model. Short version:

- Container UID 1000, all caps dropped, read-only rootfs, named-volume
  HOME, mount blacklist on `--mount`, cloud-metadata blackholed,
  cap-drop blocks `mount`, `mknod`, `unshare`, ptrace, raw socket.
- Validated against `claude-opus-4.7` red-team across three rounds
  (naïve / informed / white-box). All held; in two of three rounds the
  attacker model voluntarily emitted `give_up`.
- Accepted residual risks: the OpenRouter key is readable inside the
  container; the container has default Docker bridge egress (host LAN
  reachable). Both documented in `SECURITY.md`.

## Common maintenance operations

| Need                                | Command                                            |
| ----------------------------------- | -------------------------------------------------- |
| Upgrade OH to latest                | `./update-oh.sh` / `.\update-oh.ps1`               |
| Pin a specific OH version           | `./update-oh.sh --version 0.1.9`                   |
| Update this wrapper repo            | `./update-deployer.sh`                             |
| Add a second instance               | `./deploy.sh --name work`                          |
| Add a host directory to the sandbox | `oh-ctl mount add /data/proj`                      |
| Make a directory read-only          | `oh-ctl mount add /data/docs --ro`                 |
| Remove a mount                      | `oh-ctl mount rm /data/proj`                       |
| Switch default instance             | `oh-ctl set-default work`                          |
| Tail the default logs               | `oh-ctl logs -f`                                   |
| Drop into the container             | `oh-ctl shell`                                     |
| Wipe everything                     | `./uninstall.sh --all`                             |
