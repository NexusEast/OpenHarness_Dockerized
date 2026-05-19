# OpenHarness Dockerized

Run [HKUDS/OpenHarness](https://github.com/HKUDS/OpenHarness) inside Docker
while keeping the host-side `oh` / `ohmo` commands feeling like a native
install. No OpenHarness source code is vendored in this repo — the image is
built fresh from `pip install openharness-ai`.

> Currently only **OpenRouter** is supported as the LLM backend.

## Why?

- You want the isolation, reproducibility and easy upgrades of a container,
  **without** giving up the ergonomics of a CLI that just reads/writes the
  files in your current directory.
- You want to run multiple OpenHarness instances side by side (e.g. one per
  project, or one per provider profile) and switch between them painlessly.
- You don't want to litter your host with OH's runtime (Python venv, Node,
  ripgrep, fd, dozens of pip packages…).

## Features

- **Zero-friction passthrough.** Host shims (`oh` / `ohmo` / `openh` /
  `openharness` / `oh-ctl`) forward to `docker exec` transparently. Your
  current working directory is preserved inside the container, and the files
  the agent writes land directly on your host disk.
- **Multiple instances.** Deploy as many containers as you like
  (`oh-default`, `oh-work`, `oh-personal`, …). Select the target via a
  default-instance mechanism, a per-call `--oh-instance NAME`, or
  `OH_INSTANCE=NAME` in the environment.
- **Persistent user config.** `~/.openharness`, `~/.ohmo`, `~/.claude`,
  `~/.codex` are bind-mounted from your `$HOME`, so skills, plugins,
  credentials and memory survive container recreations and are shared with
  any future native install.
- **No vendored OH source.** The `Dockerfile` does `pip install openharness-ai`
  at build time. Upgrade by re-running `update-oh.sh` / `update-oh.ps1`.
  To update the wrapper repo itself (this very tree), use
  `update-deployer.sh` / `update-deployer.ps1`.
- **OpenRouter wizard.** `deploy.sh` / `deploy.ps1` asks for your OpenRouter
  API key + default model and writes the provider profile inside the
  container for you.
- **Cross-platform host.** macOS, Linux, WSL, and Windows PowerShell.

## Platform support

| Host shell           | Wizard           | Forwarded CLI names                              | Notes                                                                |
| -------------------- | ---------------- | ------------------------------------------------ | -------------------------------------------------------------------- |
| macOS                | `./deploy.sh`    | `oh` / `ohmo` / `openh` / `openharness` / `oh-ctl` | Mount source = host path (identical)                                 |
| Linux                | `./deploy.sh`    | same                                             | Same                                                                 |
| WSL (Debian/Ubuntu)  | `./deploy.sh`    | same                                             | Uses Docker Desktop's daemon under the hood                          |
| Windows PowerShell   | `.\deploy.ps1`   | `openh` / `ohmo` / `openharness` / `oh-ctl`      | No `oh` shim (PowerShell aliases `oh` to `Out-Host`); use `openh`    |

`.cmd` wrappers are installed too, so Windows `cmd.exe` works as well
(`openh.cmd ...`). All shells share the same docker daemon, the same image,
and the same `~/.openharness-docker/config.json`.

## Requirements

- **Docker** 24+ (Docker Desktop on Windows/macOS works out of the box)
- **bash** (or PowerShell 7+ on Windows)
- **jq** (only required by the `*.sh` scripts on \*nix)
- Internet access to `pypi.org` and `docker.io` when first building the image
- An **OpenRouter** API key — get one at https://openrouter.ai/keys

## Quick start

### macOS / Linux / WSL

```bash
git clone https://github.com/NexusEast/OpenHarness_Dockerized.git
cd OpenHarness_Dockerized
./setup-permissions.sh         # +x for all .sh (if cloned on Windows / NTFS)
./deploy.sh                    # interactive wizard
oh                             # use it just like the native CLI
ohmo init                      # initialize your ohmo workspace
```

### Windows PowerShell

```powershell
git clone https://github.com/NexusEast/OpenHarness_Dockerized.git
cd OpenHarness_Dockerized
.\deploy.ps1                   # interactive wizard
openh                          # use it just like the native CLI ('oh' would collide with Out-Host)
ohmo init
```

After deploy, the shims are installed to:
- **\*nix:** `~/.local/bin/` (add it to `PATH` if not already)
- **Windows:** `%USERPROFILE%\.openharness-docker\bin\` (add to PATH, or
  dot-source the generated `profile.ps1` from your `$PROFILE`)

## Command cheatsheet

| Command                                            | What it does                                              |
| -------------------------------------------------- | --------------------------------------------------------- |
| `oh ...` (\*nix) / `openh ...` (PS)                | Forward to the default container; cwd mirrors the host    |
| `ohmo ...`                                         | Forward `ohmo` to the default container                   |
| `oh-ctl list`                                      | List instances, mark the default with `*`                 |
| `oh-ctl set-default NAME`                          | Set `NAME` as the default instance                        |
| `oh-ctl exec NAME -- <cmd...>`                     | Run something inside a specific instance                  |
| `oh-ctl status [NAME]`                             | Container health (all instances or just one)              |
| `oh-ctl restart [NAME]`                            | Restart an instance (default if omitted)                  |
| `oh-ctl logs [NAME] [-f]`                          | Tail container logs                                       |
| `oh-ctl shell [NAME]`                              | Interactive bash inside the container                     |
| `oh-ctl rm NAME [--purge]`                         | Remove a container (`--purge` also wipes metadata)        |
| `oh --oh-instance NAME ...`                        | One-shot override of the default instance                 |
| `OH_INSTANCE=NAME oh ...`                          | Same, via environment variable                            |

## Maintenance scripts

| *nix              | PowerShell        | Purpose                                                |
| ----------------- | ----------------- | ------------------------------------------------------ |
| `deploy.sh`         | `deploy.ps1`         | Deploy a new instance, or redeploy an existing one     |
| `status.sh`         | `status.ps1`         | Alias for `oh-ctl status`                              |
| `restart.sh`        | `restart.ps1`        | Alias for `oh-ctl restart`                             |
| `update-oh.sh`      | `update-oh.ps1`      | Rebuild the OH runtime image and recreate containers   |
| `update-deployer.sh`| `update-deployer.ps1`| Update this wrapper repo itself (`git pull --ff-only`) |
| `uninstall.sh`      | `uninstall.ps1`      | Remove containers and shims (keeps your user data)     |

## How file mounting works

Mount points inside the container:

| Platform              | Host path        | Container path           |
| --------------------- | ---------------- | ------------------------ |
| macOS / Linux / WSL   | `$HOME`          | `$HOME` (identical)      |
| Windows PowerShell    | `C:\Users\you`   | `/mnt/c/Users/you`       |

Because the container path always corresponds 1:1 to the host path, `oh` run
from any mounted directory behaves the same as it would natively.

### Three things, three boundaries

This project deliberately keeps three things separate:

| #   | Lives at                                                                | What is it?                                            | Container access                       |
| --- | ----------------------------------------------------------------------- | ------------------------------------------------------ | -------------------------------------- |
| 1.  | The **wrapper repo** (this repo: `deploy.sh`, `Dockerfile`, …)          | The plumbing you `git pull` / `git push` to update    | **No access.** Shadowed if it falls inside a bind-mount |
| 2.  | The **OpenHarness source** (`openharness-ai` from PyPI)                 | The actual `oh` / `ohmo` runtime                       | Lives **only inside the image**; never on host         |
| 3.  | Your **workspace** (your projects under `$HOME`, anywhere else you mount) | Where `oh` reads/writes when you use it                | Full read/write — that's the whole point |

In other words:

- `git pull` on this wrapper repo **cannot** affect a running container.
  Containers don't see the repo at all (and even if you cloned it under
  `$HOME`, the repo path is shadowed inside the container — see below).
- An `oh` agent inside the container **cannot** modify the wrapper repo,
  the Dockerfile, or your `~/.openharness-docker` state. It would see
  empty directories there and any writes would land in throwaway
  in-memory storage.
- Upgrading OpenHarness only happens when you explicitly run `update-oh.sh`
  / `update-oh.ps1` (which rebuilds the image from `pip install`).
  Updating this wrapper repo itself is a separate command:
  `update-deployer.sh` / `update-deployer.ps1`.

### Per-instance state isolation

Each instance also has its own copy of OpenHarness's user state — the
provider profile (your OpenRouter key, default model), the ohmo soul /
identity / memory, skills, etc. They live on the host at:

```
~/.openharness-instances/<instance-name>/
├── openharness/      → bind-mounted as ~/.openharness inside the container
└── ohmo/             → bind-mounted as ~/.ohmo       inside the container
```

So if you deploy:

```bash
./deploy.sh --name oh-work     --model anthropic/claude-3.5-sonnet
./deploy.sh --name oh-personal --model openai/gpt-4o-mini
```

…the second deploy does **not** clobber the first one's settings.
`oh-work` keeps using claude-3.5-sonnet, `oh-personal` uses gpt-4o-mini,
and their ohmo memories never bleed into each other. Your project files
under `$HOME`, on the other hand, **are** still shared (because both
agents need to be able to edit your code — that's the whole point).

`oh-ctl rm <name> --purge` removes both the container and that instance's
per-instance state directory.

### Isolation guard ("shadow mounts")

If the wrapper repo path or `~/.openharness-docker` happens to fall
**inside** an attached bind-mount (typical case: you cloned this repo
under `$HOME`), the deploy wizard automatically overlays a small
`tmpfs` at the same in-container path. The container then sees an empty
directory there, and any writes go into the tmpfs (gone when the
container is removed). Your real wrapper-repo files on the host are
never touched.

You'll see this in the deploy output:

```
[i] Wrapper repo is inside a bind-mount; shadowing it inside the container
    so 'oh' cannot touch it: /home/you/oh-wrapper
[i] Wrapper state dir will be shadowed inside the container:
    /home/you/.openharness-docker
```

### What if my project is outside the mounted area?

(Typical on Windows when your code lives on `D:\` but only `C:\Users\you` is
mounted.) The shim won't let `docker` blow up with a cryptic error. It probes
whether your `cwd` is visible inside the container and, if not, falls back to
the instance's home with a friendly warning:

```
[!] Path not visible inside container 'oh-default':
[!]     host cwd : D:\Projects\foo
[!]     expected : /mnt/d/Projects/foo
[!] Falling back to: /mnt/c/Users/you
[!] Tip: redeploy with  -ExtraMount 'D:\Projects\foo'  to add this path to the container.
```

To fix it, redeploy with the extra path mounted:

```bash
# *nix
./deploy.sh --name oh-default --extra-mount /opt/projects
# PowerShell
.\deploy.ps1 -Name oh-default -ExtraMount D:\Projects
```

## Multi-instance & default selection

1. The first instance you deploy is **automatically set as the default**.
2. Subsequent deploys **ask** whether to take over as the new default. Force
   the choice with `--set-default` / `--no-default` (or `-SetDefault` /
   `-NoDefault` in PowerShell).
3. When you type `oh ...` the shim picks the target instance in this order:
   - `OH_INSTANCE` env var, or `--oh-instance NAME` on the command line
   - Otherwise the saved `default_instance` in `~/.openharness-docker/config.json`
   - Otherwise the only deployed instance (if there's exactly one)
   - Otherwise it errors and prints a helpful list
4. `oh-ctl list` marks the current default with `*`.

## Layout on disk

```
~/.openharness-docker/             (Windows: %USERPROFILE%\.openharness-docker\)
├── config.json                    # default_instance + per-instance metadata
├── instances/<name>/              # reserved for per-instance scratch files
├── bin/                           # (Windows) installed shim scripts
└── profile.ps1                    # (Windows) helper functions for $PROFILE
```

Container naming convention: `oh-<instance-name>`. Every container we create
carries the label `dev.openharness.dockerized=1` (plus
`dev.openharness.instance=<name>`), so our scripts can filter on it and we
never touch unrelated containers.

## Troubleshooting

### `openh` / `oh` is not found
- **\*nix:** add `export PATH="$HOME/.local/bin:$PATH"` to your shell rc.
- **Windows:** add the shim dir to your user PATH:
  ```powershell
  [Environment]::SetEnvironmentVariable(
      'Path',
      "$HOME\.openharness-docker\bin;$([Environment]::GetEnvironmentVariable('Path','User'))",
      'User')
  ```
  …and restart your shell.

### `oh provider list` does not show OpenRouter
Re-run the wizard for that instance — it will rewrite the provider profile:
```bash
./deploy.sh --name <instance>     # or  .\deploy.ps1 -Name <instance>
```

### Can't reach the container / passthrough produces no output
```bash
oh-ctl status            # is the container running?
oh-ctl logs              # entrypoint output
oh-ctl shell             # poke around inside
```

### Full reset
```bash
./uninstall.sh --all      # PowerShell: .\uninstall.ps1 -All
```
This removes containers, the image, and the shims, but leaves your
`~/.openharness` and `~/.ohmo` alone (your skills, memory and credentials).

## Design notes

The repository is small. The interesting decisions are written up in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Highlights:

- Bind-mount the user `$HOME` (or `C:\Users\you` ↔ `/mnt/c/Users/you` on
  Windows) so the in-container path matches the host path exactly.
- Bake one `ohuser` (UID 1000) into the image; resync its UID/GID at
  container start to match `HOST_UID` / `HOST_GID`. This lets a single image
  work for any host user, including `root` with UID 0 (typical inside WSL).
- PowerShell quirk: functions capture external-command stdout into their
  return pipeline. So the shim builds the `docker exec` argv inside a
  function (`Get-OhdExecArgs`) and then runs `& docker @argv` at the **top
  level**, ensuring stdout streams straight to the user's console.

## Contributing

PRs and issues are welcome. Please:

- Write **everything in English** (commits, PR descriptions, issues, code
  comments).
- Run an end-to-end deploy + shim test on the platform you're touching
  before submitting. The README "Troubleshooting" section is a reasonable
  smoke test.
- Don't add a `# syntax=docker/dockerfile:1.6` line to the Dockerfile — it
  forces BuildKit to fetch the frontend image, which breaks in
  network-restricted environments. Stick with the default frontend.

## License

MIT, in the spirit of the upstream HKUDS/OpenHarness project. This wrapper
includes none of its source code — only an installation recipe.
