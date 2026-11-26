#!/usr/bin/env bash
# ==============================================================================
# colabd - Remote VM lifecycle, account-aware release guards, tunnel orchestration
# Compatible with Bash 3.2+ (macOS and Linux)
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

_collect_sessions_for_account_cb() {
  local acct="$1"
  local mode="$2"
  local out_tracked="$3"
  local out_orphans="$4"

  : > "$out_tracked"
  : > "$out_orphans"

  local sess_cfg
  sess_cfg="$(colab_session_config_path "$acct")"

  local local_rows=""
  local_rows="$(account_store sessions-list "$sess_cfg" 2>/dev/null || true)"

  local live_out=""
  if resolve_colab_bin >/dev/null 2>&1; then
    live_out="$(probe_colab_command "$mode" "$acct" 6 sessions 2>/dev/null || true)"
  fi

  local managed_name=""
  if [[ "$MANAGED_SESSION" -eq 1 && "$ACTIVE_SESSION_HAS_OWNER" -eq 1 && "$ACTIVE_SESSION_ACCOUNT" == "$acct" && "$ACTIVE_SESSION_AUTH_MODE" == "$mode" ]]; then
    managed_name="${ACTIVE_SESSION_NAME:-$SESSION_NAME}"
  fi

  local host_py=""
  host_py="$(resolve_host_python 2>/dev/null || command -v python3 2>/dev/null || true)"
  if [[ -z "$host_py" ]]; then
    return 1
  fi

  "$host_py" - "$local_rows" "$live_out" "$managed_name" "$out_tracked" "$out_orphans" <<'PY'
import pathlib, re, sys

local_rows, live_out, managed_name, out_tracked, out_orphans = sys.argv[1:6]
tracked = {}
orphans = {}

for line in local_rows.splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    name = parts[0].strip()
    accel = parts[1].strip() if len(parts) > 1 else "NONE"
    shape = parts[2].strip() if len(parts) > 2 else "STANDARD"
    ep = parts[3].strip() if len(parts) > 3 else ""
    if name:
        tracked[name] = f"[{name}] {ep} | Hardware: {accel} | Shape: {shape} (本地会话记录)"

for line in live_out.splitlines():
    m = re.match(r"^\s*\[([^\]]+)\]\s+(\S+)(.*)$", line)
    if not m:
        continue
    name, ep, rest = m.group(1).strip(), m.group(2).strip(), m.group(3).strip()
    if name == "?":
        orphans[ep] = line.strip()
    else:
        tracked[name] = line.strip()

if managed_name and managed_name not in tracked:
    tracked[managed_name] = f"[{managed_name}] (当前 colabd 托管会话)"

pathlib.Path(out_tracked).write_text(
    "".join(f"{k}\t{v}\n" for k, v in sorted(tracked.items())),
    encoding="utf-8",
)
pathlib.Path(out_orphans).write_text(
    "".join(f"{k}\t{v}\n" for k, v in sorted(orphans.items())),
    encoding="utf-8",
)
PY
}

