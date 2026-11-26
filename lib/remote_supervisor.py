#!/usr/bin/env python3
"""
colabd remote supervisor (executed inside the Google Colab Jupyter kernel via `colab exec`).

Supports multiple inference engines (`strata` and `maya`) and tiered/custom Hugging Face models.

Responsibilities:
1. Inspect remote GPU VRAM, NVIDIA driver version, system RAM, local NVMe free space, and Drive mount.
2. Prefetch cached model/Engram shards from Google Drive onto local NVMe when enabled.
3. Configure storage & symlink topology (`nvme_engram`, `drive_engram`, `drive_full`, `local_nvme`).
4. Fetch custom Hugging Face `.strata`/`.gguf`/safetensors files with resumable atomic downloads.
5. Start reverse tunnels (Cloudflare Quick/Named Tunnel or SSH local port forward).
6. Launch the selected inference engine:
   - `strata`: Prebuilt CUDA fast path when NVIDIA driver >= 575.51 (with automatic source-build fallback
     on older Colab drivers), foreground log tether, and clean `strata launch --stop` shutdown.
   - `maya`: Full Project Maya model catalog, RAM expert residency (`--mmap-experts off`), and refusal
     ablation (`--ablation` / `--ablate-default`).
7. Poll `/health` (verifying `loaded == true` for Strata JSON responses) and atomically sync newly
   downloaded shards back to Google Drive.
"""

import json
import os
import queue
import re
import shutil
import signal
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
        "maya_port": os.environ.get("COLABD_MAYA_PORT", "8080"),
        "strata_kv_format": os.environ.get("COLABD_STRATA_KV_FORMAT", "auto"),
        "strata_parallel": os.environ.get("COLABD_STRATA_PARALLEL", "1"),
        "strata_build_fallback": os.environ.get("COLABD_STRATA_BUILD_FALLBACK", "auto"),
        "maya_ablation": os.environ.get("COLABD_MAYA_ABLATION", "on"),
        "maya_ablate_default": os.environ.get("COLABD_MAYA_ABLATE_DEFAULT", "off"),
        "storage_mode": os.environ.get("COLABD_STORAGE_MODE", "nvme_engram"),
        "drive_prefetch": os.environ.get("COLABD_DRIVE_PREFETCH", "1"),
        "drive_save_policy": os.environ.get("COLABD_DRIVE_SAVE_POLICY", "both"),
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
MAYA_PORT: int = int(CONFIG.get("maya_port", "8080"))
STRATA_KV_FORMAT: str = str(CONFIG.get("strata_kv_format", "auto")).strip().lower()
STRATA_PARALLEL: str = str(CONFIG.get("strata_parallel", "1")).strip()
STRATA_BUILD_FALLBACK: str = str(CONFIG.get("strata_build_fallback", "auto")).strip().lower()
MAYA_ABLATION: str = str(CONFIG.get("maya_ablation", "on")).strip().lower()
MAYA_ABLATE_DEFAULT: str = str(CONFIG.get("maya_ablate_default", "off")).strip().lower()

STORAGE_MODE: str = str(CONFIG.get("storage_mode", "nvme_engram"))
DRIVE_PREFETCH: bool = str(CONFIG.get("drive_prefetch", "1")) == "1"
DRIVE_SAVE_POLICY: str = str(CONFIG.get("drive_save_policy", "both"))
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
TEMP_SUFFIXES = (".tmp", ".part", ".pulling.tmp", ".syncing.tmp")
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
output_queue = queue.Queue()
_main_thread_id = threading.get_ident()
_main_loop_active = False
_stop_event = threading.Event()
_active_strata_bin: Optional[str] = None
_active_strata_env: Optional[Dict[str, str]] = None

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
    "models_dir": "",
    "ram_resident_active": False,
    "cache_sync_state": "idle",
    "cache_sync_detail": "无待回存任务",
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


def refresh_disk_metrics() -> None:
    target_local = WORK_DIR if WORK_DIR.exists() else Path("/")
    local_free = shutil.disk_usage(target_local).free / (1024 ** 3)
    drive_free = (
        round(shutil.disk_usage(DRIVE_MOUNT_ROOT).free / (1024 ** 3), 1)
        if DRIVE_MOUNT_ROOT.exists()
        else None
    )
    emit_telemetry(local_free_gb=round(local_free, 1), drive_free_gb=drive_free)


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
    if DRIVE_MOUNT_ROOT.exists():
        cleanup_temp_files(Path(DRIVE_CACHE_DIR))
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


