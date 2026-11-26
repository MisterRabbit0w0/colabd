#!/usr/bin/env bash
# ==============================================================================
# colabd - Remote VM lifecycle, storage preflight, tunnel orchestration, cleanup
# ==============================================================================

stop_local_daemons() {
  if [[ -n "$SSH_PID" ]] && kill -0 "$SSH_PID" 2>/dev/null; then
    kill "$SSH_PID" 2>/dev/null || true
    wait "$SSH_PID" 2>/dev/null || true
  fi
  SSH_PID=""

  if [[ -n "$EXEC_PID" ]] && kill -0 "$EXEC_PID" 2>/dev/null; then
    kill "$EXEC_PID" 2>/dev/null || true
    wait "$EXEC_PID" 2>/dev/null || true
  fi
  EXEC_PID=""
}

stop_colab_instance() {
  local target="${ACTIVE_SESSION_NAME:-$SESSION_NAME}"
  stop_local_daemons
  if command -v colab >/dev/null 2>&1; then
    if [[ "$MANAGED_SESSION" -eq 1 ]] || ( [[ "$AUTH_STATE" == "ok" ]] && colab_cli status -s "$target" >/dev/null 2>&1 ); then
      echo "${C_YELLOW}[回收] 正在执行 colab --auth ${COLAB_AUTH_MODE} stop -s ${target} 销毁远端实例并释放算力...${C_RESET}"
      colab_cli stop -s "$target" >/dev/null 2>&1 || colab_cli stop -s "$target" || true
      echo "${C_GREEN}[回收] Colab 实例 '${target}' 已销毁。${C_RESET}"
    fi
  fi
  MANAGED_SESSION=0
  ACTIVE_SESSION_NAME=""
}

CLEANED_UP=0
cleanup_on_exit() {
  local code=$?
  if [[ "$CLEANED_UP" -eq 1 ]]; then
    return
  fi
  CLEANED_UP=1
  if [[ "${COLABD_SKIP_AUTO_STOP:-0}" != "1" ]]; then
    echo ""
    stop_colab_instance
  fi
  rm -rf "$STATE_DIR"
  exit "$code"
}

build_remote_runner() {
  local effective_storage="$1"
  python3 - \
    "$MODEL_PRESET" "$MAYA_CONTEXT" "$MAYA_DRAFTING" "$MAYA_PORT" \
    "$effective_storage" "$DRIVE_PREFETCH" "$DRIVE_SAVE_POLICY" "$EXPERT_RAM_POLICY" \
    "$CUSTOM_MODELS_DIR" "$DRIVE_CACHE_DIR" \
    "$TUNNEL_MODE" "$CF_TUNNEL_TOKEN" "$CF_PUBLIC_HOSTNAME" \
    "$HF_TOKEN" "$MAYA_API_KEY" "$NO_VISION" "$WEB_UI" "$LOCAL_BIND" \
    > "$RUNNER_PY" <<'PYCFG'
import sys

keys = [
    "model_preset", "maya_context", "maya_drafting", "maya_port",
    "storage_mode", "drive_prefetch", "drive_save_policy", "expert_ram_policy",
    "custom_models_dir", "drive_cache_dir",
    "tunnel_mode", "cf_tunnel_token", "cf_public_hostname",
    "hf_token", "maya_api_key", "no_vision", "web_ui", "local_bind",
]
cfg = dict(zip(keys, sys.argv[1:]))
print(f"CONFIG = {repr(cfg)}\n")
PYCFG

  cat "${COLABD_LIB_DIR}/remote_supervisor.py" >> "$RUNNER_PY"
}

probe_remote_local_free_gb() {
  local sess="$1"
  echo 'import shutil; print(int(shutil.disk_usage("/content").free // (1024**3)))' \
    | colab_cli exec -s "$sess" 2>/dev/null \
    | tr -d '\r' \
    | grep -E '^[0-9]+$' \
    | tail -n 1
}

