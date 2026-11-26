#!/usr/bin/env bash
# ==============================================================================
# colabd - Identity-based multi-account CRUD, scope validation & repair, GCP auth
# Accounts are uniquely identified by normalized (email, auth_mode):
#   - oauth2 -> <email>
#   - adc    -> adc:<email>
# Compatible with Bash 3.2+ (macOS and Linux)
# ==============================================================================

# Default timeout (seconds) for non-interactive `colab` auth/session probes.
# Must be generous enough for cold Python boot + OS keyring I/O + automatic
# 1-hour OAuth 2.0 access_token refresh + Colab API roundtrip.
COLABD_AUTH_PROBE_TIMEOUT="${COLABD_AUTH_PROBE_TIMEOUT:-15}"

account_store() {
  local py_bin=""
  py_bin="$(resolve_host_python 2>/dev/null || true)"
  if [[ -z "$py_bin" ]]; then
    echo "${C_RED}[错误] 未找到可用的 Python 解释器，请运行 'colabd env setup' 初始化独立 uv 运行环境。${C_RESET}" >&2
    return 1
  fi
  COLAB_CLI_CONFIG_DIR="$COLAB_CLI_CONFIG_DIR" "$py_bin" "${COLABD_LIB_DIR}/account_store.py" "$@"
}

restore_oauth_swap_if_needed() {
  if [[ "${OAUTH_SWAP_ACTIVE:-0}" -eq 1 ]]; then
    OAUTH_SWAP_ACTIVE=0
    if [[ "${OAUTH_SWAP_HAD_PREV:-0}" -eq 1 && -n "${OAUTH_SWAP_BACKUP_FILE:-}" && -f "${OAUTH_SWAP_BACKUP_FILE}" ]]; then
      account_store oauth-import-active "$OAUTH_SWAP_BACKUP_FILE" >/dev/null 2>&1 || true
    else
      account_store oauth-clear-active >/dev/null 2>&1 || true
    fi
    [[ -n "${OAUTH_SWAP_BACKUP_FILE:-}" ]] && rm -f "$OAUTH_SWAP_BACKUP_FILE"
    OAUTH_SWAP_BACKUP_FILE=""
    OAUTH_SWAP_HAD_PREV=0
  fi
}

probe_colab_command() {
  local auth_mode="$1"
  local acct="$2"
  local timeout_sec="$3"
  shift 3

  local colab_bin=""
  colab_bin="$(resolve_colab_bin 2>/dev/null || true)"
  if [[ -z "$colab_bin" ]]; then
    echo "未安装 google-colab-cli"
    return 1
  fi

  local host_py=""
  host_py="$(resolve_host_python 2>/dev/null || true)"
  if [[ -z "$host_py" ]]; then
    echo "未找到可用的 Python 解释器"
    return 1
  fi

  local sess_cfg="${COLABD_PROBE_SESSIONS_FILE:-}"
  if [[ -z "$sess_cfg" ]]; then
    if [[ -n "$acct" ]]; then
      sess_cfg="$(colab_session_config_path "$acct")"
      mkdir -p "$(dirname "$sess_cfg")"
      chmod 700 "$(dirname "$sess_cfg")" 2>/dev/null || true
    elif [[ "$COLAB_CLI_CONFIG_DIR" != "$HOME/.config/colab-cli" ]]; then
      sess_cfg="${COLAB_CLI_CONFIG_DIR}/sessions.json"
      mkdir -p "$(dirname "$sess_cfg")"
    fi
  fi

  local adc_override="${COLABD_PROBE_ADC_FILE:-}"
  if [[ -z "$adc_override" && "$auth_mode" == "adc" && -n "$acct" ]]; then
    if ! adc_override="$(colab_adc_credentials_path "$acct")"; then
      echo "账号 '${acct}' 缺少本地 ADC 凭证文件 (adc.json)"
      return 1
    fi
  fi

  "$host_py" - "$colab_bin" "$auth_mode" "$sess_cfg" "$adc_override" "$timeout_sec" "$@" <<'PY'
import os
import signal
import subprocess
import sys

colab_bin, auth_mode, sess_cfg, adc_override, timeout_s = sys.argv[1:6]
sub_args = sys.argv[6:]

cmd = [colab_bin]
if sess_cfg:
    cmd.extend(["--config", sess_cfg])
cmd.extend(["--auth", auth_mode])
cmd.extend(sub_args)

env = os.environ.copy()
env["BROWSER"] = "/usr/bin/false"
if adc_override:
    env["GOOGLE_APPLICATION_CREDENTIALS"] = adc_override

try:
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
        start_new_session=True,
    )
    out, _ = proc.communicate(timeout=float(timeout_s))
    if out:
        sys.stdout.write(out)
    sys.exit(proc.returncode)
except subprocess.TimeoutExpired:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except Exception:
        pass
    try:
        proc.wait(timeout=1.0)
    except Exception:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except Exception:
            pass
    sys.stdout.write(f"探测超时 ({timeout_s}s，可能正在刷新 OAuth 令牌或网络较慢)\n")
    sys.exit(124)
except Exception as exc:
    sys.stdout.write(f"{exc}\n")
    sys.exit(1)
PY
}

# Prints FIELD_SEP-delimited row: email \x1f scope_checked \x1f missing_req_csv \x1f missing_opt_csv \x1f scopes_csv
probe_colab_identity_and_scopes() {
  local auth_mode="$1"
  local acct="$2"
  local timeout_sec="${3:-$COLABD_AUTH_PROBE_TIMEOUT}"
  local adc_file_override="${4:-}"

  local out=""
  local probe_rc=0
  if [[ -n "$adc_file_override" ]]; then
    out="$(COLABD_PROBE_ADC_FILE="$adc_file_override" probe_colab_command "$auth_mode" "$acct" "$timeout_sec" whoami 2>/dev/null)" || probe_rc=$?
  else
    out="$(probe_colab_command "$auth_mode" "$acct" "$timeout_sec" whoami 2>/dev/null)" || probe_rc=$?
  fi
  if [[ "$probe_rc" -ne 0 ]]; then
    return "$probe_rc"
  fi

  local adc_for_parse="$adc_file_override"
  if [[ -z "$adc_for_parse" && "$auth_mode" == "adc" ]]; then
    adc_for_parse="$(colab_adc_credentials_path "$acct" 2>/dev/null || true)"
  fi

  printf '%s' "$out" | account_store parse-whoami "$auth_mode" - --adc-file "$adc_for_parse"
}

_has_local_auth_credentials() {
  local mode="${1:-$COLAB_AUTH_MODE}"
  local acct="${2:-$ACTIVE_ACCOUNT}"
  if [[ "$mode" == "adc" ]]; then
    local adc_file=""
    adc_file="$(colab_adc_credentials_path "$acct" 2>/dev/null || true)"
    [[ -n "$adc_file" && -f "$adc_file" ]]
    return $?
  fi
  if account_store oauth-has-active >/dev/null 2>&1; then
    return 0
  fi
  if [[ -n "$acct" ]] && account_store exists "$ACCOUNTS_DIR" "$acct" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

format_short_scopes() {
  local csv="${1:-}"
  local out=""
  local rest="$csv"
  while [[ -n "$rest" ]]; do
    local item="${rest%%,*}"
    if [[ "$rest" == *","* ]]; then
      rest="${rest#*,}"
    else
      rest=""
    fi
    local short="${item##*/}"
    if [[ -n "$out" ]]; then
      out="${out}, ${short}"
    else
      out="${short}"
    fi
  done
  echo "$out"
}

_sessions_output_indicates_auth_error() {
  local txt="${1:-}"
  case "$txt" in
    *"No valid default credentials found"*|*"Not authenticated"*|*"ACCESS_TOKEN_SCOPE_INSUFFICIENT"*|*"HTTP 403"*|*"HTTP 401"*|*"Unauthorized"*)
      return 0
      ;;
  esac
  return 1
}

