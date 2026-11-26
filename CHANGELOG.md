# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-11-26

### Added

- Modular CLI daemon (`bin/colabd` and `lib/*`) compatible with Linux and macOS Bash 3.2+.
- Interactive terminal control panel with status dashboard, live build and inference log viewer, settings editor, and streaming API test runner.
- Non-blocking Google Colab login probe, interactive OAuth 2.0 and `gcloud` ADC login flows, orphan-safe `colab logout` account switching, and remote VM GCP credential propagation via `colab auth`.
- Default support for uncensored [`orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF`](https://huggingface.co/orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF) (`Mix-128G` and `Mix-256G`) alongside `GLM-5.3-Flash Maya-M-Derisked` and `Inkling 2 Mini` on [`mw00/project-maya`](https://github.com/mw00/project-maya).
- Tiered shard pipeline: Google Drive shard lookup, sequential prefetch of the 161 GB `Engram-Q6_K` table onto local `/content` NVMe SSD, Hugging Face download fallback, and atomic `.syncing.tmp` background sync-back to Google Drive (`both`, `weights_only`, `engram_only`, `none`).
- Full-RAM MoE expert residency control (`--mmap-experts off` and `DS4_REQUIRE_ALL_RAM=1`) to eliminate network filesystem I/O during token generation.
- Tunnel support for Cloudflare Quick Tunnels, Cloudflare Zero Trust Named Tunnels, and native `colab ssh --proxy-mode` local port forwarding.
- Automatic `colab stop` teardown on script exit and `Ctrl+C`.