action_start_or_restart() {
  if ! ensure_cli_and_authenticated; then
    read -r -p "按回车返回主菜单..." _
    return
  fi

  if model_requires_hf_token "$MODEL_PRESET" && [[ -z "$HF_TOKEN" ]]; then
    echo ""
    echo "${C_YELLOW}[提示] 当前选择的 '${MODEL_PRESET}' 来自受限仓库 (orcarouter Abliterated GGUF)。${C_RESET}"
    echo "请先确保已在浏览器同意协议: https://huggingface.co/orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF"
    read -r -s -p "请输入你的 Hugging Face Token (hf_...，直接回车取消启动): " input_hf
    echo ""
    if [[ -z "$input_hf" ]]; then
      echo "${C_RED}[取消] 未提供 HF_TOKEN，已取消启动。${C_RESET}"
      sleep 1
      return
    fi
    HF_TOKEN="$input_hf"
    save_config
    echo "${C_GREEN}[已保存] HF_TOKEN 已按 600 权限写入 ${CONFIG_FILE}${C_RESET}"
  fi

  if [[ "$TUNNEL_MODE" == "cf_named" && -z "$CF_TUNNEL_TOKEN" ]]; then
    echo "${C_YELLOW}[提示] 当前为 Cloudflare 固定域名模式，但尚未设置 CF_TUNNEL_TOKEN。${C_RESET}"
    read -r -s -p "请输入 Cloudflare Tunnel Token (直接回车取消): " input_cf
    echo ""
    [[ -z "$input_cf" ]] && return
    CF_TUNNEL_TOKEN="$input_cf"
    save_config
  fi

  if is_bg_running; then
    echo "${C_YELLOW}[信息] 正在停止当前后台守护连接以执行重启...${C_RESET}"
    stop_local_daemons
  fi

  ACTIVE_SESSION_NAME="$SESSION_NAME"
  MANAGED_SESSION=1
  if colab_cli status -s "$SESSION_NAME" >/dev/null 2>&1; then
    echo "${C_GREEN}[会话] 复用已活跃的 Colab 实例: ${SESSION_NAME}${C_RESET}"
  else
    local new_args=(new -s "$SESSION_NAME" --gpu "$GPU_TYPE")
    [[ "$HIGH_MEM" == "1" ]] && new_args+=(--high-mem)
    echo "${C_CYAN}[分配] 正在申请 Colab GPU 实例: colab --auth ${COLAB_AUTH_MODE} ${new_args[*]} ...${C_RESET}"
    if ! colab_cli "${new_args[@]}"; then
      echo "${C_RED}[失败] Colab 实例分配失败（可能是当前 GPU 规格库存紧张或配额不足）。${C_RESET}"
      MANAGED_SESSION=0
      ACTIVE_SESSION_NAME=""
      read -r -p "按回车返回主菜单..." _
      return
    fi
  fi

  if [[ "$AUTO_GCP_AUTH" == "1" ]]; then
    echo "${C_CYAN}[GCP 授权] 正在向远端实例注入 GCP 服务凭证 (colab auth -s ${SESSION_NAME})...${C_RESET}"
    colab_cli auth -s "$SESSION_NAME" || echo "${C_YELLOW}[警告] colab auth 未成功，继续后续流程。${C_RESET}"
  fi

  local effective_storage="$STORAGE_MODE"
  local total_needed
  total_needed="$(model_total_gb "$MODEL_PRESET")"

  if [[ "$effective_storage" == "auto" ]]; then
    echo "${C_CYAN}[预检] 正在探测远端 /content 磁盘剩余容量...${C_RESET}"
    local free_gb
    free_gb="$(probe_remote_local_free_gb "$SESSION_NAME")"
    free_gb="${free_gb:-0}"

    if [[ "$free_gb" -ge "$total_needed" ]]; then
      echo "${C_GREEN}[预检] 本地 /content 剩余约 ${free_gb} GiB (满足完整 ${total_needed} GiB)，选用纯本地高速盘模式 (local_nvme)。${C_RESET}"
      effective_storage="local_nvme"
    elif model_has_engram "$MODEL_PRESET" && [[ "$free_gb" -ge 175 ]]; then
      echo ""
      echo "${C_YELLOW}[空间检测] 本地 /content 剩余约 ${free_gb} GiB (小于完整 ${total_needed} GiB，但足以放 161GB Engram 表)。${C_RESET}"
      echo "请选择本次跨盘与缓存运行方案:"
      echo "  1) 【反向跨盘 nvme_engram】(推荐: 先去云盘找 Engram 拉到本地 NVMe 跑，主权重挂云盘全载入内存，推理零网盘 I/O)"
      echo "  2) 【正向跨盘 drive_engram】(主权重放本地 NVMe，161GB Engram 软链在云盘上按需查表)"
      echo "  3) 【全量云盘 drive_full】  (所有文件均在 ${DRIVE_CACHE_DIR} 上读写)"
      echo "  4) 改跑无需外挂表的【GLM-5.3-Flash Maya-M-Derisked 去拒绝版】(约 116GB，本地盘直跑)"
      echo "  0) 取消启动并立即回收实例"
      read -r -p "请输入选项 [1]: " disk_choice
      disk_choice="${disk_choice:-1}"
      case "$disk_choice" in
        1) effective_storage="nvme_engram";  STORAGE_MODE="nvme_engram";  save_config ;;
        2) effective_storage="drive_engram"; STORAGE_MODE="drive_engram"; save_config ;;
        3) effective_storage="drive_full";   STORAGE_MODE="drive_full";   save_config ;;
        4) MODEL_PRESET="glm-maya-m-derisked"; effective_storage="local_nvme"; save_config ;;
        0) stop_colab_instance; return ;;
        *) effective_storage="nvme_engram" ;;
      esac
    else
      echo "${C_YELLOW}[空间预警] 本地 /content 仅剩 ${free_gb} GiB，切换至全量云盘模式 (drive_full)。${C_RESET}"
      effective_storage="drive_full"
    fi
  fi

  local need_drive=0
  if [[ "$effective_storage" == "nvme_engram" || "$effective_storage" == "drive_engram" || "$effective_storage" == "drive_full" ]]; then
    need_drive=1
  elif [[ "$DRIVE_PREFETCH" == "1" || "$DRIVE_SAVE_POLICY" != "none" ]]; then
    need_drive=1
  fi

  if [[ "$need_drive" -eq 1 ]]; then
    echo "${C_CYAN}[挂载] 正在挂载 Google Drive 至远端 /content/drive (用于查找缓存分片与按策略回存)...${C_RESET}"
    if ! colab_cli drivemount -s "$SESSION_NAME"; then
      if [[ "$effective_storage" == "local_nvme" ]]; then
        echo "${C_YELLOW}[警告] Google Drive 挂载未成功，将在纯本地模式下直接走公网回退下载。${C_RESET}"
      else
        echo "${C_RED}[错误] 当前存储拓扑 (${effective_storage}) 依赖 Google Drive，挂载失败已中止。${C_RESET}"
        read -r -p "按回车返回主菜单..." _
        return
      fi
    fi
  fi

  if [[ "$TUNNEL_MODE" == "ssh" ]]; then
    if ! command -v ssh >/dev/null 2>&1; then
      echo "${C_RED}[错误] 本机缺少 OpenSSH (ssh) 客户端，无法建立本地转发。${C_RESET}"
      read -r -p "按回车返回主菜单..." _
      return
    fi
    local ssh_key="${HOME}/.ssh/id_ed25519"
    if [[ ! -f "$ssh_key" && ! -f "${HOME}/.ssh/id_ecdsa" ]]; then
      echo "${C_CYAN}[SSH] 正在自动生成 Colab 支持的 Ed25519 密钥 (${ssh_key})...${C_RESET}"
      mkdir -p "${HOME}/.ssh"
      ssh-keygen -t ed25519 -N "" -f "$ssh_key" >/dev/null
    fi
    local colab_bin
    colab_bin="$(command -v colab)"
    : > "$SSH_LOG"
    ssh \
      -o "ProxyCommand=${colab_bin} --auth ${COLAB_AUTH_MODE} ssh --proxy-mode -s ${SESSION_NAME}" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ServerAliveInterval=30 \
      -N -L "${LOCAL_BIND}:${MAYA_PORT}:127.0.0.1:${MAYA_PORT}" \
      root@colab >"$SSH_LOG" 2>&1 &
    SSH_PID=$!
  fi

  build_remote_runner "$effective_storage"
  : > "$REMOTE_LOG"
  colab_cli exec -s "$SESSION_NAME" -f "$RUNNER_PY" >>"$REMOTE_LOG" 2>&1 &
  EXEC_PID=$!

  echo "${C_GREEN}[已启动] 后台守护进程已运行 (PID: ${EXEC_PID})，正在执行云盘分片检索与隧道初始化...${C_RESET}"
  local waited=0
  while [[ $waited -lt 15 ]]; do
    local ep
    ep="$(resolve_current_endpoint)"
    if [[ -n "$ep" ]]; then
      echo "${C_BOLD}${C_GREEN}[就绪入口] ${ep}${C_RESET} (分片拉取/下载与编译进度可在菜单 [3] 实时查看)"
      break
    fi
    if ! is_bg_running; then
      echo "${C_RED}[异常] 远端守护进程提前退出，请进入菜单 [3] 查看错误日志。${C_RESET}"
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  sleep 1
}
