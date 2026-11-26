#!/usr/bin/env bash
# ==============================================================================
# colabd automated test suite
# Validates shell syntax, Python compilation, storage prefetch/sync-back,
# multi-account keyring/ADC switching, orphan-safe release guards, global down,
# installer/uninstaller, and exit auto-stop lifecycle.
# ==============================================================================

set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[1/7] Checking Bash syntax and Python bytecode compilation..."
bash -n bin/colabd lib/*.sh scripts/*.sh tests/*.sh
python3 -m py_compile lib/*.py

echo "[2/7] Testing CLI subcommands (--version, --help) and local installer..."
VER_OUT="$("${ROOT_DIR}/bin/colabd" --version)"
[[ "$VER_OUT" == "colabd 0.1.0" ]] || { echo "Unexpected version: $VER_OUT" >&2; exit 1; }
"${ROOT_DIR}/bin/colabd" --help >/dev/null

SANDBOX="$(mktemp -d "${ROOT_DIR}/.test_sandbox.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

COLABD_HOME="${SANDBOX}/share/colabd" COLABD_RUNTIME_DIR="${SANDBOX}/inst_rt" COLABD_BIN_DIR="${SANDBOX}/bin" \
  COLABD_SKIP_VENV_SETUP=1 bash "${ROOT_DIR}/scripts/install.sh" >/dev/null
[[ -L "${SANDBOX}/bin/colabd" ]] || { echo "Symlink not created by install.sh" >&2; exit 1; }
[[ -f "${SANDBOX}/share/colabd/lib/env.sh" ]] || { echo "env.sh not installed" >&2; exit 1; }
[[ -f "${SANDBOX}/share/colabd/lib/account_store.py" ]] || { echo "account_store.py not installed" >&2; exit 1; }
[[ "$("${SANDBOX}/bin/colabd" version)" == "colabd 0.1.0" ]] || { echo "Installed binary failed" >&2; exit 1; }
mkdir -p "${SANDBOX}/inst_rt/venv/bin"
COLABD_HOME="${SANDBOX}/share/colabd" COLABD_RUNTIME_DIR="${SANDBOX}/inst_rt" COLABD_BIN_DIR="${SANDBOX}/bin" XDG_CONFIG_HOME="${SANDBOX}/cfg" \
  bash "${ROOT_DIR}/scripts/uninstall.sh" --purge >/dev/null
[[ ! -e "${SANDBOX}/bin/colabd" ]] || { echo "uninstall.sh did not remove symlink" >&2; exit 1; }
[[ ! -e "${SANDBOX}/inst_rt" ]] || { echo "uninstall.sh did not remove isolated runtime" >&2; exit 1; }

echo "[3/7] Testing Google Drive shard prefetch, NVMe routing, fallback sync-back, and mmap patching..."
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
export COLABD_RUNTIME_DIR="{box}/unit_rt"
COLABD_LIB_DIR="{root}/lib"
source "{root}/lib/core.sh"
source "{root}/lib/env.sh"
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
PYTEST

echo "[4/7] Testing account_store.py keyring isolation, 0600 permissions, and session migration..."
python3 - "$ROOT_DIR" "$SANDBOX" <<'PYSTORE'
import json
import os
import pathlib
import stat
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
box = pathlib.Path(sys.argv[2])
store = root / "lib" / "account_store.py"
accts = box / "store_test" / "accounts"
colab_dir = box / "store_test" / "colab-cli"
kr_file = box / "store_test" / "keyring.json"
colab_dir.mkdir(parents=True, exist_ok=True)

env = os.environ.copy()
env["COLABD_KEYRING_FILE"] = str(kr_file)
env["COLAB_CLI_CONFIG_DIR"] = str(colab_dir)

def run_store(*args, check=True):
    return subprocess.run(
        [sys.executable, str(store), *args],
        env=env,
        text=True,
        capture_output=True,
        check=check,
    )

assert run_store("validate-name", "pro-1_a.b", check=False).returncode == 0
assert run_store("validate-name", "../escape", check=False).returncode != 0
assert run_store("validate-name", ".hidden", check=False).returncode != 0

# Legacy token migration + save + clear
legacy_tok = colab_dir / "token.json"
legacy_tok.write_text(json.dumps({"email": "alice@example.com", "token": "tok-a"}))
assert run_store("oauth-has-active").stdout.strip() == "legacy"
assert run_store("oauth-save-profile", str(accts), "alice", "--email", "alice@example.com").stdout.strip() == "keyring"

# Activate writes to keyring and removes legacy token.json
assert run_store("oauth-activate-profile", str(accts), "alice").stdout.strip() == "keyring"
assert not legacy_tok.exists()
assert stat.S_IMODE(kr_file.stat().st_mode) == 0o600
assert stat.S_IMODE((accts / "alice" / "meta.json").stat().st_mode) == 0o600

# Session migration preserves active runtime metadata
src_sess = colab_dir / "sessions.json"
dst_sess = accts / "alice" / "sessions.json"
src_sess.write_text(json.dumps({"colabd-llm": {"accelerator": "G4", "machine_shape": "HIGH_RAM", "endpoint": "ep-1"}}))
run_store("sessions-migrate", str(src_sess), str(dst_sess))
assert not src_sess.exists() and dst_sess.exists()
assert "colabd-llm\tG4\tHIGH_RAM\tep-1" in run_store("sessions-list", str(dst_sess)).stdout

# ADC profile save enforces 0600 permissions
adc_src = box / "store_test" / "adc_src.json"
adc_src.write_text(json.dumps({"type": "authorized_user", "email": "corp@example.com"}))
run_store("adc-save-profile", str(accts), "work", str(adc_src), "--email", "corp@example.com")
assert stat.S_IMODE((accts / "work" / "adc.json").stat().st_mode) == 0o600

# Clear active removes keyring entry
run_store("oauth-clear-active")
assert run_store("oauth-has-active", check=False).returncode != 0

# Delete profile removes keyring entry & directory
run_store("delete-profile", str(accts), "alice")
assert not (accts / "alice").exists()
kr_data = json.loads(kr_file.read_text())
assert "oauth_token:alice" not in kr_data.get("colabd-accounts", {})
PYSTORE

echo "[5/7] Testing multi-account switching, isolated sessions, real logout, and cross-account release..."
MULTI_BOX="${SANDBOX}/multi"
mkdir -p "${MULTI_BOX}/mockbin" "${MULTI_BOX}/cfg" "${MULTI_BOX}/colab_cli" "${MULTI_BOX}/gcloud_cfg"

# Realistic mock colab CLI:
# - Rejects `colab logout` with exit code 2 (matching official google-colab-cli v0.8.0!)
# - Reads/writes active OAuth2 token from COLABD_KEYRING_FILE["google-colab-cli"]["oauth_token"]
# - Reads ADC identity from GOOGLE_APPLICATION_CREDENTIALS or CLOUDSDK_CONFIG
# - Tracks per-account server assignments in SERVER_STATE_FILE AND local sessions in --config PATH
cat > "${MULTI_BOX}/mockbin/colab" <<'MOCKCOLAB'
#!/usr/bin/env python3
import json
import os
import pathlib
import sys

KR_FILE = pathlib.Path(os.environ["COLABD_KEYRING_FILE"])
SRV_FILE = pathlib.Path(os.environ["MOCK_SERVER_STATE"])
LOG_FILE = pathlib.Path(os.environ["MOCK_CALL_LOG"])
NEXT_LOGIN_FILE = pathlib.Path(os.environ["MOCK_NEXT_LOGIN_FILE"])
DEFAULT_SESS = pathlib.Path(os.environ.get("COLAB_CLI_CONFIG_DIR", "~/.config/colab-cli")).expanduser() / "sessions.json"

def load_json(p):
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {}

def save_json(p, data):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2), encoding="utf-8")

args = sys.argv[1:]
cfg_path = DEFAULT_SESS
auth_mode = "oauth2"
while args and args[0].startswith("-"):
    if args[0] == "--config":
        cfg_path = pathlib.Path(args[1])
        args = args[2:]
    elif args[0] == "--auth":
        auth_mode = args[1]
        args = args[2:]
    else:
        args = args[1:]

sub = args[0] if args else ""
sub_args = args[1:]

if sub == "version":
    print("Version: 0.8.0")
    sys.exit(0)

if sub == "logout":
    print("No such command 'logout'.", file=sys.stderr)
    sys.exit(2)

def current_identity(allow_interactive=False):
    if auth_mode == "adc":
        adc_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
        if not adc_path:
            adc_path = str(pathlib.Path(os.environ.get("CLOUDSDK_CONFIG", "~/.config/gcloud")).expanduser() / "application_default_credentials.json")
        p = pathlib.Path(adc_path)
        if not p.is_file():
            return None
        data = load_json(p)
        return data.get("mock_email") or "adc@example.com"

    kr = load_json(KR_FILE)
    tok_raw = kr.get("google-colab-cli", {}).get("oauth_token")
    if tok_raw:
        try:
            return json.loads(tok_raw).get("email")
        except Exception:
            return "unknown@example.com"

    if allow_interactive and os.environ.get("BROWSER") != "/usr/bin/false":
        email = NEXT_LOGIN_FILE.read_text(encoding="utf-8").strip() if NEXT_LOGIN_FILE.exists() else "fresh@example.com"
        kr.setdefault("google-colab-cli", {})["oauth_token"] = json.dumps({"email": email, "refresh_token": f"rt-{email}"})
        save_json(KR_FILE, kr)
        return email
    return None

allow_login = sub in ("sessions", "whoami", "new")
ident = current_identity(allow_interactive=allow_login)

with LOG_FILE.open("a", encoding="utf-8") as lf:
    lf.write(f"COLAB ident={ident or 'NONE'} mode={auth_mode} cfg={cfg_path.name} sub={sub} args={' '.join(sub_args)}\n")

if not ident:
    print("Not authenticated", file=sys.stderr)
    sys.exit(1)

if sub == "whoami":
    print(f"Auth provider: {auth_mode}")
    print(f"Email:         {ident}")
    print("Expires in:    59m")
    sys.exit(0)

if sub == "usage":
    print(f"Account: {ident} | Balance: 100.00 CU")
    sys.exit(0)

srv = load_json(SRV_FILE)
acct_srv = srv.setdefault(ident, {})
local = load_json(cfg_path)

def opt_val(flag):
    if flag in sub_args:
        i = sub_args.index(flag)
        if i + 1 < len(sub_args):
            return sub_args[i + 1]
    return None

if sub == "new":
    sname = opt_val("-s") or "default"
    gpu = opt_val("--gpu") or "NONE"
    ep = f"m-{ident.split('@')[0]}-{sname}"
    acct_srv[ep] = {"accelerator": gpu, "machine_shape": "HIGH_RAM"}
    save_json(SRV_FILE, srv)
    local[sname] = {"name": sname, "endpoint": ep, "accelerator": gpu, "machine_shape": "HIGH_RAM", "token": "rtok", "url": "https://mock"}
    save_json(cfg_path, local)
    print("[colab] Session READY.")
    sys.exit(0)

if sub == "sessions":
    if not acct_srv:
        print("[colab] No active sessions found on server.")
        sys.exit(0)
    by_ep = {v["endpoint"]: k for k, v in local.items() if isinstance(v, dict) and "endpoint" in v}
    for ep, info in sorted(acct_srv.items()):
        name = by_ep.get(ep, "?")
        print(f"[{name}] {ep} | Hardware: {info['accelerator']} | Shape: {info['machine_shape']} | Variant: GPU")
    sys.exit(0)

if sub == "status":
    sname = opt_val("-s")
    if sname:
        if sname in local and local[sname]["endpoint"] in acct_srv:
            ep = local[sname]["endpoint"]
            print(f"[{sname}] {ep} | Hardware: {local[sname]['accelerator']} | Status: IDLE")
            sys.exit(0)
        print(f"[colab] Session '{sname}' not found.")
        sys.exit(1)
    sys.exit(0)

if sub == "stop":
    sname = opt_val("-s") or next(iter(local.keys()), "")
    if sname not in local:
        print(f"[colab] Session '{sname}' not found.")
        sys.exit(1)
    ep = local[sname]["endpoint"]
    if ep not in acct_srv:
        print(f"[colab] Endpoint '{ep}' does not belong to {ident}!", file=sys.stderr)
        sys.exit(1)
    del acct_srv[ep]
    del local[sname]
    save_json(SRV_FILE, srv)
    save_json(cfg_path, local)
    with LOG_FILE.open("a", encoding="utf-8") as lf:
        lf.write(f"STOPPED ident={ident} mode={auth_mode} session={sname} ep={ep}\n")
    print("[colab] Session terminated.")
    sys.exit(0)

sys.exit(0)
MOCKCOLAB

cat > "${MULTI_BOX}/mockbin/gcloud" <<'MOCKGCLOUD'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${CLOUDSDK_CONFIG}"
if [[ "${1:-}" == "auth" && "${2:-}" == "application-default" && "${3:-}" == "revoke" ]]; then
  rm -f "${CLOUDSDK_CONFIG}/application_default_credentials.json"
  exit 0
fi
EMAIL="$(cat "${MOCK_NEXT_LOGIN_FILE}")"
printf '{"type":"authorized_user","mock_email":"%s"}\n' "$EMAIL" > "${CLOUDSDK_CONFIG}/application_default_credentials.json"
exit 0
MOCKGCLOUD

chmod +x "${MULTI_BOX}/mockbin/colab" "${MULTI_BOX}/mockbin/gcloud"

export XDG_CONFIG_HOME="${MULTI_BOX}/cfg"
export COLABD_RUNTIME_DIR="${MULTI_BOX}/rt"
export COLAB_CLI_CONFIG_DIR="${MULTI_BOX}/colab_cli"
export CLOUDSDK_CONFIG="${MULTI_BOX}/gcloud_cfg"
export COLABD_KEYRING_FILE="${MULTI_BOX}/keyring.json"
export MOCK_SERVER_STATE="${MULTI_BOX}/server_state.json"
export MOCK_CALL_LOG="${MULTI_BOX}/calls.log"
export MOCK_NEXT_LOGIN_FILE="${MULTI_BOX}/next_login.txt"
export NO_COLOR=1

run_colabd() {
  PATH="${MULTI_BOX}/mockbin:$PATH" bash --noprofile --norc "${ROOT_DIR}/bin/colabd" "$@"
}

# 5a. Add acc1 (oauth2), start a runtime on acc1, then add acc2 (oauth2) with --release -> must release acc1 BEFORE clearing keyring!
echo "acc1@example.com" > "$MOCK_NEXT_LOGIN_FILE"
run_colabd auth add acc1 --oauth2 --release >/dev/null
grep -q '^ACTIVE_ACCOUNT=acc1$' "${XDG_CONFIG_HOME}/colabd/config.env"

PATH="${MULTI_BOX}/mockbin:$PATH" colab --config "${XDG_CONFIG_HOME}/colabd/accounts/acc1/sessions.json" --auth oauth2 new -s colabd-llm --gpu G4 >/dev/null

echo "acc2@example.com" > "$MOCK_NEXT_LOGIN_FILE"
run_colabd auth add acc2 --oauth2 --release >/dev/null
grep -q '^ACTIVE_ACCOUNT=acc2$' "${XDG_CONFIG_HOME}/colabd/config.env"
grep -q 'STOPPED ident=acc1@example.com mode=oauth2 session=colabd-llm ep=m-acc1-colabd-llm' "$MOCK_CALL_LOG"
WHOAMI_OUT="$(run_colabd auth whoami)"
printf '%s\n' "$WHOAMI_OUT" | grep -q 'acc2@example.com'

# 5b. Instant switch back to acc1 (must swap keyring back to acc1 WITHOUT needing new login!)
rm -f "$MOCK_NEXT_LOGIN_FILE"
run_colabd switch acc1 --release >/dev/null
grep -q '^ACTIVE_ACCOUNT=acc1$' "${XDG_CONFIG_HOME}/colabd/config.env"
WHOAMI_OUT="$(run_colabd auth whoami)"
printf '%s\n' "$WHOAMI_OUT" | grep -q 'acc1@example.com'

# 5c. Add ADC profile gcp1, start runtime on gcp1, switch to acc1 with --keep, then release via `colabd down -a gcp1`!
echo "gcp1@corp.example.com" > "$MOCK_NEXT_LOGIN_FILE"
run_colabd auth add gcp1 --adc --release >/dev/null
grep -q '^ACTIVE_ACCOUNT=gcp1$' "${XDG_CONFIG_HOME}/colabd/config.env"
grep -q '^COLAB_AUTH_MODE=adc$' "${XDG_CONFIG_HOME}/colabd/config.env"
GOOGLE_APPLICATION_CREDENTIALS="${XDG_CONFIG_HOME}/colabd/accounts/gcp1/adc.json" \
  PATH="${MULTI_BOX}/mockbin:$PATH" colab --config "${XDG_CONFIG_HOME}/colabd/accounts/gcp1/sessions.json" --auth adc new -s gcp-job --gpu A100 >/dev/null

run_colabd switch acc1 --keep >/dev/null
grep -q '^ACTIVE_ACCOUNT=acc1$' "${XDG_CONFIG_HOME}/colabd/config.env"
run_colabd down -a gcp1 >/dev/null
grep -q 'STOPPED ident=gcp1@corp.example.com mode=adc session=gcp-job ep=m-gcp1-gcp-job' "$MOCK_CALL_LOG"
grep -q '^ACTIVE_ACCOUNT=acc1$' "${XDG_CONFIG_HOME}/colabd/config.env"

# 5d. Global release `colabd down --all` stops active runtimes across acc1 (oauth2), acc2 (oauth2), and gcp1 (adc), restoring acc1 afterwards!
PATH="${MULTI_BOX}/mockbin:$PATH" colab --config "${XDG_CONFIG_HOME}/colabd/accounts/acc1/sessions.json" --auth oauth2 new -s s-acc1 --gpu G4 >/dev/null
run_colabd switch acc2 --keep >/dev/null
PATH="${MULTI_BOX}/mockbin:$PATH" colab --config "${XDG_CONFIG_HOME}/colabd/accounts/acc2/sessions.json" --auth oauth2 new -s s-acc2 --gpu H100 >/dev/null
GOOGLE_APPLICATION_CREDENTIALS="${XDG_CONFIG_HOME}/colabd/accounts/gcp1/adc.json" \
  PATH="${MULTI_BOX}/mockbin:$PATH" colab --config "${XDG_CONFIG_HOME}/colabd/accounts/gcp1/sessions.json" --auth adc new -s s-gcp1 --gpu L4 >/dev/null
run_colabd switch acc1 --keep >/dev/null

run_colabd down --all >/dev/null
grep -q 'STOPPED ident=acc1@example.com mode=oauth2 session=s-acc1 ep=m-acc1-s-acc1' "$MOCK_CALL_LOG"
grep -q 'STOPPED ident=acc2@example.com mode=oauth2 session=s-acc2 ep=m-acc2-s-acc2' "$MOCK_CALL_LOG"
grep -q 'STOPPED ident=gcp1@corp.example.com mode=adc session=s-gcp1 ep=m-gcp1-s-gcp1' "$MOCK_CALL_LOG"
WHOAMI_OUT="$(run_colabd auth whoami)"
printf '%s\n' "$WHOAMI_OUT" | grep -q 'acc1@example.com'

# 5e. Delete inactive profile acc2 that still has an active VM -> must release acc2 BEFORE deleting acc2, keeping acc1 active!
run_colabd switch acc2 --release >/dev/null
PATH="${MULTI_BOX}/mockbin:$PATH" colab --config "${XDG_CONFIG_HOME}/colabd/accounts/acc2/sessions.json" --auth oauth2 new -s s-del-acc2 --gpu T4 >/dev/null
run_colabd switch acc1 --keep >/dev/null
run_colabd auth remove acc2 --release >/dev/null
grep -q 'STOPPED ident=acc2@example.com mode=oauth2 session=s-del-acc2 ep=m-acc2-s-del-acc2' "$MOCK_CALL_LOG"
[[ ! -d "${XDG_CONFIG_HOME}/colabd/accounts/acc2" ]] || { echo "acc2 directory not deleted" >&2; exit 1; }
WHOAMI_OUT="$(run_colabd auth whoami)"
printf '%s\n' "$WHOAMI_OUT" | grep -q 'acc1@example.com'

# 5f. Real logout on acc1 with active VM -> stops acc1 VM FIRST, clears active keyring, never calls `colab logout`!
PATH="${MULTI_BOX}/mockbin:$PATH" colab --config "${XDG_CONFIG_HOME}/colabd/accounts/acc1/sessions.json" --auth oauth2 new -s s-logout --gpu G4 >/dev/null
run_colabd auth logout --release >/dev/null
grep -q 'STOPPED ident=acc1@example.com mode=oauth2 session=s-logout ep=m-acc1-s-logout' "$MOCK_CALL_LOG"
grep -Eq "^ACTIVE_ACCOUNT=(''){0,1}$" "${XDG_CONFIG_HOME}/colabd/config.env"
if run_colabd auth whoami >/dev/null 2>&1; then
  echo "Expected whoami to fail after logout" >&2
  exit 1
fi
# Ensure colab logout was never invoked
if grep -q 'sub=logout' "$MOCK_CALL_LOG"; then
  echo "colabd must never invoke nonexistent 'colab logout'" >&2
  exit 1
fi

# Verify zero server-side sessions remain across all accounts!
python3 - "$MOCK_SERVER_STATE" <<'PYCHK'
import json, pathlib, sys
srv = json.loads(pathlib.Path(sys.argv[1]).read_text())
leftover = {k: v for k, v in srv.items() if v}
assert not leftover, f"Leaked server sessions remained: {leftover}"
PYCHK

echo "[6/7] Testing interactive TUI settings, switch back to acc1, and exit auto-stop..."
# Re-activate acc1, create a session on acc1, open interactive TUI -> change drive save policy -> quit -> auto-stop releases it!
run_colabd switch acc1 --release >/dev/null
PATH="${MULTI_BOX}/mockbin:$PATH" colab --config "${XDG_CONFIG_HOME}/colabd/accounts/acc1/sessions.json" --auth oauth2 new -s colabd-llm --gpu G4 >/dev/null
printf '5\n4\nY\n2\n0\n0\n' | run_colabd >/dev/null 2>&1
grep -q '^DRIVE_SAVE_POLICY=weights_only$' "${XDG_CONFIG_HOME}/colabd/config.env"
grep -q 'STOPPED ident=acc1@example.com mode=oauth2 session=colabd-llm ep=m-acc1-colabd-llm' "$MOCK_CALL_LOG"

echo "[7/7] Testing colabd managed isolated uv venv runtime (works with zero external colab on PATH)..."
ENV_BOX="${SANDBOX}/uv_env"
mkdir -p "${ENV_BOX}/home" "${ENV_BOX}/uvbin" "${ENV_BOX}/cfg" "${ENV_BOX}/colab_cli"
REAL_PY3="$(python3 -c 'import sys; print(sys.executable)')"
MOCK_COLAB_SRC="${MULTI_BOX}/mockbin/colab"
UV_LOG="${ENV_BOX}/uv.log"

cat > "${ENV_BOX}/uvbin/uv" <<MOCKUV
#!/usr/bin/env bash
set -euo pipefail
echo "UV: \$*" >> "${UV_LOG}"
if [[ "\${1:-}" == "--version" ]]; then
  echo "uv 0.13.6 (mock)"
  exit 0
fi
if [[ "\${1:-}" == "venv" ]]; then
  VENV_PATH=""
  for arg in "\$@"; do
    VENV_PATH="\$arg"
  done
  mkdir -p "\${VENV_PATH}/bin"
  printf '#!/bin/sh\nexec "%s" "\$@"\n' "${REAL_PY3}" > "\${VENV_PATH}/bin/python"
  printf '#!/bin/sh\nexec "%s" "\$@"\n' "${REAL_PY3}" > "\${VENV_PATH}/bin/python3"
  chmod +x "\${VENV_PATH}/bin/python" "\${VENV_PATH}/bin/python3"
  exit 0
fi
if [[ "\${1:-}" == "pip" && "\${2:-}" == "install" ]]; then
  PY_TARGET=""
  while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--python" ]]; then
      PY_TARGET="\$2"
      shift 2
      continue
    fi
    shift
  done
  VBIN="\$(dirname "\$PY_TARGET")"
  {
    printf '#!%s\n' "${REAL_PY3}"
    tail -n +2 "${MOCK_COLAB_SRC}"
  } > "\${VBIN}/colab"
  chmod +x "\${VBIN}/colab"
  exit 0
fi
exit 1
MOCKUV
chmod +x "${ENV_BOX}/uvbin/uv"

# Build a clean minimal PATH containing NO colab binary at all
CLEAN_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# 7a. Install via install.sh WITH isolated uv venv bootstrap enabled
HOME="${ENV_BOX}/home" \
  XDG_CONFIG_HOME="${ENV_BOX}/cfg" \
  COLABD_HOME="${ENV_BOX}/app" \
  COLABD_RUNTIME_DIR="${ENV_BOX}/runtime" \
  COLABD_BIN_DIR="${ENV_BOX}/bin" \
  COLABD_UV_BIN="${ENV_BOX}/uvbin/uv" \
  COLABD_REQUIRE_VENV=1 \
  NO_COLOR=1 \
  bash "${ROOT_DIR}/scripts/install.sh" >/dev/null

[[ -x "${ENV_BOX}/runtime/venv/bin/colab" ]] || { echo "install.sh did not create managed venv colab" >&2; exit 1; }
[[ -x "${ENV_BOX}/runtime/venv/bin/python" ]] || { echo "install.sh did not create managed venv python" >&2; exit 1; }
grep -q 'UV: venv --clear --python 3.12' "$UV_LOG"
grep -q 'UV: pip install --python .*/runtime/venv/bin/python google-colab-cli' "$UV_LOG"