_release_sessions_for_account_cb() {
  local acct="$1"
  local mode="$2"
  local specific_session="${3:-}"
  local include_orphans="${4:-0}"

  local is_managed_owner=0
  if [[ "$ACTIVE_SESSION_HAS_OWNER" -eq 1 && "$ACTIVE_SESSION_ACCOUNT" == "$acct" && "$ACTIVE_SESSION_AUTH_MODE" == "$mode" ]]; then
    is_managed_owner=1
  elif [[ "$ACTIVE_SESSION_HAS_OWNER" -eq 0 && "$acct" == "$ACTIVE_ACCOUNT" && "$mode" == "$COLAB_AUTH_MODE" ]]; then
    is_managed_owner=1
  fi

  if [[ "$is_managed_owner" -eq 1 ]]; then
    stop_local_daemons
  fi

  if ! resolve_colab_bin >/dev/null 2>&1; then
    return 0
  fi

  local tmp_tracked="${STATE_DIR}/rel_tracked.$$"
  local tmp_orphans="${STATE_DIR}/rel_orphans.$$"
  _collect_sessions_for_account_cb "$acct" "$mode" "$tmp_tracked" "$tmp_orphans"

  local email=""
  if [[ -n "$acct" ]]; then
    email="$(account_store meta-get "$ACCOUNTS_DIR" "$acct" email 2>/dev/null || true)"
  elif [[ "$acct" == "$ACTIVE_ACCOUNT" ]]; then
    email="$AUTH_EMAIL"
  fi
  local label
  label="$(format_account_label "$acct" "$mode" "$email")"

  local failed=0

  if [[ -n "$specific_session" ]]; then
    echo "${C_YELLOW}[回收] 正在释放账号 '${label}' 的实例 '${specific_session}' (colab stop -s ${specific_session})...${C_RESET}"
    if colab_cli_for "$mode" "$acct" stop -s "$specific_session" >/dev/null 2>&1 || colab_cli_for "$mode" "$acct" stop -s "$specific_session"; then
      echo "${C_GREEN}[回收] 账号 '${label}' 的实例 '${specific_session}' 已销毁。${C_RESET}"
      if [[ "$is_managed_owner" -eq 1 && "${ACTIVE_SESSION_NAME:-$SESSION_NAME}" == "$specific_session" ]]; then
        MANAGED_SESSION=0
        ACTIVE_SESSION_NAME=""
        ACTIVE_SESSION_ACCOUNT=""
        ACTIVE_SESSION_AUTH_MODE=""
        ACTIVE_SESSION_HAS_OWNER=0
      fi
    else
      echo "${C_RED}[警告] 释放账号 '${label}' 的实例 '${specific_session}' 未返回成功，请留意 Colab 控制台。${C_RESET}"
      failed=$((failed + 1))
    fi
  else
    local sname
    while IFS=$'\t' read -r sname _; do
      [[ -z "$sname" ]] && continue
      echo "${C_YELLOW}[回收] 正在释放账号 '${label}' 的实例 '${sname}' (colab stop -s ${sname})...${C_RESET}"
      if colab_cli_for "$mode" "$acct" stop -s "$sname" >/dev/null 2>&1 || colab_cli_for "$mode" "$acct" stop -s "$sname"; then
        echo "${C_GREEN}[回收] 账号 '${label}' 的实例 '${sname}' 已销毁。${C_RESET}"
      else
        echo "${C_RED}[警告] 释放账号 '${label}' 的实例 '${sname}' 失败，请确认凭证或手动停止。${C_RESET}"
        failed=$((failed + 1))
      fi
    done < "$tmp_tracked"

    if [[ "$is_managed_owner" -eq 1 ]]; then
      MANAGED_SESSION=0
      ACTIVE_SESSION_NAME=""
      ACTIVE_SESSION_ACCOUNT=""
      ACTIVE_SESSION_AUTH_MODE=""
      ACTIVE_SESSION_HAS_OWNER=0
    fi
  fi

  if [[ "$include_orphans" == "1" && -s "$tmp_orphans" ]]; then
    local adc_arg=""
    if [[ "$mode" == "adc" && -n "$acct" && -f "${ACCOUNTS_DIR}/${acct}/adc.json" ]]; then
      adc_arg="${ACCOUNTS_DIR}/${acct}/adc.json"
    fi
    local ep
    while IFS=$'\t' read -r ep _; do
      [[ -z "$ep" ]] && continue
      echo "${C_YELLOW}[强行回收] 正在释放账号 '${label}' 的未纳管远端实例 ${ep} ...${C_RESET}"
      if [[ -n "$adc_arg" ]]; then
        if account_store unassign-orphan "$mode" "$ep" --adc-file "$adc_arg"; then
          echo "${C_GREEN}[已回收] 远端实例 ${ep} 已销毁。${C_RESET}"
        else
          echo "${C_RED}[失败] 无法回收未纳管实例 ${ep}。${C_RESET}"
          failed=$((failed + 1))
        fi
      else
        if account_store unassign-orphan "$mode" "$ep"; then
          echo "${C_GREEN}[已回收] 远端实例 ${ep} 已销毁。${C_RESET}"
        else
          echo "${C_RED}[失败] 无法回收未纳管实例 ${ep}。${C_RESET}"
          failed=$((failed + 1))
        fi
      fi
    done < "$tmp_orphans"
  fi

  rm -f "$tmp_tracked" "$tmp_orphans"
  [[ "$failed" -eq 0 ]]
}