_adopt_external_login_if_valid() {
  local mode="$1"
  local email="$2"
  local scopes_csv="$3"
  local missing_opt="$4"

  [[ -z "$email" ]] && return 1

  local save_out=""
  if [[ "$mode" == "oauth2" ]]; then
    save_out="$(account_store oauth-save-account "$ACCOUNTS_DIR" "$email" \
      --scopes-csv "$scopes_csv" \
      --missing-req-csv "" \
      --missing-opt-csv "$missing_opt" 2>/dev/null || true)"
  else
    local adc_src=""
    adc_src="$(colab_adc_credentials_path "" 2>/dev/null || true)"
    [[ -z "$adc_src" || ! -f "$adc_src" ]] && return 1
    save_out="$(account_store adc-save-account "$ACCOUNTS_DIR" "$email" "$adc_src" \
      --scopes-csv "$scopes_csv" \
      --missing-req-csv "" \
      --missing-opt-csv "$missing_opt" 2>/dev/null || true)"
  fi

  [[ -z "$save_out" ]] && return 1
  local adopted_id=""
  IFS=$'\t' read -r _ adopted_id _ <<< "$save_out"
  [[ -z "$adopted_id" ]] && return 1

  local old_sess_cfg new_sess_cfg
  old_sess_cfg="${COLAB_CLI_CONFIG_DIR}/sessions.json"
  new_sess_cfg="$(colab_session_config_path "$adopted_id")"
  if [[ "$old_sess_cfg" != "$new_sess_cfg" ]]; then
    account_store sessions-migrate "$old_sess_cfg" "$new_sess_cfg" >/dev/null 2>&1 || true
  fi

  if [[ "$MANAGED_SESSION" -eq 1 && "$ACTIVE_SESSION_HAS_OWNER" -eq 1 && -z "$ACTIVE_SESSION_ACCOUNT" ]]; then
    ACTIVE_SESSION_ACCOUNT="$adopted_id"
  fi

  ACTIVE_ACCOUNT="$adopted_id"
  AUTH_EMAIL="$email"
  AUTH_NOTE="$(account_store meta-get "$ACCOUNTS_DIR" "$adopted_id" note 2>/dev/null || true)"
  save_config
  return 0
}

refresh_colab_auth_status() {
  local timeout_sec="${1:-$COLABD_AUTH_PROBE_TIMEOUT}"
  local force_whoami="${2:-0}"

  AUTH_MISSING_REQ_SCOPES=""
  AUTH_MISSING_OPT_SCOPES=""

  # Check CLI & host Python BEFORE touching ACTIVE_ACCOUNT so missing Python never wipes config!
  if ! resolve_colab_bin >/dev/null 2>&1; then
    AUTH_STATE="missing_cli"
    AUTH_DETAIL="未初始化独立 uv 运行环境或未安装 google-colab-cli"
    return 1
  fi
  if ! resolve_host_python >/dev/null 2>&1; then
    AUTH_STATE="missing_cli"
    AUTH_DETAIL="未找到可用 Python 解释器 (请运行 colabd env setup)"
    return 1
  fi

  if [[ -n "$ACTIVE_ACCOUNT" ]]; then
    local resolved_id=""
    if resolved_id="$(account_store resolve-id "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" 2>/dev/null)"; then
      if [[ "$resolved_id" != "$ACTIVE_ACCOUNT" ]]; then
        ACTIVE_ACCOUNT="$resolved_id"
        save_config
      fi
      local meta_mode meta_email meta_note meta_mreq meta_mopt
      meta_mode="$(account_store meta-get "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" auth_mode 2>/dev/null || true)"
      meta_email="$(account_store meta-get "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" email 2>/dev/null || true)"
      meta_note="$(account_store meta-get "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" note 2>/dev/null || true)"
      meta_mreq="$(account_store meta-get "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" missing_required_scopes 2>/dev/null || true)"
      meta_mopt="$(account_store meta-get "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" missing_optional_scopes 2>/dev/null || true)"
      if [[ "$meta_mode" == "oauth2" || "$meta_mode" == "adc" ]]; then
        COLAB_AUTH_MODE="$meta_mode"
      fi
      AUTH_EMAIL="$meta_email"
      AUTH_NOTE="$meta_note"
      AUTH_MISSING_REQ_SCOPES="$meta_mreq"
      AUTH_MISSING_OPT_SCOPES="$meta_mopt"
    else
      ACTIVE_ACCOUNT=""
      AUTH_EMAIL=""
      AUTH_NOTE=""
      save_config
    fi
  fi

  # Never auto-resurrect host gcloud ADC after explicit logout/remove.
  if [[ -z "$ACTIVE_ACCOUNT" && "$COLAB_AUTH_MODE" == "adc" && "${AUTO_ADOPT_EXTERNAL:-1}" == "0" ]]; then
    AUTH_STATE="unauth"
    AUTH_EMAIL=""
    AUTH_NOTE=""
    AUTH_DETAIL="当前未登录 (执行 colabd auth login 登录或 colabd switch 切换账号)"
    return 1
  fi

  if [[ "$COLAB_AUTH_MODE" == "adc" ]]; then
    local adc_file=""
    if ! adc_file="$(colab_adc_credentials_path "$ACTIVE_ACCOUNT")" || [[ ! -f "$adc_file" ]]; then
      AUTH_STATE="unauth"
      AUTH_DETAIL="未找到 ADC 凭证文件 (请运行 colabd auth refresh ${ACTIVE_ACCOUNT})"
      return 1
    fi
  fi

  local probe_out=""
  local probe_rc=0
  local sess_ok=0
  if probe_out="$(probe_colab_command "$COLAB_AUTH_MODE" "$ACTIVE_ACCOUNT" "$timeout_sec" sessions 2>/dev/null)"; then
    if ! _sessions_output_indicates_auth_error "$probe_out"; then
      sess_ok=1
    fi
  else
    probe_rc=$?
  fi

  if [[ "$sess_ok" -eq 1 ]]; then
    local first_line=""
    first_line="$(printf '%s\n' "$probe_out" | awk 'NF {print; exit}')"
    AUTH_DETAIL="${first_line:-凭证有效}"
    if [[ "${#AUTH_DETAIL}" -gt 72 ]]; then
      AUTH_DETAIL="${AUTH_DETAIL:0:72}"
    fi

    # Always verify ADC via whoami (because real `colab --auth adc sessions` swallows SystemExit on empty sessions!),
    # and re-verify when forced, un-adopted, missing email, or previously flagged missing_required_scopes.
    if [[ "$COLAB_AUTH_MODE" == "adc" || "$force_whoami" == "1" || -z "$ACTIVE_ACCOUNT" || -z "$AUTH_EMAIL" || -n "$AUTH_MISSING_REQ_SCOPES" ]]; then
      local w_tsv=""
      local w_rc=0
      if w_tsv="$(probe_colab_identity_and_scopes "$COLAB_AUTH_MODE" "$ACTIVE_ACCOUNT" "$timeout_sec" 2>/dev/null)"; then
        local w_email w_checked w_mreq w_mopt w_scopes
        IFS="$FIELD_SEP" read -r w_email w_checked w_mreq w_mopt w_scopes <<< "$w_tsv"
        [[ -n "$w_email" ]] && AUTH_EMAIL="$w_email"
        if [[ "$w_checked" == "1" ]]; then
          AUTH_MISSING_REQ_SCOPES="$w_mreq"
          AUTH_MISSING_OPT_SCOPES="$w_mopt"
          if [[ -n "$ACTIVE_ACCOUNT" ]]; then
            account_store meta-set "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" \
              --scopes-csv "$w_scopes" \
              --missing-req-csv "$w_mreq" \
              --missing-opt-csv "$w_mopt" >/dev/null 2>&1 || true
          fi
        fi

        if [[ -n "$AUTH_MISSING_REQ_SCOPES" ]]; then
          AUTH_STATE="insufficient_scope"
          AUTH_DETAIL="权限域不足: 缺少 $(format_short_scopes "$AUTH_MISSING_REQ_SCOPES") (请运行 colabd auth refresh)"
          return 1
        fi

        if [[ -z "$ACTIVE_ACCOUNT" && -n "$AUTH_EMAIL" && ( "$COLAB_AUTH_MODE" == "oauth2" || "${AUTO_ADOPT_EXTERNAL:-1}" == "1" ) ]]; then
          _adopt_external_login_if_valid "$COLAB_AUTH_MODE" "$AUTH_EMAIL" "$w_scopes" "$w_mopt" || true
        fi
      else
        w_rc=$?
        if [[ "$COLAB_AUTH_MODE" == "adc" ]]; then
          if [[ "$w_rc" -eq 124 ]]; then
            AUTH_STATE="timeout"
            AUTH_DETAIL="ADC 认证状态探测超时 (${timeout_sec}s，可能正在刷新令牌或网络较慢)"
            return 1
          fi
          AUTH_STATE="unauth"
          AUTH_DETAIL="ADC 凭证无效或已过期 (请运行 colabd auth refresh ${ACTIVE_ACCOUNT})"
          return 1
        fi
      fi
    fi

    if [[ -n "$AUTH_MISSING_REQ_SCOPES" ]]; then
      AUTH_STATE="insufficient_scope"
      AUTH_DETAIL="权限域不足: 缺少 $(format_short_scopes "$AUTH_MISSING_REQ_SCOPES") (请运行 colabd auth refresh)"
      return 1
    fi

    AUTH_STATE="ok"
    return 0
  else
    # Timeout (rc=124) while local credentials exist is a slow OAuth refresh / network stall,
    # NOT an expired/logged-out account — never misreport it as `unauth`!
    if [[ "$probe_rc" -eq 124 ]] && _has_local_auth_credentials "$COLAB_AUTH_MODE" "$ACTIVE_ACCOUNT"; then
      AUTH_STATE="timeout"
      AUTH_DETAIL="认证状态探测超时 (${timeout_sec}s，可能正在刷新 OAuth 令牌或网络较慢；本地凭证保留)"
      return 1
    fi

    # sessions failed — inspect whoami to distinguish missing scopes (403) from truly unauthenticated
    local w_tsv=""
    if w_tsv="$(probe_colab_identity_and_scopes "$COLAB_AUTH_MODE" "$ACTIVE_ACCOUNT" "$timeout_sec" 2>/dev/null)"; then
      local w_email w_checked w_mreq w_mopt w_scopes
      IFS="$FIELD_SEP" read -r w_email w_checked w_mreq w_mopt w_scopes <<< "$w_tsv"
      [[ -n "$w_email" ]] && AUTH_EMAIL="$w_email"
      if [[ "$w_checked" == "1" && -n "$w_mreq" ]]; then
        AUTH_MISSING_REQ_SCOPES="$w_mreq"
        AUTH_MISSING_OPT_SCOPES="$w_mopt"
        if [[ -n "$ACTIVE_ACCOUNT" ]]; then
          account_store meta-set "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" \
            --scopes-csv "$w_scopes" \
            --missing-req-csv "$w_mreq" \
            --missing-opt-csv "$w_mopt" >/dev/null 2>&1 || true
        fi
        AUTH_STATE="insufficient_scope"
        AUTH_DETAIL="权限域不足: 缺少 $(format_short_scopes "$w_mreq") (请运行 colabd auth refresh 补齐)"
        return 1
      fi
    fi

    AUTH_STATE="unauth"
    local err_line=""
    err_line="$(printf '%s\n' "$probe_out" | awk 'NF {line=$0} END {print line}')"
    AUTH_DETAIL="${err_line:-未登录或令牌失效}"
    if [[ "${#AUTH_DETAIL}" -gt 72 ]]; then
      AUTH_DETAIL="${AUTH_DETAIL:0:72}"
    fi
    if [[ -z "$ACTIVE_ACCOUNT" ]]; then
      AUTH_EMAIL=""
      AUTH_NOTE=""
    fi
    return 1
  fi
}

