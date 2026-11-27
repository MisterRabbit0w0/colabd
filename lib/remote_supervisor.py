#!/usr/bin/env python3
"""
colabd remote supervisor (executed inside the Google Colab Jupyter kernel via `colab exec`).

Supports multiple inference engines (`strata` and `maya`) and tiered/custom Hugging Face models.

Responsibilities:
1. Inspect remote GPU VRAM, NVIDIA driver version, system RAM, local NVMe free space, and Drive mount.
2. Configure direct-to-target storage & symlink topology (`local_nvme`, `nvme_engram`, `drive_engram`, `drive_full`)
   with zero post-download sync-back or Drive->NVMe copying.
3. Download local NVMe Hugging Face files via multi-threaded HTTP Range workers (resumable + atomic rename).
4. Stream Drive-bound expansion weights directly to Google Drive via:
   - Google Drive REST API v3 Resumable Upload (zero local disk cache, HTTP 200 verified) when a Drive API token
     is available, or
   - Sequential FUSE direct-write with local root disk watermark backpressure & pre-exit flush protection.
5. Start reverse tunnels (Cloudflare Quick/Named Tunnel or SSH local port forward).
6. Launch the selected inference engine (`strata` or `maya`) with high-speed HF download env flags enabled.
7. Poll `/health` (verifying `loaded == true` for Strata JSON responses) and stream telemetry on the main thread.
"""

from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
import queue
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# When invoked via session_runner.py, CONFIG is injected above this module.
if "CONFIG" not in globals():
    CONFIG: Dict[str, Any] = {
        "engine_type": os.environ.get("COLABD_ENGINE_TYPE", "maya"),
        "model_preset": os.environ.get("COLABD_MODEL_PRESET", "ds4-abliterated-128g"),
        "model_spec": {},
        "maya_context": os.environ.get("COLABD_MAYA_CONTEXT", "65536"),
        "maya_drafting": os.environ.get("COLABD_MAYA_DRAFTING", "on"),
        "maya_port": os.environ.get("COLABD_MAYA_PORT", "8081"),
        "remote_port": os.environ.get("COLABD_REMOTE_PORT", os.environ.get("COLABD_MAYA_PORT", "8081")),
        "strata_kv_format": os.environ.get("COLABD_STRATA_KV_FORMAT", "auto"),
        "strata_parallel": os.environ.get("COLABD_STRATA_PARALLEL", "1"),
        "strata_build_fallback": os.environ.get("COLABD_STRATA_BUILD_FALLBACK", "auto"),
        "maya_ablation": os.environ.get("COLABD_MAYA_ABLATION", "on"),
        "maya_ablate_default": os.environ.get("COLABD_MAYA_ABLATE_DEFAULT", "off"),
        "storage_mode": os.environ.get("COLABD_STORAGE_MODE", "nvme_engram"),
        "hf_download_concurrency": os.environ.get("COLABD_HF_DOWNLOAD_CONCURRENCY", "8"),
        "drive_write_mode": os.environ.get("COLABD_DRIVE_WRITE_MODE", "auto"),
        "expert_ram_policy": os.environ.get("COLABD_EXPERT_RAM_POLICY", "auto"),
        "custom_models_dir": os.environ.get("COLABD_CUSTOM_MODELS_DIR", "/content/maya-models"),
        "drive_cache_dir": os.environ.get("COLABD_DRIVE_CACHE_DIR", "/content/drive/MyDrive/maya-models"),
        "tunnel_mode": os.environ.get("COLABD_TUNNEL_MODE", "cf_quick"),
        "cf_tunnel_token": os.environ.get("COLABD_CF_TUNNEL_TOKEN", ""),
        "cf_public_hostname": os.environ.get("COLABD_CF_PUBLIC_HOSTNAME", ""),
        "hf_token": os.environ.get("HF_TOKEN", ""),
        "maya_api_key": os.environ.get("COLABD_MAYA_API_KEY", "sk-colabd-local"),
        "no_vision": os.environ.get("COLABD_NO_VISION", "0"),
        "web_ui": os.environ.get("COLABD_WEB_UI", "1"),
        "local_bind": os.environ.get("COLABD_LOCAL_BIND", "127.0.0.1"),
    }

MODEL_PRESET: str = str(CONFIG.get("model_preset", "ds4-abliterated-128g"))
MODEL_SPEC: Dict[str, Any] = CONFIG.get("model_spec") if isinstance(CONFIG.get("model_spec"), dict) else {}
ENGINE_TYPE: str = str(CONFIG.get("engine_type") or MODEL_SPEC.get("engine") or "maya").strip().lower()
if ENGINE_TYPE not in ("strata", "maya"):
    ENGINE_TYPE = "maya"

MAYA_CONTEXT: str = str(CONFIG.get("maya_context", "65536"))
MAYA_DRAFTING: str = str(CONFIG.get("maya_drafting", "on"))
MAYA_PORT: int = int(CONFIG.get("maya_port", "8081"))
REMOTE_PORT: int = int(CONFIG.get("remote_port") or MAYA_PORT)
STRATA_KV_FORMAT: str = str(CONFIG.get("strata_kv_format", "auto")).strip().lower() or "auto"
STRATA_PARALLEL: str = str(CONFIG.get("strata_parallel", "1")).strip()
STRATA_BUILD_FALLBACK: str = str(CONFIG.get("strata_build_fallback", "auto")).strip().lower()
MAYA_ABLATION: str = str(CONFIG.get("maya_ablation", "on")).strip().lower()
MAYA_ABLATE_DEFAULT: str = str(CONFIG.get("maya_ablate_default", "off")).strip().lower()

STORAGE_MODE: str = str(CONFIG.get("storage_mode", "nvme_engram"))
try:
    HF_DOWNLOAD_CONCURRENCY: int = max(1, min(16, int(str(CONFIG.get("hf_download_concurrency", "8")).strip() or "8")))
except ValueError:
    HF_DOWNLOAD_CONCURRENCY = 8
DRIVE_WRITE_MODE: str = str(CONFIG.get("drive_write_mode", "auto")).strip().lower()
if DRIVE_WRITE_MODE not in ("auto", "api_stream", "fuse"):
    DRIVE_WRITE_MODE = "auto"
EXPERT_RAM_POLICY: str = str(CONFIG.get("expert_ram_policy", "auto"))
CUSTOM_MODELS_DIR: str = str(CONFIG.get("custom_models_dir", "/content/maya-models"))
DRIVE_CACHE_DIR: str = str(CONFIG.get("drive_cache_dir", "/content/drive/MyDrive/maya-models"))
TUNNEL_MODE: str = str(CONFIG.get("tunnel_mode", "cf_quick"))
CF_TUNNEL_TOKEN: str = str(CONFIG.get("cf_tunnel_token", ""))
CF_PUBLIC_HOSTNAME: str = str(CONFIG.get("cf_public_hostname", ""))
HF_TOKEN: str = str(CONFIG.get("hf_token", ""))
MAYA_API_KEY: str = str(CONFIG.get("maya_api_key", "sk-colabd-local"))
NO_VISION: bool = str(CONFIG.get("no_vision", "0")) == "1"
WEB_UI: bool = str(CONFIG.get("web_ui", "1")) == "1"
LOCAL_BIND: str = str(CONFIG.get("local_bind", "127.0.0.1"))

WORK_DIR = Path(os.environ.get("MAYA_WORK_ROOT", "/content"))
DRIVE_MOUNT_ROOT = Path(os.environ.get("MAYA_DRIVE_MOUNT_ROOT", "/content/drive/MyDrive"))
DRIVEFS_CACHE_ROOT = Path(os.environ.get("COLABD_DRIVEFS_CACHE_DIR", "/root/.config/Google/DriveFS"))

HF_BASE_URL = os.environ.get("COLABD_HF_BASE_URL", "https://huggingface.co").rstrip("/")
DRIVE_API_BASE = os.environ.get("COLABD_DRIVE_API_BASE", "https://www.googleapis.com/drive/v3").rstrip("/")
DRIVE_UPLOAD_BASE = os.environ.get("COLABD_DRIVE_UPLOAD_BASE", "https://www.googleapis.com/upload/drive/v3").rstrip("/")

