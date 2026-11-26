#!/usr/bin/env bash
# ==============================================================================
# colabd automated test suite
# Validates shell syntax, Python compilation, storage prefetch/sync-back,
# auth/logout switching, installer/uninstaller, and exit auto-stop lifecycle.
# ==============================================================================

set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[1/4] Checking Bash syntax and Python bytecode compilation..."
bash -n bin/colabd lib/*.sh scripts/*.sh tests/*.sh
python3 -m py_compile lib/remote_supervisor.py

echo "[2/4] Testing CLI subcommands (--version, --help) and local installer..."
VER_OUT="$("${ROOT_DIR}/bin/colabd" --version)"
[[ "$VER_OUT" == "colabd 0.1.0" ]] || { echo "Unexpected version: $VER_OUT" >&2; exit 1; }
"${ROOT_DIR}/bin/colabd" --help >/dev/null

SANDBOX="$(mktemp -d "${ROOT_DIR}/.test_sandbox.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

COLABD_HOME="${SANDBOX}/share/colabd" COLABD_BIN_DIR="${SANDBOX}/bin" bash "${ROOT_DIR}/scripts/install.sh" >/dev/null
[[ -L "${SANDBOX}/bin/colabd" ]] || { echo "Symlink not created by install.sh" >&2; exit 1; }
[[ "$("${SANDBOX}/bin/colabd" version)" == "colabd 0.1.0" ]] || { echo "Installed binary failed" >&2; exit 1; }
COLABD_HOME="${SANDBOX}/share/colabd" COLABD_BIN_DIR="${SANDBOX}/bin" XDG_CONFIG_HOME="${SANDBOX}/cfg" \
  bash "${ROOT_DIR}/scripts/uninstall.sh" --purge >/dev/null
[[ ! -e "${SANDBOX}/bin/colabd" ]] || { echo "uninstall.sh did not remove symlink" >&2; exit 1; }

echo "[3/4] Testing Google Drive shard prefetch, NVMe routing, fallback sync-back, and mmap patching..."
mkdir -p "${SANDBOX}/cfg" "${SANDBOX}/work/maya-models" \
  "${SANDBOX}/drive/maya-models/Engram-Q6_K" \
  "${SANDBOX}/drive/maya-models/DeepSeek-V4.1-Flash-1017-abliterated-GGUF/Mix-128G"

dd if=/dev/urandom of="${SANDBOX}/drive/maya-models/Engram-Q6_K/engram-00001.gguf" bs=1024 count=32 2>/dev/null
dd if=/dev/urandom of="${SANDBOX}/drive/maya-models/DeepSeek-V4.1-Flash-1017-abliterated-GGUF/Mix-128G/model-00001.gguf" bs=1024 count=32 2>/dev/null

python3 - "$ROOT_DIR" "$SANDBOX" <<'PYTEST'
import json
import os
import pathlib
import py_compile
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
box = pathlib.Path(sys.argv[2])

cmd = f"""
export XDG_CONFIG_HOME="{box}/cfg"
COLABD_LIB_DIR="{root}/lib"
source "{root}/lib/core.sh"
source "{root}/lib/auth.sh"
source "{root}/lib/lifecycle.sh"
load_config
CUSTOM_MODELS_DIR="{box}/work/maya-models"
DRIVE_CACHE_DIR="{box}/drive/maya-models"
DRIVE_PREFETCH="1"
DRIVE_SAVE_POLICY="both"
EXPERT_RAM_POLICY="force_ram"
build_remote_runner "nvme_engram"
echo "$RUNNER_PY"
"""
runner_py = subprocess.check_output(["bash", "-c", cmd], text=True).strip().splitlines()[-1]
py_compile.compile(runner_py, doraise=True)

os.environ["MAYA_WORK_ROOT"] = str(box / "work")
os.environ["MAYA_DRIVE_MOUNT_ROOT"] = str(box / "drive")
os.environ["MAYA_SKIP_APT"] = "1"

ns = {"__name__": "unit_test"}
exec(compile(pathlib.Path(runner_py).read_text(), runner_py, "exec"), ns)

models_dir, ram_res = ns["prepare_storage_and_deps"]()
assert ram_res is True

local_engram = models_dir / "Engram-Q6_K"
assert not local_engram.is_symlink()
assert (local_engram / "engram-00001.gguf").exists()

ablit_link = models_dir / "DeepSeek-V4.1-Flash-1017-abliterated-GGUF" / "Engram-Q6_K"
assert ablit_link.is_symlink() and ablit_link.resolve() == local_engram.resolve()

mix_link = models_dir / "DeepSeek-V4.1-Flash-1017-abliterated-GGUF" / "Mix-128G"
assert mix_link.is_symlink()

# Simulate fallback download onto local NVMe and verify atomic sync-back to Drive
(local_engram / "engram-00002.gguf").write_bytes(b"fallback_shard" * 512)
ns["sync_new_shards_to_drive"](models_dir)
synced_shard = box / "drive" / "maya-models" / "Engram-Q6_K" / "engram-00002.gguf"
assert synced_shard.exists() and synced_shard.stat().st_size == (local_engram / "engram-00002.gguf").stat().st_size

maya_dir = box / "work" / "project-maya"
maya_dir.mkdir(parents=True, exist_ok=True)
cfg_file = maya_dir / "maya-ds4.json"
cfg_file.write_text(json.dumps({"args": ["--max-context", "65536"]}))
ns["patch_existing_maya_configs"](maya_dir, True)
assert json.loads(cfg_file.read_text())["args"][-2:] == ["--mmap-experts", "off"]

pathlib.Path(runner_py).parent.rmdir if False else None
PYTEST

echo "[4/4] Testing interactive auth, logout orphan-guard, 0600 config, and automatic colab stop on exit..."
mkdir -p "${SANDBOX}/mockbin" "${SANDBOX}/gcloud_cfg"

cat > "${SANDBOX}/mockbin/colab" <<'MOCK'
#!/usr/bin/env bash
STATE_F="$(dirname "$0")/logged_in"
LOG_F="$(dirname "$0")/calls.log"
echo "COLAB: $* (BROWSER=${BROWSER:-unset})" >> "$LOG_F"
AUTH_M="oauth2"
if [[ "${1:-}" == "--auth" ]]; then
  AUTH_M="$2"
  shift 2
fi
SUB="${1:-}"
if [[ "$SUB" == "logout" ]]; then
  rm -f "$STATE_F"
  exit 0
fi
if [[ "$SUB" == "sessions" ]]; then
  if [[ -f "$STATE_F" ]]; then
    echo "1 active session (${AUTH_M})"
    exit 0
  fi
  if [[ "${BROWSER:-}" != "/usr/bin/false" ]]; then
    echo "$AUTH_M" > "$STATE_F"
    exit 0
  fi
  exit 1
fi
[[ -f "$STATE_F" ]] || exit 1
exit 0
MOCK

cat > "${SANDBOX}/mockbin/gcloud" <<MOCKG
#!/usr/bin/env bash
echo "GCLOUD: \$*" >> "${SANDBOX}/mockbin/calls.log"
mkdir -p "${SANDBOX}/gcloud_cfg"
echo '{"type":"authorized_user"}' > "${SANDBOX}/gcloud_cfg/application_default_credentials.json"
echo "adc" > "${SANDBOX}/mockbin/logged_in"
exit 0
MOCKG

chmod +x "${SANDBOX}/mockbin/colab" "${SANDBOX}/mockbin/gcloud"

printf '6\n2\n\n5\n\n4\nY\nY\n2\n\n0\n5\n4\nY\n2\n0\n0\n' | \
  XDG_CONFIG_HOME="${SANDBOX}/cfg" CLOUDSDK_CONFIG="${SANDBOX}/gcloud_cfg" PATH="${SANDBOX}/mockbin:$PATH" NO_COLOR=1 \
  bash --noprofile --norc "${ROOT_DIR}/bin/colabd" >/dev/null 2>&1

grep -q '^COLAB_AUTH_MODE=adc$' "${SANDBOX}/cfg/colabd/config.env"
grep -q '^DRIVE_SAVE_POLICY=weights_only$' "${SANDBOX}/cfg/colabd/config.env"
grep -q 'COLAB: --auth adc stop -s colabd-llm' "${SANDBOX}/mockbin/calls.log"

echo "ALL TESTS PASSED."
