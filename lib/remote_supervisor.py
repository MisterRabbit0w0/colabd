#!/usr/bin/env python3
"""
colabd remote supervisor (executed inside the Google Colab Jupyter kernel via `colab exec`).

Responsibilities:
1. Inspect remote GPU VRAM, system RAM, local NVMe free space, and Google Drive mount state.
2. Prefetch cached model/Engram shards from Google Drive onto local NVMe when enabled.
3. Configure symlink topology (`nvme_engram`, `drive_engram`, `drive_full`, `local_nvme`).
4. Enforce full-RAM expert residency (`--mmap-experts off`) when memory pool permits.
5. Start reverse tunnels (Cloudflare Quick/Named Tunnel) and stream Project Maya logs.
6. Poll `/health` and atomically sync newly downloaded fallback shards back to Google Drive.
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
import urllib.request
from pathlib import Path

# When invoked via session_runner.py, CONFIG is injected above this module.
if "CONFIG" not in globals():
    CONFIG = {
        "model_preset": os.environ.get("COLABD_MODEL_PRESET", "ds4-abliterated-128g"),
        "maya_context": os.environ.get("COLABD_MAYA_CONTEXT", "65536"),
        "maya_drafting": os.environ.get("COLABD_MAYA_DRAFTING", "on"),
        "maya_port": os.environ.get("COLABD_MAYA_PORT", "8080"),
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

MODEL_PRESET = CONFIG["model_preset"]
MAYA_CONTEXT = CONFIG["maya_context"]
MAYA_DRAFTING = CONFIG["maya_drafting"]
MAYA_PORT = int(CONFIG["maya_port"])
STORAGE_MODE = CONFIG["storage_mode"]
DRIVE_PREFETCH = CONFIG["drive_prefetch"] == "1"
DRIVE_SAVE_POLICY = CONFIG["drive_save_policy"]
EXPERT_RAM_POLICY = CONFIG["expert_ram_policy"]
CUSTOM_MODELS_DIR = CONFIG["custom_models_dir"]
DRIVE_CACHE_DIR = CONFIG["drive_cache_dir"]
TUNNEL_MODE = CONFIG["tunnel_mode"]
CF_TUNNEL_TOKEN = CONFIG["cf_tunnel_token"]
CF_PUBLIC_HOSTNAME = CONFIG["cf_public_hostname"]
HF_TOKEN = CONFIG["hf_token"]
MAYA_API_KEY = CONFIG["maya_api_key"]
NO_VISION = CONFIG["no_vision"] == "1"
WEB_UI = CONFIG["web_ui"] == "1"
LOCAL_BIND = CONFIG["local_bind"]

WORK_DIR = Path(os.environ.get("MAYA_WORK_ROOT", "/content"))
DRIVE_MOUNT_ROOT = Path(os.environ.get("MAYA_DRIVE_MOUNT_ROOT", "/content/drive/MyDrive"))

WHOLE_MODEL_MEM_GB = {
    "ds4-abliterated-128g": 128,
    "ds4-abliterated-256g": 256,
    "glm-maya-m-derisked": 140,
    "glm-maya-xs": 84,
    "inkling-2-mini": 24,
}

MODEL_SUBDIRS = {
    "ds4-abliterated-128g": "DeepSeek-V4.1-Flash-1017-abliterated-GGUF/Mix-128G",
    "ds4-abliterated-256g": "DeepSeek-V4.1-Flash-1017-abliterated-GGUF/Mix-256G",
    "glm-maya-m-derisked": "Maya-M-Derisked",
    "glm-maya-xs": "Maya-XS",
    "inkling-2-mini": "Inkling-2-Mini",
}

SHARD_SUFFIXES = {".gguf", ".safetensors", ".bin", ".json", ".txt", ".jinja", ".model"}
TEMP_SUFFIXES = (".tmp", ".part", ".pulling.tmp", ".syncing.tmp")

procs = []
telemetry_lock = threading.Lock()
output_queue = queue.Queue()
_main_thread_id = threading.get_ident()
_main_loop_active = False

TELEMETRY = {
    "phase": "初始化远端环境",
    "gpu": "检测中...",
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


def emit_telemetry(**updates) -> None:
    with telemetry_lock:
        TELEMETRY.update(updates)
        payload = json.dumps(TELEMETRY, ensure_ascii=False)
    _emit_line(f"[TELEMETRY] {payload}\n")


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


def terminate_all(*_args) -> None:
    emit_telemetry(phase="正在关闭进程", api_healthy=False)
    log("\n[REMOTE] 收到终止信号，正在停止隧道与 Project Maya 引擎并清理临时分片...")
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


def run_checked(cmd, **kwargs) -> None:
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


def list_valid_shards(folder: Path):
    if not folder.exists():
        return []
    found = []
    for root, _dirs, files in os.walk(folder, followlinks=False):
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


def prefetch_dir_from_drive(drive_candidates, local_target: Path, label: str) -> int:
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

    tasks = []
    engram_local = local_models_dir / "Engram-Q6_K"
    if DRIVE_SAVE_POLICY in ("both", "engram_only") and engram_local.exists() and not engram_local.is_symlink():
        for rel, src_fp, sz in list_valid_shards(engram_local):
            dst_fp = drive_root / "Engram-Q6_K" / rel
            if not dst_fp.exists() or dst_fp.stat().st_size != sz:
                tasks.append(("Engram", src_fp, dst_fp, sz))

    if DRIVE_SAVE_POLICY in ("both", "weights_only"):
        for item in sorted(local_models_dir.iterdir()):
            if item.name == "Engram-Q6_K" or item.is_symlink():
                continue
            if item.is_dir():
                for rel, src_fp, sz in list_valid_shards(item):
                    if "slots" in rel.parts or "maya-ds4" in rel.parts or "maya-mm3" in rel.parts:
                        continue
                    dst_fp = drive_root / item.name / rel
                    if not dst_fp.exists() or dst_fp.stat().st_size != sz:
                        tasks.append(("主权重", src_fp, dst_fp, sz))

    if not tasks:
        emit_telemetry(cache_sync_state="done", cache_sync_detail="云盘分片已是最新，无需回存")
        log("[CACHE] 云盘缓存检查完毕：所有目标分片均已同步。")
        return

    total_bytes = sum(t[3] for t in tasks)
    log(f"[CACHE] 后台启动回存任务：共 {len(tasks)} 个新下载分片 ({total_bytes/(1024**3):.1f} GiB) 将原子同步至云盘 ({drive_root})...")
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
    if EXPERT_RAM_POLICY == "allow_disk":
        return False
    if EXPERT_RAM_POLICY == "force_ram":
        return True
    needed = WHOLE_MODEL_MEM_GB.get(MODEL_PRESET, 140)
    return (vram_gb + ram_gb) >= needed


def patch_existing_maya_configs(maya_dir: Path, ram_resident: bool) -> None:
    target_flag = "off" if ram_resident else ("on" if EXPERT_RAM_POLICY == "allow_disk" else None)
    if not target_flag:
        return
    for cfg_path in maya_dir.glob("maya-*.json"):
        try:
            data = json.loads(cfg_path.read_text())
            args = data.get("args")
            if isinstance(args, list):
                if "--mmap-experts" in args:
                    i = args.index("--mmap-experts")
                    if i + 1 < len(args):
                        args[i + 1] = target_flag
                else:
                    args.extend(["--mmap-experts", target_flag])
                cfg_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        except Exception:
            pass


def prepare_storage_and_deps():
    gpu_info = "未检测到 NVIDIA GPU"
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
                pretty.append(f"{parts[0]} ({mib/1024.0:.1f} GiB, drv {parts[2]})")
            else:
                pretty.append(ln)
        gpu_info = " | ".join(pretty)
    except Exception:
        pass

    mem_gb = 0.0
    if Path("/proc/meminfo").exists():
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal:"):
                mem_gb = round(int(line.split()[1]) / (1024 * 1024), 1)
                break

    ram_resident = decide_ram_residency(vram_gb, mem_gb)
    emit_telemetry(
        gpu=gpu_info,
        vram_gb=round(vram_gb, 1),
        ram_gb=mem_gb,
        ram_resident_active=ram_resident,
    )
    refresh_disk_metrics()
    log(
        f"[REMOTE] 硬件池: GPU={gpu_info} | 系统内存={mem_gb} GiB | "
        f"总内存池={vram_gb + mem_gb:.1f} GiB | 专家全内存常驻={'开启' if ram_resident else '按需映射'}"
    )

    drive_available = DRIVE_MOUNT_ROOT.exists()
    drive_root = Path(DRIVE_CACHE_DIR)
    if drive_available:
        cleanup_temp_files(drive_root)

    is_ds4 = MODEL_PRESET in ("ds4-abliterated-128g", "ds4-abliterated-256g")
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
        if is_ds4:
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
        missing = []
        for binary, pkg in [
            ("git", "git"),
            ("cmake", "cmake"),
            ("g++", "build-essential"),
            ("curl", "curl"),
        ]:
            if not shutil.which(binary):
                missing.append(pkg)
        if missing:
            emit_telemetry(phase="安装系统编译依赖")
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
    while True:
        time.sleep(8)
        refresh_disk_metrics()
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {MAYA_API_KEY}"})
        try:
            with urllib.request.urlopen(req, timeout=3) as resp:
                ok = 200 <= resp.status < 300
        except Exception:
            ok = False
        if ok and not was_healthy:
            was_healthy = True
            patch_existing_maya_configs(maya_dir, ram_resident)
            emit_telemetry(api_healthy=True, phase="在线服务中 (Ready)")
            log("\n[REMOTE] >>> Project Maya 推理引擎已就绪，可开始接收 API 请求！ <<<\n")
            if not sync_triggered:
                sync_triggered = True
                threading.Thread(
                    target=sync_new_shards_to_drive,
                    args=(models_dir,),
                    daemon=True,
                ).start()
        elif not ok and was_healthy:
            was_healthy = False
            emit_telemetry(api_healthy=False, phase="引擎重载或忙碌中")


def run_maya(models_dir: Path, ram_resident: bool) -> int:
    maya_dir = WORK_DIR / "project-maya"
    if not (maya_dir / ".git").exists():
        emit_telemetry(phase="克隆 mw00/project-maya 仓库")
        run_checked(
            ["git", "clone", "--depth", "1", "https://github.com/mw00/project-maya.git", str(maya_dir)]
        )

    patch_existing_maya_configs(maya_dir, ram_resident)

    env = os.environ.copy()
    env["MAYA_UPDATE_CHECK"] = "0"
    if not WEB_UI:
        env["MAYA_WEB_UI"] = "0"
    if HF_TOKEN:
        env["HF_TOKEN"] = HF_TOKEN

    cmd = [
        "./maya.sh",
        "--setup",
        "--yes",
        "--plain",
        "--download-model",
        "--drafting", MAYA_DRAFTING,
        "--models-dir", str(models_dir),
        "--context", str(MAYA_CONTEXT),
        "--host", "127.0.0.1",
        "--port", str(MAYA_PORT),
        "--api-key", MAYA_API_KEY,
    ]

    if ram_resident:
        if MODEL_PRESET.startswith("ds4-"):
            cmd.extend(["--env", "DS4_REQUIRE_ALL_RAM=1"])
        elif MODEL_PRESET.startswith("glm-"):
            cmd.extend(["--env", "MAYA_GLM_RAM_RESIDENT=1"])
    elif EXPERT_RAM_POLICY == "allow_disk":
        if MODEL_PRESET.startswith("ds4-"):
            cmd.extend(["--env", "DS4_REQUIRE_ALL_RAM=0"])
        elif MODEL_PRESET.startswith("glm-"):
            cmd.extend(["--env", "MAYA_GLM_RAM_RESIDENT=0"])

    if MODEL_PRESET == "ds4-abliterated-128g":
        cmd.extend(["--model", "DeepSeek-V4.1-Flash-1017", "--ds4-quant", "abliterated-128g"])
    elif MODEL_PRESET == "ds4-abliterated-256g":
        cmd.extend(["--model", "DeepSeek-V4.1-Flash-1017", "--ds4-quant", "abliterated-256g"])
    else:
        cmd.extend(["--model", MODEL_PRESET])

    if NO_VISION:
        cmd.append("--no-vision")

    emit_telemetry(phase="校验本地分片 / 回退下载缺失项 / 编译预热引擎")
    log("[REMOTE] 执行 Project Maya 启动流水线 (命中本地或软链分片将直接通过 SHA256 复用，缺失项自动回退公网下载)...")
    p = subprocess.Popen(
        cmd,
        cwd=str(maya_dir),
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

    def forward_maya() -> None:
        assert p.stdout is not None
        for line in p.stdout:
            output_queue.put(line)
        output_queue.put(None)

    threading.Thread(target=forward_maya, daemon=True).start()

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


def main() -> None:
    models_dir, ram_resident = prepare_storage_and_deps()
    start_tunnel()
    maya_dir = WORK_DIR / "project-maya"
    threading.Thread(
        target=health_and_sync_poller,
        args=(models_dir, maya_dir, ram_resident),
        daemon=True,
    ).start()
    rc = run_maya(models_dir, ram_resident)
    emit_telemetry(phase=f"进程已退出 (code={rc})", api_healthy=False)
    sys.exit(rc)


if __name__ == "__main__":
    main()
