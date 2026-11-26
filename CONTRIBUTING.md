# Contributing to colabd

## Architecture

`colabd` splits host control from remote execution across five files:

- `bin/colabd` resolves symlinks, parses subcommands, registers signal traps, and loads modules.
- `lib/core.sh` manages atomic `0600` config files in `~/.config/colabd/config.env` and maps model metadata.
- `lib/auth.sh` probes [`google-colab-cli`](https://github.com/googlecolab/google-colab-cli) login state without opening unwanted browser tabs, runs OAuth 2.0 or `gcloud` ADC login flows, stops active runtimes before `colab logout`, and forwards GCP credentials with `colab auth`.
- `lib/lifecycle.sh` allocates Colab GPU runtimes, checks `/content` disk space, mounts Google Drive when needed, manages local OpenSSH `ProxyCommand` port forwarding, and runs `colab stop` on exit.
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