guard_release_before_account_change() {
  local reason="${1:-切换账号}"
  local target_acct_override="${2:-}"
  local auto_mode="${3:-prompt}"
  local is_destructive="${4:-0}"

  LAST_GUARD_KEPT_REMOTE=0

  local check_acct="$ACTIVE_ACCOUNT"
  local check_mode="$COLAB_AUTH_MODE"
  local check_email="$AUTH_EMAIL"
  local checking_current=1

  if [[ -n "$target_acct_override" ]]; then
    check_acct="$target_acct_override"
    check_mode="$(account_store meta-get "$ACCOUNTS_DIR" "$check_acct" auth_mode 2>/dev/null || echo "oauth2")"
    check_email="$(account_store meta-get "$ACCOUNTS_DIR" "$check_acct" email 2>/dev/null || true)"
    if [[ "$check_acct" != "$ACTIVE_ACCOUNT" ]]; then
      checking_current=0
    fi
  fi

  local tmp_tracked="${STATE_DIR}/guard_tracked.$$"
  local tmp_orphans="${STATE_DIR}/guard_orphans.$$"
  : > "$tmp_tracked"
  : > "$tmp_orphans"

  run_with_account_creds "$check_acct" "$check_mode" _collect_sessions_for_account_cb "$tmp_tracked" "$tmp_orphans" || true

  local has_tracked=0
  local has_orphans=0
  [[ -s "$tmp_tracked" ]] && has_tracked=1
  [[ -s "$tmp_orphans" ]] && has_orphans=1

  local has_local_bg=0
  if [[ "$checking_current" -eq 1 ]] && is_bg_running; then
    has_local_bg=1
  fi

  if [[ "$has_tracked" -eq 0 && "$has_orphans" -eq 0 && "$has_local_bg" -eq 0 ]]; then
    rm -f "$tmp_tracked" "$tmp_orphans"
    return 0
  fi

  local label
  label="$(format_account_label "$check_acct" "$check_mode" "$check_email")"
  echo ""
  echo "${C_YELLOW}[防扣费保护] 执行【${reason}】前，检测到账号 '${label}' 存在活跃 Colab 实例：${C_RESET}"

  if [[ "$has_tracked" -eq 1 ]]; then
    local desc
    while IFS=$'\t' read -r _ desc; do
      [[ -z "$desc" ]] && continue
      echo "  • ${desc}"
    done < "$tmp_tracked"
  fi
  if [[ "$has_orphans" -eq 1 ]]; then
    echo "  ${C_YELLOW}(以下为服务端未纳管 [?] 实例，可能是网页端 Notebook 或其他终端创建):${C_RESET}"
    local odesc
    while IFS=$'\t' read -r _ odesc; do
      [[ -z "$odesc" ]] && continue
      echo "  • ${odesc}"
    done < "$tmp_orphans"
  fi

  if [[ "$checking_current" -eq 1 && "$(read_telemetry_field cache_sync_state)" == "syncing" ]]; then
    echo "${C_YELLOW}[注意] 后台正在回存新下载的模型分片至 Google Drive ($(read_telemetry_field cache_sync_detail))。${C_RESET}"
  fi

  local decision=""
  case "$auto_mode" in
    release) decision="1" ;;
    keep)    decision="3" ;;
    *)
      echo ""
      echo "请选择处理方式:"
      echo "  1) 立即释放上述活跃实例并继续 (推荐，自动执行 colab stop 防止漏扣费)"
      echo "  2) 取消本次操作 (保留当前实例继续运行)"
      if [[ "$is_destructive" == "1" ]]; then
        echo "  3) 不释放远端实例仍强行继续 (${C_RED}高风险：清理/删除凭证后无法直接用 colabd 释放该实例${C_RESET})"
      else
        echo "  3) 暂不释放远端实例，仅切号 (风险：旧账号实例将继续扣费；后续可用 colabd down --all 释放)"
      fi
      read -r -p "请选择 [1]: " decision
      decision="${decision:-1}"
      ;;
  esac

  case "$decision" in
    1|y|Y)
      if [[ "$has_tracked" -eq 1 || "$has_local_bg" -eq 1 ]]; then
        run_with_account_creds "$check_acct" "$check_mode" _release_sessions_for_account_cb "" "0" || true
      fi
      if [[ "$has_orphans" -eq 1 ]]; then
        if [[ "$auto_mode" == "prompt" ]]; then
          read -r -p "是否同时强行回收上述未纳管的 [?] 远端实例? [y/N]: " orph_yn
          if [[ "${orph_yn:-N}" =~ ^[Yy]$ ]]; then
            run_with_account_creds "$check_acct" "$check_mode" _release_sessions_for_account_cb "" "1" || true
          else
            echo "${C_YELLOW}[提醒] 已保留未纳管 [?] 实例，如不再需要请及时在 Colab 网页端关闭。${C_RESET}"
          fi
        else
          echo "${C_YELLOW}[提醒] 检测到未纳管 [?] 远端实例，未自动强制销毁（以免误关网页端 Notebook）。${C_RESET}"
        fi
      fi
      rm -f "$tmp_tracked" "$tmp_orphans"
      return 0
      ;;
    3|k|K)
      if [[ "$checking_current" -eq 1 ]]; then
        stop_local_daemons
        MANAGED_SESSION=0
        ACTIVE_SESSION_NAME=""
        ACTIVE_SESSION_ACCOUNT=""
        ACTIVE_SESSION_AUTH_MODE=""
        ACTIVE_SESSION_HAS_OWNER=0
      fi
      LAST_GUARD_KEPT_REMOTE=1
      echo "${C_YELLOW}[风险提示] 已跳过远端实例释放，旧账号 '${label}' 的实例可能仍在计费。${C_RESET}"
      if [[ -n "$check_acct" && "$is_destructive" != "1" ]]; then
        echo "${C_YELLOW}           可随时执行 'colabd down -a ${check_acct}' 或 'colabd down --all' 统一释放。${C_RESET}"
      fi
      rm -f "$tmp_tracked" "$tmp_orphans"
      return 0
      ;;
    *)
      echo "${C_GREEN}[已取消] 保留当前活跃实例，未更改账号状态。${C_RESET}"
      rm -f "$tmp_tracked" "$tmp_orphans"
      return 1
      ;;
  esac
}

