#!/usr/bin/env bash
# ==============================================================================
# colabd uninstaller
# ==============================================================================

set -euo pipefail

INSTALL_HOME="${COLABD_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/colabd}"
RUNTIME_DIR="${COLABD_RUNTIME_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/colabd-runtime}"
BIN_LINK="${COLABD_BIN_DIR:-$HOME/.local/bin}/colabd"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/colabd"

PURGE=0
if [[ "${1:-}" == "--purge" ]]; then
  PURGE=1
fi

if [[ "$PURGE" -eq 1 && -d "${CONFIG_DIR}/accounts" ]]; then
  STORE_SCRIPT=""
  if [[ -f "${INSTALL_HOME}/lib/account_store.py" ]]; then
    STORE_SCRIPT="${INSTALL_HOME}/lib/account_store.py"
  else
    SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
    if [[ -n "$SCRIPT_SOURCE" && -f "$SCRIPT_SOURCE" ]]; then
      CANDIDATE_STORE="$(cd -P "$(dirname "$SCRIPT_SOURCE")/.." && pwd)/lib/account_store.py"
      [[ -f "$CANDIDATE_STORE" ]] && STORE_SCRIPT="$CANDIDATE_STORE"
    fi
  fi
  PY_BIN=""
  if [[ -x "${RUNTIME_DIR}/venv/bin/python" ]]; then
    PY_BIN="${RUNTIME_DIR}/venv/bin/python"
  elif command -v python3 >/dev/null 2>&1; then
    PY_BIN="$(command -v python3)"
  fi
  if [[ -n "$STORE_SCRIPT" && -n "$PY_BIN" ]]; then
    "$PY_BIN" "$STORE_SCRIPT" purge-all-keyrings "${CONFIG_DIR}/accounts" >/dev/null 2>&1 || true
  fi
fi

rm -f "$BIN_LINK"
rm -rf "$INSTALL_HOME" "$RUNTIME_DIR"
echo "[colabd] Removed ${BIN_LINK}, ${INSTALL_HOME}, and isolated runtime ${RUNTIME_DIR}."

if [[ -d "$CONFIG_DIR" ]]; then
  if [[ "$PURGE" -eq 1 ]]; then
    rm -rf "$CONFIG_DIR"
    echo "[colabd] Purged configuration directory ${CONFIG_DIR} and saved account keyring entries."
  else
    echo "[colabd] Preserved configuration at ${CONFIG_DIR}. Pass --purge to delete saved accounts and tokens."
  fi
fi