def copy_file_stream(src: Path, dst: Path, tmp_suffix: str, progress_prefix: str) -> bool:
    dst.parent.mkdir(parents=True, exist_ok=True)
    src_size = src.stat().st_size
    if dst.exists() and not dst.is_symlink() and dst.stat().st_size == src_size:
        return False

    free_bytes = shutil.disk_usage(dst.parent).free
    if free_bytes < src_size + (2 * 1024 ** 3):
        log(
            f"[CACHE][SKIP] 目标盘 ({dst.parent}) 剩余空间不足 ({free_bytes / (1024**3):.1f} GiB)，"
            f"跳过拷贝 {src.name} ({src_size / (1024**3):.1f} GiB)"
        )
        return False

    tmp_dst = dst.with_name(dst.name + tmp_suffix)
    copied = 0
    last_report = time.time()
    start_t = last_report
    buf_size = 16 * 1024 * 1024

    try:
        with src.open("rb") as fsrc, tmp_dst.open("wb") as fdst:
            while True:
                chunk = fsrc.read(buf_size)
                if not chunk:
                    break
                fdst.write(chunk)
                copied += len(chunk)
                now = time.time()
                if now - last_report >= 4.0:
                    pct = (copied / src_size) * 100.0
                    mb_s = (copied / (1024 ** 2)) / max(now - start_t, 0.1)
                    log(
                        f"[CACHE] {progress_prefix}: {src.name} {pct:.1f}% "
                        f"({copied/(1024**3):.1f}/{src_size/(1024**3):.1f} GiB, {mb_s:.0f} MB/s)"
                    )
                    last_report = now
        if tmp_dst.stat().st_size != src_size:
            raise IOError("拷贝完成后字节数不一致")
        os.replace(tmp_dst, dst)
        return True
    except Exception as exc:
        log(f"[CACHE][WARN] 拷贝 {src.name} 中断 ({exc})，将交由下游回退处理。")
        try:
            tmp_dst.unlink(missing_ok=True)
        except OSError:
            pass
        return False


def prefetch_dir_from_drive(drive_candidates: List[Path], local_target: Path, label: str) -> int:
    pulled_count = 0
    for cand in drive_candidates:
        shards = list_valid_shards(cand)
        if not shards:
            continue
        total_gb = sum(sz for _, _, sz in shards) / (1024 ** 3)
        log(f"[CACHE] 在云盘 ({cand}) 发现 {len(shards)} 个 {label} 分片 (共 {total_gb:.1f} GiB)，开始拉取至本地 NVMe...")
        emit_telemetry(phase=f"从云盘拉取 {label} 至本地 NVMe")
        for rel, src_fp, _sz in shards:
            dst_fp = local_target / rel
            if copy_file_stream(src_fp, dst_fp, ".pulling.tmp", f"拉取 {label}"):
                pulled_count += 1
            refresh_disk_metrics()
        break
    if pulled_count == 0 and not list_valid_shards(local_target):
        log(f"[CACHE] 云盘未找到可复用的 {label} 分片，稍后自动回退公网高速下载。")
    return pulled_count


