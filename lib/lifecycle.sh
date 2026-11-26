#!/usr/bin/env bash
# ==============================================================================
# colabd - Remote VM lifecycle, fail-closed release gates, tunnel orchestration
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

# Real `google-colab-cli` v0.8.0 `colab status -s <name>` returns exit code 0 even when
# printing "[colab] Session '<name>' not found." Always verify actual output!
colab_session_is_active() {
  local auth_mode="$1"
  local acct="$2"
  local sess_name="$3"

  local out=""
  if ! out="$(probe_colab_command "$auth_mode" "$acct" 8 status -s "$sess_name" 2>&1)"; then
    return 1
  fi
  if _sessions_output_indicates_auth_error "$out"; then
    return 1
  fi

  local host_py=""
  host_py="$(resolve_host_python 2>/dev/null || command -v python3 2>/dev/null || true)"
  [[ -z "$host_py" ]] && return 1
  "$host_py" - "$out" "$sess_name" <<'PY'
import re, sys
text, sname = sys.argv[1], sys.argv[2]
pat = re.compile(r"^\s*\[" + re.escape(sname) + r"\]\s+\S+\s+\|\s+Hardware:")
for line in text.splitlines():
    if pat.match(line):
        sys.exit(0)
sys.exit(1)
PY
}

_collect_local_sessions_only() {
  local acct="$1"
  local mode="$2"
  local out_tracked="$3"

  : > "$out_tracked"
  local sess_cfg=""
  sess_cfg="$(colab_session_config_path "$acct")"
  local local_rows=""
  local_rows="$(account_store sessions-list "$sess_cfg" 2>/dev/null || true)"

  local managed_name=""
  if [[ "$MANAGED_SESSION" -eq 1 && "$ACTIVE_SESSION_HAS_OWNER" -eq 1 && "$ACTIVE_SESSION_ACCOUNT" == "$acct" && "$ACTIVE_SESSION_AUTH_MODE" == "$mode" ]]; then
    managed_name="${ACTIVE_SESSION_NAME:-$SESSION_NAME}"
  fi

  local host_py=""
  host_py="$(resolve_host_python 2>/dev/null || command -v python3 2>/dev/null || true)"
  [[ -z "$host_py" ]] && return 1

  "$host_py" - "$local_rows" "$managed_name" "$out_tracked" <<'PY'
import pathlib, sys
local_rows, managed_name, out_tracked = sys.argv[1:4]
tracked = {}
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
if managed_name and managed_name not in tracked:
    tracked[managed_name] = f"[{managed_name}] (当前 colabd 托管会话)"
pathlib.Path(out_tracked).write_text(
    "".join(f"{k}\t{v}\n" for k, v in sorted(tracked.items())),
    encoding="utf-8",
)
PY
}

