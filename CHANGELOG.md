# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-11-26

### Added

- Self-contained isolated `uv` Python 3.12 runtime (`~/.local/share/colabd-runtime/venv`) managed via `install.sh` and `colabd env [status|setup|upgrade|reset]` / `colabd doctor`, eliminating system Python version, PEP 668, `PATH`, and `conda`/`pyenv` shim breakage.
- Modular CLI daemon (`bin/colabd` and `lib/*`) compatible with Linux and macOS Bash 3.2+.
- Interactive terminal control panel with status dashboard, live build and inference log viewer, settings editor, and streaming API test runner.
- Identity-based multi-account management keyed uniquely by normalized `(email, auth_mode)` with automatic duplicate detection, auto-adoption of external logins, `colab whoami` scope validation & `colabd auth refresh` in-place permission repair, fail-closed safe account removal (`auth remove` / `auth logout` with opt-in `--revoke` and `--force`, refusing credential deletion if runtime stop or verification fails or a daemon is live), `colabd down -a <id>` / `colabd down --all` cross-account cleanup, and remote VM GCP credential propagation via `colab auth`.
- Multi-engine inference support ([`Niko1221/Strata`](https://github.com/Niko1221/Strata) and [`mw00/project-maya`](https://github.com/mw00/project-maya)) with a unified hardware-tiered preset registry (`lib/model_registry.py`), custom Hugging Face repository support, and `colabd models` / `colabd use` commands.
- Direct-to-target storage & high-speed download pipeline: multi-threaded HTTP Range downloads (plus `hf_transfer`/`hf_xet` acceleration) directly onto local `/content` NVMe without mounting Google Drive for fitting models, and direct-to-Drive capacity expansion (`nvme_engram`, `drive_engram`, `drive_full`) via Google Drive REST API v3 Resumable Upload (zero local cache) with automatic FUSE sequential direct-write, local root disk watermark backpressure, and pre-exit flush fallback.
- Full-RAM MoE expert residency control (`--mmap-experts off`) and engine-specific tuning options (KV format, concurrency, driver-aware build fallback, and refusal-direction ablation switches).
- Tunnel support for Cloudflare Quick Tunnels, Cloudflare Zero Trust Named Tunnels, and native `colab ssh --proxy-mode` local port forwarding.
- Automatic `colab stop` teardown on script exit and `Ctrl+C`.