def sync_new_shards_to_drive(local_models_dir: Path) -> None:
    if DRIVE_SAVE_POLICY == "none":
        emit_telemetry(cache_sync_state="disabled", cache_sync_detail="已按设置关闭回存云盘")
        return
    if STORAGE_MODE == "drive_full":
        emit_telemetry(cache_sync_state="done", cache_sync_detail="全量云盘直连模式 (实时落盘)")
        return
    if not DRIVE_MOUNT_ROOT.exists():
        emit_telemetry(cache_sync_state="skipped", cache_sync_detail="未挂载 Google Drive，跳过回存")
        return

    drive_root = Path(DRIVE_CACHE_DIR)
    drive_root.mkdir(parents=True, exist_ok=True)

    tasks: List[Tuple[str, Path, Path, int]] = []
    engram_local = local_models_dir / "Engram-Q6_K"
    if DRIVE_SAVE_POLICY in ("both", "engram_only") and engram_local.exists() and not engram_local.is_symlink():
        for rel, src_fp, sz in list_valid_shards(engram_local):
            dst_fp = drive_root / "Engram-Q6_K" / rel
            if not dst_fp.exists() or dst_fp.stat().st_size != sz:
                tasks.append(("Engram", src_fp, dst_fp, sz))

    if DRIVE_SAVE_POLICY in ("both", "weights_only"):
        for item in sorted(local_models_dir.iterdir()):
            if item.name == "Engram-Q6_K" or item.name in SKIP_SYNC_DIRS or item.is_symlink():
                continue
            if item.is_dir():
                for rel, src_fp, sz in list_valid_shards(item):
                    if any(part in SKIP_SYNC_DIRS for part in rel.parts):
                        continue
                    dst_fp = drive_root / item.name / rel
                    if not dst_fp.exists() or dst_fp.stat().st_size != sz:
                        tasks.append(("主权重", src_fp, dst_fp, sz))

    if not tasks:
        emit_telemetry(cache_sync_state="done", cache_sync_detail="云盘分片已是最新，无需回存")
        log("[CACHE] 云盘缓存检查完毕：所有目标分片均已同步。")
        return

    total_bytes = sum(t[3] for t in tasks)
    log(
        f"[CACHE] 后台启动回存任务：共 {len(tasks)} 个新下载分片 "
        f"({total_bytes/(1024**3):.1f} GiB) 将原子同步至云盘 ({drive_root})..."
    )
    emit_telemetry(
        cache_sync_state="syncing",
        cache_sync_detail=f"正在回存 {len(tasks)} 个分片 ({total_bytes/(1024**3):.1f} GiB)",
    )

    synced = 0
    for idx, (kind, src_fp, dst_fp, _sz) in enumerate(tasks, 1):
        emit_telemetry(
            cache_sync_state="syncing",
            cache_sync_detail=f"[{idx}/{len(tasks)}] 正在回存{kind}: {src_fp.name}",
        )
        if copy_file_stream(src_fp, dst_fp, ".syncing.tmp", f"回存{kind}[{idx}/{len(tasks)}]"):
            synced += 1
        refresh_disk_metrics()

    emit_telemetry(
        cache_sync_state="done",
        cache_sync_detail=f"已完成回存 ({synced}/{len(tasks)} 个新分片写入云盘)",
    )
    log(f"[CACHE] 云盘后台回存全部结束：成功写入 {synced}/{len(tasks)} 个分片。")


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
            if changed:
                cfg_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        except Exception:
            pass


