# Contributing to colabd

## Architecture

`colabd` splits host control from remote execution across six files:

- `bin/colabd` resolves symlinks, parses subcommands (including multi-account `auth`/`switch`/`down`), registers signal traps, and loads modules.
- `lib/core.sh` manages atomic `0600` config files in `~/.config/colabd/config.env`, per-account `colab` CLI wrappers, and model metadata.
- `lib/account_store.py` manages OS keyring OAuth 2.0 profile slots, `0600` ADC credential snapshots, isolated per-account `sessions.json` files, real credential clearing (logout), and optional orphan runtime unassignment.
- `lib/auth.sh` probes [`google-colab-cli`](https://github.com/googlecolab/google-colab-cli) login state and email (`colab whoami`), manages multi-account add/save/switch/delete/logout flows, and forwards GCP credentials with `colab auth`.
- `lib/lifecycle.sh` allocates Colab GPU runtimes, tracks runtime account ownership, enforces pre-switch/pre-logout/pre-delete release guards, sweeps all saved accounts (`colabd down --all`), checks `/content` disk space, mounts Google Drive, manages local OpenSSH `ProxyCommand` port forwarding, and runs account-aware `colab stop` on exit.
- `lib/remote_supervisor.py` runs inside the remote Colab Jupyter kernel via `colab exec`. Keeping the kernel active maintains Colab liveness. The supervisor prefetches cached shards from Google Drive onto local NVMe, configures symlinks, starts `cloudflared`, launches [`mw00/project-maya`](https://github.com/mw00/project-maya), polls `/health`, and syncs newly downloaded shards back to Google Drive using atomic `.syncing.tmp` renames.

## Host shell portability rules

macOS ships with Bash 3.2 at `/bin/bash`. Every `.sh` file in `bin/`, `lib/`, `scripts/`, and `tests/` must run cleanly under Bash 3.2 as well as Bash 5.x on Linux:

1. Do not use `declare -A`, `${var,,}`, `read -i`, or `mapfile`.
2. Do not use `sed -i` or GNU-only flags on the host.
3. Create temporary directories with `mktemp -d "${TMPDIR:-/tmp}/colabd.XXXXXX"` so BSD `mktemp` succeeds.

## Running checks locally

Run the full lint and integration suite before opening a pull request:

```bash
make lint
make test
```
