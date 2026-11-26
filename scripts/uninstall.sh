#!/usr/bin/env bash
# ==============================================================================
# colabd uninstaller
# ==============================================================================

set -euo pipefail

INSTALL_HOME="${COLABD_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/colabd}"
BIN_LINK="${COLABD_BIN_DIR:-$HOME/.local/bin}/colabd"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/colabd"

rm -f "$BIN_LINK"
rm -rf "$INSTALL_HOME"
echo "[colabd] Removed ${BIN_LINK} and ${INSTALL_HOME}."

if [[ -d "$CONFIG_DIR" ]]; then
  if [[ "${1:-}" == "--purge" ]]; then
    rm -rf "$CONFIG_DIR"
    echo "[colabd] Purged configuration directory ${CONFIG_DIR}."
  else
    echo "[colabd] Preserved configuration at ${CONFIG_DIR}. Pass --purge to delete saved tokens."
  fi
fi