format_auth_badge() {
  local id_part=""
  if [[ -n "$ACTIVE_ACCOUNT" ]]; then
    id_part="${ACTIVE_ACCOUNT}"
    [[ -n "$AUTH_NOTE" ]] && id_part="${id_part} [${AUTH_NOTE}]"
    id_part="${id_part} | "
  elif [[ -n "$AUTH_EMAIL" ]]; then
    id_part="${AUTH_EMAIL} | "
  fi

  case "$AUTH_STATE" in
    ok)
      local scope_warn=""
      if [[ -n "$AUTH_MISSING_OPT_SCOPES" ]]; then
        scope_warn=" | ${C_YELLOW}⚠缺 $(format_short_scopes "$AUTH_MISSING_OPT_SCOPES")${C_RESET}"
      fi
      echo "${C_GREEN}● 已登录${C_RESET} (${id_part}模式: ${COLAB_AUTH_MODE}${scope_warn} | GCP自动授权: $( [[ "$AUTO_GCP_AUTH" == "1" ]] && echo "开" || echo "关" ))"
      ;;
    insufficient_scope)
      echo "${C_RED}⚠ 权限域不足${C_RESET} (${id_part}缺少 $(format_short_scopes "$AUTH_MISSING_REQ_SCOPES") — 请执行 'colabd auth refresh' 或进菜单 [6]->[4])"
      ;;
    missing_cli)
      echo "${C_RED}✗ 未初始化独立 uv 运行环境${C_RESET} (请执行 'colabd env setup' 或进菜单 [6]->[9])"
      ;;
    timeout)
      echo "${C_YELLOW}◌ 认证状态探测超时${C_RESET} (${id_part}模式: ${COLAB_AUTH_MODE} — 令牌刷新中或网络较慢，凭证保留，可重试)"
      ;;
    unauth)
      echo "${C_YELLOW}○ 未登录或令牌已过期${C_RESET} (${id_part}模式: ${COLAB_AUTH_MODE} — 请进菜单 [6] 登录或切号)"
      ;;
    *)
      echo "${C_DIM}○ 待检测${C_RESET} (${id_part}模式: ${COLAB_AUTH_MODE})"
      ;;
  esac
}

sync_active_oauth_to_profile() {
  if [[ -z "$ACTIVE_ACCOUNT" ]]; then
    return 0
  fi
  if ! account_store exists "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" >/dev/null 2>&1; then
    return 0
  fi
  local pmode pemail
  pmode="$(account_store meta-get "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" auth_mode 2>/dev/null || true)"
  pemail="$(account_store meta-get "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" email 2>/dev/null || true)"
  if [[ "$pmode" != "oauth2" || -z "$pemail" ]]; then
    return 0
  fi
  if account_store oauth-has-active >/dev/null 2>&1; then
    # Guard against external keyring drift: if active token carries a different email, do NOT overwrite pemail's slot!
    local peek_email=""
    peek_email="$(account_store oauth-peek-active-email 2>/dev/null || true)"
    if [[ -n "$peek_email" && "$peek_email" != "$pemail" ]]; then
      return 0
    fi
    account_store oauth-save-account "$ACCOUNTS_DIR" "$pemail" >/dev/null 2>&1 || true
  fi
  return 0
}

run_with_account_creds() {
  local target_acct="$1"
  local target_mode="$2"
  local callback_fn="$3"
  shift 3

  if [[ "$target_mode" == "adc" ]]; then
    if [[ -n "$target_acct" ]] && ! colab_adc_credentials_path "$target_acct" >/dev/null 2>&1; then
      return 1
    fi
    "$callback_fn" "$target_acct" "$target_mode" "$@"
    return $?
  fi

  if [[ "$target_acct" == "$ACTIVE_ACCOUNT" && "$COLAB_AUTH_MODE" == "oauth2" ]]; then
    "$callback_fn" "$target_acct" "$target_mode" "$@"
    return $?
  fi

  sync_active_oauth_to_profile || true

  local backup_file="${STATE_DIR}/oauth_swap_backup.$$.json"
  local had_prev=0
  if account_store oauth-export-active "$backup_file" >/dev/null 2>&1; then
    had_prev=1
  fi

  local swapped=0
  if [[ -n "$target_acct" ]]; then
    OAUTH_SWAP_BACKUP_FILE="$backup_file"
    OAUTH_SWAP_HAD_PREV="$had_prev"
    OAUTH_SWAP_ACTIVE=1
    if account_store oauth-activate-account "$ACCOUNTS_DIR" "$target_acct" >/dev/null 2>&1; then
      swapped=1
    else
      OAUTH_SWAP_ACTIVE=0
      OAUTH_SWAP_BACKUP_FILE=""
      OAUTH_SWAP_HAD_PREV=0
      rm -f "$backup_file"
      return 1
    fi
  fi

  local rc=0
  "$callback_fn" "$target_acct" "$target_mode" "$@" || rc=$?

  if [[ "$swapped" -eq 1 ]]; then
    restore_oauth_swap_if_needed
  else
    rm -f "$backup_file"
  fi
  return "$rc"
}

