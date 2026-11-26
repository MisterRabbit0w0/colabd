# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-11-26

### Added

- Self-contained isolated `uv` Python 3.12 runtime (`~/.local/share/colabd-runtime/venv`) managed via `install.sh` and `colabd env [status|setup|upgrade|reset]` / `colabd doctor`, eliminating system Python version, PEP 668, `PATH`, and `conda`/`pyenv` shim breakage.
- Modular CLI daemon (`bin/colabd` and `lib/*`) compatible with Linux and macOS Bash 3.2+.
- Interactive terminal control panel with status dashboard, live build and inference log viewer, settings editor, and streaming API test runner.
- Identity-based multi-account management keyed uniquely by normalized `(email, auth_mode)` with automatic duplicate detection, auto-adoption of external logins, `colab whoami` scope validation & `colabd auth refresh` in-place permission repair, fail-closed safe account removal (`auth remove` / `auth logout` with opt-in `--revoke` and `--force`, refusing credential deletion if runtime stop or verification fails or a daemon is live), `colabd down -a <id>` / `colabd down --all` cross-account cleanup, and remote VM GCP credential propagation via `colab auth`.
- Default support for uncensored [`orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF`](https://huggingface.co/orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF) (`Mix-128G` and `Mix-256G`) alongside `GLM-5.3-Flash Maya-M-Derisked` and `Inkling 2 Mini` on [`mw00/project-maya`](https://github.com/mw00/project-maya).
- Tiered shard pipeline: Google Drive shard lookup, sequential prefetch of the 161 GB `Engram-Q6_K` table onto local `/content` NVMe SSD, Hugging Face download fallback, and atomic `.syncing.tmp` background sync-back to Google Drive (`both`, `weights_only`, `engram_only`, `none`).
- Full-RAM MoE expert residency control (`--mmap-experts off` and `DS4_REQUIRE_ALL_RAM=1`) to eliminate network filesystem I/O during token generation.
- Tunnel support for Cloudflare Quick Tunnels, Cloudflare Zero Trust Named Tunnels, and native `colab ssh --proxy-mode` local port forwarding.
- Automatic `colab stop` teardown on script exit and `Ctrl+C`.
