# OpenHarness Sandbox

> Run [HKUDS/OpenHarness](https://github.com/HKUDS/OpenHarness) (`oh`)
> as a hardened Docker sandbox, without giving the agent any access to your
> host filesystem.

`oh` is a powerful agentic CLI. Powerful agentic CLIs that run with the
privileges of the user who invoked them have all the privileges of that user
— including the ability to read `~/.ssh/id_rsa`, write `~/.bashrc`, exfiltrate
cloud credentials, or install persistence. **A "Docker wrapper" is not by
itself a sandbox** — it just changes the layout. This repo provides an
opinionated, hardened, red-team-validated sandbox where it actually is.

> [!IMPORTANT]
> Read [`SECURITY.md`](./SECURITY.md) before deploying to any machine that
> stores secrets you care about. The threat model, the isolation contract,
> and the residual risks (the OpenRouter key being readable inside the
> sandbox; the container reaching your host's LAN by default) are all there.

## Table of contents

- [What you get](#what-you-get)
- [Quick start](#quick-start)
- [How to give the agent access to a directory](#how-to-give-the-agent-access-to-a-directory)
- [How `oh` finds your code](#how-oh-finds-your-code)
- [Multiple instances](#multiple-instances)
- [Updating, restarting, removing](#updating-restarting-removing)
- [Files in this repo](#files-in-this-repo)
- [Red-team validation](#red-team-validation)
- [FAQ](#faq)

## What you get

- **A non-root container** (UID 1000) with **all Linux capabilities dropped**,
  **read-only rootfs**, and **no host filesystem access** beyond paths you
  explicitly mount.
- **Per-instance HOME on a Docker named volume** (`oh-<name>-home`).
  Persistent across container recreates, **invisible** to the host's home
  directory.
- **Cloud metadata blackholed**: `169.254.169.254`,
  `metadata.tencentyun.com`, `metadata.google.internal`,
  `metadata.aliyuncs.com`, `metadata.azure.com` all resolve to `127.0.0.1`
  inside the sandbox.
- **A blacklist on `--mount`** that refuses sensitive host paths (`$HOME`,
  `/etc`, `/var/run/docker.sock`, `~/.ssh`, `~/.aws`, …).
- **An interactive `[y/N]` confirmation** if you run `oh` from a host
  directory that isn't already mounted, because that's the moment a
  user-confused-deputy mistake would actually expose data.
- **`oh` / `ohmo` / `openh` / `oh-ctl`** shims so you keep the original
  user experience.
- A red-team rig at `sandbox/redteam/` that has been run against
  `claude-opus-4.7` and `nemotron-3-super-120b` (both: 0 escapes).

Supported hosts: macOS, Linux, WSL2, Windows (with Docker Desktop + WSL2
integration).

## Quick start

```bash
git clone <this-repo> openharness-sandbox
cd openharness-sandbox

# Linux / macOS / WSL
./deploy.sh

# Windows PowerShell
.\deploy.ps1
```

The wizard:

1. asks for an instance name (default: `default`),
2. asks for your OpenRouter API key (get one at
   [openrouter.ai/keys](https://openrouter.ai/keys); **use a sub-key with a
   budget cap** — the agent inside the sandbox can read it),
3. builds the Docker image (first time only),
4. creates the hardened container,
5. installs shims to `~/.local/bin` (sh) or `%USERPROFILE%\.openharness-docker\bin`
   (ps1).

After it finishes, the agent has **no host filesystem access**. That's
intentional. To give it some, use `oh-ctl mount`:

## How to give the agent access to a directory

```bash
# Expose the host directory /data/proj read-write inside the sandbox.
# It will appear inside the container at /work/proj.
oh-ctl mount add /data/proj

# Read-only:
oh-ctl mount add /data/docs --ro

# List active mounts for an instance:
oh-ctl mount list

# Remove:
oh-ctl mount rm /data/proj
```

Adding or removing a mount **recreates the container**. Your openharness
profile, conversation history, etc. live in the named volume HOME and
survive the recreation.

The mount blacklist (see [SECURITY.md](./SECURITY.md)) will refuse anything
under `$HOME`, `/etc`, `/var`, the docker socket, etc. To intentionally
expose part of your `$HOME`, copy or symlink the data into a separate
directory first (e.g. `/data/`), then mount that.

## How `oh` finds your code

When you run `oh` (or `openh` on Windows), the shim figures out where your
host CWD is exposed inside the container:

| You are at host path…                  | The shim does…                                          |
| -------------------------------------- | ------------------------------------------------------- |
| `/data/proj` (already mounted at `/work/proj`) | runs `oh` inside the long-lived container with `cwd=/work/proj` |
| `/some/other/safe/path` (not mounted)  | asks `Mount it for this command? [y/N]` (default N)     |
| answer `y`                             | spawns a one-shot `docker run --rm` with the same hardening **plus** that single mount |
| answer `n`, or non-interactive shell   | runs from `/oh-home` and warns that the agent can't see your cwd |
| `/etc`, `~/.ssh`, etc. (blacklisted)   | refuses to mount, runs from `/oh-home` instead          |

To skip the prompt set `OH_AUTO_MOUNT_CWD=1` (auto-yes) or `=0` (auto-no).
Default is interactive; **non-interactive shells default to no**.

## Multiple instances

```bash
./deploy.sh --name work
./deploy.sh --name personal --mount /data/personal
oh-ctl list
oh-ctl set-default personal
OH_INSTANCE=work oh -p "..."
```

Each instance has its own:

- container (`oh-<name>`)
- HOME named volume (`oh-<name>-home`)
- mount list (in `~/.openharness-docker/config.json`)
- model selection / OpenRouter key

State does **not** bleed between instances.

## Updating, restarting, removing

```bash
# Rebuild the image and recreate every container (preserves home volumes)
./update-oh.sh
.\update-oh.ps1

# Pull the latest version of this wrapper repo
./update-deployer.sh
.\update-deployer.ps1

# Restart / status
./restart.sh [name]
./status.sh

# Remove the container only (keep state and image):
oh-ctl rm <name>
# Remove everything for one instance, including the HOME volume:
oh-ctl rm <name> --purge

# Wholesale uninstall:
./uninstall.sh                 # containers + shims, keep volumes + image
./uninstall.sh --volumes       # also wipe home volumes (DESTROYS state)
./uninstall.sh --all           # everything: containers + volumes + image + metadata + shims
```

## Files in this repo

```
deploy.sh / deploy.ps1            interactive deploy wizard
docker/Dockerfile                 hardened sandbox image
docker/entrypoint.sh              container entrypoint (refuses to run as root)
scripts/oh-ctl.sh, oh-ctl.ps1     instance + mount management
scripts/install-shims.sh|.ps1     install oh / ohmo / openh / oh-ctl shims
scripts/lib/common.sh             sh helpers (path blacklist, exec, …)
scripts/lib/Common.psm1           ps1 mirror of common.sh
scripts/lib/shim_template.sh|.ps1 template for the per-CLI forwarder shims
update-oh.sh|.ps1                 rebuild image + recreate every instance
update-deployer.sh|.ps1           git-pull this wrapper
restart.sh|.ps1, status.sh|.ps1   thin oh-ctl wrappers
uninstall.sh|.ps1                 cleanup
SECURITY.md                       threat model, isolation contract, attack list
docs/ARCHITECTURE.md              design rationale and trade-offs
sandbox/redteam/                  red-team rig: agent + canaries + forensics
```

## Red-team validation

`sandbox/redteam/` contains an LLM-driven escape rig that runs **inside**
the sandbox and tries to read host canary files. The current configuration
has been validated against `claude-opus-4.7` (three rounds, all held;
naïve and informed rounds ended with the model voluntarily giving up).
See `SECURITY.md` for re-run instructions.

If you find a way to escape that the red-team didn't catch, please open a
private security advisory.

## FAQ

**Q: This breaks my workflow — `oh` used to see all of `~`, now it sees nothing.**
A: That was the bug. Use `oh-ctl mount add` for the directories you actually
want the agent to read or write. The transparency you had previously was
also being given to a process you don't control.

**Q: Can I just disable the sandbox / get the old behavior back?**
A: No. There is no "share-home" mode. If you really want host-wide access for
some reason (and you understand the consequences), fork this repo and add
the bind mount yourself; please don't ask the maintainers to add the
flag.

**Q: The agent inside can still read my OpenRouter key, right?**
A: Yes. It has to, to call the LLM. Use a dedicated OpenRouter sub-key with a
budget cap. See `SECURITY.md` § "Accepted residual risks".

**Q: Can the container talk to other services on my LAN?**
A: Yes, through the Docker bridge, by default. If your host runs an
unauthenticated Redis on `127.0.0.1`, the container can reach it via
`172.17.0.1`. Pass `--no-network` (sh) / `-NoNetwork` (ps1) to deploy with
`--network=none` if your workload doesn't need OpenRouter.

**Q: I'm on Windows. Why is `oh` aliased to `openh`?**
A: Because PowerShell aliases the literal name `oh` to `Out-Host`, which
shadows our shim and produces confusing errors. Use `openh` (or `openharness`)
on Windows.

**Q: How do I expose a Windows path?**
A: `oh-ctl mount add D:\Projects\Foo`. The shim translates Windows paths
to Docker bind sources correctly. The path appears inside the container as
`/work/Foo`.

**Q: What about Docker Desktop on macOS?**
A: It works. The same blacklist applies. macOS users typically mount things
like `/Users/me/code/proj`, which is **inside** `$HOME` and so will be
**rejected** by the blacklist. Move or symlink it under `/Volumes/Code/` or
similar, mount that.
