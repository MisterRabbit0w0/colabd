# colabd

[![CI](https://github.com/MisterRabbit0w0/colabd/actions/workflows/ci.yml/badge.svg)](https://github.com/MisterRabbit0w0/colabd/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS-lightgrey.svg)](https://github.com/googlecolab/google-colab-cli)

English | [简体中文](README.zh-CN.md)

The endgame for frontier LLM serving on Google Colab.

`colabd` turns a disposable Google Colab GPU VM into a local-controlled frontier LLM server backed by [`google-colab-cli`](https://github.com/googlecolab/google-colab-cli) and [`mw00/project-maya`](https://github.com/mw00/project-maya). It runs 748B MoE models such as [`DeepSeek-V4.1-Flash-1017`](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017) and its uncensored [`orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF`](https://huggingface.co/orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF) builds on a single Colab Pro+ GPU, exposes authenticated OpenAI and Anthropic endpoints over Cloudflare or WebSocket SSH tunnels, and destroys the remote VM automatically the moment you exit.

## Why colabd exists

Serving 300B to 750B MoE models on consumer Google Colab hits three concrete walls:

1. **The 235 GB local disk wall.** A Colab Pro+ `G4` runtime gives you an NVIDIA RTX PRO 6000 Blackwell with 95.6 GB VRAM and 176.9 GB system RAM, which is 272.5 GB of combined memory. Yet its local `/content` NVMe disk only has about 235.7 GB free. `DeepSeek-V4.1-Flash-1017` (`abliterated-128g`) needs about 123 GB for weights and drafters plus 161 GB for the `Engram-Q6_K` lookup table, totaling 284 GB. Storing everything on `/content` runs out of disk space, while running random lookups directly over a Google Drive FUSE mount stalls token generation and triggers rate limits.
2. **Leaked Compute Units.** Detached scripts or forgotten browser sessions keep burning 10.05 Compute Units per hour on `G4` or 18 Compute Units per hour on `H100` after you finish coding.
3. **Kernel liveness drops.** Running daemons over raw SSH alone leaves the Jupyter kernel idle, causing Colab to recycle the VM prematurely.

`colabd` solves all three problems from a single terminal binary on Linux and macOS:

- **Zero network I/O during inference.** In `nvme_engram` mode, `colabd` checks your Google Drive cache first, pulls the 161 GB `Engram-Q6_K` shards onto the fast local `/content` NVMe SSD, falls back to Hugging Face download for any missing shard, and symlinks the 114 GB `Mix-128G` weights from Google Drive. At startup, [`project-maya`](https://github.com/mw00/project-maya/blob/main/docs/MEMORY.md) loads all 114 GB of weights into your 272.5 GB VRAM + pinned RAM pool (`--mmap-experts off`). Once ready, experts run 100% from memory and Engram lookups hit local NVMe plus ~140 GB of Linux page cache.
- **Atomic Drive cache sync.** After the server reaches `/health` HTTP 200, a background worker copies newly downloaded shards back to Google Drive using `.syncing.tmp` temporary files and atomic `os.replace()` renames, governed by your save policy (`both`, `weights_only`, `engram_only`, `none`).
- **Self-contained isolated `uv` runtime.** `install.sh` and `colabd env setup` automatically provision a dedicated Python 3.12 virtualenv in `~/.local/share/colabd-runtime/venv` containing `google-colab-cli` (and bootstrap a private `uv` binary without modifying your shell profile if `uv` is not installed). Every local helper, `keyring` account operation, `colab` invocation, and SSH `ProxyCommand` runs inside that isolated venv — immune to macOS Python 3.9, Ubuntu 22.04 Python 3.10, PEP 668, `conda`/`pyenv` shims, or missing `PATH` entries.
- **Tethered lifecycle & multi-account release safety.** `colabd` executes the remote supervisor inside the Colab Jupyter kernel via `colab exec` to satisfy activity-based liveness, binds `SIGINT`, `SIGTERM`, `SIGHUP`, and `EXIT` traps to stop the runtime under its exact owning account, and solves `google-colab-cli`'s lack of a `logout` command via isolated multi-account profiles (OS keyring slots + `0600` ADC snapshots + per-account `sessions.json`). Switching accounts, logging out, or deleting a profile automatically triggers orphan-runtime release guards, and `colabd down --all` sweeps all saved accounts.

## Architecture

```text
Local Host (Linux / macOS, Bash 3.2+)
  └── colabd (TUI Dashboard + Account-Aware Lifecycle Trap -> `colab stop` on exit)
        ├── Auth Center: Multi-Account OAuth 2.0 Keyring Slots / Isolated ADC / Real Logout / `colab auth`
        ├── Tunnel Bridge: Cloudflare HTTPS or `colab ssh --proxy-mode` -> 127.0.0.1:8080
        └── `colab exec` (keeps Colab Jupyter kernel active)
              │
              ▼
Google Colab GPU VM (e.g., G4 95.6 GB VRAM + 176.9 GB RAM + 235.7 GB Local NVMe)
  └── remote_supervisor.py
        ├── 1. Prefetch cached Engram-Q6_K shards from Google Drive -> Local NVMe
        ├── 2. Fallback download missing shards from Hugging Face
        ├── 3. Load 100% of MoE experts into VRAM + Pinned RAM (`--mmap-experts off`)
        ├── 4. Serve OpenAI (`/v1/chat/completions`, `/v1/responses`) & Anthropic (`/v1/messages`)
        └── 5. Background atomic sync-back (`.syncing.tmp` -> Google Drive)
```

## Requirements

- Linux or macOS with Bash 3.2+ (`colabd` automatically bootstraps its own isolated `uv` + Python 3.12 + [`google-colab-cli`](https://pypi.org/project/google-colab-cli/) runtime under `~/.local/share/colabd-runtime/venv`, with zero system Python 3.12 requirement).
- A Google Colab Pro or Pro+ account for `G4`, `A100`, `H100`, or `L4` GPU runtimes.
- For [`orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF`](https://huggingface.co/orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF): accept the gated repository terms on Hugging Face and generate an `HF_TOKEN`.

## Quick start

Install `colabd` into `~/.local/bin`:

```bash
git clone https://github.com/MisterRabbit0w0/colabd.git
cd colabd
make install
```

Or install in one line:

```bash
curl -fsSL https://raw.githubusercontent.com/MisterRabbit0w0/colabd/main/scripts/install.sh | bash
```

Launch the interactive control panel:

```bash
colabd
```

1. Press `6` to sign in to Google Colab via OAuth 2.0 or [`gcloud`](https://docs.cloud.google.com/sdk/gcloud/reference/colab) ADC.
2. Press `5` to enter Settings, paste your `HF_TOKEN` under option `9`, and choose your storage and tunnel policies. Settings save automatically to `~/.config/colabd/config.env` with `0600` permissions.
3. Press `1` to allocate the GPU runtime, pull or download shards, and open your tunnel.
4. Point Claude Code, VS Code, Cursor, or any OpenAI/Anthropic SDK at the printed URL and Bearer API key.
5. Press `0` or `Ctrl+C` when finished. `colabd` terminates the tunnel and runs `colab stop` to release your runtime.

## Storage topologies and Google Drive policies

Configure both the runtime layout (`STORAGE_MODE`) and post-download write-back policy (`DRIVE_SAVE_POLICY`) in menu option `5`:

| Storage mode | Runtime placement | Best hardware match |
| :--- | :--- | :--- |
| `nvme_engram` | 161 GB `Engram-Q6_K` on local `/content` NVMe; main weights symlinked to Drive and pinned in RAM | Colab Pro+ `G4` (96 GB VRAM, 177 GB RAM, 235 GB NVMe) + 120 GB to 300 GB Google Drive |
| `local_nvme` | Both main weights and `Engram-Q6_K` on local NVMe (still prefetches from and syncs to Drive) | `GLM-5.3-Flash Maya-M-Derisked` (116 GB) on consumer Colab, or Colab Enterprise SSD >= 350 GB |
| `drive_engram` | Main weights on local NVMe; 161 GB `Engram-Q6_K` symlinked to Google Drive | Accounts that want zero Engram transfer wait and accept slower cold n-gram lookups |
| `drive_full` | All weights and tables read and written directly on `/content/drive/MyDrive` | Running `abliterated-256g` (397 GB total) where main weights exceed local 235 GB NVMe |

| Drive save policy | Behavior after fallback download | Google Drive space needed (`Mix-128G`) |
| :--- | :--- | :--- |
| `both` | Atomically backs up both main weights and `Engram-Q6_K` to Google Drive | >= 280 GB |
| `weights_only` | Persists 114 GB main weights on Drive; keeps 161 GB Engram ephemeral on local NVMe | >= 120 GB |
| `engram_only` | Persists 161 GB `Engram-Q6_K` on Drive only | >= 165 GB |
| `none` | Never writes new shards to Drive (Drive acts as read-only cache or stays unmounted) | 0 GB |

## CLI subcommands

```bash
colabd                         # Open the interactive TUI control panel
colabd up                      # Allocate/start runtime immediately and attach TUI tether
colabd auth                    # Open multi-account switcher, real logout, and GCP auth center
colabd auth list               # List saved account profiles and per-account active sessions
colabd auth add [name]         # Add and authenticate a new account profile (--oauth2 / --adc)
colabd auth save [name]        # Archive the current login into a named profile
colabd auth use <name>         # Release active runtime (with guard) and switch account
colabd switch <name>           # Shortcut for 'colabd auth use <name>'
colabd auth logout             # Release active runtime and clear keyring / ADC credentials
colabd auth remove <name>      # Release target account runtimes and delete its profile
colabd settings                # Open persistent configuration editor
colabd down                    # Stop active runtime(s) on the current account
colabd down -a <name>          # Stop active runtime(s) on a specific saved account
colabd down --all              # Sweep and stop active runtimes across ALL saved accounts
colabd env [status|setup|upgrade|reset]
                               # Inspect, bootstrap, upgrade, or rebuild the isolated uv venv
colabd doctor                  # Alias for 'colabd env status'
colabd version                 # Print colabd version
```

## Development and testing

Run syntax validation, ShellCheck, and the end-to-end mock test suite:

```bash
make lint
make test
```

## Acknowledgments

- [`googlecolab/google-colab-cli`](https://github.com/googlecolab/google-colab-cli) for official terminal runtime provisioning, `colab exec`, and WebSocket SSH proxy support.
- [`mw00/project-maya`](https://github.com/mw00/project-maya) by Peasant Smith and contributors for the three-tier VRAM/RAM/NVMe MoE inference engine.
- [`orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF`](https://huggingface.co/orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF) and [`deepseek-ai/DeepSeek-V4.1-Flash-1017`](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017) for open model weights.
- [`cloudflare/cloudflared`](https://github.com/cloudflare/cloudflared) for Quick and Zero Trust HTTPS tunnels.

## License

Released under the [MIT License](LICENSE).
