# Contributing to colabd

## Architecture

`colabd` splits host control from remote execution across eight files:

- `bin/colabd` resolves symlinks, parses subcommands (including `models`/`use`/`up`, multi-account `auth`/`switch`/`down`, and runtime `env`/`doctor`), registers signal traps, and loads modules.
- `lib/model_registry.py` provides the single source of truth for inference engine definitions, hardware-tiered presets, and custom Hugging Face model resolution.
- `lib/core.sh` manages atomic `0600` config files in `~/.config/colabd/config.env`, per-account `colab` CLI wrappers, and registry metadata lookups.
- `lib/env.sh` manages `colabd`'s isolated `uv` Python 3.12 runtime (`~/.local/share/colabd-runtime/venv`), standalone `uv` bootstrap, unified `colab`/`python` binary resolution, and environment diagnostics (`colabd doctor`).
- `lib/account_store.py` manages identity-based accounts keyed uniquely by normalized `(email, auth_mode)`, OS keyring OAuth 2.0 entries, `0600` ADC credential snapshots, isolated per-account `sessions.json` files, `colab whoami` scope validation, opt-in token revocation / keyring purging, and optional orphan runtime unassignment.
- `lib/auth.sh` probes [`google-colab-cli`](https://github.com/googlecolab/google-colab-cli) login state, email, and granted scopes (`colab whoami`), manages deduplicated login, in-place scope repair (`auth refresh`), switching, safe removal/logout, and remote VM GCP credential forwarding via `colab auth`.
- `lib/lifecycle.sh` allocates Colab GPU runtimes (with Free-tier `--high-mem` fallback), tracks runtime account ownership, enforces pre-switch guards and Fail-Closed pre-delete release verification gates, sweeps all saved accounts (`colabd down --all`), verifies `/content` disk space and Google Drive mount readiness, manages local OpenSSH `ProxyCommand` port forwarding, and runs account-aware `colab stop` on exit.
- `lib/remote_supervisor.py` runs inside the remote Colab Jupyter kernel via `colab exec`. Keeping the kernel active maintains Colab liveness. The supervisor probes GPU/driver/memory metrics, configures direct-to-target storage (`local_nvme` without Drive mount, or `nvme_engram`/`drive_engram`/`drive_full` for Drive expansion), downloads local NVMe models via multi-threaded HTTP Range workers, streams Drive-bound expansion weights via Google Drive REST API v3 Resumable Upload (with FUSE watermark-backpressure fallback), starts `cloudflared`, dispatches the selected inference engine ([`Niko1221/Strata`](https://github.com/Niko1221/Strata) or [`mw00/project-maya`](https://github.com/mw00/project-maya)), and polls `/health` for readiness.

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
