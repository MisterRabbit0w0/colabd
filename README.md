# colabd

[![CI](https://github.com/MisterRabbit0w0/colabd/actions/workflows/ci.yml/badge.svg)](https://github.com/MisterRabbit0w0/colabd/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS-lightgrey.svg)](https://github.com/googlecolab/google-colab-cli)

English | [简体中文](README.zh-CN.md)

The endgame for multi-engine frontier & free-tier LLM serving on Google Colab.

`colabd` turns a disposable Google Colab GPU VM — from a **Free T4 (16 GB)** to a **Pro+ G4 (96 GB Blackwell) / H100 / A100 / L4** — into a local-controlled LLM server backed by [`google-colab-cli`](https://github.com/googlecolab/google-colab-cli), [`Niko1221/Strata`](https://github.com/Niko1221/Strata), and [`mw00/project-maya`](https://github.com/mw00/project-maya). It runs everything from **Free-tier uncensored `Inkling-2-Mini` (`SC117/Inkling-2-Mini-abliterated-Strata` SQ-10/15 & GGUFs)**, `Qwen3.8-Flash-Next`, `Qwen3.6-35B-A3B`, and `Tencent Hy4-Flash` to 300B–750B frontier MoE models (`DeepSeek-V4.1-Flash-1017`, `GLM-5.3 744B`, `GLM-5.3-Flash 321B`, `MiniMax-M3.1-Flash 428B`) and custom Hugging Face repositories, exposing authenticated OpenAI and Anthropic endpoints over Cloudflare or WebSocket SSH tunnels while automatically destroying the remote VM on exit.

## Why colabd exists

Serving 300B to 750B MoE models on consumer Google Colab hits three concrete walls:

1. **The 235 GB local disk wall.** A Colab Pro+ `G4` runtime gives you an NVIDIA RTX PRO 6000 Blackwell with 95.6 GB VRAM and 176.9 GB system RAM, which is 272.5 GB of combined memory. Yet its local `/content` NVMe disk only has about 235.7 GB free. `DeepSeek-V4.1-Flash-1017` (`abliterated-128g`) needs about 123 GB for weights and drafters plus 161 GB for the `Engram-Q6_K` lookup table, totaling 284 GB. Storing everything on `/content` runs out of disk space, while running random lookups directly over a Google Drive FUSE mount stalls token generation and triggers rate limits.
2. **Leaked Compute Units.** Detached scripts or forgotten browser sessions keep burning 10.05 Compute Units per hour on `G4` or 18 Compute Units per hour on `H100` after you finish coding.
3. **Kernel liveness drops.** Running daemons over raw SSH alone leaves the Jupyter kernel idle, causing Colab to recycle the VM prematurely.

`colabd` solves all three problems from a single terminal binary on Linux and macOS:

- **Zero network I/O during inference.** In `nvme_engram` mode, `colabd` checks your Google Drive cache first, pulls the 161 GB `Engram-Q6_K` shards onto the fast local `/content` NVMe SSD, falls back to Hugging Face download for any missing shard, and symlinks the 114 GB `Mix-128G` weights from Google Drive. At startup, [`project-maya`](https://github.com/mw00/project-maya/blob/main/docs/MEMORY.md) loads all 114 GB of weights into your 272.5 GB VRAM + pinned RAM pool (`--mmap-experts off`). Once ready, experts run 100% from memory and Engram lookups hit local NVMe plus ~140 GB of Linux page cache.
- **Atomic Drive cache sync.** After the server reaches `/health` HTTP 200, a background worker copies newly downloaded shards back to Google Drive using `.syncing.tmp` temporary files and atomic `os.replace()` renames, governed by your save policy (`both`, `weights_only`, `engram_only`, `none`).
- **Self-contained isolated `uv` runtime.** `install.sh` and `colabd env setup` automatically provision a dedicated Python 3.12 virtualenv in `~/.local/share/colabd-runtime/venv` containing `google-colab-cli` (and bootstrap a private `uv` binary without modifying your shell profile if `uv` is not installed). Every local helper, `keyring` account operation, `colab` invocation, and SSH `ProxyCommand` runs inside that isolated venv — immune to macOS Python 3.9, Ubuntu 22.04 Python 3.10, PEP 668, `conda`/`pyenv` shims, or missing `PATH` entries.
- **Tethered lifecycle, identity-based accounts & scope repair.** `colabd` executes the remote supervisor inside the Colab Jupyter kernel via `colab exec` for activity-based liveness, binds `SIGINT`/`SIGTERM`/`SIGHUP`/`EXIT` traps to stop runtimes under their exact owning account, and manages accounts keyed uniquely by normalized `(email, auth_mode)` (automatic deduplication, OS keyring OAuth 2.0 storage, `0600` ADC snapshots, and per-account `sessions.json`). Login and `colabd auth refresh` inspect granted `Scopes` via `colab whoami` to catch and repair missing permissions (such as `colaboratory` or `drive.file`), while `auth remove` / `auth logout` enforce a hard release gate that refuses to delete credentials if stopping active runtimes fails.

## Architecture

```text
Local Host (Linux / macOS, Bash 3.2+)
  └── colabd (TUI Dashboard + Account-Aware Lifecycle Trap -> `colab stop` on exit)
        ├── Auth Center: Identity-Based OAuth 2.0 Keyring / Isolated ADC / Scope Repair / Safe Logout
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

## Supported engines & tiered model presets

`colabd` ships a unified model registry (`lib/model_registry.py`) supporting **two engines** and **custom Hugging Face repos**:

| Tier / Hardware | Engine | Representative Presets | Notes |
| :--- | :--- | :--- | :--- |
| **Free / Entry (`T4 16GB`, Std-RAM)** | `strata` | `strata-inkling-uncensored-sq10` *(Free T4 pick)*, `strata-inkling-uncensored-sq15`, `strata-inkling-uncensored-gguf`, `strata-inkling-sq10/15` | Uses [`SC117/Inkling-2-Mini-abliterated-Strata`](https://huggingface.co/SC117/Inkling-2-Mini-abliterated-Strata) (`.strata` v1.1 + DSpark + BF16 Vision) or `AtomicChat` GGUF. Prebuilt CUDA fast-path on drivers >= 575.51 with automatic source-build fallback on older Colab nodes; automatically omits `--high-mem`. |
| **Free / Entry (`T4 16GB`)** | `maya` | `maya-inkling-2-mini` *(alias `inkling-2-mini`)* | Project Maya `maya-ik2` with built-in refusal ablation vector (`--ablation on`, optional `--ablate-default on`). |
| **Mid-Range (`L4 24GB` / High-RAM)** | `strata` / `maya` | `strata-inkling-uncensored-sq20`, `strata-qwen36-q4`, `strata-qwen38-coder`, `strata-qwen38-gyro-s`, `strata-qwen38-q2`, `glm-maya-xs`, `glm-maya-s24`, `hy4-flash-maya-xs` | Covers 26B lossless, 35B MoE, Qwen3.8-Flash-Next Coder/Q2, GLM-5.3-Flash S24, and Tencent Hy4-Flash. |
| **Flagship (`A100` / `G4` / `H100`)** | `maya` / `strata` | `ds4-abliterated-128g/256g`, `deepseek-maya-xs/s`, `glm-5.3-maya-xs` (744B), `glm-maya-m-derisked/l`, `minimax-maya-xs/s` (428B), `hy4-flash-maya-m/l`, `strata-qwen38-iq3s/unsloth-q4`, `strata-hy4-sq96` | Full three-tier VRAM/RAM/NVMe MoE serving with `nvme_engram` hybrid Drive routing. |
| **Custom HF Repo / Quant** | `strata` / `maya` | `strata-custom-hf`, `maya-custom` | Point at any Hugging Face `.strata`, `.gguf`, safetensors repo, or upstream engine quant ID with Drive prefetch & atomic sync-back. |

### Free-tier quick start (`T4` + Strata + Inkling-2-Mini Uncensored)

```bash
colabd auth login
colabd use strata-inkling-uncensored-sq10   # Switches to Strata, T4, HIGH_MEM=0, local_nvme
colabd up
```

## Requirements

- Linux or macOS with Bash 3.2+ (`colabd` automatically bootstraps its own isolated `uv` + Python 3.12 + [`google-colab-cli`](https://pypi.org/project/google-colab-cli/) runtime under `~/.local/share/colabd-runtime/venv`, with zero system Python 3.12 requirement).
- A **Google Colab Free** account (`T4` 16 GB standard RAM for Strata/Maya `Inkling-2-Mini` presets) **or** a Colab Pro / Pro+ account for `L4`, `A100`, `G4`, or `H100` runtimes.
- For gated Hugging Face repositories such as [`orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF`](https://huggingface.co/orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF): accept the repository terms and provide an `HF_TOKEN`.

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
- [`Niko1221/Strata`](https://github.com/Niko1221/Strata) for the consumer-hardware MoE & `strata-inkling` inference engine with prebuilt CUDA binaries and OpenAI/Anthropic APIs.
- [`mw00/project-maya`](https://github.com/mw00/project-maya) by Peasant Smith and contributors for the three-tier VRAM/RAM/NVMe frontier MoE inference engine.
- [`SC117/Inkling-2-Mini-abliterated-Strata`](https://huggingface.co/SC117/Inkling-2-Mini-abliterated-Strata), [`OpenUncensored/Inkling-2-Mini-Uncensored`](https://huggingface.co/OpenUncensored/Inkling-2-Mini-Uncensored), [`AtomicChat/Inkling-2-Mini-Uncensored-GGUF`](https://huggingface.co/AtomicChat/Inkling-2-Mini-Uncensored-GGUF), [`orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF`](https://huggingface.co/orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF), and [`deepseek-ai/DeepSeek-V4.1-Flash-1017`](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017) for open model weights.
- [`cloudflare/cloudflared`](https://github.com/cloudflare/cloudflared) for Quick and Zero Trust HTTPS tunnels.

## License

Released under the [MIT License](LICENSE).