print_saved_accounts_table() {
  local rows=""
  rows="$(account_store list "$ACCOUNTS_DIR" 2>/dev/null || true)"
  if [[ -z "$rows" ]]; then
    echo "    ${C_DIM}(尚无已登录账号；选 [3] 登录首个 Google 账号，或执行 colabd auth login)${C_RESET}"
    return 1
  fi

  local acc_id mode note has_cred scope_st scount snames
  while IFS="$FIELD_SEP" read -r acc_id mode _ note has_cred scope_st scount snames _; do
    [[ -z "$acc_id" ]] && continue
    local marker=" "
    local color=""
    local end_color=""
    if [[ "$acc_id" == "$ACTIVE_ACCOUNT" ]]; then
      marker="*"
      color="${C_GREEN}"
      end_color="${C_RESET}"
    fi

    local scope_disp="权限正常"
    case "$scope_st" in
      missing:*) scope_disp="${C_RED}✗缺 ${scope_st#missing:}${C_RESET}" ;;
      warn:*)    scope_disp="${C_YELLOW}⚠缺 ${scope_st#warn:}${C_RESET}" ;;
      unknown)   scope_disp="${C_DIM}待校验${C_RESET}" ;;
    esac

    local cred_warn=""
    if [[ "$has_cred" != "1" ]]; then
      cred_warn=" ${C_RED}[凭证缺失]${C_RESET}"
    fi

    local sess_info="活跃实例: 0"
    if [[ "${scount:-0}" -gt 0 ]]; then
      sess_info="${C_YELLOW}活跃实例: ${scount} (${snames})${C_RESET}"
    fi

    local note_part=""
    [[ -n "$note" ]] && note_part="  备注: ${note}"

    printf '    %s%s %-30s [%-6s] %s  |  %s%s%s%s\n' \
      "$color" "$marker" "$acc_id" "$mode" "$scope_disp" "$sess_info" "$note_part" "$cred_warn" "$end_color"
  done <<< "$rows"
  return 0
}

resolve_account_id() {
  local query="${1:-}"
  [[ -z "$query" ]] && return 1
  account_store resolve-id "$ACCOUNTS_DIR" "$query" 2>/dev/null
}