MULTIPART_MIN_BYTES = max(1024 * 1024, int(os.environ.get("COLABD_MULTIPART_MIN_BYTES", str(64 * 1024 * 1024))))
_raw_drive_chunk = int(os.environ.get("COLABD_DRIVE_CHUNK_BYTES", str(16 * 1024 * 1024)))
DRIVE_API_CHUNK_BYTES = max(256 * 1024, (_raw_drive_chunk // (256 * 1024)) * (256 * 1024))
FUSE_MIN_LOCAL_FREE_GB = float(os.environ.get("COLABD_FUSE_MIN_LOCAL_FREE_GB", "20.0"))
FUSE_CRITICAL_LOCAL_FREE_GB = float(os.environ.get("COLABD_FUSE_CRITICAL_LOCAL_FREE_GB", "5.0"))
FUSE_BACKPRESSURE_MAX_WAIT_SEC = float(os.environ.get("COLABD_FUSE_MAX_WAIT_SEC", "600.0"))

STRATA_PREBUILT_DRIVER_FLOOR = (575, 51)
STRATA_INSTALL_URL = os.environ.get(
    "COLABD_STRATA_INSTALL_URL",
    "https://github.com/Niko1221/Strata/releases/latest/download/install.sh",
)
STRATA_REPO_URL = os.environ.get("COLABD_STRATA_REPO_URL", "https://github.com/Niko1221/Strata.git")
MAYA_REPO_URL = os.environ.get("COLABD_MAYA_REPO_URL", "https://github.com/mw00/project-maya.git")

WHOLE_MODEL_MEM_GB: Dict[str, int] = {
    "ds4-abliterated-128g": 128,
    "ds4-abliterated-256g": 256,
    "deepseek-maya-xs": 128,
    "deepseek-maya-s": 192,
    "glm-5.3-maya-xs": 192,
    "glm-maya-m-derisked": 140,
    "glm-maya-l": 176,
    "glm-maya-s24": 108,
    "glm-maya-xs": 84,
    "minimax-maya-xs": 112,
    "minimax-maya-s": 144,
    "hy4-flash-maya-xs": 64,
    "hy4-flash-maya-m": 96,
    "hy4-flash-maya-l": 128,
    "inkling-2-mini": 24,
    "maya-inkling-2-mini": 24,
}
if isinstance(MODEL_SPEC.get("mem_gb"), (int, float)):
    WHOLE_MODEL_MEM_GB[MODEL_PRESET] = int(MODEL_SPEC["mem_gb"])

MODEL_SUBDIRS: Dict[str, str] = {
    "ds4-abliterated-128g": "DeepSeek-V4.1-Flash-1017-abliterated-GGUF/Mix-128G",
    "ds4-abliterated-256g": "DeepSeek-V4.1-Flash-1017-abliterated-GGUF/Mix-256G",
    "glm-maya-m-derisked": "Maya-M-Derisked",
    "glm-maya-xs": "Maya-XS",
    "inkling-2-mini": "Inkling-2-Mini",
    "maya-inkling-2-mini": "Inkling-2-Mini",
}
if isinstance(MODEL_SPEC.get("cache_subdir"), str) and MODEL_SPEC["cache_subdir"]:
    MODEL_SUBDIRS[MODEL_PRESET] = MODEL_SPEC["cache_subdir"]

SHARD_SUFFIXES = {".gguf", ".strata", ".safetensors", ".bin", ".json", ".txt", ".jinja", ".model"}
TEMP_SUFFIXES = (".tmp", ".part", ".part.meta.json", ".pulling.tmp", ".syncing.tmp")
SKIP_SYNC_DIRS = {
    "slots",
    "maya-ds4",
    "maya-mm3",
    "marks",
    "packs",
    "launch",
    "profiles",
    "components",
    "terminal",
    ".venv",
    "__pycache__",
}

procs: List[subprocess.Popen] = []
telemetry_lock = threading.Lock()
output_queue: "queue.Queue[Optional[str]]" = queue.Queue()
_main_thread_id = threading.get_ident()
_main_loop_active = False
_stop_event = threading.Event()
_active_strata_bin: Optional[str] = None
_active_strata_env: Optional[Dict[str, str]] = None
_wrote_via_fuse = False
_drive_folder_cache: Dict[Tuple[str, ...], str] = {}

TELEMETRY: Dict[str, Any] = {
    "phase": "初始化远端环境",
    "engine": ENGINE_TYPE,
    "model_preset": MODEL_PRESET,
    "gpu": "检测中...",
    "driver_version": "",
    "vram_gb": 0.0,
    "ram_gb": 0.0,
    "local_free_gb": 0.0,
    "drive_free_gb": None,
    "drivefs_cache_gb": 0.0,
    "models_dir": "",
    "ram_resident_active": False,
    "drive_io_state": "disabled",
    "drive_io_detail": "纯本地模式 (未挂载云盘)",
    "public_url": "",
    "api_healthy": False,
}


def _emit_line(line: str) -> None:
    """Emit output on the main kernel thread so ipykernel 6+ preserves parent_header."""
    if _main_loop_active and threading.get_ident() != _main_thread_id:
        output_queue.put(line)
    else:
        sys.stdout.write(line)
        sys.stdout.flush()


def log(msg: str) -> None:
    _emit_line(f"{msg}\n")


def emit_telemetry(**updates: Any) -> None:
    with telemetry_lock:
        TELEMETRY.update(updates)
        payload = json.dumps(TELEMETRY, ensure_ascii=False)
    _emit_line(f"[TELEMETRY] {payload}\n")


def parse_driver_tuple(version: str) -> Tuple[int, ...]:
    nums = [int(p) for p in re.findall(r"\d+", str(version or ""))[:3]]
    return tuple(nums)


def driver_meets_floor(driver_version: str, floor: Tuple[int, ...] = STRATA_PREBUILT_DRIVER_FLOOR) -> bool:
    parsed = parse_driver_tuple(driver_version)
    if not parsed:
        return False
    padded = parsed + (0,) * max(0, len(floor) - len(parsed))
    return padded[: len(floor)] >= floor


def choose_strata_install_mode(driver_version: str, policy: str = "auto") -> str:
    pol = (policy or "auto").strip().lower()
    if pol == "prebuilt":
        return "prebuilt"
    if pol == "source":
        return "source"
    if driver_meets_floor(driver_version, STRATA_PREBUILT_DRIVER_FLOOR):
        return "prebuilt"
    return "source"


def check_health_response(status_code: int, body_bytes: bytes) -> Tuple[bool, str]:
    """Evaluate `/health` HTTP response across Project Maya and Strata.

    Strata returns HTTP 200 with `{"status": "ok", "loaded": false, "service": "strata"}`
    while weights are still loading into VRAM; wait for `loaded == true` before marking ready.
    """
    if not (200 <= status_code < 300):
        return False, "unreachable"
    raw = (body_bytes or b"").strip()
    if raw.startswith(b"{"):
        try:
            data = json.loads(raw.decode("utf-8", errors="replace"))
            if isinstance(data, dict) and "loaded" in data:
                if bool(data.get("loaded")):
                    return True, "ready"
                return False, "loading"
        except Exception:
            pass
    return True, "ready"


def _measure_drivefs_cache_gb() -> float:
    if not DRIVEFS_CACHE_ROOT.exists():
        return 0.0
    total = 0
    for dirpath, _dirnames, filenames in os.walk(DRIVEFS_CACHE_ROOT, followlinks=False):
        for fn in filenames:
            try:
                total += (Path(dirpath) / fn).stat().st_size
            except OSError:
                pass
    return round(total / (1024 ** 3), 2)


def _is_on_drive_mount(path: Path) -> bool:
    if not DRIVE_MOUNT_ROOT.exists():
        return False
    try:
        drive_real = os.path.realpath(str(DRIVE_MOUNT_ROOT))
        # Resolve parent if file itself does not exist yet so symlinks on parent dirs are honored!
        probe_target = path if path.exists() else path.parent
        target_real = os.path.realpath(str(probe_target))
        return target_real == drive_real or target_real.startswith(drive_real + os.sep)
    except OSError:
        return False


def _drive_rel_parts(dst: Path) -> Optional[List[str]]:
    if not _is_on_drive_mount(dst):
        return None
    drive_real = Path(os.path.realpath(str(DRIVE_MOUNT_ROOT)))
    parent_real = Path(os.path.realpath(str(dst.parent)))
    full_real = parent_real / dst.name
    try:
        rel = full_real.relative_to(drive_real)
    except ValueError:
        return None
    return [p for p in rel.parts if p and p != "."]


def refresh_disk_metrics() -> None:
    target_local = WORK_DIR if WORK_DIR.exists() else Path("/")
    local_free = shutil.disk_usage(target_local).free / (1024 ** 3)
    drive_mounted = DRIVE_MOUNT_ROOT.exists()
    drive_free = (
        round(shutil.disk_usage(DRIVE_MOUNT_ROOT).free / (1024 ** 3), 1)
        if drive_mounted
        else None
    )
    dfs_gb = _measure_drivefs_cache_gb() if drive_mounted else 0.0
    emit_telemetry(
        local_free_gb=round(local_free, 1),
        drive_free_gb=drive_free,
        drivefs_cache_gb=dfs_gb,
    )


def cleanup_temp_files(root: Path) -> None:
    if not root.exists():
        return
    for dirpath, _dirnames, filenames in os.walk(root, followlinks=False):
        for fn in filenames:
            if fn.endswith(TEMP_SUFFIXES):
                try:
                    (Path(dirpath) / fn).unlink()
                except OSError:
                    pass


def flush_drivefs_before_exit() -> None:
    """Best-effort flush of pending FUSE DriveFS writes before VM teardown."""
    if not _wrote_via_fuse or not DRIVE_MOUNT_ROOT.exists():
        return
    if os.environ.get("COLABD_SKIP_DRIVE_FLUSH") == "1":
        return
    emit_telemetry(drive_io_state="flushing", drive_io_detail="退出前正在刷新 DriveFS 写缓存至 Google Drive...")
    log("[DRIVE] 检测到本次曾通过 FUSE 写入 Google Drive，正在执行退出前刷盘 (os.sync + drive.flush_and_unmount)...")
    try:
        os.sync()
    except OSError:
        pass
    try:
        from google.colab import drive as _colab_drive  # type: ignore

        _colab_drive.flush_and_unmount()
        log("[DRIVE] DriveFS 缓存刷新并卸载完成。")
    except Exception as exc:
        log(f"[DRIVE][WARN] 无法调用 google.colab.drive.flush_and_unmount() ({exc})，已执行 os.sync()。")


def terminate_all(*_args: Any) -> None:
    _stop_event.set()
    emit_telemetry(phase="正在关闭进程", api_healthy=False)
    engine_name = "Strata" if ENGINE_TYPE == "strata" else "Project Maya"
    log(f"\n[REMOTE] 收到终止信号，正在停止隧道与 {engine_name} 引擎并清理临时分片...")

    if _active_strata_bin:
        try:
            subprocess.run(
                [_active_strata_bin, "launch", "--stop"],
                env=_active_strata_env or os.environ.copy(),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=12,
            )
        except Exception:
            pass

    for p in reversed(procs):
        if p and p.poll() is None:
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except Exception:
                try:
                    p.terminate()
                except Exception:
                    pass
    time.sleep(2)
    for p in reversed(procs):
        if p and p.poll() is None:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except Exception:
                try:
                    p.kill()
                except Exception:
                    pass
    cleanup_temp_files(Path(CUSTOM_MODELS_DIR))
    if DRIVE_MOUNT_ROOT.exists():
        cleanup_temp_files(Path(DRIVE_CACHE_DIR))
        flush_drivefs_before_exit()
    sys.exit(0)


signal.signal(signal.SIGINT, terminate_all)
signal.signal(signal.SIGTERM, terminate_all)


def run_checked(cmd: List[str], **kwargs: Any) -> None:
    log(f"[REMOTE] $ {' '.join(cmd)}")
    subprocess.run(cmd, check=True, **kwargs)


def ensure_symlink(link_path: Path, target_dir: Path) -> None:
    target_dir.mkdir(parents=True, exist_ok=True)
    link_path.parent.mkdir(parents=True, exist_ok=True)
    if link_path.is_symlink():
        if link_path.resolve() != target_dir.resolve():
            link_path.unlink()
            link_path.symlink_to(target_dir, target_is_directory=True)
    elif link_path.exists():
        if link_path.is_dir() and not any(link_path.iterdir()):
            link_path.rmdir()
            link_path.symlink_to(target_dir, target_is_directory=True)
    else:
        link_path.symlink_to(target_dir, target_is_directory=True)


def list_valid_shards(folder: Path) -> List[Tuple[Path, Path, int]]:
    if not folder.exists():
        return []
    found: List[Tuple[Path, Path, int]] = []
    for root, dirs, files in os.walk(folder, followlinks=False):
        dirs[:] = [d for d in sorted(dirs) if d not in SKIP_SYNC_DIRS and not d.startswith(".")]
        for fn in sorted(files):
            if fn.startswith(".") or fn.endswith(TEMP_SUFFIXES):
                continue
            fp = Path(root) / fn
            if fp.is_symlink():
                continue
            if fp.suffix.lower() in SHARD_SUFFIXES:
                try:
                    sz = fp.stat().st_size
                    if sz > 0:
                        found.append((fp.relative_to(folder), fp, sz))
                except OSError:
                    pass
    return found


def decide_ram_residency(vram_gb: float, ram_gb: float) -> bool:
    if ENGINE_TYPE == "strata":
        return False
    if EXPERT_RAM_POLICY == "allow_disk":
        return False
    if EXPERT_RAM_POLICY == "force_ram":
        return True
    needed = WHOLE_MODEL_MEM_GB.get(MODEL_PRESET, 140)
    return (vram_gb + ram_gb) >= needed


def patch_existing_maya_configs(maya_dir: Path, ram_resident: bool) -> None:
    target_flag = "off" if ram_resident else ("on" if EXPERT_RAM_POLICY == "allow_disk" else None)
    want_ablate_default = MAYA_ABLATION == "on" and MAYA_ABLATE_DEFAULT == "on"
    if not target_flag and not want_ablate_default:
        return
    for cfg_path in maya_dir.glob("maya-*.json"):
        try:
            data = json.loads(cfg_path.read_text(encoding="utf-8"))
            args = data.get("args")
            changed = False
            if isinstance(args, list):
                if target_flag:
                    if "--mmap-experts" in args:
                        i = args.index("--mmap-experts")
                        if i + 1 < len(args) and args[i + 1] != target_flag:
                            args[i + 1] = target_flag
                            changed = True
                    else:
                        args.extend(["--mmap-experts", target_flag])
                        changed = True
                if want_ablate_default and ("--ablate" in args or isinstance(data.get("ablate"), dict)):
                    if "--ablate-default" in args:
                        i = args.index("--ablate-default")
                        if i + 1 < len(args) and args[i + 1] != "on":
                            args[i + 1] = "on"
                            changed = True
                    else:
                        args.extend(["--ablate-default", "on"])
                        changed = True
                    if isinstance(data.get("ablate"), dict) and data["ablate"].get("default") != "on":
                        data["ablate"]["default"] = "on"
                        changed = True
                if STRATA_KV_FORMAT and STRATA_KV_FORMAT != "auto":
                    if "--kv" in args:
                        i = args.index("--kv")
                        if i + 1 < len(args) and args[i + 1] != STRATA_KV_FORMAT:
                            args[i + 1] = STRATA_KV_FORMAT
                            changed = True
                    else:
                        args.extend(["--kv", STRATA_KV_FORMAT])
                        changed = True
            if changed:
                cfg_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        except Exception:
            pass


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Prevent urllib from treating HTTP 308 Resume Incomplete as a redirect."""

    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        return None


_NO_REDIRECT_OPENER = urllib.request.build_opener(_NoRedirectHandler())


def _hf_headers(extra: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    headers = {"User-Agent": "colabd/0.2"}
    if HF_TOKEN:
        headers["Authorization"] = f"Bearer {HF_TOKEN}"
    if extra:
        headers.update(extra)
    return headers


def _hf_resolve_url(repo: str, filename: str) -> str:
    encoded_path = "/".join(urllib.parse.quote(part, safe="") for part in filename.split("/"))
    return f"{HF_BASE_URL}/{repo}/resolve/main/{encoded_path}"


def _probe_hf_file(url: str, optional: bool = False) -> Tuple[Optional[int], bool, str, bool]:
    """Probe HF URL via `GET Range: bytes=0-0`.

    Returns `(total_bytes, supports_range, final_url, skipped_optional)`.
    """
    req = urllib.request.Request(url, headers=_hf_headers({"Range": "bytes=0-0"}))
    try:
        with urllib.request.urlopen(req, timeout=45) as resp:
            status = getattr(resp, "status", 200)
            final_url = resp.geturl() or url
            cr = resp.headers.get("Content-Range", "")
            cl = resp.headers.get("Content-Length", "")
            # Drain the 1-byte probe body so connection closes cleanly
            resp.read(16)
            if status == 206 and "/" in cr:
                total_str = cr.rsplit("/", 1)[-1].strip()
                if total_str.isdigit():
                    return int(total_str), True, final_url, False
            if cl.isdigit():
                supports_r = resp.headers.get("Accept-Ranges", "").lower() == "bytes"
                return int(cl), supports_r, final_url, False
            return None, False, final_url, False
    except urllib.error.HTTPError as exc:
        if optional and exc.code in (404, 403):
            return None, False, url, True
        if exc.code == 416:
            return 0, False, url, False
        raise RuntimeError(f"探测 {url} 失败 (HTTP {exc.code})") from exc
    except Exception:
        if optional:
            return None, False, url, True
        raise


def _download_hf_local_single(url: str, dst: Path, optional: bool = False) -> Optional[Path]:
    """Single-stream resumable download to local NVMe with atomic rename."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    part_path = dst.with_name(dst.name + ".part")
    existing = part_path.stat().st_size if part_path.is_file() else 0

    req_headers = _hf_headers({"Range": f"bytes={existing}-"} if existing > 0 else None)
    req = urllib.request.Request(url, headers=req_headers)
    try:
        resp = urllib.request.urlopen(req, timeout=45)
    except urllib.error.HTTPError as exc:
        if exc.code == 416 and existing > 0:
            os.replace(part_path, dst)
            return dst
        if optional and exc.code in (404, 403):
            log(f"[HF][INFO] 可选伴随文件不存在 (HTTP {exc.code})，跳过: {dst.name}")
            return None
        raise RuntimeError(f"下载 {dst.name} 失败 (HTTP {exc.code})") from exc
    except Exception as exc:
        if optional:
            log(f"[HF][WARN] 下载可选文件 {dst.name} 失败 ({exc})，继续。")
            return None
        raise

    with resp:
        status = getattr(resp, "status", 200)
        if existing > 0 and status != 206:
            existing = 0
        cl_hdr = resp.headers.get("Content-Length")
        remaining = int(cl_hdr) if cl_hdr and cl_hdr.isdigit() else None
        total = (existing + remaining) if remaining is not None else None
        mode = "ab" if existing > 0 and status == 206 else "wb"

        if total:
            log(f"[HF] 开始下载 {dst.name} ({total / (1024**3):.2f} GiB, 单流)...")
        else:
            log(f"[HF] 开始下载 {dst.name} ...")
        emit_telemetry(phase=f"下载 {dst.name}")

        written = existing
        start_t = time.time()
        last_report = start_t
        buf_size = 8 * 1024 * 1024
        with part_path.open(mode) as fh:
            while True:
                chunk = resp.read(buf_size)
                if not chunk:
                    break
                fh.write(chunk)
                written += len(chunk)
                now = time.time()
                if now - last_report >= 4.0:
                    elapsed = max(now - start_t, 0.1)
                    mb_s = ((written - existing) / (1024 ** 2)) / elapsed
                    if total and total > 0:
                        pct = min(100.0, (written / total) * 100.0)
                        log(
                            f"[HF] {dst.name}: {pct:.1f}% "
                            f"({written/(1024**3):.2f}/{total/(1024**3):.2f} GiB, {mb_s:.1f} MB/s)"
                        )
                    else:
                        log(f"[HF] {dst.name}: {written/(1024**3):.2f} GiB ({mb_s:.1f} MB/s)")
                    refresh_disk_metrics()
                    last_report = now

        if total is not None and part_path.stat().st_size != total:
            raise IOError(f"{dst.name} 字节数校验不完整 ({part_path.stat().st_size} != {total})")
        os.replace(part_path, dst)
        refresh_disk_metrics()
        log(f"[HF] 下载完成: {dst.name} ({dst.stat().st_size / (1024**3):.2f} GiB)")
        return dst


def _download_hf_local_multipart(url: str, dst: Path, total: int, workers: int) -> Path:
    """Multi-threaded HTTP Range download directly onto local NVMe with resumable chunk metadata."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    part_path = dst.with_name(dst.name + ".part")
    meta_path = dst.with_name(dst.name + ".part.meta.json")

    if total >= 128 * 1024 * 1024:
        chunk_size = 16 * 1024 * 1024
    else:
        chunk_size = max(256 * 1024, (total + (workers * 2) - 1) // (workers * 2))

    chunks: List[Tuple[int, int, int]] = []
    idx = 0
    pos = 0
    while pos < total:
        end = min(total - 1, pos + chunk_size - 1)
        chunks.append((idx, pos, end))
        pos = end + 1
        idx += 1

    done_indices = set()
    resuming = False
    if part_path.is_file() and meta_path.is_file() and part_path.stat().st_size == total:
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            if meta.get("total") == total and meta.get("chunk_size") == chunk_size:
                done_indices = {int(i) for i in meta.get("done", []) if 0 <= int(i) < len(chunks)}
                resuming = len(done_indices) > 0
        except Exception:
            done_indices = set()

    if not resuming:
        with part_path.open("wb") as fh:
            fh.truncate(total)
        meta_path.write_text(
            json.dumps({"total": total, "chunk_size": chunk_size, "done": []}),
            encoding="utf-8",
        )

    pending = [c for c in chunks if c[0] not in done_indices]
    already_bytes = sum((c[2] - c[1] + 1) for c in chunks if c[0] in done_indices)

    log(
        f"[HF] 开始并发下载 {dst.name} ({total / (1024**3):.2f} GiB, "
        f"{workers} 线程, {len(pending)}/{len(chunks)} 待拉分块)..."
    )
    emit_telemetry(phase=f"并发下载 {dst.name} ({workers}x)")

    state_lock = threading.Lock()
    progress = {"bytes": already_bytes, "new_bytes": 0, "last_report": time.time(), "start_t": time.time()}
    fd = os.open(str(part_path), os.O_RDWR)

    def fetch_chunk(c_idx: int, start: int, end: int) -> None:
        expected = end - start + 1
        last_exc: Optional[BaseException] = None
        for attempt in range(4):
            try:
                req = urllib.request.Request(url, headers=_hf_headers({"Range": f"bytes={start}-{end}"}))
                with urllib.request.urlopen(req, timeout=60) as resp:
                    status = getattr(resp, "status", 200)
                    if status != 206:
                        raise IOError(f"分块 Range 请求返回非 206 状态码 ({status})")
                    data = resp.read()
                if len(data) != expected:
                    raise IOError(f"分块字节数不匹配 ({len(data)} != {expected})")
                # POSIX atomic positioned write (thread-safe without shared file offset)
                written_chunk = 0
                mv = memoryview(data)
                while written_chunk < expected:
                    n = os.pwrite(fd, mv[written_chunk:], start + written_chunk)
                    if n <= 0:
                        raise IOError("os.pwrite 写入 0 字节")
                    written_chunk += n
                with state_lock:
                    done_indices.add(c_idx)
                    progress["bytes"] += expected
                    progress["new_bytes"] += expected
                    now = time.time()
                    if now - progress["last_report"] >= 4.0 or len(done_indices) == len(chunks):
                        pct = min(100.0, (progress["bytes"] / total) * 100.0)
                        mb_s = (progress["new_bytes"] / (1024 ** 2)) / max(now - progress["start_t"], 0.1)
                        log(
                            f"[HF] {dst.name} ({workers}x): {pct:.1f}% "
                            f"({progress['bytes']/(1024**3):.2f}/{total/(1024**3):.2f} GiB, {mb_s:.1f} MB/s)"
                        )
                        try:
                            meta_path.write_text(
                                json.dumps({"total": total, "chunk_size": chunk_size, "done": sorted(done_indices)}),
                                encoding="utf-8",
                            )
                        except OSError:
                            pass
                        refresh_disk_metrics()
                        progress["last_report"] = now
                return
            except Exception as exc:
                last_exc = exc
                if attempt < 3:
                    time.sleep(min(8.0, 1.5 * (2 ** attempt)))
        raise RuntimeError(f"分块 {c_idx} ({start}-{end}) 下载失败: {last_exc}") from last_exc

    try:
        if pending:
            with ThreadPoolExecutor(max_workers=workers) as pool:
                futs = [pool.submit(fetch_chunk, ci, st, ed) for ci, st, ed in pending]
                for fut in as_completed(futs):
                    fut.result()
    finally:
        os.close(fd)

    if len(done_indices) != len(chunks) or part_path.stat().st_size != total:
        raise IOError(f"{dst.name} 并发下载校验不完整")
    try:
        meta_path.unlink(missing_ok=True)
    except OSError:
        pass
    os.replace(part_path, dst)
    refresh_disk_metrics()
    elapsed_all = max(time.time() - progress["start_t"], 0.1)
    avg_mb_s = (progress["new_bytes"] / (1024 ** 2)) / elapsed_all
    log(f"[HF] 并发下载完成: {dst.name} ({total / (1024**3):.2f} GiB, 均速 {avg_mb_s:.1f} MB/s)")
    return dst


def _get_drive_api_token(force_refresh: bool = False) -> Optional[str]:
    """Acquire (or force-refresh) an OAuth access token with Drive scope on Colab VM.

    Checks in order:
      1. `COLABD_DRIVE_ACCESS_TOKEN` env var (for tests / explicit injection).
      2. `google.auth.default(scopes=[drive])` (standard ADC chain).
      3. Persistent Colab / gcloud ADC files on disk (`/content/.config/application_default_credentials.json`,
         `~/.config/gcloud/application_default_credentials.json`) so auth survives `colab restart-kernel`.
    """
    env_tok = os.environ.get("COLABD_DRIVE_ACCESS_TOKEN", "").strip()
    if env_tok:
        return env_tok

    scopes = ["https://www.googleapis.com/auth/drive"]
    try:
        import google.auth  # type: ignore
        from google.auth.transport.requests import Request as _GReq  # type: ignore

        creds, _ = google.auth.default(scopes=scopes)
        if force_refresh or not creds.valid or not creds.token:
            creds.refresh(_GReq())
        if creds.token:
            return str(creds.token)
    except Exception:
        pass

    try:
        from google.oauth2.credentials import Credentials as _GUserCreds  # type: ignore
        from google.auth.transport.requests import Request as _GReq  # type: ignore

        adc_candidates = [
            Path(os.environ.get("COLABD_VM_ADC_FILE", "/content/.config/application_default_credentials.json")),
            Path.home() / ".config" / "gcloud" / "application_default_credentials.json",
        ]
        for cand in adc_candidates:
            if not cand.is_file():
                continue
            try:
                creds = _GUserCreds.from_authorized_user_file(str(cand), scopes=scopes)
                if force_refresh or not creds.valid or not creds.token:
                    creds.refresh(_GReq())
                if creds.token:
                    return str(creds.token)
            except Exception:
                continue
    except Exception:
        pass

    if os.environ.get("COLABD_DISABLE_GCLOUD_TOKEN_FALLBACK") != "1" and shutil.which("gcloud"):
        try:
            tok = subprocess.check_output(
                ["gcloud", "auth", "print-access-token"],
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=15,
            ).strip()
            if tok:
                return tok
        except Exception:
            pass
    return None


def _drive_api_request_json(token: str, method: str, url: str, body: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    cur_token = token
    data_bytes: Optional[bytes] = json.dumps(body).encode("utf-8") if body is not None else None
    last_exc: Optional[BaseException] = None
    refreshed_401 = False
    for attempt in range(4):
        headers = {"Authorization": f"Bearer {cur_token}", "User-Agent": "colabd/0.2"}
        if data_bytes is not None:
            headers["Content-Type"] = "application/json; charset=utf-8"
        try:
            req = urllib.request.Request(url, data=data_bytes, headers=headers, method=method)
            with urllib.request.urlopen(req, timeout=45) as resp:
                raw = resp.read().decode("utf-8", errors="replace").strip()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            last_exc = exc
            if exc.code == 401 and not refreshed_401:
                new_tok = _get_drive_api_token(force_refresh=True)
                if new_tok:
                    cur_token = new_tok
                    refreshed_401 = True
                    continue
            if exc.code in (429, 500, 502, 503, 504) and attempt < 3:
                time.sleep(min(15.0, 2.0 * (2 ** attempt)))
                continue
            detail = exc.read().decode("utf-8", errors="replace")[:300]
            raise RuntimeError(f"Drive API {method} {url} 失败 (HTTP {exc.code}): {detail}") from exc
        except Exception as exc:
            last_exc = exc
            if attempt < 3:
                time.sleep(min(10.0, 1.5 * (2 ** attempt)))
                continue
            raise
    raise RuntimeError(f"Drive API 请求重试耗尽: {last_exc}")


def _escape_drive_q(value: str) -> str:
    return value.replace("\\", "\\\\").replace("'", "\\'")


def _drive_ensure_folder_path(token: str, folder_parts: List[str]) -> str:
    parent_id = "root"
    walked: List[str] = []
    for part in folder_parts:
        walked.append(part)
        key = tuple(walked)
        if key in _drive_folder_cache:
            parent_id = _drive_folder_cache[key]
            continue
        q = (
            f"name='{_escape_drive_q(part)}' and '{parent_id}' in parents "
            "and mimeType='application/vnd.google-apps.folder' and trashed=false"
        )
        qs = urllib.parse.urlencode({"q": q, "fields": "files(id,name)", "pageSize": "5"})
        res = _drive_api_request_json(token, "GET", f"{DRIVE_API_BASE}/files?{qs}")
        files = res.get("files") or []
        if files and files[0].get("id"):
            parent_id = str(files[0]["id"])
        else:
            created = _drive_api_request_json(
                token,
                "POST",
                f"{DRIVE_API_BASE}/files?fields=id",
                {
                    "name": part,
                    "mimeType": "application/vnd.google-apps.folder",
                    "parents": [parent_id],
                },
            )
            parent_id = str(created["id"])
        _drive_folder_cache[key] = parent_id
    return parent_id


def _drive_find_file(token: str, parent_id: str, filename: str) -> Optional[Dict[str, Any]]:
    q = f"name='{_escape_drive_q(filename)}' and '{parent_id}' in parents and trashed=false"
    qs = urllib.parse.urlencode({"q": q, "fields": "files(id,name,size,md5Checksum)", "pageSize": "5"})
    res = _drive_api_request_json(token, "GET", f"{DRIVE_API_BASE}/files?{qs}")
    files = res.get("files") or []
    return files[0] if files else None


def _drive_start_resumable_session(
    token: str,
    parent_id: str,
    filename: str,
    total: Optional[int],
    existing_file_id: Optional[str] = None,
) -> str:
    if existing_file_id:
        url = f"{DRIVE_UPLOAD_BASE}/files/{existing_file_id}?uploadType=resumable&fields=id,name,size"
        method = "PATCH"
        meta_body: Dict[str, Any] = {"name": filename}
    else:
        url = f"{DRIVE_UPLOAD_BASE}/files?uploadType=resumable&fields=id,name,size"
        method = "POST"
        meta_body = {"name": filename, "parents": [parent_id]}

    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json; charset=utf-8",
        "X-Upload-Content-Type": "application/octet-stream",
        "User-Agent": "colabd/0.2",
    }
    if total is not None:
        headers["X-Upload-Content-Length"] = str(total)
    req = urllib.request.Request(url, data=json.dumps(meta_body).encode("utf-8"), headers=headers, method=method)
    with _NO_REDIRECT_OPENER.open(req, timeout=45) as resp:
        loc = resp.headers.get("Location") or resp.headers.get("location")
        if not loc:
            raise RuntimeError("Drive Resumable Upload 未返回 Location 上传会话地址")
        return loc


def _drive_query_resumable_offset(token: str, upload_uri: str, total: Optional[int]) -> int:
    total_str = str(total) if total is not None else "*"
    req = urllib.request.Request(
        upload_uri,
        data=b"",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Length": "0",
            "Content-Range": f"bytes */{total_str}",
        },
        method="PUT",
    )
    try:
        with _NO_REDIRECT_OPENER.open(req, timeout=30) as resp:
            if 200 <= getattr(resp, "status", 200) < 300 and total is not None:
                return total
            return 0
    except urllib.error.HTTPError as exc:
        if exc.code == 308:
            rng = exc.headers.get("Range") or exc.headers.get("range") or ""
            m = re.search(r"bytes=0-(\d+)", rng)
            return (int(m.group(1)) + 1) if m else 0
        raise


def _read_exact_chunk(stream: Any, size: int) -> bytes:
    buf = bytearray()
    while len(buf) < size:
        part = stream.read(size - len(buf))
        if not part:
            break
        buf.extend(part)
    return bytes(buf)


def stream_hf_to_drive_api(
    repo: str,
    filename: str,
    dst: Path,
    token: str,
    optional: bool = False,
) -> Optional[Path]:
    """Stream HF file directly into Google Drive via REST API v3 Resumable Upload (0 bytes local cache)."""
    rel_parts = _drive_rel_parts(dst)
    if not rel_parts:
        raise RuntimeError(f"无法解析 {dst} 相对 {DRIVE_MOUNT_ROOT} 的云盘路径")

    url = _hf_resolve_url(repo, filename)
    total, _supports_range, final_url, skipped = _probe_hf_file(url, optional=optional)
    if skipped:
        log(f"[HF][INFO] 可选伴随文件 {repo}/{filename} 不存在，跳过。")
        return None

    folder_parts = rel_parts[:-1]
    remote_name = rel_parts[-1]
    parent_id = _drive_ensure_folder_path(token, folder_parts)
    existing = _drive_find_file(token, parent_id, remote_name)
    if existing and total is not None:
        try:
            if int(existing.get("size", -1)) == total and total > 0:
                log(
                    f"[DRIVE-API] 云盘已存在完整文件，原地复用跳过传输: "
                    f"{'/'.join(rel_parts)} ({total / (1024**3):.2f} GiB)"
                )
                return dst
        except (TypeError, ValueError):
            pass

    existing_id = str(existing["id"]) if existing and existing.get("id") else None
    upload_uri = _drive_start_resumable_session(token, parent_id, remote_name, total, existing_file_id=existing_id)

    total_disp = f"{total / (1024**3):.2f} GiB" if total else "未知大小"
    log(f"[DRIVE-API] 开始 0 本地缓存流式直传至 Google Drive: {'/'.join(rel_parts)} ({total_disp})...")
    emit_telemetry(
        phase=f"Drive API 流式直传 {remote_name}",
        drive_io_state="streaming_api",
        drive_io_detail=f"流式直传 {remote_name} (0 本地缓存)",
    )

    offset = 0
    start_t = time.time()
    last_report = start_t
    resp_meta: Dict[str, Any] = {}
    hf_resp = None

    def open_hf_at(byte_offset: int) -> Any:
        hdrs = _hf_headers({"Range": f"bytes={byte_offset}-"} if byte_offset > 0 else None)
        req = urllib.request.Request(final_url, headers=hdrs)
        return urllib.request.urlopen(req, timeout=60)

    try:
        hf_resp = open_hf_at(0)
        while True:
            chunk = _read_exact_chunk(hf_resp, DRIVE_API_CHUNK_BYTES)
            if not chunk:
                if total is not None and offset < total:
                    raise IOError(f"HF 响应流提前结束 ({offset} < {total})")
                break

            chunk_len = len(chunk)
            chunk_start = offset
            chunk_end = offset + chunk_len - 1
            is_final = (total is not None and (chunk_end + 1) >= total) or (chunk_len < DRIVE_API_CHUNK_BYTES)
            cr_total = str(total) if total is not None else (str(chunk_end + 1) if is_final else "*")

            uploaded_ok = False
            for attempt in range(5):
                put_req = urllib.request.Request(
                    upload_uri,
                    data=chunk,
                    headers={
                        "Authorization": f"Bearer {token}",
                        "Content-Length": str(chunk_len),
                        "Content-Range": f"bytes {chunk_start}-{chunk_end}/{cr_total}",
                    },
                    method="PUT",
                )
                try:
                    with _NO_REDIRECT_OPENER.open(put_req, timeout=120) as uresp:
                        raw = uresp.read().decode("utf-8", errors="replace").strip()
                        resp_meta = json.loads(raw) if raw else {}
                        offset = chunk_end + 1
                        uploaded_ok = True
                        break
                except urllib.error.HTTPError as exc:
                    if exc.code == 308:
                        rng = exc.headers.get("Range") or exc.headers.get("range") or ""
                        m = re.search(r"bytes=0-(\d+)", rng)
                        offset = (int(m.group(1)) + 1) if m else (chunk_end + 1)
                        uploaded_ok = True
                        break
                    if exc.code == 401 and attempt < 4:
                        # OAuth access token expires after ~60m during multi-hour 100GB+ uploads: auto-refresh!
                        new_tok = _get_drive_api_token(force_refresh=True)
                        if new_tok:
                            token = new_tok
                            log("[DRIVE-API] 访问令牌已过期 (HTTP 401)，已自动刷新令牌并继续分块上传...")
                            acked = _drive_query_resumable_offset(token, upload_uri, total)
                            if acked != chunk_start:
                                offset = acked
                                hf_resp.close()
                                hf_resp = open_hf_at(offset)
                                uploaded_ok = True
                                break
                            continue
                    if exc.code in (429, 500, 502, 503, 504) and attempt < 4:
                        time.sleep(min(20.0, 2.0 * (2 ** attempt)))
                        acked = _drive_query_resumable_offset(token, upload_uri, total)
                        if acked != chunk_start:
                            offset = acked
                            hf_resp.close()
                            hf_resp = open_hf_at(offset)
                            uploaded_ok = True
                            break
                        continue
                    err_body = exc.read().decode("utf-8", errors="replace")[:300]
                    raise RuntimeError(f"Drive API 分块上传失败 (HTTP {exc.code}): {err_body}") from exc
                except Exception as exc:
                    if attempt < 4:
                        time.sleep(min(20.0, 2.0 * (2 ** attempt)))
                        acked = _drive_query_resumable_offset(token, upload_uri, total)
                        if acked != chunk_start:
                            offset = acked
                            hf_resp.close()
                            hf_resp = open_hf_at(offset)
                            uploaded_ok = True
                            break
                        continue
                    raise RuntimeError(f"Drive API 流式直传连接异常: {exc}") from exc

            if not uploaded_ok:
                raise RuntimeError(f"Drive API 上传分块 {chunk_start}-{chunk_end} 重试耗尽")

            now = time.time()
            if now - last_report >= 4.0 or (total is not None and offset >= total):
                mb_s = (offset / (1024 ** 2)) / max(now - start_t, 0.1)
                if total and total > 0:
                    pct = min(100.0, (offset / total) * 100.0)
                    msg = f"{remote_name}: {pct:.1f}% ({offset/(1024**3):.2f}/{total/(1024**3):.2f} GiB, {mb_s:.1f} MB/s)"
                else:
                    msg = f"{remote_name}: {offset/(1024**3):.2f} GiB ({mb_s:.1f} MB/s)"
                log(f"[DRIVE-API] {msg}")
                emit_telemetry(drive_io_state="streaming_api", drive_io_detail=msg)
                refresh_disk_metrics()
                last_report = now

            if resp_meta:
                break
    finally:
        if hf_resp is not None:
            try:
                hf_resp.close()
            except Exception:
                pass

    if total is not None and resp_meta.get("size") is not None:
        if int(resp_meta["size"]) != total:
            raise IOError(f"Drive API 服务端落盘字节数校验不一致 ({resp_meta['size']} != {total})")

    # Wait briefly for FUSE mount metadata to reflect newly uploaded object
    if DRIVE_MOUNT_ROOT.exists() and not dst.exists():
        deadline = time.time() + 15.0
        while time.time() < deadline:
            if dst.exists():
                break
            time.sleep(0.5)

    emit_telemetry(
        drive_io_state="ready",
        drive_io_detail=f"Drive API 已确认落盘: {remote_name}",
    )
    log(f"[DRIVE-API] 服务端 HTTP 200 真落盘完成: {'/'.join(rel_parts)} ({offset / (1024**3):.2f} GiB, 0 本地缓存)")
    return dst


def _wait_for_local_disk_headroom(filename: str) -> None:
    """Pause FUSE direct-write if VM local root disk drops below watermark while DriveFS drains its cache."""
    target_local = WORK_DIR if WORK_DIR.exists() else Path("/")
    waited = 0.0
    warned = False
    while True:
        local_free_gb = shutil.disk_usage(target_local).free / (1024 ** 3)
        if local_free_gb >= FUSE_MIN_LOCAL_FREE_GB:
            if warned:
                log(f"[DRIVE-FUSE] 本地根盘余量已恢复至 {local_free_gb:.1f} GiB，继续写入 {filename}。")
            return
        dfs_gb = _measure_drivefs_cache_gb()
        if not warned:
            log(
                f"[DRIVE-FUSE][背压暂停] 本地根盘仅剩 {local_free_gb:.1f} GiB "
                f"(< {FUSE_MIN_LOCAL_FREE_GB:.0f} GiB 警戒线 | DriveFS缓存={dfs_gb:.1f} GiB)，"
                f"暂停写入 {filename} 等待 DriveFS 上传释放本地缓存..."
            )
            warned = True
        emit_telemetry(
            local_free_gb=round(local_free_gb, 1),
            drivefs_cache_gb=dfs_gb,
            drive_io_state="writing_fuse",
            drive_io_detail=f"背压等待 DriveFS 释放缓存 (本地余 {local_free_gb:.1f} GiB)",
        )
        if waited >= FUSE_BACKPRESSURE_MAX_WAIT_SEC:
            if local_free_gb < FUSE_CRITICAL_LOCAL_FREE_GB:
                raise RuntimeError(
                    f"本地根盘持续低于临界水位 ({local_free_gb:.1f} GiB < {FUSE_CRITICAL_LOCAL_FREE_GB:.0f} GiB)，"
                    "为防止 DriveFS 写缓存撑爆 VM 已中止写入。建议开启 colab auth 改用 Drive API 0 缓存直传。"
                )
            log(
                f"[DRIVE-FUSE][WARN] 等待 {waited:.0f}s 后本地余量仍为 {local_free_gb:.1f} GiB "
                f"(高于临界线 {FUSE_CRITICAL_LOCAL_FREE_GB:.0f} GiB)，继续低速写入。"
            )
            return
        step = min(2.0, max(0.05, FUSE_BACKPRESSURE_MAX_WAIT_SEC - waited))
        time.sleep(step)
        waited += step


def _download_hf_fuse_direct(repo: str, filename: str, dst: Path, optional: bool = False) -> Optional[Path]:
    """Sequential direct-write to Google Drive FUSE mount with local disk watermark backpressure."""
    global _wrote_via_fuse
    dst.parent.mkdir(parents=True, exist_ok=True)
    url = _hf_resolve_url(repo, filename)
    total, _supports_range, final_url, skipped = _probe_hf_file(url, optional=optional)
    if skipped:
        log(f"[HF][INFO] 可选伴随文件 {repo}/{filename} 不存在，跳过。")
        return None

    existing = dst.stat().st_size if (dst.exists() and not dst.is_symlink()) else 0
    if total is not None and total > 0 and existing == total:
        log(f"[DRIVE-FUSE] 云盘已存在完整文件，原地复用跳过下载: {dst.name} ({total / (1024**3):.2f} GiB)")
        return dst
    if total is not None and existing > total:
        existing = 0

    drive_free = shutil.disk_usage(dst.parent).free
    need_rem = (total - existing) if (total is not None and total > existing) else 0
    if need_rem > 0 and drive_free < need_rem + (1 * 1024 ** 3):
        raise RuntimeError(
            f"Google Drive 剩余配额不足 ({drive_free / (1024**3):.1f} GiB < 所需 {need_rem / (1024**3):.1f} GiB)，"
            f"无法直落写入 {dst.name}"
        )

    _wait_for_local_disk_headroom(dst.name)

    req_headers = _hf_headers({"Range": f"bytes={existing}-"} if existing > 0 else None)
    req = urllib.request.Request(final_url, headers=req_headers)
    resp = urllib.request.urlopen(req, timeout=60)
    with resp:
        status = getattr(resp, "status", 200)
        if existing > 0 and status != 206:
            existing = 0
        mode = "ab" if existing > 0 and status == 206 else "wb"
        log(
            f"[DRIVE-FUSE] 开始顺序直写至 Google Drive: {dst.name} "
            f"({(total or 0) / (1024**3):.2f} GiB, 带本地盘水位背压)..."
        )
        emit_telemetry(
            phase=f"FUSE 直写云盘 {dst.name}",
            drive_io_state="writing_fuse",
            drive_io_detail=f"FUSE 顺序直写 {dst.name}",
        )
        _wrote_via_fuse = True
        written = existing
        since_check = 0
        start_t = time.time()
        last_report = start_t
        buf_size = 8 * 1024 * 1024

        with dst.open(mode) as fh:
            while True:
                chunk = resp.read(buf_size)
                if not chunk:
                    break
                fh.write(chunk)
                written += len(chunk)
                since_check += len(chunk)
                if since_check >= 64 * 1024 * 1024:
                    fh.flush()
                    _wait_for_local_disk_headroom(dst.name)
                    since_check = 0
                now = time.time()
                if now - last_report >= 4.0:
                    mb_s = ((written - existing) / (1024 ** 2)) / max(now - start_t, 0.1)
                    if total and total > 0:
                        pct = min(100.0, (written / total) * 100.0)
                        msg = f"FUSE {dst.name}: {pct:.1f}% ({written/(1024**3):.2f}/{total/(1024**3):.2f} GiB, {mb_s:.1f} MB/s)"
                    else:
                        msg = f"FUSE {dst.name}: {written/(1024**3):.2f} GiB ({mb_s:.1f} MB/s)"
                    log(f"[DRIVE-FUSE] {msg}")
                    emit_telemetry(drive_io_state="writing_fuse", drive_io_detail=msg)
                    refresh_disk_metrics()
                    last_report = now
            fh.flush()
            try:
                os.fsync(fh.fileno())
            except OSError:
                pass

    if total is not None and dst.stat().st_size != total:
        raise IOError(f"FUSE 直写 {dst.name} 字节数不完整 ({dst.stat().st_size} != {total})")
    refresh_disk_metrics()
    emit_telemetry(
        drive_io_state="ready",
        drive_io_detail=f"FUSE 写入完成: {dst.name} (DriveFS 缓存 {_measure_drivefs_cache_gb():.1f} GiB)",
    )
    log(f"[DRIVE-FUSE] 直写完成: {dst.name} ({dst.stat().st_size / (1024**3):.2f} GiB)")
    return dst


def download_hf_file(repo: str, filename: str, dst: Path, optional: bool = False) -> Optional[Path]:
    """Download a file from Hugging Face directly to its target storage (local NVMe or Google Drive)."""
    dst.parent.mkdir(parents=True, exist_ok=True)

    # Route Drive-bound targets through Direct-to-Drive channels (API streaming or FUSE + backpressure)
    if _is_on_drive_mount(dst):
        if DRIVE_WRITE_MODE == "fuse":
            return _download_hf_fuse_direct(repo, filename, dst, optional=optional)
        token = _get_drive_api_token()
        if token:
            return stream_hf_to_drive_api(repo, filename, dst, token=token, optional=optional)
        if DRIVE_WRITE_MODE == "api_stream":
            raise RuntimeError(
                "当前已强制设置为 Drive API 流式直传 (DRIVE_WRITE_MODE=api_stream)，但远端未获取到 Drive API OAuth 令牌。"
                "请先执行 'colab auth' 注入远端凭证，或将设置 [4] 切换为 auto / fuse。"
            )
        log("[DRIVE] 未检测到远端 Drive API 令牌，自动回退至 FUSE 顺序直写 + 本地水位背压模式。")
        return _download_hf_fuse_direct(repo, filename, dst, optional=optional)

    # Local NVMe fast path: skip if already present, else multi-threaded Range download
    if dst.exists() and not dst.is_symlink() and dst.stat().st_size > 0:
        log(f"[HF] 命中本地 NVMe 文件，跳过下载: {dst.name} ({dst.stat().st_size / (1024**3):.2f} GiB)")
        return dst

    url = _hf_resolve_url(repo, filename)
    if HF_DOWNLOAD_CONCURRENCY > 1:
        total, supports_range, final_url, skipped = _probe_hf_file(url, optional=optional)
        if skipped:
            log(f"[HF][INFO] 可选伴随文件 {repo}/{filename} 不存在，跳过。")
            return None
        if supports_range and total is not None and total >= MULTIPART_MIN_BYTES:
            return _download_hf_local_multipart(final_url, dst, total, HF_DOWNLOAD_CONCURRENCY)
        return _download_hf_local_single(final_url, dst, optional=optional)

    return _download_hf_local_single(url, dst, optional=optional)


def discover_hf_repo_files(repo: str) -> List[str]:
    url = f"{HF_BASE_URL}/api/models/{repo}"
    req = urllib.request.Request(url, headers=_hf_headers())
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8", errors="replace"))
    siblings = data.get("siblings") or []
    return [str(s["rfilename"]) for s in siblings if isinstance(s, dict) and s.get("rfilename")]


def ensure_hf_subdir_files(repo: str, subdir: str, target_dir: Path) -> int:
    """Download all valid model/config files under `subdir/` of `repo` directly into `target_dir`."""
    target_dir.mkdir(parents=True, exist_ok=True)
    prefix = subdir.strip("/") + "/"
    files = discover_hf_repo_files(repo)
    matched = [
        f
        for f in sorted(files)
        if f.startswith(prefix)
        and not Path(f).name.startswith(".")
        and Path(f).suffix.lower() in SHARD_SUFFIXES
    ]
    if not matched:
        log(f"[HF][WARN] 仓库 {repo} 子目录 '{subdir}' 未发现可识别权重分片，将交由引擎自行下载。")
        return 0
    log(f"[HF] 在 {repo}/{subdir} 发现 {len(matched)} 个文件，直接下载至目标目录 ({target_dir})...")
    done_cnt = 0
    for rf in matched:
        rel_sub = rf[len(prefix) :]
        if download_hf_file(repo, rf, target_dir / rel_sub, optional=False) is not None:
            done_cnt += 1
    return done_cnt


def ensure_hf_model_files(repo: str, model_file: str, extra_files: List[str], target_dir: Path) -> Path:
    """Download required HF files directly into target_dir and return path to primary model file/dir."""
    target_dir.mkdir(parents=True, exist_ok=True)
    primary_path: Optional[Path] = None

    if model_file:
        primary_path = download_hf_file(repo, model_file, target_dir / Path(model_file).name, optional=False)
        for ef in extra_files:
            if NO_VISION and "vision" in ef.lower():
                continue
            download_hf_file(repo, ef, target_dir / Path(ef).name, optional=True)
        assert primary_path is not None
        return primary_path

    # No explicit filename: inspect HF repo siblings and download the best matching artifact set.
    files = discover_hf_repo_files(repo)
    strata_files = [
        f for f in files if f.lower().endswith(".strata") and "vision" not in f.lower() and "engram" not in f.lower()
    ]
    gguf_files = [
        f
        for f in files
        if f.lower().endswith(".gguf")
        and not re.match(r"^(?:.*/)?(?:mmproj|dspark|imatrix|mtp[-_])", f, re.I)
    ]

    if strata_files:
        chosen = sorted(strata_files)[0]
        primary_path = download_hf_file(repo, chosen, target_dir / Path(chosen).name, optional=False)
        for aux in files:
            low = aux.lower()
            if (not NO_VISION and "vision" in low and low.endswith(".strata")) or Path(aux).name in (
                "tokenizer.json",
                "chat_template.jinja",
            ):
                download_hf_file(repo, aux, target_dir / Path(aux).name, optional=True)
        assert primary_path is not None
        return primary_path

    if gguf_files:
        first_shard = next((f for f in sorted(gguf_files) if "-00001-of-" in f.lower()), None)
        if first_shard:
            stem = first_shard.split("-00001-of-")[0]
            shard_set = [f for f in sorted(gguf_files) if f.startswith(stem + "-")]
            for sf in shard_set:
                p = download_hf_file(repo, sf, target_dir / Path(sf).name, optional=False)
                if sf == first_shard:
                    primary_path = p
        else:
            chosen = sorted(gguf_files)[0]
            primary_path = download_hf_file(repo, chosen, target_dir / Path(chosen).name, optional=False)
        assert primary_path is not None
        return primary_path

    # Fallback: safetensors directory
    st_files = [
        f
        for f in files
        if f.lower().endswith((".safetensors", ".json", ".jinja")) and not f.startswith(".")
    ]
    if not st_files:
        raise RuntimeError(f"仓库 {repo} 中未找到可识别的 .strata / .gguf / .safetensors 模型文件")
    for sf in st_files:
        download_hf_file(repo, sf, target_dir / sf, optional=False)
    return target_dir


def prepare_storage_and_deps() -> Tuple[Path, bool]:
    gpu_info = "未检测到 NVIDIA GPU"
    driver_ver = ""
    vram_gb = 0.0
    try:
        raw_gpu = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=name,memory.total,driver_version", "--format=csv,noheader,nounits"],
            text=True,
        ).strip()
        lines = [ln.strip() for ln in raw_gpu.splitlines() if ln.strip()]
        pretty = []
        for ln in lines:
            parts = [p.strip() for p in ln.split(",")]
            if len(parts) >= 3:
                mib = float(parts[1])
                vram_gb += mib / 1024.0
                if not driver_ver:
                    driver_ver = parts[2]
                pretty.append(f"{parts[0]} ({mib/1024.0:.1f} GiB, drv {parts[2]})")
            else:
                pretty.append(ln)
        gpu_info = " | ".join(pretty)
    except Exception:
        pass

    mem_gb = 0.0
    if Path("/proc/meminfo").exists():
        for line in Path("/proc/meminfo").read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("MemTotal:"):
                mem_gb = round(int(line.split()[1]) / (1024 * 1024), 1)
                break

    ram_resident = decide_ram_residency(vram_gb, mem_gb)
    emit_telemetry(
        engine=ENGINE_TYPE,
        model_preset=MODEL_PRESET,
        gpu=gpu_info,
        driver_version=driver_ver,
        vram_gb=round(vram_gb, 1),
        ram_gb=mem_gb,
        ram_resident_active=ram_resident,
    )
    refresh_disk_metrics()
    engine_name = "Strata" if ENGINE_TYPE == "strata" else "Project Maya"
    log(
        f"[REMOTE] 引擎={engine_name} | 预设={MODEL_PRESET} | GPU={gpu_info} | "
        f"系统内存={mem_gb} GiB | 总内存池={vram_gb + mem_gb:.1f} GiB"
    )

    drive_available = DRIVE_MOUNT_ROOT.exists()
    drive_root = Path(DRIVE_CACHE_DIR)
    if drive_available:
        cleanup_temp_files(drive_root)

    is_ds4 = bool(MODEL_SPEC.get("has_engram")) or MODEL_PRESET in (
        "ds4-abliterated-128g",
        "ds4-abliterated-256g",
        "deepseek-maya-xs",
        "deepseek-maya-s",
    )
    is_ds4_ablit = MODEL_PRESET in ("ds4-abliterated-128g", "ds4-abliterated-256g")
    model_rel_sub = MODEL_SUBDIRS.get(MODEL_PRESET, "")

    if STORAGE_MODE == "drive_full":
        if not drive_available:
            log("[REMOTE][ERROR] 未检测到挂载的 Google Drive (/content/drive/MyDrive)，无法运行 drive_full 扩容模式。")
            sys.exit(2)
        models_dir = drive_root
        models_dir.mkdir(parents=True, exist_ok=True)
        emit_telemetry(
            drive_io_state="ready",
            drive_io_detail=f"全量云盘扩容直落模式 ({DRIVE_WRITE_MODE})",
        )
        log(f"[REMOTE] 存储拓扑: 全量云盘扩容 drive_full ({models_dir}，原地复用 / 缺失直接下载到云盘)")

    elif STORAGE_MODE == "nvme_engram":
        if is_ds4 and not drive_available:
            local_free_gb = shutil.disk_usage(WORK_DIR if WORK_DIR.exists() else Path("/")).free / (1024 ** 3)
            if local_free_gb < 280.0:
                log(
                    f"[REMOTE][ERROR] nvme_engram 扩容模式依赖 Google Drive 存放主权重，但未检测到 {DRIVE_MOUNT_ROOT} "
                    f"(且本地盘仅剩 {local_free_gb:.1f} GiB < 280 GiB)，已中止以防写爆磁盘。"
                )
                sys.exit(2)
        models_dir = Path(CUSTOM_MODELS_DIR)
        models_dir.mkdir(parents=True, exist_ok=True)
        cleanup_temp_files(models_dir)

        engram_nvme = models_dir / "Engram-Q6_K"
        engram_nvme.mkdir(parents=True, exist_ok=True)
        if is_ds4:
            if is_ds4_ablit:
                ablit_parent = models_dir / "DeepSeek-V4.1-Flash-1017-abliterated-GGUF"
                ablit_parent.mkdir(parents=True, exist_ok=True)
                ensure_symlink(ablit_parent / "Engram-Q6_K", engram_nvme)

            if model_rel_sub and drive_available:
                drive_weight_dir = drive_root / model_rel_sub
                local_weight_link = models_dir / model_rel_sub
                ensure_symlink(local_weight_link, drive_weight_dir)
                existing_shards = list_valid_shards(drive_weight_dir)
                if existing_shards:
                    log(
                        f"[DRIVE] 云盘已有 {len(existing_shards)} 个主权重文件 ({drive_weight_dir})，"
                        "将原地复用并在启动时顺序载入显存+内存。"
                    )
                else:
                    log(f"[DRIVE] 云盘暂无主权重文件，缺失分片将直接下载至云盘目录 ({drive_weight_dir})。")
        emit_telemetry(
            drive_io_state="ready" if drive_available else "disabled",
            drive_io_detail=f"反向跨盘扩容: 主权重直落云盘 ({DRIVE_WRITE_MODE}) / Engram 直落 NVMe",
        )
        log(f"[REMOTE] 存储拓扑: 反向跨盘扩容 nvme_engram (本地 NVMe={models_dir}, 主权重软链直落云盘)")

    elif STORAGE_MODE == "drive_engram":
        if not drive_available:
            log("[REMOTE][ERROR] 未检测到挂载的 Google Drive，无法运行 drive_engram 扩容模式。")
            sys.exit(2)
        models_dir = Path(CUSTOM_MODELS_DIR)
        models_dir.mkdir(parents=True, exist_ok=True)
        cleanup_temp_files(models_dir)

        drive_engram = drive_root / "Engram-Q6_K"
        ensure_symlink(models_dir / "Engram-Q6_K", drive_engram)
        if is_ds4_ablit:
            ensure_symlink(
                models_dir / "DeepSeek-V4.1-Flash-1017-abliterated-GGUF" / "Engram-Q6_K",
                drive_engram,
            )
        emit_telemetry(
            drive_io_state="ready",
            drive_io_detail=f"正向跨盘扩容: 外挂查表直落云盘 ({DRIVE_WRITE_MODE}) / 主权重直落 NVMe",
        )
        log(f"[REMOTE] 存储拓扑: 正向跨盘扩容 drive_engram (本地主权重={models_dir}, 外挂表软链云盘={drive_engram})")

    else:
        models_dir = Path(CUSTOM_MODELS_DIR)
        models_dir.mkdir(parents=True, exist_ok=True)
        cleanup_temp_files(models_dir)
        if is_ds4 and is_ds4_ablit:
            engram_nvme = models_dir / "Engram-Q6_K"
            engram_nvme.mkdir(parents=True, exist_ok=True)
            ensure_symlink(
                models_dir / "DeepSeek-V4.1-Flash-1017-abliterated-GGUF" / "Engram-Q6_K",
                engram_nvme,
            )
        emit_telemetry(
            drive_io_state="disabled",
            drive_io_detail="纯本地高速 NVMe (未挂载云盘)",
        )
        log(f"[REMOTE] 存储拓扑: 纯本地高速盘 local_nvme ({models_dir}, {HF_DOWNLOAD_CONCURRENCY} 线程并发直连 HF)")

    emit_telemetry(models_dir=str(models_dir))
    refresh_disk_metrics()

    if shutil.which("systemctl"):
        subprocess.run(
            ["systemctl", "stop", "systemd-oomd"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    if os.environ.get("MAYA_SKIP_APT") != "1":
        need_build_tools = ENGINE_TYPE == "maya" or choose_strata_install_mode(driver_ver, STRATA_BUILD_FALLBACK) == "source"
        checks = [("curl", "curl"), ("git", "git")]
        if need_build_tools:
            checks.extend([("cmake", "cmake"), ("g++", "build-essential")])
        missing = [pkg for binary, pkg in checks if not shutil.which(binary)]
        if missing:
            emit_telemetry(phase="安装系统依赖")
            _ensure_apt_packages(missing)

    return models_dir, ram_resident


def _is_local_port_free(port: int, host: str = "127.0.0.1") -> bool:
    try:
        with socket.create_connection((host, port), timeout=0.4):
            return False
    except OSError:
        pass
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind((host, port))
        return True
    except OSError:
        return False


def _select_free_remote_port(preferred_port: int, host: str = "127.0.0.1") -> int:
    for port in range(preferred_port, min(65536, preferred_port + 128)):
        if _is_local_port_free(port, host=host):
            return port
    return preferred_port


def _stop_leftover_strata_if_present() -> None:
    strata_bin = WORK_DIR / "strata-bin" / "strata"
    if not strata_bin.is_file():
        return
    try:
        subprocess.run(
            [str(strata_bin), "launch", "--stop"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
    except Exception:
        pass


def start_tunnel() -> None:
    if TUNNEL_MODE == "ssh":
        host_disp = "127.0.0.1" if LOCAL_BIND == "0.0.0.0" else LOCAL_BIND
        emit_telemetry(public_url=f"http://{host_disp}:{MAYA_PORT}")
        suffix = f" (远端引擎端口 {REMOTE_PORT})" if REMOTE_PORT != MAYA_PORT else ""
        log(f"[REMOTE] 隧道模式: Colab 官方 WebSocket SSH -> 本地 http://{host_disp}:{MAYA_PORT}{suffix}")
        return

    cf_bin = Path("/usr/local/bin/cloudflared")
    if not cf_bin.exists():
        emit_telemetry(phase="下载 cloudflared 客户端")
        log("[REMOTE] 正在下载官方 cloudflared 客户端...")
        tmp_cf = cf_bin.with_name(cf_bin.name + ".downloading.tmp")
        try:
            urllib.request.urlretrieve(
                "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64",
                tmp_cf,
            )
            tmp_cf.chmod(0o755)
            os.replace(tmp_cf, cf_bin)
        except Exception:
            try:
                tmp_cf.unlink(missing_ok=True)
            except OSError:
                pass
            raise

    if TUNNEL_MODE == "cf_named":
        if not CF_TUNNEL_TOKEN:
            log("[REMOTE][ERROR] 已选 Cloudflare 固定域名模式，但未设置 CF_TUNNEL_TOKEN！")
            sys.exit(2)
        log("[REMOTE] 正在启动 Cloudflare Named Tunnel...")
        p = subprocess.Popen(
            [str(cf_bin), "tunnel", "--no-autoupdate", "run", "--token", CF_TUNNEL_TOKEN],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
        procs.append(p)

        def drain_cf_named() -> None:
            assert p.stdout is not None
            for _line in p.stdout:
                pass

        threading.Thread(target=drain_cf_named, daemon=True).start()
        pub = CF_PUBLIC_HOSTNAME.strip() or "https://<Cloudflare-Zero-Trust-绑定域名>"
        if not pub.startswith("http"):
            pub = f"https://{pub}"
        emit_telemetry(public_url=pub.rstrip("/"))
        log(f"[REMOTE] Cloudflare 固定域名隧道已拉起: {pub}")
        return

    log(f"[REMOTE] 正在启动 Cloudflare Quick Tunnel -> http://127.0.0.1:{REMOTE_PORT} ...")
    p = subprocess.Popen(
        [str(cf_bin), "tunnel", "--no-autoupdate", "--url", f"http://127.0.0.1:{REMOTE_PORT}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    procs.append(p)
    pattern = re.compile(r"https://[a-zA-Z0-9-]+\.trycloudflare\.com")
    ready = threading.Event()

    def watch_cf() -> None:
        assert p.stdout is not None
        for line in p.stdout:
            m = pattern.search(line)
            if m and not ready.is_set():
                url = m.group(0)
                emit_telemetry(public_url=url)
                log(f"\n[REMOTE] >>> Cloudflare 公网 HTTPS 地址已生成: {url} <<<\n")
                ready.set()

    threading.Thread(target=watch_cf, daemon=True).start()
    ready.wait(timeout=25)


def health_poller(maya_dir: Path, ram_resident: bool) -> None:
    url = f"http://127.0.0.1:{REMOTE_PORT}/health"
    was_healthy = False
    engine_name = "Strata" if ENGINE_TYPE == "strata" else "Project Maya"

    while not _stop_event.is_set():
        time.sleep(8)
        if _stop_event.is_set():
            break
        refresh_disk_metrics()
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {MAYA_API_KEY}"})
        ok = False
        state = "unreachable"
        try:
            with urllib.request.urlopen(req, timeout=3) as resp:
                ok, state = check_health_response(resp.status, resp.read(65536))
        except Exception:
            ok, state = False, "unreachable"

        if ok and not was_healthy:
            was_healthy = True
            if ENGINE_TYPE == "maya":
                patch_existing_maya_configs(maya_dir, ram_resident)
            emit_telemetry(api_healthy=True, phase="在线服务中 (Ready)")
            log(f"\n[REMOTE] >>> {engine_name} 推理引擎已就绪，可开始接收 API 请求！ <<<\n")
        elif not ok and state == "loading" and not was_healthy:
            emit_telemetry(api_healthy=False, phase="模型权重加载入显存中...")
        elif not ok and was_healthy:
            was_healthy = False
            emit_telemetry(api_healthy=False, phase="引擎重载或忙碌中")


def _stream_subprocess(cmd: List[str], cwd: Optional[Path], env: Dict[str, str]) -> int:
    p = subprocess.Popen(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        start_new_session=True,
    )
    procs.append(p)

    global _main_loop_active
    _main_loop_active = True

    def forward() -> None:
        assert p.stdout is not None
        for line in p.stdout:
            output_queue.put(line)
        output_queue.put(None)

    threading.Thread(target=forward, daemon=True).start()

    while True:
        try:
            item = output_queue.get(timeout=1.0)
        except queue.Empty:
            if p.poll() is not None:
                break
            continue
        if item is None:
            break
        sys.stdout.write(item)
        sys.stdout.flush()

    _main_loop_active = False
    while not output_queue.empty():
        try:
            item = output_queue.get_nowait()
            if item is not None:
                sys.stdout.write(item)
                sys.stdout.flush()
        except queue.Empty:
            break
    return p.wait()


# ==============================================================================
# Strata Engine Adapter (Niko1221/Strata)
# ==============================================================================


def _ensure_apt_packages(packages: List[str]) -> None:
    if os.environ.get("MAYA_SKIP_APT") == "1" or not packages:
        return
    if not shutil.which("apt-get"):
        return
    run_checked(["apt-get", "update", "-qq"])
    run_checked(["apt-get", "install", "-y", "-qq"] + packages)


def _is_venv_capable_python(py_bin: str) -> bool:
    try:
        res = subprocess.run(
            [py_bin, "-c", "import sys, venv, ensurepip; sys.exit(0 if sys.version_info >= (3, 10) else 1)"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return res.returncode == 0
    except OSError:
        return False


def _find_venv_capable_python() -> Optional[str]:
    candidates: List[str] = []
    for raw in (
        "/usr/bin/python3",
        shutil.which("python3.12"),
        shutil.which("python3.11"),
        shutil.which("python3.10"),
        shutil.which("python3.13"),
        shutil.which("python3"),
        sys.executable,
    ):
        if not raw:
            continue
        cand = str(raw)
        if cand not in candidates:
            candidates.append(cand)
    for cand in candidates:
        if Path(cand).exists() and _is_venv_capable_python(cand):
            return cand
    return None


def _ensure_strata_source_env(strata_src: Path) -> Path:
    """Prepare build tools & a working Python venv for Strata/setup.sh.

    Colab places Python 3.13 at `/usr/local/bin/python3` without `ensurepip`,
    causing Strata's `setup.sh` (`PY=python3; ok_py $PY`) to fail even after
    installing `python3-venv` for `/usr/bin/python3` (3.12). Pre-creating
    `terminal/.venv` (or `.venv`) with a verified venv+pip interpreter lets
    `setup.sh` jump straight to `exec .venv/bin/python setup.py`.
    """
    missing_tools = [
        pkg for binary, pkg in [("cmake", "cmake"), ("g++", "build-essential")]
        if not shutil.which(binary)
    ]
    if missing_tools:
        emit_telemetry(phase="安装 Strata 源码编译依赖")
        _ensure_apt_packages(missing_tools)

    venv_root = (strata_src / "terminal") if (strata_src / "terminal" / "setup.py").is_file() else strata_src
    venv_dir = venv_root / ".venv"
    venv_py = venv_dir / "bin" / "python"
    if venv_py.exists():
        pip_ok = subprocess.run(
            [str(venv_py), "-m", "pip", "--version"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode == 0
        if pip_ok:
            return venv_dir
        shutil.rmtree(venv_dir, ignore_errors=True)

    py_bin = _find_venv_capable_python()
    if not py_bin and os.environ.get("MAYA_SKIP_APT") != "1":
        emit_telemetry(phase="安装 Python venv 依赖")
        _ensure_apt_packages(["python3", "python3-venv", "python3-pip"])
        py_bin = _find_venv_capable_python()

    if py_bin:
        log(f"[REMOTE] 初始化 Strata 源码 Python 虚拟环境: {py_bin} -> {venv_dir}")
        run_checked([py_bin, "-m", "venv", str(venv_dir)])
    else:
        uv_bin = shutil.which("uv")
        if uv_bin:
            log(f"[REMOTE] 使用 uv 初始化 Strata 源码 Python 虚拟环境: {venv_dir}")
            run_checked([uv_bin, "venv", "--managed-python", "--seed", "--python", "3.12", str(venv_dir)])
    return venv_dir


def build_strata_launch_cmd(
    strata_bin: str,
    strata_spec: Dict[str, Any],
    data_dir: Path,
    model_path: Optional[Path] = None,
) -> List[str]:
    family = str(strata_spec.get("family") or "inkling-2-mini")
    model_tag = str(strata_spec.get("model") or "SQ-10")
    cmd = [
        strata_bin,
        "launch",
        "--family",
        family,
        "--model",
        model_tag,
        "--data-dir",
        str(data_dir),
        "--context",
        str(MAYA_CONTEXT),
        "--vision",
        "off" if NO_VISION else "on",
        "--access",
        "local",
        "--port",
        str(REMOTE_PORT),
        "--api-key",
        MAYA_API_KEY,
        "--yes",
        "--restart",
        "--no-tui",
    ]
    if model_path is not None:
        cmd.extend(["--model-path", str(model_path)])
    draft_cfg = MAYA_DRAFTING.strip().lower()
    if draft_cfg == "off":
        cmd.extend(["--drafting", "off"])
    elif draft_cfg in ("auto", "mtp", "dflash2"):
        cmd.extend(["--drafting", draft_cfg])
    elif draft_cfg in ("on", "measure"):
        cmd.extend(["--drafting", "auto"])
    if STRATA_KV_FORMAT and STRATA_KV_FORMAT != "auto":
        cmd.extend(["--kv", STRATA_KV_FORMAT])
    if STRATA_PARALLEL.isdigit() and int(STRATA_PARALLEL) > 1:
        cmd.extend(["--parallel", STRATA_PARALLEL])
    return cmd


def build_strata_source_setup_cmd(
    setup_script: Path,
    strata_spec: Dict[str, Any],
    data_dir: Path,
    model_path: Optional[Path] = None,
) -> List[str]:
    family = str(strata_spec.get("family") or "inkling-2-mini")
    model_tag = str(strata_spec.get("model") or "SQ-10")
    cmd = [
        str(setup_script),
        "--build",
        "--yes",
        "--family",
        family,
        "--model",
        model_tag,
        "--data-dir",
        str(data_dir),
        "--context",
        str(MAYA_CONTEXT),
        "--vision",
        "no" if NO_VISION else "yes",
        "--host",
        "127.0.0.1",
        "--port",
        str(REMOTE_PORT),
        "--api-key",
        MAYA_API_KEY,
    ]
    if model_path is not None:
        cmd.extend(["--gguf-dir", str(model_path)])
    if MAYA_DRAFTING == "off":
        cmd.extend(["--drafter", "off"])
    elif MAYA_DRAFTING == "on" and family == "inkling-2-mini":
        cmd.extend(["--drafter", "dspark"])
    if STRATA_KV_FORMAT and STRATA_KV_FORMAT != "auto":
        cmd.extend(["--kv", STRATA_KV_FORMAT])
    if STRATA_PARALLEL.isdigit() and int(STRATA_PARALLEL) > 1:
        cmd.extend(["--parallel", STRATA_PARALLEL])
    return cmd


def _find_latest_strata_log(search_roots: List[Path]) -> Optional[Path]:
    newest: Optional[Path] = None
    newest_mtime = -1.0
    for root in search_roots:
        if not root.exists():
            continue
        for p in root.rglob("*.log"):
            try:
                st = p.stat()
                if st.st_mtime > newest_mtime:
                    newest_mtime = st.st_mtime
                    newest = p
            except OSError:
                pass
    return newest


def _tether_strata_background(strata_bin: str, env: Dict[str, str], log_roots: List[Path]) -> int:
    """Keep the Colab kernel active while Strata serves in background, streaming logs & checking liveness."""
    global _main_loop_active
    _main_loop_active = True
    log("[REMOTE] Strata 后台服务已拉起，进入前台日志保活循环 (保持 Colab 内核活跃)...")

    tailed_file: Optional[Path] = None
    file_pos = 0
    consecutive_down = 0
    last_probe = 0.0
    start_ts = time.time()

    try:
        while not _stop_event.is_set():
            while not output_queue.empty():
                try:
                    item = output_queue.get_nowait()
                    if item is not None:
                        sys.stdout.write(item)
                        sys.stdout.flush()
                except queue.Empty:
                    break

            cand_log = _find_latest_strata_log(log_roots)
            if cand_log and cand_log != tailed_file:
                tailed_file = cand_log
                file_pos = 0
                sys.stdout.write(f"[REMOTE] 挂载 Strata 实时日志: {tailed_file}\n")
                sys.stdout.flush()

            if tailed_file and tailed_file.is_file():
                try:
                    sz = tailed_file.stat().st_size
                    if sz < file_pos:
                        file_pos = 0
                    if sz > file_pos:
                        with tailed_file.open("r", encoding="utf-8", errors="replace") as fh:
                            fh.seek(file_pos)
                            chunk = fh.read()
                            file_pos = fh.tell()
                        if chunk:
                            sys.stdout.write(chunk)
                            sys.stdout.flush()
                except OSError:
                    pass

            now = time.time()
            if now - last_probe >= 10.0:
                last_probe = now
                req = urllib.request.Request(
                    f"http://127.0.0.1:{REMOTE_PORT}/health",
                    headers={"Authorization": f"Bearer {MAYA_API_KEY}"},
                )
                reachable = False
                try:
                    with urllib.request.urlopen(req, timeout=3) as resp:
                        reachable = 200 <= resp.status < 500
                except Exception:
                    reachable = False
                if reachable:
                    consecutive_down = 0
                elif now - start_ts > 90.0:
                    consecutive_down += 1
                    if consecutive_down >= 6:
                        sys.stdout.write("[REMOTE][ERROR] Strata 服务端口连续 60 秒无响应，判定引擎已退出。\n")
                        sys.stdout.flush()
                        return 1

            time.sleep(1.0)
    finally:
        _main_loop_active = False

    return 0


def run_strata(models_dir: Path) -> int:
    global _active_strata_bin, _active_strata_env

    strata_spec = MODEL_SPEC.get("strata") if isinstance(MODEL_SPEC.get("strata"), dict) else {}
    source_kind = str(strata_spec.get("source") or "catalog")
    strata_data_dir = models_dir / "strata-data"
    strata_data_dir.mkdir(parents=True, exist_ok=True)

    model_path: Optional[Path] = None
    if source_kind in ("hf_files", "custom_hf"):
        hf_repo = str(strata_spec.get("hf_repo") or "").strip()
        model_file = str(strata_spec.get("model_file") or "").strip()
        extra_files = list(strata_spec.get("extra_files") or [])
        if not hf_repo:
            log("[REMOTE][ERROR] 当前为自定义 Strata HF 模式，但未配置 CUSTOM_HF_REPO！")
            return 2
        rel_sub = MODEL_SUBDIRS.get(MODEL_PRESET, "Custom-Strata")
        local_target = models_dir / rel_sub
        emit_telemetry(phase=f"拉取/校验 Hugging Face 权重 ({hf_repo})")
        model_path = ensure_hf_model_files(hf_repo, model_file, extra_files, local_target)
        log(f"[REMOTE] Strata 本地模型路径就绪: {model_path}")

    driver_ver = str(TELEMETRY.get("driver_version") or "")
    install_mode = choose_strata_install_mode(driver_ver, STRATA_BUILD_FALLBACK)
    log(
        f"[REMOTE] Strata 启动模式: {install_mode} "
        f"(当前驱动: {driver_ver or '未知'} | 预编译最低要求: {STRATA_PREBUILT_DRIVER_FLOOR[0]}.{STRATA_PREBUILT_DRIVER_FLOOR[1]} | 策略: {STRATA_BUILD_FALLBACK})"
    )

    env = os.environ.copy()
    env["STRATA_DATA_DIR"] = str(strata_data_dir)
    env["STRATA_API_KEY"] = MAYA_API_KEY
    env["HF_HUB_ENABLE_HF_TRANSFER"] = "1"
    env["HF_XET_HIGH_PERFORMANCE"] = "1"
    if HF_TOKEN:
        env["HF_TOKEN"] = HF_TOKEN

    if install_mode == "prebuilt":
        strata_bin_dir = WORK_DIR / "strata-bin"
        strata_bin_dir.mkdir(parents=True, exist_ok=True)
        strata_bin = strata_bin_dir / "strata"
        env["STRATA_BIN_DIR"] = str(strata_bin_dir)
        env["PATH"] = f"{strata_bin_dir}:{env.get('PATH', '')}"

        if not strata_bin.exists():
            emit_telemetry(phase="下载并安装 Strata 官方预编译终端")
            installer_path = WORK_DIR / "strata-install.sh"
            log(f"[REMOTE] 正在下载 Strata 官方安装脚本: {STRATA_INSTALL_URL}")
            urllib.request.urlretrieve(STRATA_INSTALL_URL, installer_path)
            rc = _stream_subprocess(["sh", str(installer_path)], cwd=WORK_DIR, env=env)
            if rc != 0 or not strata_bin.exists():
                if STRATA_BUILD_FALLBACK == "auto":
                    log("[REMOTE][WARN] Strata 预编译安装失败，自动回退至源码编译模式...")
                    install_mode = "source"
                else:
                    log(f"[REMOTE][ERROR] Strata 预编译安装失败 (exit={rc})。")
                    return rc or 1

        if install_mode == "prebuilt":
            _active_strata_bin = str(strata_bin)
            _active_strata_env = env
            launch_cmd = build_strata_launch_cmd(str(strata_bin), strata_spec, strata_data_dir, model_path)
            emit_telemetry(phase="Strata 拉取预编译 CUDA 引擎并加载模型")
            log(f"[REMOTE] 执行 Strata 启动流水线: {' '.join(launch_cmd)}")
            rc = _stream_subprocess(launch_cmd, cwd=WORK_DIR, env=env)
            if rc != 0:
                if STRATA_BUILD_FALLBACK == "auto":
                    log(f"[REMOTE][WARN] strata launch 预编译启动失败 (exit={rc})，尝试自动回退源码编译模式...")
                    install_mode = "source"
                    _active_strata_bin = None
                else:
                    return rc
            else:
                log_roots = [
                    strata_data_dir,
                    Path.home() / ".local" / "share" / "strata",
                    Path.home() / ".config" / "strata",
                ]
                return _tether_strata_background(str(strata_bin), env, log_roots)

    # Source-build path (older Colab NVIDIA driver < 575.51 or explicit source fallback)
    strata_src = WORK_DIR / "Strata"
    if not (strata_src / ".git").exists():
        emit_telemetry(phase="克隆 Niko1221/Strata 源码仓库")
        run_checked(["git", "clone", "--depth", "1", STRATA_REPO_URL, str(strata_src)])

    _ensure_strata_source_env(strata_src)
    setup_sh = strata_src / "setup.sh"
    setup_cmd = build_strata_source_setup_cmd(setup_sh, strata_spec, strata_data_dir, model_path)
    emit_telemetry(phase="Strata 源码编译 CUDA 引擎并加载模型")
    log(f"[REMOTE] 执行 Strata 源码构建与启动: {' '.join(setup_cmd)}")
    return _stream_subprocess(setup_cmd, cwd=strata_src, env=env)


# ==============================================================================
# Project Maya Engine Adapter (mw00/project-maya)
# ==============================================================================


def build_maya_cmd(
    models_dir: Path,
    ram_resident: bool,
    custom_model_dir: Optional[Path] = None,
    no_start: bool = False,
) -> List[str]:
    maya_spec = MODEL_SPEC.get("maya") if isinstance(MODEL_SPEC.get("maya"), dict) else {}
    family = str(maya_spec.get("family") or "")
    if not family:
        if MODEL_PRESET.startswith(("ds4-", "deepseek-")):
            family = "ds4"
        elif MODEL_PRESET.startswith("glm-"):
            family = "glm"
        elif MODEL_PRESET.startswith("minimax-"):
            family = "mm3"
        elif MODEL_PRESET.startswith("hy4-"):
            family = "hy4"
        elif "inkling" in MODEL_PRESET:
            family = "ik2"

    cmd = [
        "./maya.sh",
        "--setup",
        "--yes",
        "--plain",
        "--download-model",
        "--drafting",
        MAYA_DRAFTING,
        "--models-dir",
        str(models_dir),
        "--context",
        str(MAYA_CONTEXT),
        "--host",
        "127.0.0.1",
        "--port",
        str(REMOTE_PORT),
        "--api-key",
        MAYA_API_KEY,
    ]

    if MAYA_ABLATION in ("on", "off"):
        cmd.extend(["--ablation", MAYA_ABLATION])

    if STRATA_KV_FORMAT and STRATA_KV_FORMAT != "auto":
        cmd.extend(["--kv", STRATA_KV_FORMAT])

    if ram_resident:
        if family == "ds4":
            cmd.extend(["--env", "DS4_REQUIRE_ALL_RAM=1"])
        elif family == "glm":
            cmd.extend(["--env", "MAYA_GLM_RAM_RESIDENT=1"])
    elif EXPERT_RAM_POLICY == "allow_disk":
        if family == "ds4":
            cmd.extend(["--env", "DS4_REQUIRE_ALL_RAM=0"])
        elif family == "glm":
            cmd.extend(["--env", "MAYA_GLM_RAM_RESIDENT=0"])

    ds4_quant = str(maya_spec.get("ds4_quant") or "").strip()
    hy4_quant = str(maya_spec.get("hy4_quant") or "").strip()
    model_arg = str(maya_spec.get("model_arg") or "").strip()

    if ds4_quant:
        cmd.extend(["--model", model_arg or "DeepSeek-V4.1-Flash-1017", "--ds4-quant", ds4_quant])
    elif hy4_quant:
        cmd.extend(["--model", model_arg or "Hy4-Flash", "--hy4-quant", hy4_quant])
    elif MODEL_PRESET == "ds4-abliterated-128g":
        cmd.extend(["--model", "DeepSeek-V4.1-Flash-1017", "--ds4-quant", "abliterated-128g"])
    elif MODEL_PRESET == "ds4-abliterated-256g":
        cmd.extend(["--model", "DeepSeek-V4.1-Flash-1017", "--ds4-quant", "abliterated-256g"])
    elif model_arg:
        cmd.extend(["--model", model_arg])
    elif not custom_model_dir:
        cmd.extend(["--model", MODEL_PRESET])

    if custom_model_dir is not None:
        cmd.extend(["--model-dir", str(custom_model_dir)])

    if NO_VISION:
        cmd.append("--no-vision")
    if no_start:
        cmd.append("--no-start")

    return cmd


def run_maya(models_dir: Path, ram_resident: bool) -> int:
    maya_dir = WORK_DIR / "project-maya"
    if not (maya_dir / ".git").exists():
        emit_telemetry(phase="克隆 mw00/project-maya 仓库")
        run_checked(["git", "clone", "--depth", "1", MAYA_REPO_URL, str(maya_dir)])

    custom_model_dir: Optional[Path] = None
    maya_spec = MODEL_SPEC.get("maya") if isinstance(MODEL_SPEC.get("maya"), dict) else {}
    hf_repo = str(maya_spec.get("hf_repo") or "").strip()
    if hf_repo:
        rel_sub = MODEL_SUBDIRS.get(MODEL_PRESET, "Custom-Maya")
        local_target = models_dir / rel_sub
        emit_telemetry(phase=f"直落下载自定义 Hugging Face 权重 ({hf_repo})")
        ensure_hf_model_files(hf_repo, str(maya_spec.get("model_file") or ""), [], local_target)
        custom_model_dir = local_target
    else:
        # For built-in large presets whose main weights live on Google Drive (nvme_engram / drive_full),
        # stream missing main weight shards directly to Drive FIRST while local NVMe is still empty!
        direct_cfg = maya_spec.get("drive_direct_hf")
        model_rel_sub = MODEL_SUBDIRS.get(MODEL_PRESET, "")
        if isinstance(direct_cfg, dict) and model_rel_sub:
            weight_target = models_dir / model_rel_sub
            if _is_on_drive_mount(weight_target):
                d_repo = str(direct_cfg.get("hf_repo") or "").strip()
                d_sub = str(direct_cfg.get("hf_subdir") or "").strip()
                if d_repo and d_sub:
                    emit_telemetry(phase=f"直落主权重至云盘 ({d_repo}/{d_sub})")
                    log(
                        f"[DRIVE] 检测到主权重归属 Google Drive ({weight_target})，"
                        "优先直落主权重（避免与本地 Engram 争抢空间）..."
                    )
                    ensure_hf_subdir_files(d_repo, d_sub, weight_target)

    patch_existing_maya_configs(maya_dir, ram_resident)

    env = os.environ.copy()
    env["MAYA_UPDATE_CHECK"] = "0"
    env["HF_HUB_ENABLE_HF_TRANSFER"] = "1"
    env["HF_XET_HIGH_PERFORMANCE"] = "1"
    if not WEB_UI:
        env["MAYA_WEB_UI"] = "0"
    if HF_TOKEN:
        env["HF_TOKEN"] = HF_TOKEN

    need_prestart_patch = MAYA_ABLATION == "on" and MAYA_ABLATE_DEFAULT == "on"
    if need_prestart_patch:
        setup_cmd = build_maya_cmd(models_dir, ram_resident, custom_model_dir=custom_model_dir, no_start=True)
        emit_telemetry(phase="校验分片 / 编译引擎 / 注入全局去拒绝配置")
        log("[REMOTE] 执行 Project Maya 初始化 (--no-start 以便首次即激活 --ablate-default on)...")
        rc = _stream_subprocess(setup_cmd, cwd=maya_dir, env=env)
        if rc != 0:
            return rc
        patch_existing_maya_configs(maya_dir, ram_resident)
        serve_cmd = [
            "./maya.sh",
            "--plain",
            "--host",
            "127.0.0.1",
            "--port",
            str(REMOTE_PORT),
            "--api-key",
            MAYA_API_KEY,
        ]
        emit_telemetry(phase="启动 Project Maya 推理服务")
        return _stream_subprocess(serve_cmd, cwd=maya_dir, env=env)

    cmd = build_maya_cmd(models_dir, ram_resident, custom_model_dir=custom_model_dir, no_start=False)
    emit_telemetry(phase="校验分片 / 补齐缺失项 / 编译预热引擎")
    log("[REMOTE] 执行 Project Maya 启动流水线 (已就绪分片将直接通过 SHA256 原地复用，缺失项直落目标盘下载)...")
    return _stream_subprocess(cmd, cwd=maya_dir, env=env)


def main() -> None:
    global REMOTE_PORT
    models_dir, ram_resident = prepare_storage_and_deps()
    if ENGINE_TYPE == "strata":
        _stop_leftover_strata_if_present()
    if not _is_local_port_free(REMOTE_PORT):
        if TUNNEL_MODE == "ssh":
            log(f"[REMOTE][WARN] 远端端口 {REMOTE_PORT} 仍被其他程序占用，若引擎启动报端口冲突请调换 MAYA_PORT（Colab 容器默认占用 8080）。")
        else:
            picked = _select_free_remote_port(REMOTE_PORT)
            if picked != REMOTE_PORT:
                log(f"[REMOTE][WARN] 远端端口 {REMOTE_PORT} 已被占用，自动切换至空闲端口 {picked}。")
                REMOTE_PORT = picked
    start_tunnel()
    maya_dir = WORK_DIR / "project-maya"
    threading.Thread(
        target=health_poller,
        args=(maya_dir, ram_resident),
        daemon=True,
    ).start()
    if ENGINE_TYPE == "strata":
        rc = run_strata(models_dir)
    else:
        rc = run_maya(models_dir, ram_resident)
    emit_telemetry(phase=f"进程已退出 (code={rc})", api_healthy=False)
    sys.exit(rc)


if __name__ == "__main__":
    main()