# 7b. Verify colabd works end-to-end with CLEAN_PATH (no external colab on PATH, no ~/.local/bin/colab)
run_isolated_colabd() {
  HOME="${ENV_BOX}/home" \
    XDG_CONFIG_HOME="${ENV_BOX}/cfg" \
    COLAB_CLI_CONFIG_DIR="${ENV_BOX}/colab_cli" \
    COLABD_RUNTIME_DIR="${ENV_BOX}/runtime" \
    COLABD_KEYRING_FILE="${ENV_BOX}/keyring.json" \
    MOCK_SERVER_STATE="${ENV_BOX}/server.json" \
    MOCK_CALL_LOG="${ENV_BOX}/calls.log" \
    MOCK_NEXT_LOGIN_FILE="${ENV_BOX}/next_login.txt" \
    NO_COLOR=1 \
    PATH="${CLEAN_PATH}" \
    /bin/bash --noprofile --norc "${ENV_BOX}/bin/colabd" "$@"
}

DOC_OUT="$(run_isolated_colabd doctor)"
printf '%s\n' "$DOC_OUT" | grep -q '独立 uv 隔离环境'
echo "iso1@example.com" > "${ENV_BOX}/next_login.txt"
run_isolated_colabd auth add iso1 --oauth2 --release >/dev/null
ISO_WHOAMI="$(run_isolated_colabd auth whoami)"
printf '%s\n' "$ISO_WHOAMI" | grep -q 'iso1@example.com'
COLABD_KEYRING_FILE="${ENV_BOX}/keyring.json" \
  MOCK_SERVER_STATE="${ENV_BOX}/server.json" \
  MOCK_CALL_LOG="${ENV_BOX}/calls.log" \
  MOCK_NEXT_LOGIN_FILE="${ENV_BOX}/next_login.txt" \
  "${ENV_BOX}/runtime/venv/bin/colab" --config "${ENV_BOX}/cfg/colabd/accounts/iso1/sessions.json" --auth oauth2 new -s iso-sess --gpu G4 >/dev/null