stop_colab_instance() {
  local target_acct_override="${1:-}"
  local target_session_override="${2:-}"

  local owner_acct="$ACTIVE_ACCOUNT"
  local owner_mode="$COLAB_AUTH_MODE"
  local use_managed_owner=0

  if [[ -n "$target_acct_override" ]]; then
    if ! account_store exists "$ACCOUNTS_DIR" "$target_acct_override" >/dev/null 2>&1; then
      echo "${C_RED}[错误] 未找到账号槽位 '${target_acct_override}'。${C_RESET}"
      return 1
    fi
    owner_acct="$target_acct_override"
    owner_mode="$(account_store meta-get "$ACCOUNTS_DIR" "$owner_acct" auth_mode 2>/dev/null || echo "oauth2")"
  elif [[ "$ACTIVE_SESSION_HAS_OWNER" -eq 1 ]]; then
    owner_acct="$ACTIVE_SESSION_ACCOUNT"
    owner_mode="$ACTIVE_SESSION_AUTH_MODE"
    use_managed_owner=1
  fi

  if [[ -z "$target_acct_override" || "$owner_acct" == "$ACTIVE_SESSION_ACCOUNT" ]]; then
    stop_local_daemons
  fi

  if ! resolve_colab_bin >/dev/null 2>&1; then
    MANAGED_SESSION=0
    ACTIVE_SESSION_NAME=""
    ACTIVE_SESSION_ACCOUNT=""
    ACTIVE_SESSION_AUTH_MODE=""
    ACTIVE_SESSION_HAS_OWNER=0
    return 0
  fi

  if [[ -n "$target_session_override" ]]; then
    run_with_account_creds "$owner_acct" "$owner_mode" _release_sessions_for_account_cb "$target_session_override" "0" || true
    return 0
  fi

  if [[ -n "$target_acct_override" ]]; then
    run_with_account_creds "$owner_acct" "$owner_mode" _release_sessions_for_account_cb "" "0" || true
    return 0
  fi

  local target="${ACTIVE_SESSION_NAME:-$SESSION_NAME}"
  local sess_cfg
  sess_cfg="$(colab_session_config_path "$owner_acct")"
  local has_local_sessions=""
  has_local_sessions="$(account_store sessions-list "$sess_cfg" 2>/dev/null || true)"

  if [[ "$MANAGED_SESSION" -eq 1 || "$use_managed_owner" -eq 1 ]]; then
    run_with_account_creds "$owner_acct" "$owner_mode" _release_sessions_for_account_cb "$target" "0" || true
  elif [[ -n "$has_local_sessions" ]]; then
    run_with_account_creds "$owner_acct" "$owner_mode" _release_sessions_for_account_cb "" "0" || true
  elif [[ "$AUTH_STATE" == "ok" ]] && colab_cli_for "$owner_mode" "$owner_acct" status -s "$target" >/dev/null 2>&1; then
    run_with_account_creds "$owner_acct" "$owner_mode" _release_sessions_for_account_cb "$target" "0" || true
  fi

  MANAGED_SESSION=0
  ACTIVE_SESSION_NAME=""
  ACTIVE_SESSION_ACCOUNT=""
  ACTIVE_SESSION_AUTH_MODE=""
  ACTIVE_SESSION_HAS_OWNER=0
  return 0
}

