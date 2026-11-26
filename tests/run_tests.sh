#!/usr/bin/env bash
# ==============================================================================
# colabd automated test suite
# Validates shell syntax, Python compilation, storage prefetch/sync-back,
# identity-based account deduplication, scope validation & repair (auth refresh),
# hard delete release gates, cross-account down, isolated uv venv, and exit trap.
# ==============================================================================

set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[1/9] Checking Bash syntax and Python bytecode compilation..."
bash -n bin/colabd lib/*.sh scripts/*.sh tests/*.sh
python3 -m py_compile lib/*.py

echo "[2/9] Testing CLI subcommands (--version, --help, models) and local installer..."
SANDBOX="$(mktemp -d "${ROOT_DIR}/.test_sandbox.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

VER_OUT="$(XDG_CONFIG_HOME="${SANDBOX}/fresh_cfg" "${ROOT_DIR}/bin/colabd" --version)"
[[ "$VER_OUT" == "colabd 0.1.0" ]] || { echo "Unexpected version: $VER_OUT" >&2; exit 1; }
XDG_CONFIG_HOME="${SANDBOX}/fresh_cfg" "${ROOT_DIR}/bin/colabd" --help >/dev/null
MODELS_OUT="$(XDG_CONFIG_HOME="${SANDBOX}/fresh_cfg" "${ROOT_DIR}/bin/colabd" models --tier free --engine strata)"
printf '%s\n' "$MODELS_OUT" | grep -q 'strata-inkling-uncensored-sq10'
[[ ! -e "${SANDBOX}/fresh_cfg/colabd/config.env" ]] || { echo "--help/--version/models must not create config.env" >&2; exit 1; }

COLABD_HOME="${SANDBOX}/share/colabd" COLABD_RUNTIME_DIR="${SANDBOX}/inst_rt" COLABD_BIN_DIR="${SANDBOX}/bin" \
  COLABD_SKIP_VENV_SETUP=1 bash "${ROOT_DIR}/scripts/install.sh" >/dev/null
[[ -L "${SANDBOX}/bin/colabd" ]] || { echo "Symlink not created by install.sh" >&2; exit 1; }
[[ -f "${SANDBOX}/share/colabd/lib/env.sh" ]] || { echo "env.sh not installed" >&2; exit 1; }
[[ -f "${SANDBOX}/share/colabd/lib/account_store.py" ]] || { echo "account_store.py not installed" >&2; exit 1; }
[[ -f "${SANDBOX}/share/colabd/lib/model_registry.py" ]] || { echo "model_registry.py not installed" >&2; exit 1; }
[[ ! -d "${SANDBOX}/share/colabd/lib/__pycache__" ]] || { echo "install.sh must strip __pycache__ from installed lib/" >&2; exit 1; }
[[ "$(XDG_CONFIG_HOME="${SANDBOX}/fresh_cfg" "${SANDBOX}/bin/colabd" version)" == "colabd 0.1.0" ]] || { echo "Installed binary failed" >&2; exit 1; }

# Verify install.sh with COLABD_HOME == LOCAL_ROOT does NOT self-destruct
mkdir -p "${SANDBOX}/inplace_repo"
cp -R "${ROOT_DIR}/bin" "${ROOT_DIR}/lib" "${ROOT_DIR}/scripts" "${SANDBOX}/inplace_repo/"
touch "${SANDBOX}/inplace_repo/.git_marker"
COLABD_HOME="${SANDBOX}/inplace_repo" COLABD_RUNTIME_DIR="${SANDBOX}/inplace_rt" COLABD_BIN_DIR="${SANDBOX}/inplace_bin" \
  COLABD_SKIP_VENV_SETUP=1 bash "${SANDBOX}/inplace_repo/scripts/install.sh" >/dev/null
[[ -f "${SANDBOX}/inplace_repo/.git_marker" && -f "${SANDBOX}/inplace_repo/bin/colabd" && -L "${SANDBOX}/inplace_bin/colabd" ]] || {
  echo "install.sh self-destructed when COLABD_HOME == LOCAL_ROOT!" >&2
  exit 1
}

# Seed a keyring account and verify uninstall.sh --purge clears colabd-accounts keyring entries
mkdir -p "${SANDBOX}/inst_rt/venv/bin" "${SANDBOX}/purge_colab_cli"
printf '{"email":"purge@example.com","refresh_token":"rt-purge"}\n' > "${SANDBOX}/purge_colab_cli/token.json"
COLABD_KEYRING_FILE="${SANDBOX}/purge_kr.json" COLAB_CLI_CONFIG_DIR="${SANDBOX}/purge_colab_cli" \
  python3 "${ROOT_DIR}/lib/account_store.py" oauth-save-account "${SANDBOX}/cfg/colabd/accounts" "purge@example.com" >/dev/null
grep -q 'rt-purge' "${SANDBOX}/purge_kr.json"
COLABD_KEYRING_FILE="${SANDBOX}/purge_kr.json" COLABD_HOME="${SANDBOX}/share/colabd" COLABD_RUNTIME_DIR="${SANDBOX}/inst_rt" \
  COLABD_BIN_DIR="${SANDBOX}/bin" XDG_CONFIG_HOME="${SANDBOX}/cfg" \
  bash "${ROOT_DIR}/scripts/uninstall.sh" --purge >/dev/null
[[ ! -e "${SANDBOX}/bin/colabd" ]] || { echo "uninstall.sh did not remove symlink" >&2; exit 1; }
[[ ! -e "${SANDBOX}/inst_rt" ]] || { echo "uninstall.sh did not remove isolated runtime" >&2; exit 1; }
if grep -q 'rt-purge' "${SANDBOX}/purge_kr.json"; then
  echo "uninstall.sh --purge did not clear colabd-accounts keyring entries!" >&2
  exit 1
fi

echo "[3/9] Testing direct-to-target storage, multi-threaded Range HF download, Drive API streaming, FUSE backpressure, and mmap patching..."
mkdir -p "${SANDBOX}/tmp" "${SANDBOX}/cfg" "${SANDBOX}/work/maya-models" \
  "${SANDBOX}/drive/maya-models/DeepSeek-V4.1-Flash-1017-abliterated-GGUF/Mix-128G"

python3 - "$ROOT_DIR" "$SANDBOX" <<'PYTEST'
import collections
import hashlib
import http.server
import json
import os
import pathlib
import py_compile
import re
import shutil
import socketserver
import subprocess
import sys
import threading
import urllib.parse

root = pathlib.Path(sys.argv[1])
box = pathlib.Path(sys.argv[2])

cmd = f"""
export TMPDIR="{box}/tmp"
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
HF_DOWNLOAD_CONCURRENCY="4"
DRIVE_WRITE_MODE="auto"
EXPERT_RAM_POLICY="force_ram"
build_remote_runner "nvme_engram"
echo "$RUNNER_PY"
"""
runner_py = subprocess.check_output(["bash", "-c", cmd], text=True).strip().splitlines()[-1]
py_compile.compile(runner_py, doraise=True)

# Deterministic payloads for mock HF + mock Google Drive API v3
PAYLOAD_LOCAL = (b"ENGRAM_RANGE_BLOCK_" * 140000)[: 2 * 1024 * 1024 + 131072]  # 2.125 MiB
PAYLOAD_DRIVE_API = (b"DRIVE_API_STREAM_" * 90000)[: 1280 * 1024]  # 1.25 MiB (spans 3 x 512 KiB chunks)
PAYLOAD_DRIVE_FUSE = (b"DRIVE_FUSE_DIRECT_" * 40000)[: 512 * 1024]  # 512 KiB

HF_FILES = {
    "testorg/local-repo/engram-test.gguf": PAYLOAD_LOCAL,
    "orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF/Mix-128G/model-00001.gguf": PAYLOAD_DRIVE_API,
    "testorg/fuse-repo/fuse-direct.gguf": PAYLOAD_DRIVE_FUSE,
}

drive_root_dir = box / "drive"
mock_state = {
    "range_hits": 0,
    "drive_folders": {"root": drive_root_dir},
    "drive_files": {},
    "drive_sessions": {},
    "drive_put_308": 0,
    "drive_put_200": 0,
    "next_id": 1,
    "lock": threading.Lock(),
}


class MockHTTPHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send_json(self, code, obj, extra_headers=None):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        # Mock HF model file listing
        if path == "/api/models/orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF":
            self._send_json(
                200,
                {
                    "siblings": [
                        {"rfilename": "Mix-128G/model-00001.gguf"},
                        {"rfilename": "README.md"},
                    ]
                },
            )
            return

        # Mock HF file download with full Range support
        m_hf = re.match(r"^/([^/]+/[^/]+)/resolve/main/(.+)$", path)
        if m_hf:
            repo = m_hf.group(1)
            rel = urllib.parse.unquote(m_hf.group(2))
            key = f"{repo}/{rel}"
            if key not in HF_FILES:
                self.send_response(404)
                self.end_headers()
                return
            data = HF_FILES[key]
            total = len(data)
            rng = self.headers.get("Range")
            if rng and rng.startswith("bytes="):
                spec = rng[len("bytes=") :]
                s_str, e_str = spec.split("-", 1)
                start = int(s_str) if s_str else 0
                end = int(e_str) if e_str else total - 1
                end = min(end, total - 1)
                chunk = data[start : end + 1]
                if not (start == 0 and end == 0):
                    with mock_state["lock"]:
                        mock_state["range_hits"] += 1
                self.send_response(206)
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
                self.send_header("Content-Length", str(len(chunk)))
                self.end_headers()
                self.wfile.write(chunk)
                return
            self.send_response(200)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(total))
            self.end_headers()
            self.wfile.write(data)
            return

        # Mock Drive API v3 list/search
        if path == "/drive/v3/files":
            qs = urllib.parse.parse_qs(parsed.query)
            q = (qs.get("q") or [""])[0]
            m_name = re.search(r"name='([^']+)'", q)
            m_par = re.search(r"'([^']+)' in parents", q)
            is_folder = "application/vnd.google-apps.folder" in q
            name = m_name.group(1) if m_name else ""
            par = m_par.group(1) if m_par else "root"
            with mock_state["lock"]:
                if is_folder:
                    found = []
                    for fid, fpath in mock_state["drive_folders"].items():
                        if fid != "root" and fpath.name == name and fpath.parent == mock_state["drive_folders"].get(par):
                            found.append({"id": fid, "name": name})
                    self._send_json(200, {"files": found})
                else:
                    found = []
                    for fid, finfo in mock_state["drive_files"].items():
                        if finfo["parent"] == par and finfo["name"] == name:
                            found.append({"id": fid, "name": name, "size": str(finfo["size"])})
                    self._send_json(200, {"files": found})
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        cl = int(self.headers.get("Content-Length") or "0")
        body = json.loads(self.rfile.read(cl).decode("utf-8")) if cl > 0 else {}

        if parsed.path == "/drive/v3/files":
            parent_id = (body.get("parents") or ["root"])[0]
            name = body["name"]
            with mock_state["lock"]:
                fid = f"folder-{mock_state['next_id']}"
                mock_state["next_id"] += 1
                fdir = mock_state["drive_folders"][parent_id] / name
                fdir.mkdir(parents=True, exist_ok=True)
                mock_state["drive_folders"][fid] = fdir
            self._send_json(200, {"id": fid, "name": name})
            return

        if parsed.path == "/upload/drive/v3/files":
            parent_id = (body.get("parents") or ["root"])[0]
            name = body["name"]
            with mock_state["lock"]:
                sid = f"sess-{mock_state['next_id']}"
                mock_state["next_id"] += 1
                mock_state["drive_sessions"][sid] = {
                    "parent": parent_id,
                    "name": name,
                    "buf": bytearray(),
                }
            host, port = self.server.server_address
            self.send_response(200)
            self.send_header("Location", f"http://{host}:{port}/upload/session/{sid}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        self.send_response(404)
        self.end_headers()

    def do_PUT(self):
        parsed = urllib.parse.urlparse(self.path)
        m_sess = re.match(r"^/upload/session/([^/]+)$", parsed.path)
        if not m_sess:
            self.send_response(404)
            self.end_headers()
            return
        sid = m_sess.group(1)
        cl = int(self.headers.get("Content-Length") or "0")
        chunk = self.rfile.read(cl) if cl > 0 else b""
        cr = self.headers.get("Content-Range", "")
        m_cr = re.match(r"bytes (\d+)-(\d+)/(\d+|\*)", cr)
        assert m_cr, f"Unexpected Content-Range: {cr}"
        start, end, total_s = int(m_cr.group(1)), int(m_cr.group(2)), m_cr.group(3)
        total = int(total_s) if total_s.isdigit() else None

        with mock_state["lock"]:
            sess = mock_state["drive_sessions"][sid]
            assert start == len(sess["buf"]), f"Offset mismatch {start} != {len(sess['buf'])}"
            sess["buf"].extend(chunk)
            if total is not None and len(sess["buf"]) < total:
                mock_state["drive_put_308"] += 1
                self.send_response(308)
                self.send_header("Range", f"bytes=0-{end}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            fid = f"file-{mock_state['next_id']}"
            mock_state["next_id"] += 1
            dst_fp = mock_state["drive_folders"][sess["parent"]] / sess["name"]
            dst_fp.parent.mkdir(parents=True, exist_ok=True)
            dst_fp.write_bytes(bytes(sess["buf"]))
            mock_state["drive_files"][fid] = {
                "parent": sess["parent"],
                "name": sess["name"],
                "size": len(sess["buf"]),
            }
            mock_state["drive_put_200"] += 1
            size_out = str(len(sess["buf"]))
        self._send_json(200, {"id": fid, "name": sess["name"], "size": size_out})


class ReusableThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


server = ReusableThreadingServer(("127.0.0.1", 0), MockHTTPHandler)
srv_port = server.server_address[1]
srv_thread = threading.Thread(target=server.serve_forever, daemon=True)
srv_thread.start()

try:
    base_url = f"http://127.0.0.1:{srv_port}"
    os.environ["MAYA_WORK_ROOT"] = str(box / "work")
    os.environ["MAYA_DRIVE_MOUNT_ROOT"] = str(box / "drive")
    os.environ["MAYA_SKIP_APT"] = "1"
    os.environ["COLABD_HF_BASE_URL"] = base_url
    os.environ["COLABD_DRIVE_API_BASE"] = f"{base_url}/drive/v3"
    os.environ["COLABD_DRIVE_UPLOAD_BASE"] = f"{base_url}/upload/drive/v3"
    os.environ["COLABD_MULTIPART_MIN_BYTES"] = str(1024 * 1024)
    os.environ["COLABD_DRIVE_CHUNK_BYTES"] = str(512 * 1024)
    os.environ["COLABD_DRIVE_ACCESS_TOKEN"] = "mock-drive-token"

    ns = {"__name__": "unit_test"}
    exec(compile(pathlib.Path(runner_py).read_text(), runner_py, "exec"), ns)

    # Confirm legacy sync-back & prefetch functions are completely removed
    assert "sync_new_shards_to_drive" not in ns
    assert "prefetch_dir_from_drive" not in ns

    models_dir, ram_res = ns["prepare_storage_and_deps"]()
    assert ram_res is True

    local_engram = models_dir / "Engram-Q6_K"
    assert not local_engram.is_symlink()

    ablit_link = models_dir / "DeepSeek-V4.1-Flash-1017-abliterated-GGUF" / "Engram-Q6_K"
    assert ablit_link.is_symlink() and ablit_link.resolve() == local_engram.resolve()

    mix_link = models_dir / "DeepSeek-V4.1-Flash-1017-abliterated-GGUF" / "Mix-128G"
    assert mix_link.is_symlink()
    assert ns["_is_on_drive_mount"](mix_link / "model-00001.gguf") is True
    assert ns["_is_on_drive_mount"](local_engram / "engram-test.gguf") is False

    # 3a. Multi-threaded HTTP Range download onto local NVMe
    local_out = ns["download_hf_file"]("testorg/local-repo", "engram-test.gguf", local_engram / "engram-test.gguf")
    assert local_out is not None and local_out.read_bytes() == PAYLOAD_LOCAL
    assert mock_state["range_hits"] >= 4, f"Expected multi-threaded Range requests, got {mock_state['range_hits']}"
    assert not (local_engram / "engram-test.gguf.part").exists()
    assert not (local_engram / "engram-test.gguf.part.meta.json").exists()

    # 3b. Drive REST API v3 zero-local-cache streaming upload through symlink + in-place reuse
    cnt1 = ns["ensure_hf_subdir_files"](
        "orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF", "Mix-128G", mix_link
    )
    assert cnt1 == 1
    assert mock_state["drive_put_308"] >= 2, f"Expected multi-chunk 308 responses, got {mock_state['drive_put_308']}"
    assert mock_state["drive_put_200"] == 1
    drive_written = box / "drive" / "maya-models" / "DeepSeek-V4.1-Flash-1017-abliterated-GGUF" / "Mix-128G" / "model-00001.gguf"
    assert hashlib.sha256(drive_written.read_bytes()).hexdigest() == hashlib.sha256(PAYLOAD_DRIVE_API).hexdigest()

    # Second call MUST hit in-place Drive API check and trigger 0 additional uploads!
    ns["ensure_hf_subdir_files"](
        "orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF", "Mix-128G", mix_link
    )
    assert mock_state["drive_put_200"] == 1, "Expected Drive API existing-file hit to skip re-upload!"

    # 3c. Auto fallback to FUSE direct-write when no Drive API token + local disk watermark guard
    os.environ.pop("COLABD_DRIVE_ACCESS_TOKEN", None)
    ns["_get_drive_api_token"] = lambda: None
    fuse_dst = mix_link / "fuse-direct.gguf"
    fuse_out = ns["download_hf_file"]("testorg/fuse-repo", "fuse-direct.gguf", fuse_dst)
    assert fuse_out is not None and fuse_out.read_bytes() == PAYLOAD_DRIVE_FUSE
    assert ns["_wrote_via_fuse"] is True
    assert not (mix_link / "fuse-direct.gguf.part").exists()

    # Verify FUSE watermark guard checks LOCAL root disk (not Drive quota!) and aborts on critical low local disk
    DiskUsage = collections.namedtuple("usage", ["total", "used", "free"])
    orig_du = shutil.disk_usage
    ns["FUSE_BACKPRESSURE_MAX_WAIT_SEC"] = 0.15
    work_real = os.path.realpath(str(box / "work"))

    def fake_disk_usage(p):
        if os.path.realpath(str(p)).startswith(work_real):
            return DiskUsage(250 * 1024**3, 248 * 1024**3, 2 * 1024**3)  # Local disk critically low: 2 GiB!
        return DiskUsage(2000 * 1024**3, 100 * 1024**3, 1900 * 1024**3)  # Drive quota huge: 1900 GiB!

    shutil.disk_usage = fake_disk_usage
    try:
        hit_guard = False
        try:
            ns["download_hf_file"]("testorg/fuse-repo", "fuse-direct.gguf", mix_link / "fuse-blocked.gguf")
        except RuntimeError as exc:
            if "临界水位" in str(exc):
                hit_guard = True
        assert hit_guard, "Expected FUSE local-disk watermark guard to abort instead of trusting Drive quota!"
    finally:
        shutil.disk_usage = orig_du

    # 3d. Maya config patching + nvme_engram missing-Drive guard
    maya_dir = box / "work" / "project-maya"
    maya_dir.mkdir(parents=True, exist_ok=True)
    cfg_file = maya_dir / "maya-ds4.json"
    cfg_file.write_text(json.dumps({"args": ["--max-context", "65536"]}))
    ns["patch_existing_maya_configs"](maya_dir, True)
    assert json.loads(cfg_file.read_text())["args"][-2:] == ["--mmap-experts", "off"]

    ns["DRIVE_MOUNT_ROOT"] = box / "missing_drive_mount"
    shutil.disk_usage = lambda _p: DiskUsage(250 * 1024**3, 50 * 1024**3, 200 * 1024**3)
    try:
        aborted_code = None
        try:
            ns["prepare_storage_and_deps"]()
        except SystemExit as exc:
            aborted_code = exc.code
        assert aborted_code == 2, f"Expected nvme_engram missing-Drive guard exit(2), got {aborted_code}"
    finally:
        shutil.disk_usage = orig_du
finally:
    server.shutdown()
    server.server_close()
PYTEST
python3 "${ROOT_DIR}/tests/test_vm_auth.py" >/dev/null

echo "[4/9] Testing account_store.py identity deduplication, scope parser, 0600 perms, and revocation..."
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
revoke_log = box / "store_test" / "revoke.log"
colab_dir.mkdir(parents=True, exist_ok=True)

env = os.environ.copy()
env["COLABD_KEYRING_FILE"] = str(kr_file)
env["COLAB_CLI_CONFIG_DIR"] = str(colab_dir)
env["COLABD_TEST_REVOKE_LOG"] = str(revoke_log)

def run_store(*args, check=True, stdin_text=None):
    return subprocess.run(
        [sys.executable, str(store), *args],
        env=env,
        input=stdin_text,
        text=True,
        capture_output=True,
        check=check,
    )

# Canonical IDs
assert run_store("canonical-id", "Alice@Example.COM", "oauth2").stdout.strip() == "alice@example.com"
assert run_store("canonical-id", "Alice@Example.COM", "adc").stdout.strip() == "adc:alice@example.com"

# Save + deduplicate by normalized email
legacy_tok = colab_dir / "token.json"
legacy_tok.write_text(json.dumps({"email": "alice@example.com", "refresh_token": "rt-a1"}))
r1 = run_store("oauth-save-account", str(accts), "Alice@Example.com", "--note", "Pro+ Main").stdout.strip()
assert r1 == "created\talice@example.com\tkeyring", r1

# Save same email again (different case) -> MUST update in place, preserve note & count=1
legacy_tok.write_text(json.dumps({"email": "alice@example.com", "refresh_token": "rt-a2"}))
r2 = run_store("oauth-save-account", str(accts), "ALICE@EXAMPLE.COM").stdout.strip()
assert r2 == "updated\talice@example.com\tkeyring", r2
rows = [ln for ln in run_store("list", str(accts)).stdout.splitlines() if ln.strip()]
assert len(rows) == 1
assert run_store("meta-get", str(accts), "alice@example.com", "note").stdout.strip() == "Pro+ Main"

# Activate removes legacy token.json and enforces 0600
assert run_store("oauth-activate-account", str(accts), "alice@example.com").stdout.strip() == "keyring"
assert not legacy_tok.exists()
assert stat.S_IMODE(kr_file.stat().st_mode) == 0o600

# ADC profile stored in macOS-safe dir (no ':'), resolved by canonical ID
adc_src = box / "store_test" / "adc_src.json"
adc_src.write_text(json.dumps({"type": "authorized_user", "email": "corp@example.com"}))
r_adc = run_store("adc-save-account", str(accts), "corp@example.com", str(adc_src)).stdout.strip()
assert r_adc == "created\tadc:corp@example.com\tfile", r_adc
adc_dir = pathlib.Path(run_store("path", str(accts), "adc:corp@example.com").stdout.strip())
assert ":" not in adc_dir.name
assert stat.S_IMODE((adc_dir / "adc.json").stat().st_mode) == 0o600
# Bare email resolves unambiguously when only adc:corp@example.com exists
assert run_store("resolve-id", str(accts), "corp@example.com").stdout.strip() == "adc:corp@example.com"

# Scope parser catches missing required & optional scopes, and accepts OIDC short 'email' scope
whoami_missing_colab = """Auth provider: oauth2
Email:         bob@example.com
Scopes:
  - https://www.googleapis.com/auth/userinfo.email
  - openid
"""
parsed = run_store("parse-whoami", "oauth2", "-", stdin_text=whoami_missing_colab).stdout.strip().split("\x1f")
assert parsed[0] == "bob@example.com"
assert parsed[1] == "1"
assert "colaboratory" in parsed[2]
assert "drive.file" in parsed[3]

whoami_short_email = """Auth provider: oauth2
Email:         short@example.com
Scopes:
  - email
  - openid
  - https://www.googleapis.com/auth/colaboratory
  - https://www.googleapis.com/auth/drive.file
"""
parsed_short = run_store("parse-whoami", "oauth2", "-", stdin_text=whoami_short_email).stdout.strip().split("\x1f")
assert parsed_short[0] == "short@example.com"
assert parsed_short[1] == "1"
assert parsed_short[2] == "", f"Short 'email' scope should satisfy userinfo.email, got {parsed_short}"
assert parsed_short[3] == ""

# Peek active OAuth2 email & set leading-dash note via --note=
assert run_store("oauth-peek-active-email").stdout.strip() == "alice@example.com"
run_store("meta-set", str(accts), "alice@example.com", "--note=-leading-dash note")
assert run_store("meta-get", str(accts), "alice@example.com", "note").stdout.strip() == "-leading-dash note"

# Revoke + delete cleans keyring & directory
run_store("delete-account", str(accts), "alice@example.com", "--revoke")
assert "REVOKE token=rt-a" in revoke_log.read_text()
assert run_store("exists", str(accts), "alice@example.com", check=False).returncode != 0
PYSTORE

echo "[5/9] Testing identity-based CRUD, deduplication, cross-account release, and fail-closed delete gate..."
MULTI_BOX="${SANDBOX}/multi"
mkdir -p "${MULTI_BOX}/mockbin" "${MULTI_BOX}/cfg" "${MULTI_BOX}/colab_cli" "${MULTI_BOX}/gcloud_cfg"

# Realistic mock colab CLI aligned 1-to-1 with real google-colab-cli v0.8.0:
# - Rejects `colab logout` with exit code 2
# - `whoami --help` exits 0 without authenticating
# - `status -s <missing>` and `stop -s <missing>` print "not found" and exit 0 (real v0.8.0 behavior!)
# - `--auth adc sessions` on invalid ADC with empty local sessions prints "No valid default credentials found."
#   to stderr and exits 0, while `whoami` exits 1 (real sync_sessions() SystemExit swallowing!)
# - Interactive OAuth2 login with partial scopes fails unless OAUTHLIB_RELAX_TOKEN_SCOPE=1
# - `sessions` prunes stale entries from cfg_path (real sync_sessions() behavior!)
# - Returns 403 on `sessions`/`new` when `colaboratory` scope is missing
# - Supports failing `stop` when MOCK_FAIL_STOP_FILE exists
cat > "${MULTI_BOX}/mockbin/colab" <<'MOCKCOLAB'
#!/usr/bin/env python3
import json
import os
import pathlib
import sys
import time

KR_FILE = pathlib.Path(os.environ["COLABD_KEYRING_FILE"])
SRV_FILE = pathlib.Path(os.environ["MOCK_SERVER_STATE"])
LOG_FILE = pathlib.Path(os.environ["MOCK_CALL_LOG"])
NEXT_LOGIN_FILE = pathlib.Path(os.environ["MOCK_NEXT_LOGIN_FILE"])
NEXT_SCOPES_FILE = pathlib.Path(os.environ.get("MOCK_NEXT_SCOPES_FILE", "")) if os.environ.get("MOCK_NEXT_SCOPES_FILE") else None
FAIL_STOP_FILE = pathlib.Path(os.environ.get("MOCK_FAIL_STOP_FILE", "")) if os.environ.get("MOCK_FAIL_STOP_FILE") else None
DEFAULT_SESS = pathlib.Path(os.environ.get("COLAB_CLI_CONFIG_DIR", "~/.config/colab-cli")).expanduser() / "sessions.json"

DEFAULT_SCOPES = {
    "oauth2": [
        "openid",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/colaboratory",
        "https://www.googleapis.com/auth/drive.file",
    ],
    "adc": [
        "openid",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/colaboratory",
    ],
}

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

if sub == "whoami" and ("--help" in sub_args or "-h" in sub_args):
    print("Usage: colab whoami [OPTIONS]")
    sys.exit(0)

if sub == "logout":
    print("No such command 'logout'.", file=sys.stderr)
    sys.exit(2)

delay_s = float(os.environ.get("MOCK_PROBE_DELAY_SEC", "0") or "0")
if delay_s > 0 and sub in ("sessions", "whoami"):
    time.sleep(delay_s)

def next_scopes(mode):
    if NEXT_SCOPES_FILE and NEXT_SCOPES_FILE.is_file():
        raw = NEXT_SCOPES_FILE.read_text(encoding="utf-8").strip()
        if raw:
            return [s.strip() for s in raw.split(",") if s.strip()]
    return list(DEFAULT_SCOPES[mode])

def current_auth(allow_interactive=False):
    if auth_mode == "adc":
        adc_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
        if not adc_path:
            adc_path = str(pathlib.Path(os.environ.get("CLOUDSDK_CONFIG", "~/.config/gcloud")).expanduser() / "application_default_credentials.json")
        p = pathlib.Path(adc_path)
        if not p.is_file():
            return None, [], "missing_adc"
        data = load_json(p)
        if data.get("invalid"):
            return None, [], "invalid_adc"
        return (data.get("mock_email") or "adc@example.com"), data.get("mock_scopes", DEFAULT_SCOPES["adc"]), None

    kr = load_json(KR_FILE)
    tok_raw = kr.get("google-colab-cli", {}).get("oauth_token")
    if tok_raw:
        try:
            d = json.loads(tok_raw)
            return d.get("email"), d.get("scopes", DEFAULT_SCOPES["oauth2"]), None
        except Exception:
            return "unknown@example.com", DEFAULT_SCOPES["oauth2"], None

    if allow_interactive and os.environ.get("BROWSER") != "/usr/bin/false":
        email = NEXT_LOGIN_FILE.read_text(encoding="utf-8").strip() if NEXT_LOGIN_FILE.exists() else "fresh@example.com"
        scopes = next_scopes("oauth2")
        if set(scopes) != set(DEFAULT_SCOPES["oauth2"]) and os.environ.get("OAUTHLIB_RELAX_TOKEN_SCOPE") != "1":
            print("Warning: Scope has changed from requested scopes.", file=sys.stderr)
            sys.exit(1)
        kr.setdefault("google-colab-cli", {})["oauth_token"] = json.dumps(
            {"email": email, "refresh_token": f"rt-{email}", "scopes": scopes}
        )
        save_json(KR_FILE, kr)
        return email, scopes, None
    return None, [], "unauth"

allow_login = sub in ("sessions", "whoami", "new")
ident, scopes, auth_err = current_auth(allow_interactive=allow_login)

with LOG_FILE.open("a", encoding="utf-8") as lf:
    lf.write(f"COLAB ident={ident or 'NONE'} mode={auth_mode} cfg={cfg_path.name} sub={sub} args={' '.join(sub_args)}\n")

if not ident:
    if auth_mode == "adc" and sub == "sessions" and not load_json(cfg_path):
        print("No valid default credentials found.", file=sys.stderr)
        print("[colab] No active sessions found on server.")
        sys.exit(0)
    if auth_mode == "adc":
        print("No valid default credentials found.", file=sys.stderr)
    else:
        print("Not authenticated", file=sys.stderr)
    sys.exit(1)

if sub == "whoami":
    has_email_scope = (
        "https://www.googleapis.com/auth/userinfo.email" in scopes
        or "email" in scopes
    )
    print(f"Auth provider: {auth_mode}")
    print(f"Email:         {ident if has_email_scope else '<unavailable: token has no userinfo.email scope>'}")
    print("Expires in:    59m")
    if scopes:
        print("Scopes:")
        for sc in sorted(scopes):
            print(f"  - {sc}")
    else:
        print("Scopes:        <none>")
    sys.exit(0)

if "https://www.googleapis.com/auth/colaboratory" not in scopes:
    print("HTTP 403 ACCESS_TOKEN_SCOPE_INSUFFICIENT: missing colaboratory scope", file=sys.stderr)
    sys.exit(1)

if sub == "usage":
    print(f"Account: {ident} | Balance: 100.00 CU")
    sys.exit(0)

srv = load_json(SRV_FILE)
acct_srv = srv.setdefault(ident.lower(), {})
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
    ep = f"m-{ident.lower().split('@')[0]}-{sname}"
    acct_srv[ep] = {"accelerator": gpu, "machine_shape": "HIGH_RAM"}
    save_json(SRV_FILE, srv)
    local[sname] = {"name": sname, "endpoint": ep, "accelerator": gpu, "machine_shape": "HIGH_RAM", "token": "rtok", "url": "https://mock"}
    save_json(cfg_path, local)
    print("[colab] Session READY.")
    sys.exit(0)

if sub == "sessions":
    # Mirror real google-colab-cli sync_sessions() pruning stale local entries!
    pruned = {k: v for k, v in local.items() if isinstance(v, dict) and v.get("endpoint") in acct_srv}
    if pruned != local and cfg_path.exists():
        save_json(cfg_path, pruned)
        local = pruned
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
        # Real google-colab-cli v0.8.0 returns exit code 0 on missing session!
        print(f"[colab] Session '{sname}' not found.")
        sys.exit(0)
    sys.exit(0)

if sub == "stop":
    if FAIL_STOP_FILE and FAIL_STOP_FILE.exists():
        print("[colab] Simulated network error while stopping runtime", file=sys.stderr)
        sys.exit(1)
    sname = opt_val("-s") or next(iter(local.keys()), "")
    if sname not in local:
        # Real google-colab-cli v0.8.0 returns exit code 0 on missing session!
        print(f"[colab] Session '{sname}' not found.")
        sys.exit(0)
    ep = local[sname]["endpoint"]
    if ep not in acct_srv:
        print(f"[colab] Endpoint '{ep}' does not belong to {ident}!", file=sys.stderr)
        sys.exit(1)
    del acct_srv[ep]
    del local[sname]
    save_json(SRV_FILE, srv)
    save_json(cfg_path, local)
    with LOG_FILE.open("a", encoding="utf-8") as lf:
        lf.write(f"STOPPED ident={ident.lower()} mode={auth_mode} session={sname} ep={ep}\n")
    print("[colab] Session terminated.")
    sys.exit(0)

if sub in ("restart-kernel", "exec"):
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
python3 - "$EMAIL" "${CLOUDSDK_CONFIG}/application_default_credentials.json" "${MOCK_NEXT_SCOPES_FILE:-}" <<'PYG'
import json, pathlib, sys
email, dst, sc_file = sys.argv[1:4]
scopes = [
    "openid",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/colaboratory",
]
if sc_file and pathlib.Path(sc_file).is_file():
    raw = pathlib.Path(sc_file).read_text().strip()
    if raw:
        scopes = [s.strip() for s in raw.split(",") if s.strip()]
pathlib.Path(dst).write_text(json.dumps({"type": "authorized_user", "mock_email": email, "mock_scopes": scopes}))
PYG
exit 0
MOCKGCLOUD

chmod +x "${MULTI_BOX}/mockbin/colab" "${MULTI_BOX}/mockbin/gcloud"

export XDG_CONFIG_HOME="${MULTI_BOX}/cfg"
export COLABD_RUNTIME_DIR="${MULTI_BOX}/rt"
export COLAB_CLI_CONFIG_DIR="${MULTI_BOX}/colab_cli"
export CLOUDSDK_CONFIG="${MULTI_BOX}/gcloud_cfg"
export COLABD_KEYRING_FILE="${MULTI_BOX}/keyring.json"
export COLABD_TEST_REVOKE_LOG="${MULTI_BOX}/revoke.log"
export MOCK_SERVER_STATE="${MULTI_BOX}/server_state.json"
export MOCK_CALL_LOG="${MULTI_BOX}/calls.log"
export MOCK_NEXT_LOGIN_FILE="${MULTI_BOX}/next_login.txt"
export MOCK_NEXT_SCOPES_FILE="${MULTI_BOX}/next_scopes.txt"
export MOCK_FAIL_STOP_FILE="${MULTI_BOX}/fail_stop.flag"
export NO_COLOR=1

run_colabd() {
  PATH="${MULTI_BOX}/mockbin:$PATH" bash --noprofile --norc "${ROOT_DIR}/bin/colabd" "$@"
}

# 5a. Login acc1@example.com with note (must not prune external ~/.config/colab-cli/sessions.json),
#     then test multi-word & leading-dash note, then re-login ACC1@EXAMPLE.COM -> MUST deduplicate!
printf '{"external-job":{"name":"external-job","endpoint":"m-ext-1"}}\n' > "${COLAB_CLI_CONFIG_DIR}/sessions.json"
echo "acc1@example.com" > "$MOCK_NEXT_LOGIN_FILE"
run_colabd auth login --oauth2 --note "Pro+Main" --release >/dev/null
grep -q '^ACTIVE_ACCOUNT=acc1@example.com$' "${XDG_CONFIG_HOME}/colabd/config.env"
grep -q 'external-job' "${COLAB_CLI_CONFIG_DIR}/sessions.json"

run_colabd auth note acc1@example.com -leading-dash multi word >/dev/null
[[ "$(python3 "${ROOT_DIR}/lib/account_store.py" meta-get "${XDG_CONFIG_HOME}/colabd/accounts" "acc1@example.com" note)" == "-leading-dash multi word" ]]
run_colabd auth note acc1@example.com "Pro+Main" >/dev/null

ACC1_DIR="$(python3 "${ROOT_DIR}/lib/account_store.py" path "${XDG_CONFIG_HOME}/colabd/accounts" "acc1@example.com")"
PATH="${MULTI_BOX}/mockbin:$PATH" colab --config "${ACC1_DIR}/sessions.json" --auth oauth2 new -s colabd-llm --gpu G4 >/dev/null

echo "ACC1@EXAMPLE.COM" > "$MOCK_NEXT_LOGIN_FILE"
DUP_OUT="$(run_colabd auth login --oauth2 --release)"
printf '%s\n' "$DUP_OUT" | grep -q '去重检测'
grep -q 'STOPPED ident=acc1@example.com mode=oauth2 session=colabd-llm ep=m-acc1-colabd-llm' "$MOCK_CALL_LOG"
ACCT_COUNT="$(python3 "${ROOT_DIR}/lib/account_store.py" list "${XDG_CONFIG_HOME}/colabd/accounts" | wc -l | tr -d ' ')"
[[ "$ACCT_COUNT" == "1" ]] || { echo "Duplicate account created! count=$ACCT_COUNT" >&2; exit 1; }
[[ "$(python3 "${ROOT_DIR}/lib/account_store.py" meta-get "${XDG_CONFIG_HOME}/colabd/accounts" "acc1@example.com" note)" == "Pro+Main" ]]

# 5b. Login second OAuth2 account acc2@example.com + instant switch + ADC account adc:gcp1@corp.example.com
echo "acc2@example.com" > "$MOCK_NEXT_LOGIN_FILE"
run_colabd auth login --oauth2 --release >/dev/null
grep -q '^ACTIVE_ACCOUNT=acc2@example.com$' "${XDG_CONFIG_HOME}/colabd/config.env"
WHOAMI_OUT="$(run_colabd auth whoami)"
printf '%s\n' "$WHOAMI_OUT" | grep -q 'acc2@example.com'

rm -f "$MOCK_NEXT_LOGIN_FILE"
run_colabd switch acc1@example.com --release >/dev/null
grep -q '^ACTIVE_ACCOUNT=acc1@example.com$' "${XDG_CONFIG_HOME}/colabd/config.env"
WHOAMI_OUT="$(run_colabd auth whoami)"
printf '%s\n' "$WHOAMI_OUT" | grep -q 'acc1@example.com'

echo "gcp1@corp.example.com" > "$MOCK_NEXT_LOGIN_FILE"
run_colabd auth login --adc --release >/dev/null
grep -q '^ACTIVE_ACCOUNT=adc:gcp1@corp.example.com$' "${XDG_CONFIG_HOME}/colabd/config.env"
GCP1_DIR="$(python3 "${ROOT_DIR}/lib/account_store.py" path "${XDG_CONFIG_HOME}/colabd/accounts" "adc:gcp1@corp.example.com")"
GOOGLE_APPLICATION_CREDENTIALS="${GCP1_DIR}/adc.json" \
  PATH="${MULTI_BOX}/mockbin:$PATH" colab --config "${GCP1_DIR}/sessions.json" --auth adc new -s gcp-job --gpu A100 >/dev/null

# Verify colab_session_is_active parses real v0.8.0 RC=0 "not found" accurately
PATH="${MULTI_BOX}/mockbin:$PATH" bash --noprofile --norc -c "
  set -euo pipefail
  export TMPDIR='${SANDBOX}/tmp'
  COLABD_LIB_DIR='${ROOT_DIR}/lib'
  source '${ROOT_DIR}/lib/core.sh'
  source '${ROOT_DIR}/lib/env.sh'
  source '${ROOT_DIR}/lib/auth.sh'
  source '${ROOT_DIR}/lib/lifecycle.sh'
  load_config
  colab_session_is_active adc 'adc:gcp1@corp.example.com' 'gcp-job'
  if colab_session_is_active adc 'adc:gcp1@corp.example.com' 'nonexistent-sess'; then
    echo 'colab_session_is_active returned 0 on nonexistent session!' >&2
    exit 1
  fi
  rm -rf \"\$STATE_DIR\"
"

run_colabd switch acc1@example.com --keep >/dev/null
run_colabd down -a adc:gcp1@corp.example.com >/dev/null
grep -q 'STOPPED ident=gcp1@corp.example.com mode=adc session=gcp-job ep=m-gcp1-gcp-job' "$MOCK_CALL_LOG"
grep -q '^ACTIVE_ACCOUNT=acc1@example.com$' "${XDG_CONFIG_HOME}/colabd/config.env"

# 5c. Global release `colabd down --all` across all 3 accounts, restoring acc1@example.com afterwards
ACC2_DIR="$(python3 "${ROOT_DIR}/lib/account_store.py" path "${XDG_CONFIG_HOME}/colabd/accounts" "acc2@example.com")"
PATH="${MULTI_BOX}/mockbin:$PATH" colab --config "${ACC1_DIR}/sessions.json" --auth oauth2 new -s s-acc1 --gpu G4 >/dev/null
run_colabd switch acc2@example.com --keep >/dev/null
PATH="${MULTI_BOX}/mockbin:$PATH" colab --config "${ACC2_DIR}/sessions.json" --auth oauth2 new -s s-acc2 --gpu H100 >/dev/null
GOOGLE_APPLICATION_CREDENTIALS="${GCP1_DIR}/adc.json" \
  PATH="${MULTI_BOX}/mockbin:$PATH" colab --config "${GCP1_DIR}/sessions.json" --auth adc new -s s-gcp1 --gpu L4 >/dev/null
run_colabd switch acc1@example.com --keep >/dev/null

run_colabd down --all >/dev/null
grep -q 'STOPPED ident=acc1@example.com mode=oauth2 session=s-acc1 ep=m-acc1-s-acc1' "$MOCK_CALL_LOG"
grep -q 'STOPPED ident=acc2@example.com mode=oauth2 session=s-acc2 ep=m-acc2-s-acc2' "$MOCK_CALL_LOG"
grep -q 'STOPPED ident=gcp1@corp.example.com mode=adc session=s-gcp1 ep=m-gcp1-s-gcp1' "$MOCK_CALL_LOG"
WHOAMI_OUT="$(run_colabd auth whoami)"
printf '%s\n' "$WHOAMI_OUT" | grep -q 'acc1@example.com'

# 5d. HARD DELETE GATE & OPT-IN --revoke:
#   - Removing with --keep MUST fail!
#   - Removing when `colab stop` fails MUST abort & preserve credentials + sessions.json!
#   - Default remove (without --revoke) clears local keyring WITHOUT revoking shared Cloud SDK grant!
run_colabd switch acc2@example.com --release >/dev/null
PATH="${MULTI_BOX}/mockbin:$PATH" colab --config "${ACC2_DIR}/sessions.json" --auth oauth2 new -s s-hardgate --gpu T4 >/dev/null
run_colabd switch acc1@example.com --keep >/dev/null

if run_colabd auth remove acc2@example.com --keep >/dev/null 2>&1; then
  echo "Expected 'auth remove --keep' to be rejected!" >&2
  exit 1
fi
if run_colabd auth logout --keep >/dev/null 2>&1; then
  echo "Expected 'auth logout --keep' to be rejected!" >&2
  exit 1
fi

touch "$MOCK_FAIL_STOP_FILE"
if run_colabd auth remove acc2@example.com --release >/dev/null 2>&1; then
  echo "Expected 'auth remove' to ABORT when colab stop fails!" >&2
  exit 1
fi
[[ -d "$ACC2_DIR" && -f "${ACC2_DIR}/sessions.json" ]] || { echo "Hard delete gate failed: acc2 dir or sessions.json lost after failed stop!" >&2; exit 1; }
rm -f "$MOCK_FAIL_STOP_FILE"

run_colabd auth remove acc2@example.com --release >/dev/null
grep -q 'STOPPED ident=acc2@example.com mode=oauth2 session=s-hardgate ep=m-acc2-s-hardgate' "$MOCK_CALL_LOG"
[[ ! -d "$ACC2_DIR" ]] || { echo "acc2 dir not deleted after verified release" >&2; exit 1; }
if [[ -f "$COLABD_TEST_REVOKE_LOG" ]] && grep -q 'rt-acc2@example.com' "$COLABD_TEST_REVOKE_LOG"; then
  echo "Default 'auth remove' without --revoke must NOT revoke remote OAuth token!" >&2
  exit 1
fi
WHOAMI_OUT="$(run_colabd auth whoami)"
printf '%s\n' "$WHOAMI_OUT" | grep -q 'acc1@example.com'

# 5e. Unified `auth logout --revoke` removes active account cleanly, revokes when requested, & never invokes `colab logout`
PATH="${MULTI_BOX}/mockbin:$PATH" colab --config "${ACC1_DIR}/sessions.json" --auth oauth2 new -s s-logout --gpu G4 >/dev/null
run_colabd auth logout --release --revoke >/dev/null
grep -q 'STOPPED ident=acc1@example.com mode=oauth2 session=s-logout ep=m-acc1-s-logout' "$MOCK_CALL_LOG"
grep -qi 'REVOKE token=rt-acc1@example.com' "$COLABD_TEST_REVOKE_LOG"
grep -Eq "^ACTIVE_ACCOUNT=(''){0,1}$" "${XDG_CONFIG_HOME}/colabd/config.env"
[[ ! -d "$ACC1_DIR" ]] || { echo "auth logout should remove active account cleanly without leaving ghost slot" >&2; exit 1; }
if grep -q 'sub=logout' "$MOCK_CALL_LOG"; then
  echo "colabd must never invoke nonexistent 'colab logout'" >&2
  exit 1
fi

# 5f. ADC Zombie Resurrection Prevention, Strict Missing-ADC Isolation, Fail-Closed Gate, & Invalid ADC Detection
run_colabd switch adc:gcp1@corp.example.com --release >/dev/null
run_colabd auth logout --release >/dev/null
[[ -f "${CLOUDSDK_CONFIG}/application_default_credentials.json" ]] || { echo "ADC logout must never delete host gcloud ADC file!" >&2; exit 1; }
grep -q '^AUTO_ADOPT_EXTERNAL=0$' "${XDG_CONFIG_HOME}/colabd/config.env"
grep -q '^COLAB_AUTH_MODE=oauth2$' "${XDG_CONFIG_HOME}/colabd/config.env"
if run_colabd auth whoami >/dev/null 2>&1; then
  echo "Logged-out ADC account zombie-resurrected on whoami!" >&2
  exit 1
fi
LIST_AFTER_ADC_LOGOUT="$(run_colabd auth list)"
if printf '%s\n' "$LIST_AFTER_ADC_LOGOUT" | grep -q 'adc:gcp1@corp.example.com'; then
  echo "Logged-out ADC account resurrected in account list!" >&2
  exit 1
fi

# Missing managed adc.json must NOT fall back to host ADC, and remove must Fail-Closed unless --force
echo "gcp2@corp.example.com" > "$MOCK_NEXT_LOGIN_FILE"
run_colabd auth login --adc --release >/dev/null
GCP2_DIR="$(python3 "${ROOT_DIR}/lib/account_store.py" path "${XDG_CONFIG_HOME}/colabd/accounts" "adc:gcp2@corp.example.com")"
rm -f "${GCP2_DIR}/adc.json"
if run_colabd auth whoami >/dev/null 2>&1; then
  echo "Managed ADC account with missing adc.json fell back to host global ADC!" >&2
  exit 1
fi
if run_colabd auth remove adc:gcp2@corp.example.com --release >/dev/null 2>&1; then
  echo "Expected fail-closed rejection when removing ADC account with missing credentials!" >&2
  exit 1
fi
[[ -d "$GCP2_DIR" ]] || { echo "Fail-closed delete gate unexpectedly deleted gcp2 dir!" >&2; exit 1; }
run_colabd auth remove adc:gcp2@corp.example.com --release --force >/dev/null
[[ ! -d "$GCP2_DIR" ]] || { echo "--force did not remove gcp2 dir!" >&2; exit 1; }

# Expired/invalid ADC must be caught as unauth even when `colab --auth adc sessions` exits 0!
echo "gcp3@corp.example.com" > "$MOCK_NEXT_LOGIN_FILE"
run_colabd auth login --adc --release >/dev/null
GCP3_DIR="$(python3 "${ROOT_DIR}/lib/account_store.py" path "${XDG_CONFIG_HOME}/colabd/accounts" "adc:gcp3@corp.example.com")"
printf '{"type":"authorized_user","mock_email":"gcp3@corp.example.com","invalid":true}\n' > "${GCP3_DIR}/adc.json"
GOOGLE_APPLICATION_CREDENTIALS="${GCP3_DIR}/adc.json" \
  PATH="${MULTI_BOX}/mockbin:$PATH" colab --config "${GCP3_DIR}/sessions.json" --auth adc sessions >/dev/null 2>&1
if run_colabd auth whoami >/dev/null 2>&1; then
  echo "Invalid ADC was misreported as ok despite whoami failure!" >&2
  exit 1
fi
if run_colabd auth remove adc:gcp3@corp.example.com --release >/dev/null 2>&1; then
  echo "Expected fail-closed rejection when removing invalid/expired ADC account!" >&2
  exit 1
fi
run_colabd auth remove adc:gcp3@corp.example.com --release --force >/dev/null
[[ ! -d "$GCP3_DIR" ]] || { echo "--force did not remove invalid gcp3 dir!" >&2; exit 1; }

echo "[6/9] Testing missing scope detection, login rejection, auth refresh repair, and running-daemon delete block..."
# 6a. Login with missing `colaboratory` scope MUST pass OAUTHLIB_RELAX_TOKEN_SCOPE=1,
#     reach colabd's own scope check, be rejected, and NOT be saved
echo "noscope@example.com" > "$MOCK_NEXT_LOGIN_FILE"
echo "openid,https://www.googleapis.com/auth/userinfo.email" > "$MOCK_NEXT_SCOPES_FILE"
NOSCOPE_RC=0
NOSCOPE_OUT="$(run_colabd auth login --oauth2 --release 2>&1)" || NOSCOPE_RC=$?
[[ "$NOSCOPE_RC" -ne 0 ]] || { echo "Expected login missing colaboratory scope to fail!" >&2; exit 1; }
printf '%s\n' "$NOSCOPE_OUT" | grep -q '缺失必需权限域'
if python3 "${ROOT_DIR}/lib/account_store.py" exists "${XDG_CONFIG_HOME}/colabd/accounts" "noscope@example.com" >/dev/null 2>&1; then
  echo "Under-scoped account must NOT be saved into account store!" >&2
  exit 1
fi

# 6b. Existing external under-scoped token -> detected as insufficient_scope -> fixed in-place via `auth refresh`
#     WITHOUT revoking shared Cloud SDK OAuth token!
python3 - "$COLABD_KEYRING_FILE" <<'PYINJ'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
db = json.loads(p.read_text()) if p.exists() else {}
db.setdefault("google-colab-cli", {})["oauth_token"] = json.dumps({
    "email": "repair@example.com",
    "refresh_token": "rt-broken-scope",
    "scopes": ["openid", "https://www.googleapis.com/auth/userinfo.email"],
})
p.write_text(json.dumps(db, indent=2))
PYINJ

WHOAMI_ERR="$(run_colabd auth whoami 2>&1 || true)"
printf '%s\n' "$WHOAMI_ERR" | grep -q '权限域不足'

rm -f "$MOCK_NEXT_SCOPES_FILE"
echo "repair@example.com" > "$MOCK_NEXT_LOGIN_FILE"
run_colabd auth refresh --non-interactive >/dev/null
if [[ -f "$COLABD_TEST_REVOKE_LOG" ]] && grep -q 'rt-broken-scope' "$COLABD_TEST_REVOKE_LOG"; then
  echo "auth refresh must NOT revoke old token before re-auth (protects rollback & gcloud ADC)!" >&2
  exit 1
fi
grep -q '^ACTIVE_ACCOUNT=repair@example.com$' "${XDG_CONFIG_HOME}/colabd/config.env"
WHOAMI_OUT="$(run_colabd auth whoami)"
printf '%s\n' "$WHOAMI_OUT" | grep -q 'repair@example.com'

# 6c. Identity mismatch guard during `auth refresh`: browser returns different email -> MUST refuse & rollback!
echo "other@example.com" > "$MOCK_NEXT_LOGIN_FILE"
if run_colabd auth refresh repair@example.com --non-interactive >/dev/null 2>&1; then
  echo "Expected auth refresh to reject mismatched email identity!" >&2
  exit 1
fi
WHOAMI_OUT="$(run_colabd auth whoami)"
printf '%s\n' "$WHOAMI_OUT" | grep -q 'repair@example.com'

# 6d. Running local daemon hard block prevents deleting active account while service is running
PATH="${MULTI_BOX}/mockbin:$PATH" bash --noprofile --norc -c "
  set -euo pipefail
  export TMPDIR='${SANDBOX}/tmp'
  COLABD_LIB_DIR='${ROOT_DIR}/lib'
  source '${ROOT_DIR}/lib/core.sh'
  source '${ROOT_DIR}/lib/env.sh'
  source '${ROOT_DIR}/lib/auth.sh'
  source '${ROOT_DIR}/lib/lifecycle.sh'
  load_config
  sleep 30 &
  EXEC_PID=\$!
  trap 'kill \"\$EXEC_PID\" 2>/dev/null || true; wait \"\$EXEC_PID\" 2>/dev/null || true; rm -rf \"\$STATE_DIR\"' EXIT
  ACTIVE_SESSION_HAS_OWNER=1
  ACTIVE_SESSION_ACCOUNT='repair@example.com'
  ACTIVE_SESSION_NAME='colabd-llm'
  if do_remove_account 'repair@example.com' 'release' '0' >/dev/null 2>&1; then
    echo 'Expected do_remove_account to block while local daemon is running!' >&2
    exit 1
  fi
" 2>/dev/null
python3 "${ROOT_DIR}/lib/account_store.py" exists "${XDG_CONFIG_HOME}/colabd/accounts" "repair@example.com"

# 6e. Slow OAuth 2.0 1-hour refresh / probe timeout MUST NOT be misreported as expired (`unauth`)
TIMEOUT_WHOAMI_RC=0
TIMEOUT_WHOAMI_OUT="$(MOCK_PROBE_DELAY_SEC=1.5 COLABD_AUTH_PROBE_TIMEOUT=0.4 run_colabd auth whoami 2>&1)" || TIMEOUT_WHOAMI_RC=$?
[[ "$TIMEOUT_WHOAMI_RC" -ne 0 ]] || { echo "Expected timed-out whoami to exit non-zero!" >&2; exit 1; }
printf '%s\n' "$TIMEOUT_WHOAMI_OUT" | grep -q '探测超时'
if printf '%s\n' "$TIMEOUT_WHOAMI_OUT" | grep -q '未登录或令牌失效'; then
  echo "Timed-out OAuth probe falsely reported expired/unauth!" >&2
  exit 1
fi

PATH="${MULTI_BOX}/mockbin:$PATH" bash --noprofile --norc -c "
  set -euo pipefail
  export TMPDIR='${SANDBOX}/tmp'
  COLABD_LIB_DIR='${ROOT_DIR}/lib'
  source '${ROOT_DIR}/lib/core.sh'
  source '${ROOT_DIR}/lib/env.sh'
  source '${ROOT_DIR}/lib/auth.sh'
  source '${ROOT_DIR}/lib/lifecycle.sh'
  load_config

  # Default probe timeout must be >= 15s to accommodate automatic 1-hour OAuth refresh
  [[ \"\${COLABD_AUTH_PROBE_TIMEOUT}\" -ge 15 ]]

  # Timeout with valid local credentials -> AUTH_STATE=timeout (NOT unauth!) and accurate badge
  if MOCK_PROBE_DELAY_SEC=1.5 refresh_colab_auth_status 0.4 0; then
    echo 'Expected refresh_colab_auth_status to fail on 0.4s timeout!' >&2
    exit 1
  fi
  [[ \"\$AUTH_STATE\" == \"timeout\" ]] || { echo \"Expected AUTH_STATE=timeout, got \$AUTH_STATE\" >&2; exit 1; }
  BADGE=\"\$(format_auth_badge)\"
  printf '%s\n' \"\$BADGE\" | grep -q '认证状态探测超时'
  if printf '%s\n' \"\$BADGE\" | grep -q '未登录或令牌已过期'; then
    echo \"False expiry badge emitted on timeout: \$BADGE\" >&2
    exit 1
  fi

  # ensure_cli_and_authenticated automatically retries with 2x timeout and recovers cleanly
  COLABD_AUTH_PROBE_TIMEOUT=1 MOCK_PROBE_DELAY_SEC=1.3 ensure_cli_and_authenticated >/dev/null
  [[ \"\$AUTH_STATE\" == \"ok\" ]] || { echo \"Expected AUTH_STATE=ok after auto-retry, got \$AUTH_STATE\" >&2; exit 1; }

  # Timeout with NO local credentials at all still reports unauth
  EMPTY_KR='${SANDBOX}/empty_kr_timeout.json'
  printf '{}\n' > \"\$EMPTY_KR\"
  ACTIVE_ACCOUNT=''
  COLAB_AUTH_MODE='oauth2'
  if COLABD_KEYRING_FILE=\"\$EMPTY_KR\" MOCK_PROBE_DELAY_SEC=1.5 refresh_colab_auth_status 0.4 0; then
    echo 'Expected refresh_colab_auth_status to fail with no credentials!' >&2
    exit 1
  fi
  [[ \"\$AUTH_STATE\" == \"unauth\" ]] || { echo \"Expected AUTH_STATE=unauth without local creds, got \$AUTH_STATE\" >&2; exit 1; }

  rm -rf \"\$STATE_DIR\"
"

# Verify zero server-side sessions remain across all accounts!
python3 - "$MOCK_SERVER_STATE" <<'PYCHK'
import json, pathlib, sys
srv = json.loads(pathlib.Path(sys.argv[1]).read_text())
leftover = {k: v for k, v in srv.items() if v}
assert not leftover, f"Leaked server sessions remained: {leftover}"
PYCHK

echo "[7/9] Testing interactive TUI settings and exit auto-stop..."
REPAIR_DIR="$(python3 "${ROOT_DIR}/lib/account_store.py" path "${XDG_CONFIG_HOME}/colabd/accounts" "repair@example.com")"
PATH="${MULTI_BOX}/mockbin:$PATH" colab --config "${REPAIR_DIR}/sessions.json" --auth oauth2 new -s colabd-llm --gpu G4 >/dev/null
printf '5\n4\n12\n2\n0\n0\n' | run_colabd >/dev/null 2>&1
grep -q '^HF_DOWNLOAD_CONCURRENCY=12$' "${XDG_CONFIG_HOME}/colabd/config.env"
grep -q '^DRIVE_WRITE_MODE=api_stream$' "${XDG_CONFIG_HOME}/colabd/config.env"
grep -q 'STOPPED ident=repair@example.com mode=oauth2 session=colabd-llm ep=m-repair-colabd-llm' "$MOCK_CALL_LOG"

echo "[8/9] Testing colabd managed isolated uv venv runtime (works with zero external colab on PATH)..."
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

CLEAN_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

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

run_isolated_colabd() {
  HOME="${ENV_BOX}/home" \
    XDG_CONFIG_HOME="${ENV_BOX}/cfg" \
    COLAB_CLI_CONFIG_DIR="${ENV_BOX}/colab_cli" \
    COLABD_RUNTIME_DIR="${ENV_BOX}/runtime" \
    COLABD_KEYRING_FILE="${ENV_BOX}/keyring.json" \
    COLABD_TEST_REVOKE_LOG="${ENV_BOX}/revoke.log" \
    MOCK_SERVER_STATE="${ENV_BOX}/server.json" \
    MOCK_CALL_LOG="${ENV_BOX}/calls.log" \
    MOCK_NEXT_LOGIN_FILE="${ENV_BOX}/next_login.txt" \
    MOCK_NEXT_SCOPES_FILE="" \
    MOCK_FAIL_STOP_FILE="" \
    NO_COLOR=1 \
    PATH="${CLEAN_PATH}" \
    /bin/bash --noprofile --norc "${ENV_BOX}/bin/colabd" "$@"
}

DOC_OUT="$(run_isolated_colabd doctor)"
printf '%s\n' "$DOC_OUT" | grep -q '独立 uv 隔离环境'
echo "iso1@example.com" > "${ENV_BOX}/next_login.txt"
run_isolated_colabd auth login --oauth2 --release >/dev/null
ISO_WHOAMI="$(run_isolated_colabd auth whoami)"
printf '%s\n' "$ISO_WHOAMI" | grep -q 'iso1@example.com'
ISO1_DIR="$(python3 "${ROOT_DIR}/lib/account_store.py" path "${ENV_BOX}/cfg/colabd/accounts" "iso1@example.com")"
COLABD_KEYRING_FILE="${ENV_BOX}/keyring.json" \
  MOCK_SERVER_STATE="${ENV_BOX}/server.json" \
  MOCK_CALL_LOG="${ENV_BOX}/calls.log" \
  MOCK_NEXT_LOGIN_FILE="${ENV_BOX}/next_login.txt" \
  MOCK_NEXT_SCOPES_FILE="" \
  MOCK_FAIL_STOP_FILE="" \
  "${ENV_BOX}/runtime/venv/bin/colab" --config "${ISO1_DIR}/sessions.json" --auth oauth2 new -s iso-sess --gpu G4 >/dev/null
run_isolated_colabd down --all >/dev/null
grep -q 'STOPPED ident=iso1@example.com mode=oauth2 session=iso-sess' "${ENV_BOX}/calls.log"

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

echo "[9/9] Testing multi-engine registry (Strata + Project Maya), Free T4 CLI switching, driver floor, health JSON, and ablation patching..."
ENG_BOX="${SANDBOX}/multi_engine"
mkdir -p "${ENG_BOX}/cfg/colabd" "${ENG_BOX}/tmp" "${ENG_BOX}/work/maya-models" \
  "${ENG_BOX}/drive/maya-models/Inkling-2-Mini-Abliterated-Strata"

# 9a. Legacy v0.1.0 config migration: drops DRIVE_PREFETCH/DRIVE_SAVE_POLICY cleanly & preserves Maya + ds4-abliterated-128g
cat > "${ENG_BOX}/cfg/colabd/config.env" <<'LEGCFG'
SESSION_NAME=legacy-sess
GPU_TYPE=G4
HIGH_MEM=1
MODEL_PRESET=ds4-abliterated-128g
STORAGE_MODE=drive_hybrid
DRIVE_PREFETCH=1
DRIVE_SAVE_POLICY=both
LEGCFG

XDG_CONFIG_HOME="${ENG_BOX}/cfg" bash --noprofile --norc -c "
  set -euo pipefail
  export TMPDIR='${ENG_BOX}/tmp'
  COLABD_LIB_DIR='${ROOT_DIR}/lib'
  source '${ROOT_DIR}/lib/core.sh'
  source '${ROOT_DIR}/lib/env.sh'
  load_config
  [[ \"\$STORAGE_MODE\" == 'nvme_engram' ]]
  [[ \"\$ENGINE_TYPE\" == 'auto' ]]
  [[ \"\$HF_DOWNLOAD_CONCURRENCY\" == '8' ]]
  [[ \"\$DRIVE_WRITE_MODE\" == 'auto' ]]
  [[ \"\$(resolve_effective_engine)\" == 'maya' ]]
  [[ \"\$MAYA_ABLATION\" == 'on' ]]
  [[ \"\$MAYA_ABLATE_DEFAULT\" == 'off' ]]
  save_config
  rm -rf \"\$STATE_DIR\"
"
if grep -q '^DRIVE_SAVE_POLICY=' "${ENG_BOX}/cfg/colabd/config.env"; then
  echo "Legacy DRIVE_SAVE_POLICY should not be persisted after migration!" >&2
  exit 1
fi

# 9b. CLI `colabd use` auto-applies Free T4 hardware profile and `--keep-hw` preserves it
XDG_CONFIG_HOME="${ENG_BOX}/cfg" NO_COLOR=1 bash --noprofile --norc "${ROOT_DIR}/bin/colabd" \
  use strata-inkling-uncensored-sq10 >/dev/null
grep -q '^MODEL_PRESET=strata-inkling-uncensored-sq10$' "${ENG_BOX}/cfg/colabd/config.env"
grep -q '^GPU_TYPE=T4$' "${ENG_BOX}/cfg/colabd/config.env"
grep -q '^HIGH_MEM=0$' "${ENG_BOX}/cfg/colabd/config.env"
grep -q '^STORAGE_MODE=local_nvme$' "${ENG_BOX}/cfg/colabd/config.env"

XDG_CONFIG_HOME="${ENG_BOX}/cfg" NO_COLOR=1 bash --noprofile --norc "${ROOT_DIR}/bin/colabd" \
  use ds4-abliterated-128g --keep-hw >/dev/null
grep -q '^MODEL_PRESET=ds4-abliterated-128g$' "${ENG_BOX}/cfg/colabd/config.env"
grep -q '^GPU_TYPE=T4$' "${ENG_BOX}/cfg/colabd/config.env"
grep -q '^HIGH_MEM=0$' "${ENG_BOX}/cfg/colabd/config.env"

# 9c. Registry unit tests + Strata & Maya remote supervisor runner tests
dd if=/dev/urandom of="${ENG_BOX}/drive/maya-models/Inkling-2-Mini-Abliterated-Strata/Inkling-2-Mini-SQ-10-abliterated.strata" bs=1024 count=24 2>/dev/null

python3 - "$ROOT_DIR" "$ENG_BOX" <<'PYMULTI'
import json
import os
import pathlib
import py_compile
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
box = pathlib.Path(sys.argv[2])
reg_py = root / "lib" / "model_registry.py"

# Registry checks: legacy alias, DS4 drive_direct_hf metadata, custom Strata HF, custom Maya
assert subprocess.check_output([sys.executable, str(reg_py), "exists", "inkling-2-mini"], text=True).strip() == "maya-inkling-2-mini"

ds4_128 = json.loads(subprocess.check_output([sys.executable, str(reg_py), "resolve", "ds4-abliterated-128g"], text=True))
assert ds4_128["maya"]["drive_direct_hf"]["hf_subdir"] == "Mix-128G"
ds4_256 = json.loads(subprocess.check_output([sys.executable, str(reg_py), "resolve", "ds4-abliterated-256g"], text=True))
assert ds4_256["maya"]["drive_direct_hf"]["hf_subdir"] == "Mix-256G"

custom_strata = json.loads(
    subprocess.check_output(
        [
            sys.executable,
            str(reg_py),
            "resolve",
            "strata-custom-hf",
            "--engine",
            "strata",
            "--hf-repo",
            "AtomicChat/Inkling-2-Mini-Uncensored-GGUF",
            "--hf-file",
            "Inkling-2-Mini-Uncensored-AD-Q4_K.gguf",
            "--family",
            "inkling-2-mini",
        ],
        text=True,
    )
)
assert custom_strata["engine"] == "strata"
assert custom_strata["strata"]["hf_repo"] == "AtomicChat/Inkling-2-Mini-Uncensored-GGUF"
assert custom_strata["strata"]["model_file"] == "Inkling-2-Mini-Uncensored-AD-Q4_K.gguf"
assert custom_strata["strata"]["model"] == "UD-Q4_K_M"

custom_maya = json.loads(
    subprocess.check_output(
        [
            sys.executable,
            str(reg_py),
            "resolve",
            "maya-custom",
            "--engine",
            "maya",
            "--family",
            "ds4:gguf-iq3_s",
        ],
        text=True,
    )
)
assert custom_maya["engine"] == "maya"
assert custom_maya["has_engram"] is True
assert custom_maya["maya"]["ds4_quant"] == "gguf-iq3_s"

# Build & test Strata runner (SC117 Inkling-2-Mini-abliterated SQ-10)
strata_cmd = f"""
export TMPDIR="{box}/tmp"
export XDG_CONFIG_HOME="{box}/cfg"
export COLABD_RUNTIME_DIR="{box}/rt"
COLABD_LIB_DIR="{root}/lib"
source "{root}/lib/core.sh"
source "{root}/lib/env.sh"
source "{root}/lib/auth.sh"
source "{root}/lib/lifecycle.sh"
load_config
MODEL_PRESET="strata-inkling-uncensored-sq10"
ENGINE_TYPE="auto"
GPU_TYPE="T4"
HIGH_MEM="0"
MAYA_CONTEXT="65536"
MAYA_DRAFTING="on"
STRATA_KV_FORMAT="fp8"
STRATA_PARALLEL="4"
STRATA_BUILD_FALLBACK="auto"
CUSTOM_MODELS_DIR="{box}/work/maya-models"
DRIVE_CACHE_DIR="{box}/drive/maya-models"
HF_DOWNLOAD_CONCURRENCY="6"
DRIVE_WRITE_MODE="auto"
build_remote_runner "local_nvme"
echo "$RUNNER_PY"
"""
strata_runner = subprocess.check_output(["bash", "-c", strata_cmd], text=True).strip().splitlines()[-1]
py_compile.compile(strata_runner, doraise=True)

# local_nvme MUST work with ZERO Google Drive mount!
os.environ["MAYA_WORK_ROOT"] = str(box / "work")
os.environ["MAYA_DRIVE_MOUNT_ROOT"] = str(box / "nonexistent_drive_mount")
os.environ["MAYA_SKIP_APT"] = "1"

ns = {"__name__": "unit_test_strata"}
exec(compile(pathlib.Path(strata_runner).read_text(), strata_runner, "exec"), ns)

assert ns["ENGINE_TYPE"] == "strata"
assert ns["HF_DOWNLOAD_CONCURRENCY"] == 6
assert ns["choose_strata_install_mode"]("580.65.06", "auto") == "prebuilt"
assert ns["choose_strata_install_mode"]("575.51", "auto") == "prebuilt"
assert ns["choose_strata_install_mode"]("550.54.15", "auto") == "source"
assert ns["choose_strata_install_mode"]("550.54.15", "prebuilt") == "prebuilt"
assert ns["choose_strata_install_mode"]("580.65.06", "source") == "source"

assert ns["check_health_response"](200, b'{"status":"ok","loaded":false,"service":"strata"}') == (False, "loading")
assert ns["check_health_response"](200, b'{"status":"ok","loaded":true,"service":"strata"}') == (True, "ready")
assert ns["check_health_response"](200, b"ok") == (True, "ready")
assert ns["check_health_response"](503, b"busy") == (False, "unreachable")

models_dir, ram_res = ns["prepare_storage_and_deps"]()
assert ram_res is False
assert ns["TELEMETRY"]["drive_io_state"] == "disabled"
local_strata = models_dir / "Inkling-2-Mini-Abliterated-Strata" / "Inkling-2-Mini-SQ-10-abliterated.strata"
local_strata.parent.mkdir(parents=True, exist_ok=True)
local_strata.write_bytes(b"strata_local_test" * 64)

# Verify drive_full points models_dir directly to DRIVE_CACHE_DIR (eliminating Strata path mismatch)
ns["STORAGE_MODE"] = "drive_full"
ns["DRIVE_MOUNT_ROOT"] = box / "drive"
df_dir, _ = ns["prepare_storage_and_deps"]()
assert df_dir == box / "drive" / "maya-models"
assert ns["TELEMETRY"]["drive_io_state"] == "ready"

launch_cmd = ns["build_strata_launch_cmd"]("/content/strata-bin/strata", ns["MODEL_SPEC"]["strata"], models_dir / "strata-data", local_strata)
assert "--family" in launch_cmd and launch_cmd[launch_cmd.index("--family") + 1] == "inkling-2-mini"
assert "--model" in launch_cmd and launch_cmd[launch_cmd.index("--model") + 1] == "SQ-10"
assert "--model-path" in launch_cmd and launch_cmd[launch_cmd.index("--model-path") + 1] == str(local_strata)
assert "--drafting" in launch_cmd and launch_cmd[launch_cmd.index("--drafting") + 1] == "auto"
assert "--kv" in launch_cmd and launch_cmd[launch_cmd.index("--kv") + 1] == "fp8"
assert "--parallel" in launch_cmd and launch_cmd[launch_cmd.index("--parallel") + 1] == "4"
assert "--no-tui" in launch_cmd and "--restart" in launch_cmd

src_cmd = ns["build_strata_source_setup_cmd"](pathlib.Path("/content/Strata/setup.sh"), ns["MODEL_SPEC"]["strata"], models_dir / "strata-data", local_strata)
assert "--build" in src_cmd and "--gguf-dir" in src_cmd and str(local_strata) in src_cmd
assert "--drafter" in src_cmd and src_cmd[src_cmd.index("--drafter") + 1] == "dspark"

# Verify _ensure_strata_source_env skips broken python3 (like Colab 3.13 without ensurepip) and creates terminal/.venv with pip
fake_strata = box / "work" / "Strata"
(fake_strata / "terminal").mkdir(parents=True, exist_ok=True)
(fake_strata / "terminal" / "setup.py").write_text("print('ok')\n")
fake_bin = box / "fake_py_bin"
fake_bin.mkdir(parents=True, exist_ok=True)
broken_py = fake_bin / "python3"
broken_py.write_text("#!/bin/sh\nexit 1\n")
broken_py.chmod(0o755)
old_path = os.environ.get("PATH", "")
os.environ["PATH"] = f"{fake_bin}:{old_path}"
try:
    venv_dir = ns["_ensure_strata_source_env"](fake_strata)
finally:
    os.environ["PATH"] = old_path
assert venv_dir == fake_strata / "terminal" / ".venv"
assert (venv_dir / "bin" / "python").exists()
assert subprocess.run([str(venv_dir / "bin" / "python"), "-m", "pip", "--version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

# Build & test expanded Project Maya runner (maya-inkling-2-mini + ablation default on)
maya_cmd_sh = f"""
export TMPDIR="{box}/tmp"
export XDG_CONFIG_HOME="{box}/cfg"
export COLABD_RUNTIME_DIR="{box}/rt"
COLABD_LIB_DIR="{root}/lib"
source "{root}/lib/core.sh"
source "{root}/lib/env.sh"
source "{root}/lib/auth.sh"
source "{root}/lib/lifecycle.sh"
load_config
MODEL_PRESET="maya-inkling-2-mini"
ENGINE_TYPE="auto"
MAYA_ABLATION="on"
MAYA_ABLATE_DEFAULT="on"
EXPERT_RAM_POLICY="force_ram"
CUSTOM_MODELS_DIR="{box}/work/maya-models"
DRIVE_CACHE_DIR="{box}/drive/maya-models"
build_remote_runner "local_nvme"
echo "$RUNNER_PY"
"""
maya_runner = subprocess.check_output(["bash", "-c", maya_cmd_sh], text=True).strip().splitlines()[-1]
py_compile.compile(maya_runner, doraise=True)

ns_m = {"__name__": "unit_test_maya"}
exec(compile(pathlib.Path(maya_runner).read_text(), maya_runner, "exec"), ns_m)
assert ns_m["ENGINE_TYPE"] == "maya"
m_args = ns_m["build_maya_cmd"](box / "work" / "maya-models", True, no_start=True)
assert "--model" in m_args and m_args[m_args.index("--model") + 1] == "inkling-2-mini"
assert "--ablation" in m_args and m_args[m_args.index("--ablation") + 1] == "on"
assert "--no-start" in m_args

maya_dir = box / "work" / "project-maya-ablate"
maya_dir.mkdir(parents=True, exist_ok=True)
ik2_cfg = maya_dir / "maya-ik2.json"
ik2_cfg.write_text(json.dumps({"args": ["--model", "Inkling.gguf", "--ablate", "dir.gguf", "--ablate-default", "off"], "ablate": {"default": "off"}}))
ns_m["patch_existing_maya_configs"](maya_dir, True)
patched = json.loads(ik2_cfg.read_text())
assert patched["args"][patched["args"].index("--ablate-default") + 1] == "on"
assert patched["ablate"]["default"] == "on"
assert "--mmap-experts" in patched["args"] and patched["args"][patched["args"].index("--mmap-experts") + 1] == "off"
PYMULTI

echo "ALL TESTS PASSED."