_collect_sessions_for_account_cb() {
  local acct="$1"
  local mode="$2"
  local out_tracked="$3"
  local out_orphans="$4"
  local out_probe_err="${5:-}"

  : > "$out_tracked"
  : > "$out_orphans"
  [[ -n "$out_probe_err" ]] && : > "$out_probe_err"

  local sess_cfg=""
  sess_cfg="$(colab_session_config_path "$acct")"

  local local_rows=""
  local_rows="$(account_store sessions-list "$sess_cfg" 2>/dev/null || true)"

  local live_out=""
  local probe_err=""
  if resolve_colab_bin >/dev/null 2>&1; then
    if ! live_out="$(probe_colab_command "$mode" "$acct" 6 sessions 2>&1)"; then
      probe_err="${live_out:-远端 colab sessions 探测失败}"
      live_out=""
    elif _sessions_output_indicates_auth_error "$live_out"; then
      probe_err="$live_out"
      live_out=""
    elif [[ "$mode" == "adc" ]]; then
      # Real `colab --auth adc sessions` swallows SystemExit on empty sessions; verify ADC via whoami too!
      if ! probe_colab_command "$mode" "$acct" 6 whoami >/dev/null 2>&1; then
        probe_err="ADC 凭证无效或已过期 (colab whoami 校验失败)"
        live_out=""
      fi
    fi
  else
    probe_err="未找到 colab CLI"
  fi

  if [[ -n "$out_probe_err" && -n "$probe_err" ]]; then
    printf '%s\n' "$probe_err" > "$out_probe_err"
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
    m = re.match(r"^\s*\[([^\]]+)\]\s+(\S+)\s+\|\s+Hardware:", line)
    if not m:
        continue
    name, ep = m.group(1).strip(), m.group(2).strip()
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

_stop_single_session_checked() {
  local mode="$1"
  local acct="$2"
  local sname="$3"
  local label="$4"

  echo "${C_YELLOW}[回收] 正在释放账号 '${label}' 的实例 '${sname}' (colab stop -s ${sname})...${C_RESET}"
  local stop_out=""
  local stop_rc=0
  stop_out="$(colab_cli_for "$mode" "$acct" stop -s "$sname" 2>&1)" || stop_rc=$?

  if [[ "$stop_rc" -ne 0 ]] || _sessions_output_indicates_auth_error "$stop_out"; then
    echo "${C_RED}[失败] 释放账号 '${label}' 的实例 '${sname}' 失败: ${stop_out}${C_RESET}"
    return 1
  fi

  case "$stop_out" in
    *"not found"*)
      echo "${C_DIM}[提示] 账号 '${label}' 下未找到活跃实例 '${sname}'（可能已提前释放）。${C_RESET}"
      return 0
      ;;
    *)
      echo "${C_GREEN}[回收] 账号 '${label}' 的实例 '${sname}' 已销毁。${C_RESET}"
      return 0
      ;;
  esac
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

  local note=""
  if [[ -n "$acct" ]]; then
    note="$(account_store meta-get "$ACCOUNTS_DIR" "$acct" note 2>/dev/null || true)"
  elif [[ "$acct" == "$ACTIVE_ACCOUNT" ]]; then
    note="$AUTH_NOTE"
  fi
  local label=""
  label="$(format_account_label "$acct" "$mode" "$note")"

  local failed=0

  if [[ -n "$specific_session" ]]; then
    if _stop_single_session_checked "$mode" "$acct" "$specific_session" "$label"; then
      if [[ "$is_managed_owner" -eq 1 && "${ACTIVE_SESSION_NAME:-$SESSION_NAME}" == "$specific_session" ]]; then
        MANAGED_SESSION=0
        ACTIVE_SESSION_NAME=""
        ACTIVE_SESSION_ACCOUNT=""
        ACTIVE_SESSION_AUTH_MODE=""
        ACTIVE_SESSION_HAS_OWNER=0
      fi
    else
      failed=$((failed + 1))
    fi
  else
    local sname=""
    while IFS=$'\t' read -r sname _; do
      [[ -z "$sname" ]] && continue
      if ! _stop_single_session_checked "$mode" "$acct" "$sname" "$label"; then
        failed=$((failed + 1))
      fi
    done < "$tmp_tracked"

    if [[ "$is_managed_owner" -eq 1 && "$failed" -eq 0 ]]; then
      MANAGED_SESSION=0
      ACTIVE_SESSION_NAME=""
      ACTIVE_SESSION_ACCOUNT=""
      ACTIVE_SESSION_AUTH_MODE=""
      ACTIVE_SESSION_HAS_OWNER=0
    fi
  fi

  if [[ "$include_orphans" == "1" && -s "$tmp_orphans" ]]; then
    local adc_arg=""
    if [[ "$mode" == "adc" && -n "$acct" ]]; then
      adc_arg="$(colab_adc_credentials_path "$acct" 2>/dev/null || true)"
    fi
    local ep=""
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

# Non-destructive switch guard (old account credentials & sessions.json remain preserved)
guard_release_before_account_change() {
  local reason="${1:-切换账号}"
  local target_acct_override="${2:-}"
  local auto_mode="${3:-prompt}"

  local check_acct="$ACTIVE_ACCOUNT"
  local check_mode="$COLAB_AUTH_MODE"
  local check_note="$AUTH_NOTE"
  local checking_current=1

  if [[ -n "$target_acct_override" ]]; then
    check_acct="$target_acct_override"
    check_mode="$(account_store meta-get "$ACCOUNTS_DIR" "$check_acct" auth_mode 2>/dev/null || echo "oauth2")"
    check_note="$(account_store meta-get "$ACCOUNTS_DIR" "$check_acct" note 2>/dev/null || true)"
    if [[ "$check_acct" != "$ACTIVE_ACCOUNT" ]]; then
      checking_current=0
    fi
  fi

  local tmp_tracked="${STATE_DIR}/guard_tracked.$$"
  local tmp_orphans="${STATE_DIR}/guard_orphans.$$"
  : > "$tmp_tracked"
  : > "$tmp_orphans"

  if ! run_with_account_creds "$check_acct" "$check_mode" _collect_sessions_for_account_cb "$tmp_tracked" "$tmp_orphans"; then
    _collect_local_sessions_only "$check_acct" "$check_mode" "$tmp_tracked" || true
  fi

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

  local label=""
  label="$(format_account_label "$check_acct" "$check_mode" "$check_note")"
  echo ""
  echo "${C_YELLOW}[防扣费保护] 执行【${reason}】前，检测到账号 '${label}' 存在活跃 Colab 实例：${C_RESET}"

  if [[ "$has_tracked" -eq 1 ]]; then
    local desc=""
    while IFS=$'\t' read -r _ desc; do
      [[ -z "$desc" ]] && continue
      echo "  • ${desc}"
    done < "$tmp_tracked"
  fi
  if [[ "$has_orphans" -eq 1 ]]; then
    echo "  ${C_YELLOW}(以下为服务端未纳管 [?] 实例，可能是网页端 Notebook 或其他终端创建):${C_RESET}"
    local odesc=""
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
      echo "  3) 暂不释放远端实例，仅切号 (风险：旧账号实例继续扣费；后续可用 colabd down -a ${check_acct:-<账号>} 释放)"
      read -r -p "请选择 [1]: " decision
      decision="${decision:-1}"
      ;;
  esac

  case "$decision" in
    1|y|Y)
      if [[ "$has_tracked" -eq 1 || "$has_local_bg" -eq 1 ]]; then
        if ! run_with_account_creds "$check_acct" "$check_mode" _release_sessions_for_account_cb "" "0"; then
          echo "${C_RED}[中止] 释放账号 '${label}' 的活跃实例失败，已取消【${reason}】以防漏扣费。${C_RESET}"
          rm -f "$tmp_tracked" "$tmp_orphans"
          return 1
        fi
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
      echo "${C_YELLOW}[风险提示] 已跳过远端实例释放，旧账号 '${label}' 的实例可能仍在计费。${C_RESET}"
      if [[ -n "$check_acct" ]]; then
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

