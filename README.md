# colabd

[![CI](https://github.com/MisterRabbit0w0/colabd/actions/workflows/ci.yml/badge.svg)](https://github.com/MisterRabbit0w0/colabd/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS-lightgrey.svg)](https://github.com/googlecolab/google-colab-cli)

English | [简体中文](README.zh-CN.md)

The endgame for multi-engine LLM serving on Google Colab.

`colabd` turns a disposable Google Colab GPU VM — from a **Free T4 (16 GB)** to a **Pro / Pro+ L4, A100, G4, or H100** — into a local-controlled LLM server backed by [`google-colab-cli`](https://github.com/googlecolab/google-colab-cli), [`Niko1221/Strata`](https://github.com/Niko1221/Strata), and [`mw00/project-maya`](https://github.com/mw00/project-maya). Choose from built-in hardware-tiered presets (`colabd models`) or bring your own Hugging Face repository, expose authenticated OpenAI and Anthropic endpoints over Cloudflare or WebSocket SSH tunnels, and destroy the remote VM automatically the moment you exit.

## Why colabd exists

Serving open-weight LLMs across Google Colab tiers hits three recurring walls:

1. **Local disk vs. network storage trade-offs.** Large sharded weights and external lookup tables can exceed a Colab VM's local `/content` NVMe capacity, while random reads directly over a Google Drive FUSE mount stall token generation and trigger rate limits.
2. **Leaked Compute Units.** Detached scripts or forgotten browser sessions keep burning Colab compute units after you finish working.
3. **Kernel liveness drops & runtime friction.** Running daemons over raw SSH alone leaves the Jupyter kernel idle so Colab recycles the VM prematurely, while switching between Free standard-RAM runtimes and Pro/Pro+ high-RAM GPUs requires matching engine binaries, drivers, and launch flags.

`colabd` solves all three problems from a single terminal binary on Linux and macOS:

- **Multi-engine dispatch with hardware-aware defaults.** Supports both **Strata** (prebuilt CUDA fast-path with automatic source-build fallback on older drivers) and **Project Maya** (three-tier VRAM/RAM/NVMe MoE engine with optional refusal-direction ablation), plus custom Hugging Face `.strata`, `.gguf`, and safetensors repositories. Switching presets automatically aligns recommended GPU, `--high-mem` (off on Free `T4`), context length, and storage layout.
- **Direct-to-target storage & high-speed HF downloads.** Models that fit on local `/content` NVMe run purely locally without mounting Google Drive, using multi-threaded HTTP Range downloads and `HF_HUB_ENABLE_HF_TRANSFER=1` / `HF_XET_HIGH_PERFORMANCE=1`. Oversized models expand directly onto Google Drive with zero post-download sync-back: Drive-bound weights stream straight to Drive via **Google Drive REST API v3 Resumable Upload** (zero local write cache, HTTP 200 verified) when `colab auth` credentials are available, or fall back to sequential FUSE direct-write guarded by local root disk watermark backpressure and pre-exit flush protection, while experts stay resident in VRAM + pinned RAM (`--mmap-experts off`).
- **Self-contained isolated `uv` runtime.** `install.sh` and `colabd env setup` automatically provision a dedicated Python 3.12 virtualenv in `~/.local/share/colabd-runtime/venv` containing `google-colab-cli` (and bootstrap a private `uv` binary without modifying your shell profile if `uv` is not installed). Every local helper, `keyring` account operation, `colab` invocation, and SSH `ProxyCommand` runs inside that isolated venv — immune to macOS Python 3.9, Ubuntu 22.04 Python 3.10, PEP 668, `conda`/`pyenv` shims, or missing `PATH` entries.
- **Tethered lifecycle, identity-based accounts & scope repair.** `colabd` executes the remote supervisor inside the Colab Jupyter kernel via `colab exec` for activity-based liveness, binds `SIGINT`/`SIGTERM`/`SIGHUP`/`EXIT` traps to stop runtimes under their exact owning account, and manages accounts keyed uniquely by normalized `(email, auth_mode)` (automatic deduplication, OS keyring OAuth 2.0 storage, `0600` ADC snapshots, and per-account `sessions.json`). Login and `colabd auth refresh` inspect granted `Scopes` via `colab whoami` to catch and repair missing permissions (such as `colaboratory` or `drive.file`), while `auth remove` / `auth logout` enforce a hard release gate that refuses to delete credentials if stopping active runtimes fails.

## Architecture

```text
Local Host (Linux / macOS, Bash 3.2+)
  └── colabd (TUI Dashboard + Model Registry + Account-Aware Lifecycle Trap -> `colab stop` on exit)
        ├── Auth Center: Identity-Based OAuth 2.0 Keyring / Isolated ADC / Scope Repair / Safe Logout
        ├── Tunnel Bridge: Cloudflare HTTPS or `colab ssh --proxy-mode` -> 127.0.0.1:8081
        └── `colab exec` (keeps Colab Jupyter kernel active)
              │
              ▼
Google Colab GPU VM (Free T4 / L4 / A100 / G4 / H100)
  └── remote_supervisor.py
        ├── 1. Probe GPU, VRAM, NVIDIA driver version, system RAM, and disk space
        ├── 2. Direct-to-target placement: multi-threaded Range HF -> local NVMe, or Drive API streaming / FUSE direct -> Drive
        ├── 3. Dispatch engine adapter (Strata prebuilt/source or Project Maya)
        ├── 4. Serve authenticated OpenAI (`/v1/chat/completions`, `/v1/responses`) & Anthropic (`/v1/messages`)
        └── 5. Poll `/health` readiness & guard FUSE DriveFS cache / flush on exit
```

## Supported engines & hardware tiers

Run `colabd models` to inspect the full built-in preset catalog grouped by hardware tier, or configure any custom Hugging Face repository in Settings:

| Tier / Hardware | Engines | Capabilities |
| :--- | :--- | :--- |
| **Free / Entry (`T4 16GB`, Std-RAM)** | `strata`, `maya` | Prebuilt CUDA fast-path (with automatic source-build fallback on older drivers), standard-RAM allocation with automatic `--high-mem` fallback, and local NVMe serving without requiring Google Drive. |
| **Mid-Range (`L4 24GB` / High-RAM)** | `strata`, `maya` | Higher-precision quantizations, vision input, speculative drafting, and concurrent request slots. |
| **Flagship (`A100` / `G4` / `H100`)** | `maya`, `strata` | Large-scale MoE serving with three-tier VRAM/RAM/NVMe memory management and hybrid Drive routing. |
| **Custom HF Repo / Quant** | `strata`, `maya` | Bring your own Hugging Face `.strata`, `.gguf`, safetensors repo, or upstream engine quant argument with multi-threaded NVMe downloads and direct-to-Drive expansion. |

## Requirements

- Linux or macOS with Bash 3.2+ (`colabd` automatically bootstraps its own isolated `uv` + Python 3.12 + [`google-colab-cli`](https://pypi.org/project/google-colab-cli/) runtime under `~/.local/share/colabd-runtime/venv`, with zero system Python 3.12 requirement).
- A **Google Colab Free** account (`T4` 16 GB standard RAM) or a **Colab Pro / Pro+** account (`L4`, `A100`, `G4`, or `H100`).
- Optional: an `HF_TOKEN` when downloading from gated or private Hugging Face repositories.

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

Use the CLI directly or launch the interactive control panel:

```bash
colabd auth login              # Sign in to Google Colab (OAuth 2.0 or ADC)
colabd models                  # Browse built-in presets grouped by hardware tier
colabd use <preset-id>         # Select a preset and auto-apply recommended GPU/RAM settings
colabd up                      # Allocate VM, start engine, and open tunnel
```

Or launch `colabd` with no arguments for the interactive TUI:

1. Press `6` to sign in to Google Colab via OAuth 2.0 or [`gcloud`](https://docs.cloud.google.com/sdk/gcloud/reference/colab) ADC.
2. Press `5` to enter Settings, choose an engine and model preset (or configure a custom HF repo), add an `HF_TOKEN` if using gated repos, and pick your storage and tunnel policies. Settings save automatically to `~/.config/colabd/config.env` with `0600` permissions.
3. Press `1` to allocate the GPU runtime, pull or download shards, and open your tunnel.
4. Point Claude Code, VS Code, Cursor, or any OpenAI/Anthropic SDK at the printed URL and Bearer API key.
5. Press `0` or `Ctrl+C` when finished. `colabd` terminates the tunnel and runs `colab stop` to release your runtime.

## Storage topologies and direct-to-Drive expansion

Configure both the runtime layout (`STORAGE_MODE`) and download/Drive write transport (`HF_DOWNLOAD_CONCURRENCY` / `DRIVE_WRITE_MODE`) in menu option `5`:

| Storage mode | Runtime placement | Best match |
| :--- | :--- | :--- |
| `auto` | Picks `local_nvme` (zero Drive mount) when the model fits local disk, or `nvme_engram` / `drive_full` when capacity expansion is needed | Recommended default across Free and Pro+ runtimes |
| `local_nvme` | All files download directly to local `/content` NVMe via multi-threaded HTTP Range (never mounts Google Drive) | Models that fit within local VM disk capacity |
| `nvme_engram` | External lookup tables download directly to local `/content` NVMe; main weights download directly to Google Drive and load into VRAM + pinned RAM | Large external-table models whose combined size exceeds local NVMe |
| `drive_engram` | Main weights download directly to local NVMe; external lookup tables live directly on Google Drive | Skipping lookup-table local storage when slower cold lookups are acceptable |
| `drive_full` | All weights and tables download and run directly on `/content/drive/MyDrive` | Very large models whose weights exceed local VM disk capacity |

| Drive write mode (`DRIVE_WRITE_MODE`) | Direct-to-Drive transport behavior (used only during Drive expansion) |
| :--- | :--- |
| `auto` | Uses **Google Drive REST API v3 Resumable Streaming** (0 local cache, HTTP 200 verified) whenever remote `colab auth` credentials are present; automatically falls back to FUSE direct-write with local disk watermark backpressure |
| `api_stream` | Enforces Google Drive REST API v3 streaming upload (automatically triggers `colab auth` on expansion start) |
| `fuse` | Uses sequential `/content/drive` FUSE direct-write with local root disk watermark backpressure and pre-exit flush protection (no `colab auth` needed) |

## CLI subcommands

```bash
colabd                         # Open the interactive TUI control panel
colabd up [--model ID] [--engine strata|maya] [--gpu T4|L4|A100|G4|H100] [--standard-mem|--high-mem]
                               # Allocate/start runtime immediately and attach TUI tether
colabd models [--tier free|mid|flagship|custom] [--engine strata|maya]
                               # List built-in presets grouped by hardware tier & engine
colabd use <preset-id> [--engine strata|maya] [--keep-hw]
                               # Switch active preset and auto-apply recommended GPU/RAM settings
colabd auth                    # Open account management, scope check & GCP auth center
colabd auth list               # List logged-in accounts (deduped by email), scope status & sessions
colabd auth login              # Log in a Google account (auto-dedup + strict scope check, --oauth2 / --adc)
colabd auth refresh [id]       # Re-authorize in-place to repair missing scopes without losing sessions.json
colabd auth use <id>           # Release active runtime (with guard) and switch account
colabd switch <id>             # Shortcut for 'colabd auth use <id>'
colabd auth note <id> <text>   # Edit an optional display note for an account
colabd auth remove <id>        # Fail-closed release of active runtimes, then remove account (--revoke / --force)
colabd auth logout             # Safely release & remove the currently active account (--revoke / --force)
colabd settings                # Open persistent configuration editor
colabd down                    # Stop active runtime(s) on the current account
colabd down -a <id>            # Stop active runtime(s) on a specific account
colabd down --all              # Sweep and stop active runtimes across ALL accounts
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
- [`Niko1221/Strata`](https://github.com/Niko1221/Strata) for the consumer-hardware MoE inference engine with prebuilt CUDA binaries and OpenAI/Anthropic APIs.
- [`mw00/project-maya`](https://github.com/mw00/project-maya) for the three-tier VRAM/RAM/NVMe MoE inference engine.
- [`cloudflare/cloudflared`](https://github.com/cloudflare/cloudflared) for Quick and Zero Trust HTTPS tunnels.

## License

Released under the [MIT License](LICENSE).