find_other_accounts_with_local_sessions() {
  local rows=""
  rows="$(account_store list "$ACCOUNTS_DIR" 2>/dev/null || true)"
  [[ -z "$rows" ]] && return 1

  local found=""
  local name scount snames
  while IFS=$'\t' read -r name _ _ _ scount snames _; do
    [[ -z "$name" ]] && continue
    if [[ "$name" != "$ACTIVE_ACCOUNT" && "${scount:-0}" -gt 0 ]]; then
      if [[ -n "$found" ]]; then
        found="${found}, ${name}:${snames}"
      else
        found="${name}:${snames}"
      fi
    fi
  done <<< "$rows"

  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi
  return 1
}

release_all_accounts_runtimes() {
  local interactive_orphans="${1:-0}"
  if ! resolve_colab_bin >/dev/null 2>&1; then
    echo "${C_RED}[错误] 本机尚未初始化独立 uv 运行环境或未安装 google-colab-cli。${C_RESET}"
    return 1
  fi

  echo ""
  echo "${C_CYAN}[全局释放] 正在扫描所有已保存账号槽位与默认会话记录中的活跃 Colab 实例...${C_RESET}"

  local scanned=0
  local released_accounts=0
  local rows=""
  rows="$(account_store list "$ACCOUNTS_DIR" 2>/dev/null || true)"

  if [[ -n "$rows" ]]; then
    local name mode email has_cred
    while IFS=$'\t' read -r name mode email has_cred _ _ _; do
      [[ -z "$name" ]] && continue
      scanned=$((scanned + 1))
      if [[ "$has_cred" != "1" ]]; then
        echo "  ${C_DIM}• 跳过 '${name}' (${mode}): 本地凭证缺失${C_RESET}"
        continue
      fi

      local tmp_t="${STATE_DIR}/all_t_${name}.$$"
      local tmp_o="${STATE_DIR}/all_o_${name}.$$"
      : > "$tmp_t"
      : > "$tmp_o"
      run_with_account_creds "$name" "$mode" _collect_sessions_for_account_cb "$tmp_t" "$tmp_o" || true

      if [[ -s "$tmp_t" ]]; then
        released_accounts=$((released_accounts + 1))
        run_with_account_creds "$name" "$mode" _release_sessions_for_account_cb "" "0" || true
      else
        echo "  ${C_GREEN}✓${C_RESET} $(format_account_label "$name" "$mode" "$email"): 无纳管活跃实例"
      fi

      if [[ -s "$tmp_o" ]]; then
        echo "  ${C_YELLOW}! $(format_account_label "$name" "$mode" "$email") 存在未纳管 [?] 服务端实例:${C_RESET}"
        local odesc
        while IFS=$'\t' read -r _ odesc; do
          [[ -z "$odesc" ]] && continue
          echo "      ${odesc}"
        done < "$tmp_o"
        if [[ "$interactive_orphans" == "1" ]]; then
          read -r -p "    是否强行回收该账号上述 [?] 实例? [y/N]: " oy
          if [[ "${oy:-N}" =~ ^[Yy]$ ]]; then
            run_with_account_creds "$name" "$mode" _release_sessions_for_account_cb "" "1" || true
          fi
        fi
      fi
      rm -f "$tmp_t" "$tmp_o"
    done <<< "$rows"
  fi

  local default_sess_cfg
  default_sess_cfg="$(colab_session_config_path "")"
  if [[ -z "$ACTIVE_ACCOUNT" || -f "$default_sess_cfg" ]]; then
    local default_local=""
    default_local="$(account_store sessions-list "$default_sess_cfg" 2>/dev/null || true)"
    if [[ -n "$default_local" || -z "$ACTIVE_ACCOUNT" ]]; then
      scanned=$((scanned + 1))
      local tmp_dt="${STATE_DIR}/all_dt.$$"
      local tmp_do="${STATE_DIR}/all_do.$$"
      : > "$tmp_dt"
      : > "$tmp_do"
      run_with_account_creds "" "$COLAB_AUTH_MODE" _collect_sessions_for_account_cb "$tmp_dt" "$tmp_do" || true
      if [[ -s "$tmp_dt" ]]; then
        released_accounts=$((released_accounts + 1))
        run_with_account_creds "" "$COLAB_AUTH_MODE" _release_sessions_for_account_cb "" "0" || true
      else
        echo "  ${C_GREEN}✓${C_RESET} 默认未归档账号 (${COLAB_AUTH_MODE}): 无纳管活跃实例"
      fi
      rm -f "$tmp_dt" "$tmp_do"
    fi
  fi

  echo "${C_GREEN}[全局释放完成] 共扫描 ${scanned} 个账号槽位，触发释放 ${released_accounts} 个账号的活跃实例。${C_RESET}"
  refresh_colab_auth_status 4 0 || true
  return 0
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
  local host_py=""
  host_py="$(resolve_host_python 2>/dev/null || command -v python3)"
  "$host_py" - \
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
  ACTIVE_SESSION_ACCOUNT="$ACTIVE_ACCOUNT"
  ACTIVE_SESSION_AUTH_MODE="$COLAB_AUTH_MODE"
  ACTIVE_SESSION_HAS_OWNER=1
  MANAGED_SESSION=1

  if colab_cli status -s "$SESSION_NAME" >/dev/null 2>&1; then
    echo "${C_GREEN}[会话] 复用已活跃的 Colab 实例: ${SESSION_NAME} ($(format_account_label "$ACTIVE_ACCOUNT" "$COLAB_AUTH_MODE" "$AUTH_EMAIL"))${C_RESET}"
  else
    local new_args=(new -s "$SESSION_NAME" --gpu "$GPU_TYPE")
    [[ "$HIGH_MEM" == "1" ]] && new_args+=(--high-mem)
    echo "${C_CYAN}[分配] 正在以账号 '$(format_account_label "$ACTIVE_ACCOUNT" "$COLAB_AUTH_MODE" "$AUTH_EMAIL")' 申请 Colab GPU 实例 (${GPU_TYPE})...${C_RESET}"
    if ! colab_cli "${new_args[@]}"; then
      echo "${C_RED}[失败] Colab 实例分配失败（可能是当前 GPU 规格库存紧张或配额不足）。${C_RESET}"
      MANAGED_SESSION=0
      ACTIVE_SESSION_NAME=""
      ACTIVE_SESSION_ACCOUNT=""
      ACTIVE_SESSION_AUTH_MODE=""
      ACTIVE_SESSION_HAS_OWNER=0
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
    local colab_bin=""
    colab_bin="$(resolve_colab_bin)"
    local proxy_cfg_opt=""
    if [[ -n "$ACTIVE_ACCOUNT" ]]; then
      local sess_cfg
      sess_cfg="$(colab_session_config_path "$ACTIVE_ACCOUNT")"
      proxy_cfg_opt=" --config '${sess_cfg}'"
    elif [[ "$COLAB_CLI_CONFIG_DIR" != "$HOME/.config/colab-cli" ]]; then
      proxy_cfg_opt=" --config '${COLAB_CLI_CONFIG_DIR}/sessions.json'"
    fi

    : > "$SSH_LOG"
    if [[ "$COLAB_AUTH_MODE" == "adc" && -n "$ACTIVE_ACCOUNT" && -f "${ACCOUNTS_DIR}/${ACTIVE_ACCOUNT}/adc.json" ]]; then
      GOOGLE_APPLICATION_CREDENTIALS="${ACCOUNTS_DIR}/${ACTIVE_ACCOUNT}/adc.json" \
        ssh \
          -o "ProxyCommand=${colab_bin}${proxy_cfg_opt} --auth ${COLAB_AUTH_MODE} ssh --proxy-mode -s ${SESSION_NAME}" \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o ServerAliveInterval=30 \
          -N -L "${LOCAL_BIND}:${MAYA_PORT}:127.0.0.1:${MAYA_PORT}" \
          root@colab >"$SSH_LOG" 2>&1 &
    else
      ssh \
        -o "ProxyCommand=${colab_bin}${proxy_cfg_opt} --auth ${COLAB_AUTH_MODE} ssh --proxy-mode -s ${SESSION_NAME}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ServerAliveInterval=30 \
        -N -L "${LOCAL_BIND}:${MAYA_PORT}:127.0.0.1:${MAYA_PORT}" \
        root@colab >"$SSH_LOG" 2>&1 &
    fi
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