# Strict Fail-Closed destructive removal gate:
# 1. Inspects local sessions.json AND live server sessions BEFORE asking confirmation.
# 2. If credentials are missing or remote probe fails -> FAILS CLOSED (unless explicit --force / FORCE).
# 3. NEVER offers a "skip release" bypass for live tracked runtimes.
# 4. Verifies release exit code AND zero remaining tracked sessions before returning 0.
guard_hard_release_before_delete() {
  local target_id="$1"
  local target_mode="$2"
  local target_note="${3:-}"
  local auto_mode="${4:-prompt}"
  local force_unverified="${5:-0}"

  local label=""
  label="$(format_account_label "$target_id" "$target_mode" "$target_note")"

  local tmp_tracked="${STATE_DIR}/del_tracked.$$"
  local tmp_orphans="${STATE_DIR}/del_orphans.$$"
  local tmp_probe_err="${STATE_DIR}/del_probe_err.$$"
  : > "$tmp_tracked"
  : > "$tmp_orphans"
  : > "$tmp_probe_err"

  local creds_ok=1
  if ! run_with_account_creds "$target_id" "$target_mode" _collect_sessions_for_account_cb "$tmp_tracked" "$tmp_orphans" "$tmp_probe_err"; then
    creds_ok=0
    _collect_local_sessions_only "$target_id" "$target_mode" "$tmp_tracked" || true
    echo "本地凭证缺失或无法激活该账号凭证" > "$tmp_probe_err"
  fi

  local probe_failed=0
  if [[ "$creds_ok" -eq 0 || -s "$tmp_probe_err" ]]; then
    probe_failed=1
  fi

  local has_tracked=0
  local has_orphans=0
  [[ -s "$tmp_tracked" ]] && has_tracked=1
  [[ -s "$tmp_orphans" ]] && has_orphans=1

  echo ""
  echo "${C_BOLD}${C_YELLOW}[移除账号前置检查]${C_RESET} 目标账号: ${C_BOLD}${label}${C_RESET}"
  if [[ "$has_tracked" -eq 1 ]]; then
    echo "  ${C_RED}检测到未释放的纳管活跃实例:${C_RESET}"
    local desc=""
    while IFS=$'\t' read -r _ desc; do
      [[ -z "$desc" ]] && continue
      echo "    • ${desc}"
    done < "$tmp_tracked"
  else
    echo "  纳管活跃实例 : ${C_GREEN}无${C_RESET}"
  fi

  if [[ "$has_orphans" -eq 1 ]]; then
    echo "  ${C_YELLOW}检测到服务端未纳管 [?] 实例 (可能是网页端 Notebook):${C_RESET}"
    local odesc=""
    while IFS=$'\t' read -r _ odesc; do
      [[ -z "$odesc" ]] && continue
      echo "    • ${odesc}"
    done < "$tmp_orphans"
  fi

  # Fail-Closed gate when credentials are missing or remote Colab API probe failed
  if [[ "$probe_failed" -eq 1 ]]; then
    local err_summary=""
    err_summary="$(head -n 1 "$tmp_probe_err" 2>/dev/null || echo "远端校验失败")"
    echo "  ${C_RED}远端实例校验 : 失败 (${err_summary})${C_RESET}"
    if [[ "$force_unverified" == "1" ]]; then
      echo "${C_YELLOW}[强制移除] 已指定 --force，跳过无法完成的远端校验并清理本地记录（请务必确认 Colab 网页端无计费实例）。${C_RESET}"
      rm -f "$tmp_tracked" "$tmp_orphans" "$tmp_probe_err"
      return 0
    fi
    if [[ "$auto_mode" == "prompt" ]]; then
      echo ""
      echo "${C_RED}[安全门禁拦截] 无法确认账号 '${label}' 的远端是否存在仍在扣费的 GPU 实例！${C_RESET}"
      echo "  建议先运行 'colabd auth refresh ${target_id}' 恢复凭证后再安全释放并移除。"
      read -r -p "如已亲自确认 Colab 网页端无活跃实例，输入大写 FORCE 强行清理本地记录，其他任意键取消: " force_word
      if [[ "$force_word" == "FORCE" ]]; then
        rm -f "$tmp_tracked" "$tmp_orphans" "$tmp_probe_err"
        return 0
      fi
      echo "${C_GREEN}[已取消] 保留账号 '${label}' 本地记录。${C_RESET}"
      rm -f "$tmp_tracked" "$tmp_orphans" "$tmp_probe_err"
      return 1
    fi
    echo "${C_RED}[中止移除] 无法向远端核验账号 '${label}' 的实例状态 (${err_summary})，已按安全门禁拒绝删除。${C_RESET}" >&2
    echo "${C_YELLOW}请先恢复网络或运行 'colabd auth refresh ${target_id}'；如已确认网页端无计费实例，可显式追加 --force 强行清理。${C_RESET}" >&2
    rm -f "$tmp_tracked" "$tmp_orphans" "$tmp_probe_err"
    return 1
  fi

  # Case A: Tracked runtimes exist -> MUST release and verify zero remaining BEFORE deleting!
  if [[ "$has_tracked" -eq 1 ]]; then
    if [[ "$auto_mode" == "prompt" ]]; then
      echo ""
      echo "${C_RED}[安全门禁] 该账号尚有运行中的 Colab 实例，禁止在不释放实例的情况下直接移除账号。${C_RESET}"
      echo "  1) 先释放上述全部活跃实例，确认释放成功后再彻底移除该账号"
      echo "  2) 取消移除 (保留账号与实例)"
      read -r -p "请选择 [2]: " del_act
      if [[ "${del_act:-2}" != "1" ]]; then
        echo "${C_GREEN}[已取消] 未释放实例，也未移除账号 '${label}'。${C_RESET}"
        rm -f "$tmp_tracked" "$tmp_orphans" "$tmp_probe_err"
        return 1
      fi
    elif [[ "$auto_mode" != "release" ]]; then
      echo "${C_RED}[禁止移除] 账号 '${label}' 仍有活跃实例，移除操作不支持 --keep 跳过释放。${C_RESET}" >&2
      rm -f "$tmp_tracked" "$tmp_orphans" "$tmp_probe_err"
      return 1
    fi

    local rel_rc=0
    run_with_account_creds "$target_id" "$target_mode" _release_sessions_for_account_cb "" "0" || rel_rc=$?

    local tmp_verify_t="${STATE_DIR}/del_verify_t.$$"
    local tmp_verify_o="${STATE_DIR}/del_verify_o.$$"
    local tmp_verify_e="${STATE_DIR}/del_verify_e.$$"
    : > "$tmp_verify_t"
    : > "$tmp_verify_o"
    : > "$tmp_verify_e"
    local verify_rc=0
    run_with_account_creds "$target_id" "$target_mode" _collect_sessions_for_account_cb "$tmp_verify_t" "$tmp_verify_o" "$tmp_verify_e" || verify_rc=$?

    if [[ "$rel_rc" -ne 0 || "$verify_rc" -ne 0 || -s "$tmp_verify_t" || -s "$tmp_verify_e" ]]; then
      echo ""
      echo "${C_RED}[中止移除] 账号 '${label}' 的活跃实例未能完全释放或二次核验失败！${C_RESET}" >&2
      echo "${C_YELLOW}为防止远端 GPU 失联持续扣费，已完整保留该账号的本地凭证与 sessions.json。${C_RESET}" >&2
      if [[ -n "$target_id" ]]; then
        echo "${C_YELLOW}请排查网络后重试: colabd down -a ${target_id}${C_RESET}" >&2
      fi
      rm -f "$tmp_tracked" "$tmp_orphans" "$tmp_probe_err" "$tmp_verify_t" "$tmp_verify_o" "$tmp_verify_e"
      return 1
    fi
    rm -f "$tmp_verify_t" "$tmp_verify_o" "$tmp_verify_e"
  fi

  # Case B: Untracked [?] server-side sessions exist
  if [[ "$has_orphans" -eq 1 ]]; then
    if [[ "$auto_mode" == "prompt" ]]; then
      echo ""
      echo "如何处理上述服务端未纳管 [?] 实例?"
      echo "  1) 同时强行回收上述 [?] 远端实例后再移除本地账号"
      echo "  2) 确认上述为网页端 Notebook，仅移除本地 CLI 账号"
      echo "  3) 取消移除"
      read -r -p "请选择 [3]: " o_act
      case "${o_act:-3}" in
        1)
          if ! run_with_account_creds "$target_id" "$target_mode" _release_sessions_for_account_cb "" "1"; then
            echo "${C_RED}[中止移除] 未纳管 [?] 实例回收失败，已保留本地凭证以免失联。${C_RESET}"
            rm -f "$tmp_tracked" "$tmp_orphans" "$tmp_probe_err"
            return 1
          fi
          ;;
        2)
          echo "${C_YELLOW}[提示] 已按你的确认跳过网页端 [?] 实例，继续移除本地账号凭证。${C_RESET}"
          ;;
        *)
          echo "${C_GREEN}[已取消] 未移除账号 '${label}'。${C_RESET}"
          rm -f "$tmp_tracked" "$tmp_orphans" "$tmp_probe_err"
          return 1
          ;;
      esac
    else
      echo "${C_YELLOW}[提醒] 账号 '${label}' 存在未纳管 [?] 服务端实例，未自动销毁（避免误关网页端 Notebook）。${C_RESET}"
    fi
  fi

  # Case C: No tracked sessions (and no orphan prompt already confirmed) -> explicit final confirmation
  if [[ "$has_tracked" -eq 0 && "$has_orphans" -eq 0 && "$auto_mode" == "prompt" ]]; then
    read -r -p "确认彻底移除账号 '${label}' 并清除其本地钥匙串 / ADC 凭证? [y/N]: " final_yn
    if [[ ! "${final_yn:-N}" =~ ^[Yy]$ ]]; then
      echo "${C_GREEN}[已取消] 未移除账号 '${label}'。${C_RESET}"
      rm -f "$tmp_tracked" "$tmp_orphans" "$tmp_probe_err"
      return 1
    fi
  fi

  rm -f "$tmp_tracked" "$tmp_orphans" "$tmp_probe_err"
  return 0
}

