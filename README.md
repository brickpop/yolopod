# yolopod

Run AI coding harnesses inside a Podman container, sandboxed to the directory you launch
them from. One image holds them all; each gets its own command:

| Command | Runs | With |
|---|---|---|
| `pclaude` | [Claude Code](https://claude.com/claude-code) | `--dangerously-skip-permissions` |
| `pcodex` | [Codex CLI](https://github.com/openai/codex) | `--dangerously-bypass-approvals-and-sandbox` |

They never stop to ask, but they can only see the current project, their own config
(`~/.claude` or `~/.codex`) and nothing else of your machine.

```sh
cd ~/dev/some-project
pclaude     # or: pcodex
```

## Install

**1. Install Podman**

```sh
sudo dnf install podman          # Fedora / RHEL / CentOS
sudo apt install podman          # Debian / Ubuntu
sudo pacman -S podman            # Arch
brew install podman && podman machine init && podman machine start   # macOS
```

**2. Install yolopod**

```sh
git clone https://github.com/brickpop/yolopod.git
cd yolopod
./install.sh        # or: just install
```

This copies `pclaude` and `pcodex` to `~/.local/bin`, the `Containerfile` and the shared
`lib.sh` to `~/.local/share/yolopod`, and builds the image (a few minutes).

If `~/.local/bin` is not on your `PATH`:

```sh
fish_add_path ~/.local/bin                                    # fish
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc      # bash/zsh
```

**3. Log in** once, on the host, with each harness you use. See [Logins](#logins).

### Coming from pclaude or pcodex

They are now this one repo and one image. The old installs can go:

```sh
rm -rf ~/.local/share/pclaude ~/.local/share/pcodex
podman rmi -f localhost/pclaude localhost/pcodex
```

`./install.sh` overwrites the old `~/.local/bin/pclaude` and `~/.local/bin/pcodex`. Your
logins, config and session history live in `~/.claude*` and `~/.codex` and carry over.
If you set `PCLAUDE_IMAGE` or `PCODEX_IMAGE` to the old image names, unset them.

## Usage

Arguments are passed through to the harness untouched:

```sh
pclaude                             # interactive session
pclaude -p "explain this repo"      # print mode
pclaude --model opus --resume       # any claude flag or subcommand

pcodex                              # interactive session
pcodex exec "explain this repo"     # non-interactive
pcodex --model o3 resume --last     # any codex flag or subcommand
```

Codex always runs with `--no-alt-screen`: it prints inline instead of taking over the
screen, so its output stays in your terminal's scrollback and you can select and copy it.

Each launcher's own options are namespaced so they can never clash with a harness flag
(`pcodex` has the same ones as `--pcodex-*`):

| Option | |
|---|---|
| `--pclaude-build` | Build the image |
| `--pclaude-update` | Rebuild it from scratch, pulling the latest base and harnesses |
| `--pclaude-shell` | Open a shell in the container instead of the harness |
| `--pclaude-help` | Usage |

Both launchers build the same image, so `pclaude --pclaude-update` updates Codex too.

### Running something else

The image clears the entrypoint and defaults to `bash`, so any command in it can run, with
no `--entrypoint` needed:

```sh
podman run --rm -it -v $PWD:$PWD:z -w $PWD localhost/yolopod              # a shell
podman run --rm -v $PWD:$PWD:z -w $PWD localhost/yolopod forge test       # anything else
```

`pclaude --pclaude-shell` / `pcodex --pcodex-shell` are the shorthand for a shell with
all of that launcher's usual mounts applied.

## Logins

### pclaude

Log in on the host with plain `claude /login`. That single login covers `pclaude` too,
and survives image rebuilds.

Claude Code reads `~/.claude/.credentials.json` on Linux, but on macOS it keeps the token
in the login Keychain (item `Claude Code-credentials`), which the Linux container cannot
reach. So on macOS `pclaude` keeps the two in sync, before launching and again when the
container exits: whichever copy expires later wins and overwrites the other. The file is
written with mode `0600`; the Keychain item is updated in place with `security`.

Syncing both ways matters because every token refresh revokes the previous refresh token.
If the container refreshes and the Keychain keeps the old copy, both host `claude` and the
next `pclaude` would be left with a dead login.

To log out everywhere, run `claude /logout` on the host **and** delete
`~/.claude/.credentials.json`; otherwise the next `pclaude` restores the login into the
Keychain from the file.

`ANTHROPIC_API_KEY`, Bedrock and Vertex are forwarded from the environment instead (but
see the open decision in `TASKS.md`: on macOS a Keychain login is still required).

### pcodex

Log in on the host with plain `codex login`. Codex stores the login in
`~/.codex/auth.json`, which is mounted into the container, so that single login covers
`pcodex` too and survives image rebuilds. Token refreshes inside the container are written
back to the same file, so host `codex` stays logged in as well.

This relies on Codex's default `cli_auth_credentials_store = "file"`. If your
`~/.codex/config.toml` sets it to `keyring` or `auto`, the login lives in the OS keyring,
which the container cannot reach, and `pcodex` will ask you to log in.

No host `codex`? Log in from inside the container with `pcodex login --device-auth`. The
plain browser flow does not work there: its callback listens on `localhost:1455` inside
the container, which your browser cannot reach.

`OPENAI_API_KEY` or `CODEX_API_KEY` need no login at all; they are forwarded.

## What gets mounted

| Host | Container | |
|---|---|---|
| `$PWD` | `$PWD` (same path) | read-write — the only project code the harness can reach |
| `~/.claude` | `/home/node/.claude` | `pclaude` only: credentials, settings, agents, history |
| `~/.claude.json` | `/home/node/.claude.json` | `pclaude` only: project state |
| `~/.codex` | `/home/node/.codex` | `pcodex` only: login, `config.toml`, sessions, history |
| `~/.gitconfig` | `/home/node/.gitconfig` | read-only, if present |

Each launcher mounts only its own harness's config, so neither can read the other's
credentials. Likewise, each forwards only its own harness's env vars when set:

- `pclaude`: `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`,
  `ANTHROPIC_MODEL`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`
- `pcodex`: `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `CODEX_API_KEY`, `CODEX_ACCESS_TOKEN`
- both: `GH_TOKEN`, `TERM`, `COLORTERM`

Nothing else from your machine is visible. Running in `$HOME` itself is refused (it would
defeat the point); set `PCLAUDE_ALLOW_HOME=1` / `PCODEX_ALLOW_HOME=1` if you really mean it.

The project keeps its host path inside the container, and `HOME` stays `/home/node`. Both
harnesses key per-project session history off the working directory, so
`pclaude --continue` and `pcodex resume --last` pick up where the host `claude` / `codex`
left off in that same repo.

`~/.codex/config.toml` is shared with the host, so anything in it that points at host
paths or host-only programs (MCP server commands, `notify` scripts...) will not work
inside the container. The same goes for MCP servers configured in `~/.claude.json`.

The container runs with no capabilities (`--cap-drop all`) and `no-new-privileges`, so
nothing inside can escalate via setuid. Codex's own sandbox (bubblewrap) is always off —
the container is the sandbox, and it couldn't create its namespaces in there anyway.
`PCODEX_NO_YOLO=1` only brings back the approval prompts (`--sandbox danger-full-access`
keeps the inner sandbox off).

Note that the container has **unrestricted network access** — the sandbox is about your
filesystem, not about what the harness can reach online.

### SELinux

On Fedora/RHEL, bind mounts are relabelled with `:z` (shared) so that repeated and
concurrent sessions work. The stricter `:Z` gives each container a private MCS category,
which means a second session would relabel `~/.claude` or `~/.codex` out from under the
first and break it — use `PCLAUDE_RELABEL=Z` / `PCODEX_RELABEL=Z` only if you run one
session at a time. On non-SELinux hosts no suffix is added at all.

To undo the relabelling of a directory later: `restorecon -R <dir>`.

## Configuration

Each launcher reads its own prefix, `PCLAUDE_*` or `PCODEX_*`:

| Variable | Default | |
|---|---|---|
| `…_IMAGE` | `localhost/yolopod` | image to run |
| `…_HOME` | `~/.local/share/yolopod` | where `Containerfile` and `lib.sh` live |
| `…_ARGS` | — | extra `podman run` args |
| `…_NO_YOLO` | — | `1` brings back the approval prompts |
| `…_RELABEL` | `auto` | `z`, `Z` or `off` |
| `…_ALLOW_HOME` | — | `1` allows running in `$HOME` |

`install.sh` always installs into `~/.local/share/yolopod`; `…_HOME` only points a
launcher elsewhere, e.g. at a checkout you are working on.

Mount something extra:

```sh
PCLAUDE_ARGS="-v $HOME/dev/shared-lib:/shared:z" pclaude
```

Forward your SSH agent, so the harness can push:

```sh
PCODEX_ARGS="-v $SSH_AUTH_SOCK:/ssh-agent:z -e SSH_AUTH_SOCK=/ssh-agent" pcodex
```

## What's in the image

One image, `localhost/yolopod`, built from `node:26-slim`. Everything is on `PATH`, so
the harness can reach for any of it:

| | |
|---|---|
| **Claude Code** | claude |
| **Codex** | codex (ships its own `rg`) |
| **Python** | python3, pip, venv — Debian's; plus `uv` / `uvx` |
| **Node** | node, npm — from the base image |
| **Bun** | bun |
| **Deno** | deno |
| **Foundry** | forge, cast, anvil, chisel |
| **Go** | go, with `GOPATH=/home/node/go` |
| **Shell tools** | git, openssh, curl, jq, make, unzip, fzf, vim, less, ps, just, wiki |

Debian refuses a global `pip install` (PEP 668); use `uv` (`uv run`, `uv tool install`,
`uvx`) or a venv. Tools installed with `uv tool install` land in `~/.local/bin`, which is
on `PATH`, but like everything else outside the mounts they are gone when the container
exits.

The first build takes a few minutes; after that it is cached.

Pin a version at build time:

```sh
pclaude --pclaude-build --build-arg CLAUDE_CODE_VERSION=2.1.223
pclaude --pclaude-build --build-arg CODEX_VERSION=0.167.0
pclaude --pclaude-build --build-arg GO_VERSION=1.24.5 --build-arg UV_VERSION=0.9.0
```

Updates the harnesses install inside a running container are lost when it exits. Run
`pclaude --pclaude-update` now and then to bake in the current releases. The harnesses
install last in the `Containerfile`, one layer each, so bumping one reuses everything above.

## Development

```sh
just test
```

`test.sh` runs both launchers against a fake `podman` that records its arguments, so
nothing is built or started. Shared behaviour is tested once per launcher. The macOS
credential sync runs against a fake `security` command, so your real Keychain is never
touched; it needs macOS (it uses the real `plutil`) and is skipped elsewhere.

### Adding a harness

`lib.sh` holds everything the launchers share: option parsing, guards, relabelling,
mounts, the build and the `podman run`. A launcher is a short file that sets its name,
env prefix and forwarded variables, defines a few `harness_*` hooks (documented at the
top of `lib.sh`) and calls `yolopod_main`. See `pcodex` for the minimal one. Add the
tool to the `Containerfile`, the launcher to `install.sh`, and its tests to `test.sh`.

## Uninstall

```sh
rm ~/.local/bin/pclaude ~/.local/bin/pcodex
rm -rf ~/.local/share/yolopod
podman rmi -f localhost/yolopod
```