def _hf_headers(extra: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    headers = {"User-Agent": "colabd/0.2"}
    if HF_TOKEN:
        headers["Authorization"] = f"Bearer {HF_TOKEN}"
    if extra:
        headers.update(extra)
    return headers


def download_hf_file(repo: str, filename: str, dst: Path, optional: bool = False) -> Optional[Path]:
    """Download a file from Hugging Face with Range resume and atomic rename."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() and not dst.is_symlink() and dst.stat().st_size > 0:
        log(f"[HF] 命中本地缓存文件，跳过下载: {dst.name} ({dst.stat().st_size / (1024**3):.2f} GiB)")
        return dst

    encoded_path = "/".join(urllib.parse.quote(part, safe="") for part in filename.split("/"))
    url = f"https://huggingface.co/{repo}/resolve/main/{encoded_path}"
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
            log(f"[HF][INFO] 可选伴随文件 {repo}/{filename} 不存在 (HTTP {exc.code})，跳过。")
            return None
        raise RuntimeError(f"下载 {repo}/{filename} 失败 (HTTP {exc.code})") from exc
    except Exception as exc:
        if optional:
            log(f"[HF][WARN] 下载可选文件 {filename} 失败 ({exc})，继续。")
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
            log(f"[HF] 开始下载 {repo}/{filename} ({total / (1024**3):.2f} GiB)...")
        else:
            log(f"[HF] 开始下载 {repo}/{filename} ...")
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


def discover_hf_repo_files(repo: str) -> List[str]:
    url = f"https://huggingface.co/api/models/{repo}"
    req = urllib.request.Request(url, headers=_hf_headers())
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8", errors="replace"))
    siblings = data.get("siblings") or []
    return [str(s["rfilename"]) for s in siblings if isinstance(s, dict) and s.get("rfilename")]


def ensure_hf_model_files(repo: str, model_file: str, extra_files: List[str], target_dir: Path) -> Path:
    """Download required HF files into target_dir and return path to primary model file/dir."""
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
            log("[REMOTE][ERROR] 未检测到挂载的 Google Drive (/content/drive/MyDrive)，无法运行 drive_full 模式。")
            sys.exit(2)
        models_dir = drive_root
        models_dir.mkdir(parents=True, exist_ok=True)
        log(f"[REMOTE] 存储拓扑: 全量云盘直连 ({models_dir})")

    elif STORAGE_MODE == "nvme_engram":
        if is_ds4 and not drive_available:
            local_free_gb = shutil.disk_usage(WORK_DIR if WORK_DIR.exists() else Path("/")).free / (1024 ** 3)
            if local_free_gb < 280.0:
                log(
                    f"[REMOTE][ERROR] nvme_engram 模式依赖 Google Drive 挂载主权重，但未检测到 {DRIVE_MOUNT_ROOT} "
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

            if DRIVE_PREFETCH and drive_available:
                prefetch_dir_from_drive(
                    [
                        drive_root / "Engram-Q6_K",
                        drive_root / "DeepSeek-V4.1-Flash-1017-abliterated-GGUF" / "Engram-Q6_K",
                    ],
                    engram_nvme,
                    "Engram-Q6_K 条件记忆表",
                )

            if model_rel_sub and drive_available:
                drive_weight_dir = drive_root / model_rel_sub
                local_weight_link = models_dir / model_rel_sub
                save_weights = DRIVE_SAVE_POLICY in ("both", "weights_only")
                has_cached_weights = len(list_valid_shards(drive_weight_dir)) > 0

                if save_weights or (DRIVE_PREFETCH and has_cached_weights):
                    ensure_symlink(local_weight_link, drive_weight_dir)
                    if has_cached_weights:
                        log(f"[CACHE] 在云盘命中主权重分片 ({drive_weight_dir})，启动时将直接顺序载入显存+内存。")
                    else:
                        log(f"[CACHE] 云盘暂无主权重缓存，稍后回退下载并将直接持久化保存至云盘 ({drive_weight_dir})。")
        else:
            if DRIVE_PREFETCH and drive_available and model_rel_sub:
                prefetch_dir_from_drive([drive_root / model_rel_sub], models_dir / model_rel_sub, MODEL_PRESET)

        log(f"[REMOTE] 存储拓扑: 反向跨盘 nvme_engram (本地 NVMe={models_dir}, Engram 常驻高速盘)")

    elif STORAGE_MODE == "drive_engram":
        if not drive_available:
            log("[REMOTE][ERROR] 未检测到挂载的 Google Drive，无法运行 drive_engram 模式。")
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
        if DRIVE_PREFETCH and model_rel_sub:
            prefetch_dir_from_drive([drive_root / model_rel_sub], models_dir / model_rel_sub, "主模型权重")
        log(f"[REMOTE] 存储拓扑: 正向跨盘 drive_engram (本地主权重={models_dir}, 云盘软链 Engram={drive_engram})")

    else:
        models_dir = Path(CUSTOM_MODELS_DIR)
        models_dir.mkdir(parents=True, exist_ok=True)
        cleanup_temp_files(models_dir)

        if DRIVE_PREFETCH and drive_available:
            if is_ds4:
                engram_nvme = models_dir / "Engram-Q6_K"
                engram_nvme.mkdir(parents=True, exist_ok=True)
                if is_ds4_ablit:
                    ensure_symlink(
                        models_dir / "DeepSeek-V4.1-Flash-1017-abliterated-GGUF" / "Engram-Q6_K",
                        engram_nvme,
                    )
                prefetch_dir_from_drive(
                    [
                        drive_root / "Engram-Q6_K",
                        drive_root / "DeepSeek-V4.1-Flash-1017-abliterated-GGUF" / "Engram-Q6_K",
                    ],
                    engram_nvme,
                    "Engram-Q6_K 条件记忆表",
                )
            if model_rel_sub:
                prefetch_dir_from_drive([drive_root / model_rel_sub], models_dir / model_rel_sub, "主模型权重")
        log(f"[REMOTE] 存储拓扑: 纯本地高速盘 local_nvme ({models_dir})")

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
            run_checked(["apt-get", "update", "-qq"])
            run_checked(["apt-get", "install", "-y", "-qq"] + missing)

    return models_dir, ram_resident


def start_tunnel() -> None:
    if TUNNEL_MODE == "ssh":
        host_disp = "127.0.0.1" if LOCAL_BIND == "0.0.0.0" else LOCAL_BIND
        emit_telemetry(public_url=f"http://{host_disp}:{MAYA_PORT}")
        log(f"[REMOTE] 隧道模式: Colab 官方 WebSocket SSH -> 本地 http://{host_disp}:{MAYA_PORT}")
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

    log(f"[REMOTE] 正在启动 Cloudflare Quick Tunnel -> http://127.0.0.1:{MAYA_PORT} ...")
    p = subprocess.Popen(
        [str(cf_bin), "tunnel", "--no-autoupdate", "--url", f"http://127.0.0.1:{MAYA_PORT}"],
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


def health_and_sync_poller(models_dir: Path, maya_dir: Path, ram_resident: bool) -> None:
    url = f"http://127.0.0.1:{MAYA_PORT}/health"
    was_healthy = False
    sync_triggered = False
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
            if not sync_triggered:
                sync_triggered = True
                threading.Thread(
                    target=sync_new_shards_to_drive,
                    args=(models_dir,),
                    daemon=True,
                ).start()
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
        str(MAYA_PORT),
        "--api-key",
        MAYA_API_KEY,
        "--yes",
        "--restart",
        "--no-tui",
    ]
    if model_path is not None:
        cmd.extend(["--model-path", str(model_path)])
    if MAYA_DRAFTING == "off":
        cmd.extend(["--drafting", "off"])
    elif MAYA_DRAFTING == "on" and family == "inkling-2-mini":
        cmd.extend(["--drafting", "dspark"])
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
        str(MAYA_PORT),
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
                    f"http://127.0.0.1:{MAYA_PORT}/health",
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
        str(MAYA_PORT),
        "--api-key",
        MAYA_API_KEY,
    ]

    if MAYA_ABLATION in ("on", "off"):
        cmd.extend(["--ablation", MAYA_ABLATION])

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
        emit_telemetry(phase=f"拉取/校验自定义 Hugging Face 权重 ({hf_repo})")
        ensure_hf_model_files(hf_repo, str(maya_spec.get("model_file") or ""), [], local_target)
        custom_model_dir = local_target

    patch_existing_maya_configs(maya_dir, ram_resident)

    env = os.environ.copy()
    env["MAYA_UPDATE_CHECK"] = "0"
    if not WEB_UI:
        env["MAYA_WEB_UI"] = "0"
    if HF_TOKEN:
        env["HF_TOKEN"] = HF_TOKEN

    need_prestart_patch = MAYA_ABLATION == "on" and MAYA_ABLATE_DEFAULT == "on"
    if need_prestart_patch:
        setup_cmd = build_maya_cmd(models_dir, ram_resident, custom_model_dir=custom_model_dir, no_start=True)
        emit_telemetry(phase="校验本地分片 / 编译引擎 / 注入全局去拒绝配置")
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
            str(MAYA_PORT),
            "--api-key",
            MAYA_API_KEY,
        ]
        emit_telemetry(phase="启动 Project Maya 推理服务")
        return _stream_subprocess(serve_cmd, cwd=maya_dir, env=env)

    cmd = build_maya_cmd(models_dir, ram_resident, custom_model_dir=custom_model_dir, no_start=False)
    emit_telemetry(phase="校验本地分片 / 回退下载缺失项 / 编译预热引擎")
    log("[REMOTE] 执行 Project Maya 启动流水线 (命中本地或软链分片将直接通过 SHA256 复用，缺失项自动回退公网下载)...")
    return _stream_subprocess(cmd, cwd=maya_dir, env=env)


def main() -> None:
    models_dir, ram_resident = prepare_storage_and_deps()
    start_tunnel()
    maya_dir = WORK_DIR / "project-maya"
    threading.Thread(
        target=health_and_sync_poller,
        args=(models_dir, maya_dir, ram_resident),
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