stop_colab_instance() {
  local target_acct_override="${1:-}"
  local target_session_override="${2:-}"

  local owner_acct="$ACTIVE_ACCOUNT"
  local owner_mode="$COLAB_AUTH_MODE"
  local use_managed_owner=0

  if [[ -n "$target_acct_override" ]]; then
    local resolved=""
    if ! resolved="$(resolve_account_id "$target_acct_override")"; then
      echo "${C_RED}[错误] 未找到账号 '${target_acct_override}'。${C_RESET}"
      return 1
    fi
    owner_acct="$resolved"
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
    run_with_account_creds "$owner_acct" "$owner_mode" _release_sessions_for_account_cb "$target_session_override" "0"
    return $?
  fi

  if [[ -n "$target_acct_override" ]]; then
    run_with_account_creds "$owner_acct" "$owner_mode" _release_sessions_for_account_cb "" "0"
    return $?
  fi

  local target="${ACTIVE_SESSION_NAME:-$SESSION_NAME}"
  local sess_cfg=""
  sess_cfg="$(colab_session_config_path "$owner_acct")"
  local has_local_sessions=""
  has_local_sessions="$(account_store sessions-list "$sess_cfg" 2>/dev/null || true)"

  local rc=0
  if [[ "$MANAGED_SESSION" -eq 1 || "$use_managed_owner" -eq 1 ]]; then
    run_with_account_creds "$owner_acct" "$owner_mode" _release_sessions_for_account_cb "$target" "0" || rc=$?
  elif [[ -n "$has_local_sessions" ]]; then
    run_with_account_creds "$owner_acct" "$owner_mode" _release_sessions_for_account_cb "" "0" || rc=$?
  elif [[ "$AUTH_STATE" == "ok" ]] && colab_session_is_active "$owner_mode" "$owner_acct" "$target"; then
    run_with_account_creds "$owner_acct" "$owner_mode" _release_sessions_for_account_cb "$target" "0" || rc=$?
  fi

  if [[ "$rc" -eq 0 ]]; then
    MANAGED_SESSION=0
    ACTIVE_SESSION_NAME=""
    ACTIVE_SESSION_ACCOUNT=""
    ACTIVE_SESSION_AUTH_MODE=""
    ACTIVE_SESSION_HAS_OWNER=0
  fi
  return "$rc"
}