# Unified login + scope validation + identity dedup + in-place refresh engine.
# Args: <mode: oauth2|adc> <interactive_retry: 1|0> <expected_id: ""|canonical_id> <note_arg>
_authenticate_and_save_account() {
  local mode="$1"
  local interactive_retry="${2:-1}"
  local expected_id="${3:-}"
  local note_arg="${4:-}"

  local colab_bin=""
  if ! colab_bin="$(resolve_colab_bin 2>/dev/null)"; then
    echo "${C_RED}[错误] 未找到 colab 命令，请先运行 'colabd env setup'。${C_RESET}"
    return 1
  fi

  local backup_file="${STATE_DIR}/prev_oauth.$$.json"
  local had_prev=0
  if [[ "$mode" == "oauth2" ]]; then
    sync_active_oauth_to_profile || true
    if account_store oauth-export-active "$backup_file" >/dev/null 2>&1; then
      had_prev=1
    fi
  fi

  local tmp_sess="${STATE_DIR}/login_probe_sessions.$$.json"
  local tmp_adc="${STATE_DIR}/adc_candidate.$$.json"

  local supports_whoami=0
  if "$colab_bin" whoami --help >/dev/null 2>&1; then
    supports_whoami=1
  fi

  while true; do
    rm -f "$tmp_sess" "${tmp_sess}.lock" "$tmp_adc"

    if [[ "$mode" == "oauth2" ]]; then
      # Clear ONLY local keyring (never call Google /revoke before login: colab_cli already passes
      # prompt="consent", and revoking the shared Cloud SDK client_id would also kill gcloud ADC!)
      OAUTH_SWAP_BACKUP_FILE="$backup_file"
      OAUTH_SWAP_HAD_PREV="$had_prev"
      OAUTH_SWAP_ACTIVE=1
      echo "${C_CYAN}[准备授权] 正在清除本地活跃 OAuth 2.0 令牌以便拉起完整权限勾选页...${C_RESET}"
      account_store oauth-clear-active >/dev/null 2>&1 || true

      echo "${C_CYAN}[OAuth 2.0 授权] 请打开下方链接登录目标 Google 账号，务必勾选【Colab / 邮箱 / Google Drive】全部复选框，然后粘贴授权码：${C_RESET}"
      # NEVER redirect stdout/stderr here: real colab prints the URL to stderr and input() prompt to stdout!
      # OAUTHLIB_RELAX_TOKEN_SCOPE=1 prevents oauthlib from crashing before colabd inspects missing scopes.
      if [[ "$supports_whoami" -eq 1 ]]; then
        OAUTHLIB_RELAX_TOKEN_SCOPE=1 "$colab_bin" --config "$tmp_sess" --auth oauth2 whoami || true
      else
        OAUTHLIB_RELAX_TOKEN_SCOPE=1 "$colab_bin" --config "$tmp_sess" --auth oauth2 sessions || true
      fi

      if ! account_store oauth-has-active >/dev/null 2>&1; then
        echo "${C_RED}[失败] OAuth 2.0 登录未完成或被取消，正在恢复原账号凭证...${C_RESET}"
        restore_oauth_swap_if_needed
        rm -f "$tmp_sess" "${tmp_sess}.lock"
        refresh_colab_auth_status "" 0 || true
        return 1
      fi
    else
      if ! command -v gcloud >/dev/null 2>&1; then
        echo "${C_RED}[错误] 本机未检测到 'gcloud' 命令，无法进行 ADC 授权。${C_RESET}"
        rm -f "$backup_file" "$tmp_sess" "${tmp_sess}.lock"
        return 1
      fi
      echo "${C_CYAN}[ADC 授权] 正在拉起 gcloud ADC 登录 (自动附带完整 colaboratory 权限域)...${C_RESET}"
      if ! gcloud auth application-default login --scopes="$ADC_SCOPES"; then
        echo "${C_RED}[失败] gcloud ADC 登录未完成或被取消。${C_RESET}"
        rm -f "$backup_file" "$tmp_sess" "${tmp_sess}.lock"
        return 1
      fi
      local adc_src="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"
      if [[ ! -f "$adc_src" ]]; then
        echo "${C_RED}[失败] 未在 ${adc_src} 找到新生成的 ADC 凭证文件。${C_RESET}"
        rm -f "$backup_file" "$tmp_sess" "${tmp_sess}.lock"
        return 1
      fi
      cp "$adc_src" "$tmp_adc"
      chmod 600 "$tmp_adc" 2>/dev/null || true
    fi

    # Validate identity and granted scopes using isolated $tmp_sess (NEVER touching ~/.config/colab-cli/sessions.json!)
    local w_tsv=""
    local adc_probe_arg=""
    [[ "$mode" == "adc" ]] && adc_probe_arg="$tmp_adc"
    w_tsv="$(COLABD_PROBE_SESSIONS_FILE="$tmp_sess" probe_colab_identity_and_scopes "$mode" "" "$COLABD_AUTH_PROBE_TIMEOUT" "$adc_probe_arg" 2>/dev/null || true)"

    local new_email="" scope_checked="0" missing_req="" missing_opt="" all_scopes=""
    if [[ -n "$w_tsv" ]]; then
      IFS="$FIELD_SEP" read -r new_email scope_checked missing_req missing_opt all_scopes <<< "$w_tsv"
    fi

    if [[ -z "$new_email" && "$mode" == "adc" ]]; then
      new_email="$(account_store adc-extract-email "$tmp_adc" 2>/dev/null || true)"
    fi

    # 1. Hard gate: missing required scopes or unreadable email identity
    if [[ -n "$missing_req" || -z "$new_email" ]]; then
      echo ""
      echo "${C_RED}[权限域校验未通过] 本次授权缺少必需权限，已拦截入库！${C_RESET}"
      if [[ -n "$missing_req" ]]; then
        echo "  缺失必需权限域 : ${C_RED}$(format_short_scopes "$missing_req")${C_RESET}"
      fi
      if [[ -z "$new_email" ]]; then
        echo "  缺失账号邮箱   : ${C_RED}无法从 token 读取 userinfo.email，无法建立唯一账号 ID${C_RESET}"
      fi
      if [[ "$mode" == "oauth2" ]]; then
        echo "  原因说明       : 在 Google 细粒度授权页漏勾了 Colab 或邮箱复选框，会导致后续全部请求报 403。"
      else
        echo "  原因说明       : ADC 凭证缺少 colaboratory / cloud-platform 权限域，需带 --scopes 重新登录。"
      fi

      if [[ "$interactive_retry" == "1" ]]; then
        read -r -p "是否立即清除该残缺令牌并重新授权? [Y/n]: " retry_yn
        if [[ ! "${retry_yn:-Y}" =~ ^[Nn]$ ]]; then
          continue
        fi
      fi

      echo "${C_YELLOW}[已中止] 未保存残缺凭证，正在恢复原账号状态...${C_RESET}"
      if [[ "$mode" == "oauth2" ]]; then
        restore_oauth_swap_if_needed
      fi
      rm -f "$backup_file" "$tmp_sess" "${tmp_sess}.lock" "$tmp_adc"
      refresh_colab_auth_status "" 0 || true
      return 1
    fi

    # 2. Verify actual Colab backend access using $tmp_sess (and detect swallowed SystemExit in ADC!)
    local sess_check_out=""
    local sess_check_ok=0
    if [[ "$mode" == "adc" ]]; then
      if sess_check_out="$(COLABD_PROBE_SESSIONS_FILE="$tmp_sess" COLABD_PROBE_ADC_FILE="$tmp_adc" probe_colab_command "$mode" "" "$COLABD_AUTH_PROBE_TIMEOUT" sessions 2>&1)"; then
        if ! _sessions_output_indicates_auth_error "$sess_check_out"; then
          sess_check_ok=1
        fi
      fi
    else
      if sess_check_out="$(COLABD_PROBE_SESSIONS_FILE="$tmp_sess" probe_colab_command "$mode" "" "$COLABD_AUTH_PROBE_TIMEOUT" sessions 2>&1)"; then
        if ! _sessions_output_indicates_auth_error "$sess_check_out"; then
          sess_check_ok=1
        fi
      fi
    fi

    if [[ "$sess_check_ok" -ne 1 ]]; then
      echo "${C_RED}[校验失败] 凭证未能通过 Colab 后端访问测试: ${sess_check_out}${C_RESET}"
      if [[ "$interactive_retry" == "1" ]]; then
        read -r -p "是否立即重新授权? [Y/n]: " retry_yn
        if [[ ! "${retry_yn:-Y}" =~ ^[Nn]$ ]]; then
          continue
        fi
      fi
      if [[ "$mode" == "oauth2" ]]; then
        restore_oauth_swap_if_needed
      fi
      rm -f "$backup_file" "$tmp_sess" "${tmp_sess}.lock" "$tmp_adc"
      refresh_colab_auth_status "" 0 || true
      return 1
    fi

    # 3. Recommended optional scopes warning (e.g., drive.file)
    if [[ "$scope_checked" == "1" && -n "$missing_opt" ]]; then
      echo ""
      echo "${C_YELLOW}[权限提示] 账号 '${new_email}' 缺少推荐权限域: $(format_short_scopes "$missing_opt")${C_RESET}"
      echo "  说明: 未授予 Google Drive 权限 (drive.file) 时将无法挂载云盘缓存权重（纯本地模式仍可用）。"
      if [[ "$interactive_retry" == "1" ]]; then
        read -r -p "是否立即重新授权以补齐全部权限? [Y/n]: " opt_retry
        if [[ ! "${opt_retry:-Y}" =~ ^[Nn]$ ]]; then
          continue
        fi
      fi
    fi

    # 4. Identity match guard when refreshing a specific existing account
    #    (Legacy v1 slot IDs without '@' are seamlessly upgraded to the newly discovered email identity.)
    local got_id=""
    got_id="$(account_store canonical-id "$new_email" "$mode")"
    if [[ -n "$expected_id" && "$expected_id" == *"@"* && "$got_id" != "$expected_id" ]]; then
      echo ""
      echo "${C_YELLOW}[身份不匹配] 你正在刷新账号 '${expected_id}'，但本次浏览器授权返回的账号是 '${got_id}'！${C_RESET}"
      if [[ "$interactive_retry" == "1" ]]; then
        echo "  1) 丢弃本次授权，重新为 '${expected_id}' 授权"
        echo "  2) 改为按 '${got_id}' 登录/更新并切换至该账号"
        echo "  0) 取消并恢复原凭证"
        read -r -p "请选择 [1]: " mis_opt
        case "${mis_opt:-1}" in
          1) continue ;;
          2)
            # If switching away from an active managed session on ACTIVE_ACCOUNT, run release guard first!
            if [[ "$got_id" != "$ACTIVE_ACCOUNT" && "$MANAGED_SESSION" -eq 1 ]]; then
              restore_oauth_swap_if_needed
              echo "${C_YELLOW}[提示] 当前存在运行中的托管实例，请先释放后再切换至 '${got_id}'。${C_RESET}"
              rm -f "$backup_file" "$tmp_sess" "${tmp_sess}.lock" "$tmp_adc"
              return 1
            fi
            expected_id=""
            ;;
          *)
            if [[ "$mode" == "oauth2" ]]; then
              restore_oauth_swap_if_needed
            fi
            rm -f "$backup_file" "$tmp_sess" "${tmp_sess}.lock" "$tmp_adc"
            refresh_colab_auth_status "" 0 || true
            return 1
            ;;
        esac
      else
        echo "${C_RED}[拒绝覆盖] 非交互刷新模式下账号身份不一致 (${got_id} != ${expected_id})，已中止并回滚。${C_RESET}" >&2
        if [[ "$mode" == "oauth2" ]]; then
          restore_oauth_swap_if_needed
        fi
        rm -f "$backup_file" "$tmp_sess" "${tmp_sess}.lock" "$tmp_adc"
        refresh_colab_auth_status "" 0 || true
        return 1
      fi
    fi

    # 5. Deduplicated save into account store (use `--note=...` so notes starting with `-` work cleanly)
    local save_out=""
    local save_ok=0
    if [[ "$mode" == "oauth2" ]]; then
      if [[ -n "$note_arg" ]]; then
        if save_out="$(account_store oauth-save-account "$ACCOUNTS_DIR" "$new_email" \
          "--note=${note_arg}" \
          "--scopes-csv=${all_scopes}" \
          "--missing-req-csv=" \
          "--missing-opt-csv=${missing_opt}")"; then
          save_ok=1
        fi
      else
        if save_out="$(account_store oauth-save-account "$ACCOUNTS_DIR" "$new_email" \
          "--scopes-csv=${all_scopes}" \
          "--missing-req-csv=" \
          "--missing-opt-csv=${missing_opt}")"; then
          save_ok=1
        fi
      fi
    else
      if [[ -n "$note_arg" ]]; then
        if save_out="$(account_store adc-save-account "$ACCOUNTS_DIR" "$new_email" "$tmp_adc" \
          "--note=${note_arg}" \
          "--scopes-csv=${all_scopes}" \
          "--missing-req-csv=" \
          "--missing-opt-csv=${missing_opt}")"; then
          save_ok=1
        fi
      else
        if save_out="$(account_store adc-save-account "$ACCOUNTS_DIR" "$new_email" "$tmp_adc" \
          "--scopes-csv=${all_scopes}" \
          "--missing-req-csv=" \
          "--missing-opt-csv=${missing_opt}")"; then
          save_ok=1
        fi
      fi
    fi

    if [[ "$save_ok" -ne 1 ]]; then
      echo "${C_RED}[失败] 写入本地账号库失败，正在恢复原账号状态...${C_RESET}"
      if [[ "$mode" == "oauth2" ]]; then
        restore_oauth_swap_if_needed
      fi
      rm -f "$backup_file" "$tmp_sess" "${tmp_sess}.lock" "$tmp_adc"
      return 1
    fi

    local save_status saved_id storage_kind
    IFS=$'\t' read -r save_status saved_id storage_kind <<< "$save_out"

    # Commit successful login: disarm swap rollback and clean temp files
    OAUTH_SWAP_ACTIVE=0
    OAUTH_SWAP_BACKUP_FILE=""
    OAUTH_SWAP_HAD_PREV=0
    rm -f "$backup_file" "$tmp_sess" "${tmp_sess}.lock" "$tmp_adc"

    ACTIVE_ACCOUNT="$saved_id"
    COLAB_AUTH_MODE="$mode"
    AUTO_ADOPT_EXTERNAL="1"
    AUTH_EMAIL="$new_email"
    AUTH_NOTE="$(account_store meta-get "$ACCOUNTS_DIR" "$saved_id" note 2>/dev/null || true)"
    AUTH_MISSING_REQ_SCOPES=""
    AUTH_MISSING_OPT_SCOPES="$missing_opt"
    AUTH_STATE="ok"
    save_config

    if [[ -n "$expected_id" ]]; then
      echo "${C_GREEN}[权限刷新成功] 账号 '${saved_id}' 凭证与权限域已原地更新（原有会话记录与备注均已保留，存储: ${storage_kind}）。${C_RESET}"
    elif [[ "$save_status" == "updated" ]]; then
      echo "${C_YELLOW}[去重检测] 账号 '${saved_id}' 已存在，未创建重复账号 — 已原地刷新其凭证并保留原有 sessions.json 与备注（存储: ${storage_kind}）。${C_RESET}"
    else
      echo "${C_GREEN}[登录成功] 账号 '${saved_id}' 已通过权限域校验并入库激活（存储: ${storage_kind}）。${C_RESET}"
    fi
    return 0
  done
}

