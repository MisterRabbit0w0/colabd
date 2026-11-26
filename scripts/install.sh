#!/usr/bin/env bash
# ==============================================================================
# colabd installer
# Supports both local checkout installation and remote `curl -fsSL ... | bash`
# ==============================================================================

set -euo pipefail

REPO_URL="${COLABD_REPO_URL:-https://github.com/MisterRabbit0w0/colabd.git}"
INSTALL_HOME="${COLABD_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/colabd}"
BIN_DIR="${COLABD_BIN_DIR:-$HOME/.local/bin}"

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
LOCAL_ROOT=""
if [[ -n "$SCRIPT_SOURCE" && -f "$SCRIPT_SOURCE" ]]; then
  CANDIDATE_ROOT="$(cd -P "$(dirname "$SCRIPT_SOURCE")/.." && pwd)"
  if [[ -f "${CANDIDATE_ROOT}/bin/colabd" && -f "${CANDIDATE_ROOT}/lib/core.sh" ]]; then
    LOCAL_ROOT="$CANDIDATE_ROOT"
  fi
fi

mkdir -p "$BIN_DIR" "$(dirname "$INSTALL_HOME")"

if [[ -n "$LOCAL_ROOT" ]]; then
  echo "[colabd] Installing from local checkout: ${LOCAL_ROOT}"
  rm -rf "$INSTALL_HOME"
  mkdir -p "$INSTALL_HOME"
  cp -R "${LOCAL_ROOT}/bin" "${LOCAL_ROOT}/lib" "${LOCAL_ROOT}/scripts" "$INSTALL_HOME/"
else
  if ! command -v git >/dev/null 2>&1; then
    echo "[ERROR] git is required for remote installation." >&2
    exit 1
  fi
  if [[ -d "${INSTALL_HOME}/.git" ]]; then
    echo "[colabd] Updating existing installation in ${INSTALL_HOME}..."
    git -C "$INSTALL_HOME" pull --ff-only
  else
    echo "[colabd] Cloning ${REPO_URL} into ${INSTALL_HOME}..."
    rm -rf "$INSTALL_HOME"
    git clone --depth 1 "$REPO_URL" "$INSTALL_HOME"
  fi
fi

chmod +x "${INSTALL_HOME}/bin/colabd" "${INSTALL_HOME}/scripts/install.sh" "${INSTALL_HOME}/scripts/uninstall.sh"
ln -sf "${INSTALL_HOME}/bin/colabd" "${BIN_DIR}/colabd"

echo "[colabd] Installed executable to ${BIN_DIR}/colabd"
if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
  echo "[NOTE] Add ${BIN_DIR} to your PATH:"
  echo "       export PATH=\"${BIN_DIR}:\$PATH\""
fi
echo "[colabd] Run 'colabd' to start the interactive control panel."