find_other_accounts_with_local_sessions() {
  local rows=""
  rows="$(account_store list "$ACCOUNTS_DIR" 2>/dev/null || true)"
  [[ -z "$rows" ]] && return 1

  local found=""
  local acc_id scount snames
  while IFS="$FIELD_SEP" read -r acc_id _ _ _ _ _ scount snames _; do
    [[ -z "$acc_id" ]] && continue
    if [[ "$acc_id" != "$ACTIVE_ACCOUNT" && "${scount:-0}" -gt 0 ]]; then
      if [[ -n "$found" ]]; then
        found="${found}, ${acc_id}:${snames}"
      else
        found="${acc_id}:${snames}"
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
  echo "${C_CYAN}[全局释放] 正在扫描所有已登录账号与默认会话记录中的活跃 Colab 实例...${C_RESET}"

  local scanned=0
  local released_accounts=0
  local any_failed=0
  local rows=""
  rows="$(account_store list "$ACCOUNTS_DIR" 2>/dev/null || true)"

  if [[ -n "$rows" ]]; then
    local acc_id mode note has_cred
    # Read from dedicated FD 3 so interactive `read -r -p` inside the loop never consumes $rows!
    while IFS="$FIELD_SEP" read -r -u 3 acc_id mode _ note has_cred _ _ _ _; do
      [[ -z "$acc_id" ]] && continue
      scanned=$((scanned + 1))
      if [[ "$has_cred" != "1" ]]; then
        echo "  ${C_DIM}• 跳过 '${acc_id}' (${mode}): 本地凭证缺失${C_RESET}"
        continue
      fi

      local tmp_t="${STATE_DIR}/all_t_${scanned}.$$"
      local tmp_o="${STATE_DIR}/all_o_${scanned}.$$"
      local tmp_e="${STATE_DIR}/all_e_${scanned}.$$"
      : > "$tmp_t"
      : > "$tmp_o"
      : > "$tmp_e"
      if ! run_with_account_creds "$acc_id" "$mode" _collect_sessions_for_account_cb "$tmp_t" "$tmp_o" "$tmp_e"; then
        any_failed=1
        echo "  ${C_RED}✗${C_RESET} $(format_account_label "$acc_id" "$mode" "$note"): 激活凭证失败"
        rm -f "$tmp_t" "$tmp_o" "$tmp_e"
        continue
      fi

      if [[ -s "$tmp_e" ]]; then
        any_failed=1
        echo "  ${C_YELLOW}!${C_RESET} $(format_account_label "$acc_id" "$mode" "$note"): 远端探测失败 ($(head -n 1 "$tmp_e"))"
      elif [[ -s "$tmp_t" ]]; then
        released_accounts=$((released_accounts + 1))
        if ! run_with_account_creds "$acc_id" "$mode" _release_sessions_for_account_cb "" "0"; then
          any_failed=1
        fi
      else
        echo "  ${C_GREEN}✓${C_RESET} $(format_account_label "$acc_id" "$mode" "$note"): 无纳管活跃实例"
      fi

      if [[ -s "$tmp_o" ]]; then
        echo "  ${C_YELLOW}! $(format_account_label "$acc_id" "$mode" "$note") 存在未纳管 [?] 服务端实例:${C_RESET}"
        local odesc=""
        while IFS=$'\t' read -r _ odesc; do
          [[ -z "$odesc" ]] && continue
          echo "      ${odesc}"
        done < "$tmp_o"
        if [[ "$interactive_orphans" == "1" ]]; then
          read -r -p "    是否强行回收该账号上述 [?] 实例? [y/N]: " oy
          if [[ "${oy:-N}" =~ ^[Yy]$ ]]; then
            if ! run_with_account_creds "$acc_id" "$mode" _release_sessions_for_account_cb "" "1"; then
              any_failed=1
            fi
          fi
        fi
      fi
      rm -f "$tmp_t" "$tmp_o" "$tmp_e"
    done 3<<< "$rows"
  fi

  local default_sess_cfg=""
  default_sess_cfg="$(colab_session_config_path "")"
  if [[ -f "$default_sess_cfg" ]]; then
    local default_local=""
    default_local="$(account_store sessions-list "$default_sess_cfg" 2>/dev/null || true)"
    if [[ -n "$default_local" ]]; then
      scanned=$((scanned + 1))
      local tmp_dt="${STATE_DIR}/all_dt.$$"
      local tmp_do="${STATE_DIR}/all_do.$$"
      : > "$tmp_dt"
      : > "$tmp_do"
      run_with_account_creds "" "$COLAB_AUTH_MODE" _collect_sessions_for_account_cb "$tmp_dt" "$tmp_do" || true
      if [[ -s "$tmp_dt" ]]; then
        released_accounts=$((released_accounts + 1))
        if ! run_with_account_creds "" "$COLAB_AUTH_MODE" _release_sessions_for_account_cb "" "0"; then
          any_failed=1
        fi
      else
        echo "  ${C_GREEN}✓${C_RESET} 默认未关联会话 (${COLAB_AUTH_MODE}): 无纳管活跃实例"
      fi
      rm -f "$tmp_dt" "$tmp_do"
    fi
  fi

  echo "${C_GREEN}[全局释放完成] 共扫描 ${scanned} 个账号，触发释放 ${released_accounts} 个账号的活跃实例。${C_RESET}"
  refresh_colab_auth_status 4 0 || true
  [[ "$any_failed" -eq 0 ]]
}