do_login_account() {
  local mode_arg="${1:-}"
  local note_arg="${2:-}"
  local auto_release_mode="${3:-prompt}"
  local interactive_retry="1"
  [[ "$auto_release_mode" != "prompt" ]] && interactive_retry="0"

  if ! resolve_colab_bin >/dev/null 2>&1; then
    echo "${C_RED}[错误] 请先初始化独立 uv 运行环境（执行 colabd env setup 或进菜单 [6]->[9]）。${C_RESET}"
    return 1
  fi

  if [[ -n "$ACTIVE_ACCOUNT" || "$MANAGED_SESSION" -eq 1 ]]; then
    if ! guard_release_before_account_change "登录新账号" "" "$auto_release_mode"; then
      return 1
    fi
  fi

  local mode="$mode_arg"
  if [[ -z "$mode" ]]; then
    echo ""
    echo "选择登录方式:"
    echo "  1) Google OAuth 2.0 个人账号 (Free / Pro / Pro+ 推荐，令牌加密存于系统钥匙串)"
    echo "  2) GCP ADC 登录 (gcloud auth application-default login，自动附带完整 colaboratory 权限域)"
    read -r -p "请选择 [1]: " m_opt
    if [[ "${m_opt:-1}" == "2" ]]; then
      mode="adc"
    else
      mode="oauth2"
    fi
  fi

  if [[ "$mode" != "oauth2" && "$mode" != "adc" ]]; then
    echo "${C_RED}[错误] 不支持的认证模式: ${mode} (仅支持 oauth2 或 adc)。${C_RESET}"
    return 1
  fi

  _authenticate_and_save_account "$mode" "$interactive_retry" "" "$note_arg"
}

do_refresh_account() {
  local target_query="${1:-}"
  local interactive_retry="${2:-1}"

  if ! resolve_colab_bin >/dev/null 2>&1; then
    echo "${C_RED}[错误] 请先初始化独立 uv 运行环境（执行 colabd env setup）。${C_RESET}"
    return 1
  fi

  local target_id=""
  local target_mode="$COLAB_AUTH_MODE"

  if [[ -n "$target_query" ]]; then
    if ! target_id="$(resolve_account_id "$target_query")"; then
      echo "${C_RED}[错误] 未找到账号 '${target_query}'。${C_RESET}"
      return 1
    fi
    target_mode="$(account_store meta-get "$ACCOUNTS_DIR" "$target_id" auth_mode 2>/dev/null || echo "oauth2")"
  elif [[ -n "$ACTIVE_ACCOUNT" ]]; then
    target_id="$ACTIVE_ACCOUNT"
    target_mode="$(account_store meta-get "$ACCOUNTS_DIR" "$target_id" auth_mode 2>/dev/null || echo "$COLAB_AUTH_MODE")"
  else
    echo "${C_CYAN}[权限修复] 正在对当前 ${COLAB_AUTH_MODE} 登录重新发起完整权限域授权...${C_RESET}"
    _authenticate_and_save_account "$COLAB_AUTH_MODE" "$interactive_retry" "" ""
    return $?
  fi

  if [[ "$target_id" != "$ACTIVE_ACCOUNT" && ( -n "$ACTIVE_ACCOUNT" || "$MANAGED_SESSION" -eq 1 ) ]]; then
    local gmode="prompt"
    [[ "$interactive_retry" != "1" ]] && gmode="release"
    if ! guard_release_before_account_change "刷新账号 '${target_id}' 凭证" "" "$gmode"; then
      return 1
    fi
  fi

  echo "${C_CYAN}[原地刷新] 正在重新授权账号 '${target_id}' (${target_mode})，原有 sessions.json 与备注将完整保留...${C_RESET}"
  _authenticate_and_save_account "$target_mode" "$interactive_retry" "$target_id" ""
}

do_edit_account_note() {
  local target_query="${1:-}"
  local new_note="${2-__UNSET__}"

  if [[ -z "$target_query" ]]; then
    echo ""
    echo "${C_BOLD}当前已登录账号列表:${C_RESET}"
    if ! print_saved_accounts_table; then
      return 1
    fi
    read -r -p "输入要编辑备注的账号 ID (如 alice@gmail.com，回车取消): " target_query
    [[ -z "$target_query" ]] && return 1
  fi

  local target_id=""
  if ! target_id="$(resolve_account_id "$target_query")"; then
    echo "${C_RED}[错误] 未找到账号: '${target_query}'。${C_RESET}"
    return 1
  fi

  if [[ "$new_note" == "__UNSET__" ]]; then
    local cur_note=""
    cur_note="$(account_store meta-get "$ACCOUNTS_DIR" "$target_id" note 2>/dev/null || true)"
    read -r -p "输入账号 '${target_id}' 的新备注 (当前: '${cur_note}'，输入 CLEAR 清空): " new_note
    [[ "$new_note" == "CLEAR" ]] && new_note=""
  fi

  account_store meta-set "$ACCOUNTS_DIR" "$target_id" "--note=${new_note}"
  if [[ "$target_id" == "$ACTIVE_ACCOUNT" ]]; then
    AUTH_NOTE="$new_note"
  fi
  echo "${C_GREEN}[已更新] 账号 '${target_id}' 备注已设为 '${new_note:-"(空)"}'。${C_RESET}"
  return 0
}