run_isolated_colabd down --all >/dev/null
grep -q 'STOPPED ident=iso1@example.com mode=oauth2 session=iso-sess' "${ENV_BOX}/calls.log"

# 7c. Verify upgrade, reset, reinstall preservation, and remove
COLABD_UV_BIN="${ENV_BOX}/uvbin/uv" run_isolated_colabd env upgrade >/dev/null
grep -q 'UV: pip install --python .*/runtime/venv/bin/python --upgrade google-colab-cli' "$UV_LOG"

touch "${ENV_BOX}/runtime/venv/.preserve_marker"
HOME="${ENV_BOX}/home" \
  COLABD_HOME="${ENV_BOX}/app" \
  COLABD_RUNTIME_DIR="${ENV_BOX}/runtime" \
  COLABD_BIN_DIR="${ENV_BOX}/bin" \
  COLABD_SKIP_VENV_SETUP=1 \
  bash "${ROOT_DIR}/scripts/install.sh" >/dev/null
[[ -f "${ENV_BOX}/runtime/venv/.preserve_marker" ]] || { echo "Reinstalling app code wiped managed venv!" >&2; exit 1; }

run_isolated_colabd env remove >/dev/null
[[ ! -d "${ENV_BOX}/runtime/venv" ]] || { echo "env remove did not delete managed venv" >&2; exit 1; }
if run_isolated_colabd doctor >/dev/null 2>&1; then
  echo "Expected doctor to fail when managed venv removed and no external colab exists" >&2
  exit 1
fi

echo "ALL TESTS PASSED."