CLEANED_UP=0
cleanup_on_exit() {
  local code=$?
  if [[ "$CLEANED_UP" -eq 1 ]]; then
    return
  fi
  CLEANED_UP=1
  # Always restore any in-flight temporary OAuth2 keyring swap BEFORE stopping instances or wiping $STATE_DIR!
  restore_oauth_swap_if_needed
  if [[ "${COLABD_SKIP_AUTO_STOP:-0}" != "1" ]]; then
    echo ""
    stop_colab_instance || true
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
  local probe_py="${STATE_DIR}/probe_disk.$$.py"
  cat > "$probe_py" <<'PYDISK'
import shutil
print(int(shutil.disk_usage("/content").free // (1024**3)))
PYDISK
  local out=""
  out="$(probe_colab_command "$COLAB_AUTH_MODE" "$ACTIVE_ACCOUNT" 25 exec -s "$sess" -f "$probe_py" 2>/dev/null || true)"
  rm -f "$probe_py"
  printf '%s\n' "$out" | tr -d '\r' | grep -E '^[0-9]+$' | tail -n 1
}

verify_remote_drive_mounted() {
  local sess="$1"
  local probe_py="${STATE_DIR}/probe_drive.$$.py"
  cat > "$probe_py" <<'PYDRV'
import os, sys
print("DRIVE_MOUNTED_OK" if os.path.isdir("/content/drive/MyDrive") else "DRIVE_NOT_MOUNTED")
PYDRV
  local out=""
  out="$(probe_colab_command "$COLAB_AUTH_MODE" "$ACTIVE_ACCOUNT" 20 exec -s "$sess" -f "$probe_py" 2>/dev/null || true)"
  rm -f "$probe_py"
  printf '%s\n' "$out" | grep -q 'DRIVE_MOUNTED_OK'
}

validate_runtime_settings() {
  if [[ ! "$SESSION_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "${C_RED}[配置错误] SESSION_NAME '${SESSION_NAME}' 含非法字符（仅允许字母、数字、.、_、-），请进设置页 [11] 修改。${C_RESET}"
    return 1
  fi
  if [[ ! "$MAYA_PORT" =~ ^[0-9]+$ || "$MAYA_PORT" -lt 1 || "$MAYA_PORT" -gt 65535 ]]; then
    echo "${C_RED}[配置错误] MAYA_PORT '${MAYA_PORT}' 无效（需为 1-65535），请进设置页 [10] 修改。${C_RESET}"
    return 1
  fi
  if [[ ! "$LOCAL_BIND" =~ ^[A-Za-z0-9.:_-]+$ ]]; then
    echo "${C_RED}[配置错误] LOCAL_BIND '${LOCAL_BIND}' 含非法字符，请进设置页 [10] 修改。${C_RESET}"
    return 1
  fi
  return 0
}

action_start_or_restart() {
  if ! ensure_cli_and_authenticated; then
    read -r -p "按回车返回主菜单..." _
    return
  fi

  if ! validate_runtime_settings; then
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

  # Pre-check SSH client & key BEFORE allocating a Colab GPU so missing ssh never leaks a VM!
  local ssh_key=""
  if [[ "$TUNNEL_MODE" == "ssh" ]]; then
    if ! command -v ssh >/dev/null 2>&1; then
      echo "${C_RED}[错误] 本机缺少 OpenSSH (ssh) 客户端，无法建立本地转发（未分配 GPU）。${C_RESET}"
      read -r -p "按回车返回主菜单..." _
      return
    fi
    if [[ -f "${HOME}/.ssh/id_ed25519" && -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
      ssh_key="${HOME}/.ssh/id_ed25519"
    elif [[ -f "${HOME}/.ssh/id_ecdsa" && -f "${HOME}/.ssh/id_ecdsa.pub" ]]; then
      ssh_key="${HOME}/.ssh/id_ecdsa"
    else
      ssh_key="${HOME}/.ssh/id_ed25519"
      echo "${C_CYAN}[SSH] 正在自动生成 Colab 支持的 Ed25519 密钥对 (${ssh_key})...${C_RESET}"
      mkdir -p "${HOME}/.ssh"
      chmod 700 "${HOME}/.ssh" 2>/dev/null || true
      ssh-keygen -t ed25519 -N "" -f "$ssh_key" >/dev/null
    fi
  fi

  # If user renamed SESSION_NAME while another managed session is still running, release old session first!
  if [[ "$MANAGED_SESSION" -eq 1 && -n "$ACTIVE_SESSION_NAME" && "$ACTIVE_SESSION_NAME" != "$SESSION_NAME" ]]; then
    echo "${C_YELLOW}[防扣费保护] 检测到会话名已从 '${ACTIVE_SESSION_NAME}' 变更为 '${SESSION_NAME}'，正在先释放旧实例...${C_RESET}"
    stop_colab_instance || true
  elif is_bg_running; then
    echo "${C_YELLOW}[信息] 正在停止当前后台守护连接以执行重启...${C_RESET}"
    stop_local_daemons
  fi

  local created_fresh_vm=0
  local reused_vm=0

  ACTIVE_SESSION_NAME="$SESSION_NAME"
  ACTIVE_SESSION_ACCOUNT="$ACTIVE_ACCOUNT"
  ACTIVE_SESSION_AUTH_MODE="$COLAB_AUTH_MODE"
  ACTIVE_SESSION_HAS_OWNER=1
  MANAGED_SESSION=1

  if colab_session_is_active "$COLAB_AUTH_MODE" "$ACTIVE_ACCOUNT" "$SESSION_NAME"; then
    reused_vm=1
    echo "${C_GREEN}[会话] 复用已活跃的 Colab 实例: ${SESSION_NAME} ($(format_account_label "$ACTIVE_ACCOUNT" "$COLAB_AUTH_MODE" "$AUTH_NOTE"))${C_RESET}"
    echo "${C_CYAN}[内核重置] 正在重启远端 Jupyter 内核以清理旧守护进程 (colab restart-kernel)...${C_RESET}"
    colab_cli restart-kernel -s "$SESSION_NAME" >/dev/null 2>&1 || true
  else
    local new_args=(new -s "$SESSION_NAME" --gpu "$GPU_TYPE")
    [[ "$HIGH_MEM" == "1" ]] && new_args+=(--high-mem)
    echo "${C_CYAN}[分配] 正在以账号 '$(format_account_label "$ACTIVE_ACCOUNT" "$COLAB_AUTH_MODE" "$AUTH_NOTE")' 申请 Colab GPU 实例 (${GPU_TYPE})...${C_RESET}"
    if ! colab_cli "${new_args[@]}"; then
      echo "${C_RED}[失败] Colab 实例分配失败（可能是当前 GPU 规格库存紧张、配额不足或权限域不完整）。${C_RESET}"
      MANAGED_SESSION=0
      ACTIVE_SESSION_NAME=""
      ACTIVE_SESSION_ACCOUNT=""
      ACTIVE_SESSION_AUTH_MODE=""
      ACTIVE_SESSION_HAS_OWNER=0
      read -r -p "按回车返回主菜单..." _
      return
    fi
    created_fresh_vm=1
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
    local free_gb=""
    free_gb="$(probe_remote_local_free_gb "$SESSION_NAME")"
    if [[ -z "$free_gb" ]]; then
      echo "${C_YELLOW}[警告] 远端磁盘容量探测超时或未返回数值，默认按 235 GiB 消费级 Colab 盘选择推荐跨盘方案。${C_RESET}"
      if model_has_engram "$MODEL_PRESET"; then
        effective_storage="nvme_engram"
      else
        effective_storage="local_nvme"
      fi
    elif [[ "$free_gb" -ge "$total_needed" ]]; then
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
        0) stop_colab_instance || true; return ;;
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
    colab_cli drivemount -s "$SESSION_NAME" || true
    # Real `colab drivemount` returns exit code 0 even when drive.mount() raises in the kernel; always verify!
    if ! verify_remote_drive_mounted "$SESSION_NAME"; then
      if [[ "$effective_storage" == "local_nvme" ]]; then
        echo "${C_YELLOW}[警告] Google Drive 未实际挂载 (/content/drive/MyDrive 不存在)，将在纯本地模式下走公网回退下载。${C_RESET}"
      else
        echo "${C_RED}[错误] 当前存储拓扑 (${effective_storage}) 依赖 Google Drive，但未检测到 /content/drive/MyDrive 挂载（若缺少 drive.file 权限请运行 colabd auth refresh）。${C_RESET}"
        if [[ "$created_fresh_vm" -eq 1 ]]; then
          echo "${C_YELLOW}[自动回收] 正在立即释放刚分配的空闲 GPU 实例以防扣费...${C_RESET}"
          stop_colab_instance || true
        fi
        read -r -p "按回车返回主菜单..." _
        return
      fi
    fi
  fi

  if [[ "$TUNNEL_MODE" == "ssh" ]]; then
    local colab_bin=""
    colab_bin="$(resolve_colab_bin)"
    local q_colab="" q_sess="" q_mode="" proxy_cmd=""
    printf -v q_colab '%q' "$colab_bin"
    printf -v q_sess '%q' "$SESSION_NAME"
    printf -v q_mode '%q' "$COLAB_AUTH_MODE"

    if [[ -n "$ACTIVE_ACCOUNT" ]]; then
      local sess_cfg="" q_cfg=""
      sess_cfg="$(colab_session_config_path "$ACTIVE_ACCOUNT")"
      printf -v q_cfg '%q' "$sess_cfg"
      proxy_cmd="${q_colab} --config ${q_cfg} --auth ${q_mode} ssh --proxy-mode -s ${q_sess}"
    elif [[ "$COLAB_CLI_CONFIG_DIR" != "$HOME/.config/colab-cli" ]]; then
      local q_cfg=""
      printf -v q_cfg '%q' "${COLAB_CLI_CONFIG_DIR}/sessions.json"
      proxy_cmd="${q_colab} --config ${q_cfg} --auth ${q_mode} ssh --proxy-mode -s ${q_sess}"
    else
      proxy_cmd="${q_colab} --auth ${q_mode} ssh --proxy-mode -s ${q_sess}"
    fi

    local ssh_adc_file=""
    if [[ "$COLAB_AUTH_MODE" == "adc" && -n "$ACTIVE_ACCOUNT" ]]; then
      ssh_adc_file="$(colab_adc_credentials_path "$ACTIVE_ACCOUNT" 2>/dev/null || true)"
    fi

    : > "$SSH_LOG"
    if [[ -n "$ssh_adc_file" ]]; then
      GOOGLE_APPLICATION_CREDENTIALS="$ssh_adc_file" \
        ssh \
          -i "$ssh_key" \
          -o IdentitiesOnly=yes \
          -o "ProxyCommand=${proxy_cmd}" \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o ServerAliveInterval=30 \
          -N -L "${LOCAL_BIND}:${MAYA_PORT}:127.0.0.1:${MAYA_PORT}" \
          root@colab >"$SSH_LOG" 2>&1 &
    else
      ssh \
        -i "$ssh_key" \
        -o IdentitiesOnly=yes \
        -o "ProxyCommand=${proxy_cmd}" \
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
  # Pass --timeout 0 because real `colab exec` defaults to 30s idle timeout!
  colab_cli exec --timeout 0 -s "$SESSION_NAME" -f "$RUNNER_PY" >>"$REMOTE_LOG" 2>&1 &
  EXEC_PID=$!

  local reuse_tag=""
  [[ "$reused_vm" -eq 1 ]] && reuse_tag=" (复用实例并已重置内核)"
  echo "${C_GREEN}[已启动] 后台守护进程已运行 (PID: ${EXEC_PID})${reuse_tag}，正在执行云盘分片检索与隧道初始化...${C_RESET}"
  local waited=0
  while [[ $waited -lt 15 ]]; do
    local ep=""
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