do_switch_account() {
  local target_query="${1:-}"
  local auto_release_mode="${2:-prompt}"

  if ! resolve_colab_bin >/dev/null 2>&1; then
    echo "${C_RED}[错误] 本机尚未初始化独立 uv 运行环境或未安装 google-colab-cli。${C_RESET}"
    return 1
  fi

  if [[ -z "$target_query" ]]; then
    echo ""
    echo "${C_BOLD}已登录账号列表:${C_RESET}"
    if ! print_saved_accounts_table; then
      return 1
    fi
    read -r -p "输入要切换的账号 ID / 邮箱 (回车取消): " target_query
    [[ -z "$target_query" ]] && return 1
  fi

  local target_id=""
  if ! target_id="$(resolve_account_id "$target_query")"; then
    echo "${C_RED}[错误] 未找到账号: '${target_query}'（请使用 'colabd auth list' 查看完整账号 ID）。${C_RESET}"
    return 1
  fi

  local target_mode target_email target_note
  target_mode="$(account_store meta-get "$ACCOUNTS_DIR" "$target_id" auth_mode 2>/dev/null || echo "oauth2")"
  target_email="$(account_store meta-get "$ACCOUNTS_DIR" "$target_id" email 2>/dev/null || true)"
  target_note="$(account_store meta-get "$ACCOUNTS_DIR" "$target_id" note 2>/dev/null || true)"

  if [[ "$target_id" == "$ACTIVE_ACCOUNT" ]]; then
    if [[ "$target_mode" == "oauth2" ]]; then
      account_store oauth-activate-account "$ACCOUNTS_DIR" "$target_id" >/dev/null 2>&1 || true
    fi
    COLAB_AUTH_MODE="$target_mode"
    AUTO_ADOPT_EXTERNAL="1"
    save_config
    refresh_colab_auth_status "" 1 || true
    echo "${C_GREEN}[提示] 当前已位于账号 '${target_id}'，状态与权限域已刷新。${C_RESET}"
    return 0
  fi

  if ! guard_release_before_account_change "切换至账号 '${target_id}'" "" "$auto_release_mode"; then
    return 1
  fi

  sync_active_oauth_to_profile || true

  if [[ "$target_mode" == "oauth2" ]]; then
    local act_store=""
    if ! act_store="$(account_store oauth-activate-account "$ACCOUNTS_DIR" "$target_id")"; then
      echo "${C_RED}[失败] 无法加载账号 '${target_id}' 的 OAuth 2.0 令牌，请运行 'colabd auth refresh ${target_id}' 重新授权。${C_RESET}"
      return 1
    fi
    if [[ "$act_store" == "legacy" ]]; then
      echo "${C_YELLOW}[提示] 当前环境无可用系统钥匙串，已回退写入 0600 权限 token.json。${C_RESET}"
    fi
  else
    if ! colab_adc_credentials_path "$target_id" >/dev/null 2>&1; then
      echo "${C_RED}[失败] 账号 '${target_id}' 缺少本地 ADC 凭证文件 (adc.json)，请运行 'colabd auth refresh ${target_id}'。${C_RESET}"
      return 1
    fi
  fi

  ACTIVE_ACCOUNT="$target_id"
  COLAB_AUTH_MODE="$target_mode"
  AUTO_ADOPT_EXTERNAL="1"
  AUTH_EMAIL="$target_email"
  AUTH_NOTE="$target_note"
  save_config

  if refresh_colab_auth_status "" 1; then
    echo "${C_GREEN}[切号成功] 当前激活账号: $(format_account_label "$ACTIVE_ACCOUNT" "$COLAB_AUTH_MODE" "$AUTH_NOTE")${C_RESET}"
    return 0
  elif [[ "$AUTH_STATE" == "insufficient_scope" ]]; then
    echo "${C_RED}[已切换但权限域缺失] ${AUTH_DETAIL}${C_RESET}"
    return 1
  elif [[ "$AUTH_STATE" == "timeout" ]]; then
    echo "${C_YELLOW}[已切换但探测超时] 账号 '${ACTIVE_ACCOUNT}' 本地凭证已激活，但远端校验超时 (${AUTH_DETAIL})；请稍后执行 'colabd auth whoami' 确认。${C_RESET}"
    return 1
  else
    echo "${C_YELLOW}[已切换但令牌失效] 账号 '${ACTIVE_ACCOUNT}' 校验未通过 (${AUTH_DETAIL})，请运行 'colabd auth refresh ${ACTIVE_ACCOUNT}'。${C_RESET}"
    return 1
  fi
}

# Unified, safe account removal (hard-gated against running daemons & unverified/failed runtime stops)
# Args: <query> <auto_mode: prompt|release> <interactive_post: 1|0> [revoke_remote: 0|1] [force_unverified: 0|1]
do_remove_account() {
  local target_query="${1:-}"
  local auto_release_mode="${2:-prompt}"
  local interactive_post="${3:-1}"
  local revoke_remote="${4:-0}"
  local force_unverified="${5:-0}"

  if [[ -z "$target_query" ]]; then
    echo ""
    echo "${C_BOLD}已登录账号列表:${C_RESET}"
    if ! print_saved_accounts_table; then
      return 1
    fi
    read -r -p "输入要移除的完整账号 ID / 邮箱 (回车取消): " target_query
    [[ -z "$target_query" ]] && return 1
  fi

  local target_id=""
  if ! target_id="$(resolve_account_id "$target_query")"; then
    echo "${C_RED}[错误] 未找到账号: '${target_query}'（请提供准确账号 ID）。${C_RESET}"
    return 1
  fi

  # Rule 1: Hard block if target account owns a live running colabd daemon/tunnel
  if is_bg_running && [[ "$ACTIVE_SESSION_HAS_OWNER" -eq 1 && "$ACTIVE_SESSION_ACCOUNT" == "$target_id" ]]; then
    echo ""
    echo "${C_RED}[禁止移除] 账号 '${target_id}' 当前正运行着本地推理守护进程与隧道 (会话: ${ACTIVE_SESSION_NAME:-$SESSION_NAME})！${C_RESET}"
    echo "  请先在主菜单选 [7] 停止当前运行中的实例（或执行 colabd down），确认释放后再移除该账号。"
    return 1
  fi

  local target_mode target_note
  target_mode="$(account_store meta-get "$ACCOUNTS_DIR" "$target_id" auth_mode 2>/dev/null || echo "oauth2")"
  target_note="$(account_store meta-get "$ACCOUNTS_DIR" "$target_id" note 2>/dev/null || true)"

  # Rule 2 & 3: Pre-flight inspect & Fail-Closed hard release gate
  if ! guard_hard_release_before_delete "$target_id" "$target_mode" "$target_note" "$auto_release_mode" "$force_unverified"; then
    return 1
  fi

  # Rule 4: Clear active creds if removing the currently active account, then delete account cleanly
  local was_active=0
  if [[ "$target_id" == "$ACTIVE_ACCOUNT" ]]; then
    was_active=1
    if [[ "$target_mode" == "oauth2" && "$revoke_remote" == "1" ]]; then
      account_store oauth-clear-active --revoke >/dev/null 2>&1 || true
    else
      # Always clear the active google-colab-cli OAuth2 working slot on active-account logout/remove
      # so a stale OAuth2 token cannot unexpectedly resurrect when COLAB_AUTH_MODE resets to oauth2.
      account_store oauth-clear-active >/dev/null 2>&1 || true
    fi
    ACTIVE_ACCOUNT=""
    AUTO_ADOPT_EXTERNAL="0"
    COLAB_AUTH_MODE="oauth2"
    AUTH_EMAIL=""
    AUTH_NOTE=""
    AUTH_STATE="unauth"
    AUTH_DETAIL="已移除并登出账号 ${target_id}"
    AUTH_MISSING_REQ_SCOPES=""
    AUTH_MISSING_OPT_SCOPES=""
    save_config
  fi

  if [[ "$revoke_remote" == "1" ]]; then
    account_store delete-account "$ACCOUNTS_DIR" "$target_id" --revoke
  else
    account_store delete-account "$ACCOUNTS_DIR" "$target_id"
  fi
  echo "${C_GREEN}[已移除] 账号 '${target_id}' 及其本地钥匙串 / ADC 凭证与会话记录已安全清除。${C_RESET}"
  if [[ "$target_mode" == "adc" ]]; then
    echo "${C_DIM}[说明] 宿主机全局 gcloud ADC 文件未做改动（以防影响其他 GCP 工具），colabd 也不会自动重新导入它。${C_RESET}"
  fi

  # Post-delete convergence: guide switching if removing active account and other accounts remain
  if [[ "$was_active" -eq 1 ]]; then
    local remaining=""
    remaining="$(account_store list "$ACCOUNTS_DIR" 2>/dev/null || true)"
    if [[ -n "$remaining" ]]; then
      if [[ "$interactive_post" == "1" ]]; then
        echo ""
        echo "${C_CYAN}[提示] 本地仍有其他已登录账号，是否立即切换激活其中一个?${C_RESET}"
        print_saved_accounts_table || true
        read -r -p "输入要激活的账号 ID / 邮箱 (直接回车保持未登录): " next_q
        if [[ -n "$next_q" ]]; then
          do_switch_account "$next_q" "prompt" || true
        fi
      else
        echo "${C_DIM}[提示] 本地仍有其他账号，可执行 'colabd switch <账号ID>' 立即激活。${C_RESET}"
      fi
    fi
  fi
  return 0
}

