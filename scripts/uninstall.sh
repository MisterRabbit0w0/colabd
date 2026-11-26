#!/usr/bin/env bash
# ==============================================================================
# colabd uninstaller
# ==============================================================================

set -euo pipefail

INSTALL_HOME="${COLABD_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/colabd}"
RUNTIME_DIR="${COLABD_RUNTIME_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/colabd-runtime}"
BIN_LINK="${COLABD_BIN_DIR:-$HOME/.local/bin}/colabd"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/colabd"

rm -f "$BIN_LINK"
rm -rf "$INSTALL_HOME" "$RUNTIME_DIR"
echo "[colabd] Removed ${BIN_LINK}, ${INSTALL_HOME}, and isolated runtime ${RUNTIME_DIR}."

if [[ -d "$CONFIG_DIR" ]]; then
  if [[ "${1:-}" == "--purge" ]]; then
    rm -rf "$CONFIG_DIR"
    echo "[colabd] Purged configuration directory ${CONFIG_DIR}."
  else
    echo "[colabd] Preserved configuration at ${CONFIG_DIR}. Pass --purge to delete saved accounts and tokens."
  fi
fi