do_logout_current_account() {
  local auto_release_mode="${1:-prompt}"
  local interactive_post="${2:-1}"
  local revoke_remote="${3:-0}"
  local force_unverified="${4:-0}"

  if [[ -n "$ACTIVE_ACCOUNT" ]]; then
    do_remove_account "$ACTIVE_ACCOUNT" "$auto_release_mode" "$interactive_post" "$revoke_remote" "$force_unverified"
    return $?
  fi

  if ! resolve_colab_bin >/dev/null 2>&1; then
    echo "${C_YELLOW}[提示] 当前未登录任何账号。${C_RESET}"
    return 0
  fi

  if ! guard_hard_release_before_delete "" "$COLAB_AUTH_MODE" "" "$auto_release_mode" "$force_unverified"; then
    return 1
  fi

  if [[ "$COLAB_AUTH_MODE" == "oauth2" && "$revoke_remote" == "1" ]]; then
    account_store oauth-clear-active --revoke >/dev/null 2>&1 || true
  else
    account_store oauth-clear-active >/dev/null 2>&1 || true
    if [[ "$COLAB_AUTH_MODE" == "adc" ]]; then
      # Never delete arbitrary $GOOGLE_APPLICATION_CREDENTIALS or unconditionally revoke host gcloud ADC!
      echo "${C_DIM}[说明] 已解除 colabd 对外部 ADC 的绑定；宿主机全局 gcloud ADC 与 GOOGLE_APPLICATION_CREDENTIALS 文件保持原样未被改动。${C_RESET}"
    fi
  fi
  account_store sessions-clear "$(colab_session_config_path "")" >/dev/null 2>&1 || true

  AUTO_ADOPT_EXTERNAL="0"
  COLAB_AUTH_MODE="oauth2"
  AUTH_STATE="unauth"
  AUTH_EMAIL=""
  AUTH_NOTE=""
  AUTH_DETAIL="已登出"
  AUTH_MISSING_REQ_SCOPES=""
  AUTH_MISSING_OPT_SCOPES=""
  save_config
  echo "${C_GREEN}[已登出] 本地 colabd 活跃登录态已清除。${C_RESET}"
  return 0
}

do_remote_gcp_auth() {
  if ! resolve_colab_bin >/dev/null 2>&1; then
    echo "${C_RED}[错误] 本机尚未初始化独立 uv 运行环境或未安装 google-colab-cli。${C_RESET}"
    return 1
  fi
  if is_bg_running; then
    echo "${C_YELLOW}[提示] 当前远端 Jupyter 内核正被推理守护进程占用，无法在运行中并发执行 colab auth。${C_RESET}"
    read -r -p "是否开启【每次启动实例时自动执行 colab auth】开关 (下次启动/重启时将在拉起模型前注入)? [Y/n]: " auto_yn
    if [[ ! "${auto_yn:-Y}" =~ ^[Nn]$ ]]; then
      AUTO_GCP_AUTH="1"
      save_config
      echo "${C_GREEN}[已开启] 后续启动实例时将自动执行远端 GCP 授权。${C_RESET}"
    fi
    return 0
  fi

  local target="${ACTIVE_SESSION_NAME:-$SESSION_NAME}"
  if ! colab_session_is_active "$COLAB_AUTH_MODE" "$ACTIVE_ACCOUNT" "$target"; then
    echo "${C_YELLOW}[提示] 当前会话 '${target}' 尚未运行，无法立即向远端 VM 注入凭证。${C_RESET}"
    read -r -p "是否开启【每次启动实例时自动执行 colab auth】开关? [Y/n]: " auto_yn
    if [[ ! "${auto_yn:-Y}" =~ ^[Nn]$ ]]; then
      AUTO_GCP_AUTH="1"
      save_config
      echo "${C_GREEN}[已开启] 后续启动实例时将自动执行远端 GCP 授权。${C_RESET}"
    fi
    return 0
  fi

  echo "${C_CYAN}[远端授权] 正在为账号 '$(format_account_label "$ACTIVE_ACCOUNT" "$COLAB_AUTH_MODE" "$AUTH_NOTE")' 执行 colab auth -s ${target} ...${C_RESET}"
  if colab_cli auth -s "$target"; then
    echo "${C_GREEN}[成功] 远端会话 '${target}' 已完成 GCP 服务鉴权！${C_RESET}"
  else
    echo "${C_RED}[失败] 远端 GCP 授权执行失败，请确认本地账号具备对应权限。${C_RESET}"
  fi
}

do_install_or_update_cli() {
  echo ""
  local src=""
  src="$(colab_runtime_source)"
  if [[ "$src" == "managed_venv" ]]; then
    ensure_managed_uv_env "upgrade" || return 1
  else
    if [[ "$src" == "external" ]]; then
      echo "${C_YELLOW}[迁移] 当前使用的是外部 colab CLI，正在初始化 colabd 专属独立 uv 隔离环境 (${COLABD_VENV_DIR})...${C_RESET}"
    fi
    ensure_managed_uv_env "install" || return 1
  fi
  refresh_colab_auth_status "" 0 || true
}

ensure_cli_and_authenticated() {
  if ! resolve_colab_bin >/dev/null 2>&1; then
    echo "${C_YELLOW}[未初始化环境] 本机未检测到 colabd 独立 uv 运行环境或外部 'colab' 命令。${C_RESET}"
    read -r -p "是否立即自动创建独立 uv (Python ${COLABD_PYTHON_VERSION}) 虚拟环境并安装 google-colab-cli? [Y/n]: " inst_yn
    if [[ "${inst_yn:-Y}" =~ ^[Nn]$ ]]; then
      return 1
    fi
    do_install_or_update_cli || return 1
    resolve_colab_bin >/dev/null 2>&1 || return 1
  fi

  if ! refresh_colab_auth_status "" 0; then
    if [[ "$AUTH_STATE" == "timeout" ]]; then
      local retry_timeout=30
      if [[ "${COLABD_AUTH_PROBE_TIMEOUT:-15}" =~ ^[0-9]+$ && "${COLABD_AUTH_PROBE_TIMEOUT:-15}" -gt 0 ]]; then
        retry_timeout=$((COLABD_AUTH_PROBE_TIMEOUT * 2))
      fi
      echo ""
      echo "${C_YELLOW}[认证探测超时] ${AUTH_DETAIL}${C_RESET}"
      echo "${C_CYAN}[自动重试] 正在以更长超时 (${retry_timeout}s) 等待 OAuth 令牌刷新并复检...${C_RESET}"
      if refresh_colab_auth_status "$retry_timeout" 0; then
        return 0
      fi
      if [[ "$AUTH_STATE" == "timeout" ]]; then
        echo "${C_YELLOW}[探测仍超时] ${AUTH_DETAIL}${C_RESET}"
        echo "  本地凭证仍在，无需重复登录；可能是网络或代理响应较慢。"
        echo "  1) 直接继续启动（跳过本次预检，交由 colab CLI 自动完成刷新）"
        echo "  2) 再次重试认证状态探测"
        echo "  3) 重新登录 / 切换账号"
        echo "  0) 取消并返回主菜单"
        read -r -p "请选择 [1]: " timeout_choice
        case "${timeout_choice:-1}" in
          1) return 0 ;;
          2)
            refresh_colab_auth_status "$retry_timeout" 0 && return 0
            return 1
            ;;
          3) ;;
          *) return 1 ;;
        esac
      fi
    fi

    echo ""
    if [[ "$AUTH_STATE" == "insufficient_scope" ]]; then
      echo "${C_RED}[权限域不足] ${AUTH_DETAIL}${C_RESET}"
      read -r -p "是否立即重新授权以补齐必需权限域 (auth refresh)? [Y/n]: " ref_yn
      if [[ ! "${ref_yn:-Y}" =~ ^[Nn]$ ]]; then
        do_refresh_account "" "1" || return 1
        return 0
      fi
      return 1
    fi

    echo "${C_YELLOW}[需要登录] 当前尚未登录 Google Colab (${AUTH_DETAIL})。${C_RESET}"
    local has_accounts=0
    if [[ -n "$(account_store list "$ACCOUNTS_DIR" 2>/dev/null || true)" ]]; then
      has_accounts=1
    fi
    echo "  1) 登录 Google OAuth 2.0 账号 (推荐)"
    echo "  2) 登录 GCP ADC 账号 (gcloud auth application-default login)"
    if [[ "$has_accounts" -eq 1 ]]; then
      echo "  3) 从已登录账号列表中切换激活"
    fi
    echo "  0) 取消并返回主菜单"
    read -r -p "请选择 [1]: " auth_choice
    case "${auth_choice:-1}" in
      1) do_login_account "oauth2" "" "prompt" || return 1 ;;
      2) do_login_account "adc" "" "prompt" || return 1 ;;
      3)
        if [[ "$has_accounts" -eq 1 ]]; then
          do_switch_account "" "prompt" || return 1
        else
          return 1
        fi
        ;;
      *) return 1 ;;
    esac
  fi
  return 0
}
