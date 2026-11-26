#!/usr/bin/env bash
# ==============================================================================
# colabd - Multi-account authentication, profile switching, logout, and GCP auth
# Compatible with Bash 3.2+ (macOS and Linux)
# ==============================================================================

account_store() {
  local py_bin=""
  py_bin="$(resolve_host_python 2>/dev/null || true)"
  if [[ -z "$py_bin" ]]; then
    echo "${C_RED}[错误] 未找到可用的 Python 解释器，请运行 'colabd env setup' 初始化独立 uv 运行环境。${C_RESET}" >&2
    return 1
  fi
  COLAB_CLI_CONFIG_DIR="$COLAB_CLI_CONFIG_DIR" "$py_bin" "${COLABD_LIB_DIR}/account_store.py" "$@"
}

suggest_alias_from_email() {
  local email="${1:-}"
  local raw="${email%%@*}"
  if [[ -z "$raw" ]]; then
    echo "account-1"
    return 0
  fi
  local host_py=""
  host_py="$(resolve_host_python 2>/dev/null || command -v python3 2>/dev/null || true)"
  if [[ -z "$host_py" ]]; then
    echo "account-1"
    return 0
  fi
  local clean
  clean="$("$host_py" - "$raw" <<'PY' 2>/dev/null || echo "account-1"
import re, sys
s = re.sub(r"[^A-Za-z0-9._-]+", "-", sys.argv[1]).strip("._-")
if not s or not s[0].isalnum():
    s = "acc-" + s if s else "account-1"
print(s[:40])
PY
)"
  echo "${clean:-account-1}"
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

  local sess_cfg=""
  if [[ -n "$acct" ]]; then
    sess_cfg="$(colab_session_config_path "$acct")"
    mkdir -p "$(dirname "$sess_cfg")"
    chmod 700 "$(dirname "$sess_cfg")" 2>/dev/null || true
  elif [[ "$COLAB_CLI_CONFIG_DIR" != "$HOME/.config/colab-cli" ]]; then
    sess_cfg="${COLAB_CLI_CONFIG_DIR}/sessions.json"
    mkdir -p "$(dirname "$sess_cfg")"
  fi

  local adc_override=""
  if [[ "$auth_mode" == "adc" && -n "$acct" && -f "${ACCOUNTS_DIR}/${acct}/adc.json" ]]; then
    adc_override="${ACCOUNTS_DIR}/${acct}/adc.json"
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
    sys.stdout.write("等待浏览器登录授权\n")
    sys.exit(124)
except Exception as exc:
    sys.stdout.write(f"{exc}\n")
    sys.exit(1)
PY
}

probe_colab_email_for() {
  local auth_mode="$1"
  local acct="$2"
  local timeout_sec="${3:-5}"

  local out=""
  if ! out="$(probe_colab_command "$auth_mode" "$acct" "$timeout_sec" whoami 2>/dev/null)"; then
    return 1
  fi

  local host_py=""
  host_py="$(resolve_host_python 2>/dev/null || command -v python3 2>/dev/null || true)"
  [[ -z "$host_py" ]] && return 1
  "$host_py" - "$out" <<'PY' 2>/dev/null
import re, sys
text = sys.argv[1]
for line in text.splitlines():
    m = re.match(r"^\s*Email:\s*(\S+@\S+)\s*$", line)
    if m:
        print(m.group(1))
        sys.exit(0)
sys.exit(1)
PY
}

refresh_colab_auth_status() {
  local timeout_sec="${1:-4}"
  local force_whoami="${2:-0}"

  if [[ -n "$ACTIVE_ACCOUNT" ]]; then
    if ! account_store exists "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" >/dev/null 2>&1; then
      ACTIVE_ACCOUNT=""
      save_config
    else
      local meta_mode meta_email
      meta_mode="$(account_store meta-get "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" auth_mode 2>/dev/null || true)"
      meta_email="$(account_store meta-get "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" email 2>/dev/null || true)"
      if [[ "$meta_mode" == "oauth2" || "$meta_mode" == "adc" ]]; then
        COLAB_AUTH_MODE="$meta_mode"
      fi
      AUTH_EMAIL="$meta_email"
    fi
  fi

  if ! resolve_colab_bin >/dev/null 2>&1; then
    AUTH_STATE="missing_cli"
    AUTH_DETAIL="未初始化独立 uv 运行环境或未安装 google-colab-cli"
    return 1
  fi

  if [[ "$COLAB_AUTH_MODE" == "adc" ]]; then
    local adc_file
    adc_file="$(colab_adc_credentials_path "$ACTIVE_ACCOUNT")"
    if [[ ! -f "$adc_file" ]]; then
      AUTH_STATE="unauth"
      AUTH_DETAIL="未找到 ADC 凭证文件 (${adc_file})"
      return 1
    fi
  fi

  local probe_out=""
  if probe_out="$(probe_colab_command "$COLAB_AUTH_MODE" "$ACTIVE_ACCOUNT" "$timeout_sec" sessions 2>/dev/null)"; then
    AUTH_STATE="ok"
    local first_line=""
    first_line="$(printf '%s\n' "$probe_out" | awk 'NF {print; exit}')"
    AUTH_DETAIL="${first_line:-凭证有效}"
    if [[ "${#AUTH_DETAIL}" -gt 72 ]]; then
      AUTH_DETAIL="${AUTH_DETAIL:0:72}"
    fi
    if [[ "$force_whoami" == "1" || -z "$AUTH_EMAIL" ]]; then
      local detected_email=""
      detected_email="$(probe_colab_email_for "$COLAB_AUTH_MODE" "$ACTIVE_ACCOUNT" 5 || true)"
      if [[ -n "$detected_email" ]]; then
        AUTH_EMAIL="$detected_email"
        if [[ -n "$ACTIVE_ACCOUNT" ]]; then
          account_store meta-set "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" --email "$AUTH_EMAIL" >/dev/null 2>&1 || true
        fi
      fi
    fi
    return 0
  else
    AUTH_STATE="unauth"
    local err_line=""
    err_line="$(printf '%s\n' "$probe_out" | awk 'NF {line=$0} END {print line}')"
    AUTH_DETAIL="${err_line:-未登录或令牌失效}"
    if [[ "${#AUTH_DETAIL}" -gt 72 ]]; then
      AUTH_DETAIL="${AUTH_DETAIL:0:72}"
    fi
    if [[ -z "$ACTIVE_ACCOUNT" ]]; then
      AUTH_EMAIL=""
    fi
    return 1
  fi
}

format_auth_badge() {
  local acct_part=""
  if [[ -n "$ACTIVE_ACCOUNT" ]]; then
    acct_part="槽位: ${ACTIVE_ACCOUNT} | "
  fi
  local email_part=""
  if [[ -n "$AUTH_EMAIL" ]]; then
    email_part="${AUTH_EMAIL} | "
  fi

  case "$AUTH_STATE" in
    ok)
      echo "${C_GREEN}● 已登录${C_RESET} (${acct_part}${email_part}模式: ${COLAB_AUTH_MODE} | GCP自动授权: $( [[ "$AUTO_GCP_AUTH" == "1" ]] && echo "开" || echo "关" ))"
      ;;
    missing_cli)
      echo "${C_RED}✗ 未安装 google-colab-cli${C_RESET} (请进菜单 [6] 一键安装并登录)"
      ;;
    unauth)
      echo "${C_YELLOW}○ 未登录或凭证待授权${C_RESET} (${acct_part}模式: ${COLAB_AUTH_MODE} — 请进菜单 [6] 登录或切号)"
      ;;
    *)
      echo "${C_DIM}○ 待检测${C_RESET} (${acct_part}模式: ${COLAB_AUTH_MODE})"
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
  local pmode=""
  pmode="$(account_store meta-get "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" auth_mode 2>/dev/null || true)"
  if [[ "$pmode" != "oauth2" ]]; then
    return 0
  fi
  if account_store oauth-has-active >/dev/null 2>&1; then
    account_store oauth-save-profile "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" --email "$AUTH_EMAIL" >/dev/null 2>&1 || true
  fi
  return 0
}

run_with_account_creds() {
  local target_acct="$1"
  local target_mode="$2"
  local callback_fn="$3"
  shift 3

  if [[ "$target_mode" == "adc" ]]; then
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
    if account_store oauth-activate-profile "$ACCOUNTS_DIR" "$target_acct" >/dev/null 2>&1; then
      swapped=1
    else
      rm -f "$backup_file"
      return 1
    fi
  fi

  local rc=0
  "$callback_fn" "$target_acct" "$target_mode" "$@" || rc=$?

  if [[ "$swapped" -eq 1 ]]; then
    if [[ "$had_prev" -eq 1 ]]; then
      account_store oauth-import-active "$backup_file" >/dev/null 2>&1 || true
    else
      account_store oauth-clear-active >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$backup_file"
  return "$rc"
}

print_saved_accounts_table() {
  local rows=""
  rows="$(account_store list "$ACCOUNTS_DIR" 2>/dev/null || true)"
  if [[ -z "$rows" ]]; then
    echo "    ${C_DIM}(尚未保存任何账号槽位；可在登录完成后选 [4] 归档，或选 [3] 添加新账号)${C_RESET}"
    return 1
  fi

  local idx=1
  local name mode email has_cred scount snames
  while IFS=$'\t' read -r name mode email has_cred scount snames _; do
    [[ -z "$name" ]] && continue
    local marker=" "
    local color=""
    local end_color=""
    if [[ "$name" == "$ACTIVE_ACCOUNT" ]]; then
      marker="*"
      color="${C_GREEN}"
      end_color="${C_RESET}"
    fi
    local email_disp="${email:-"(邮箱待探测)"}"
    local cred_warn=""
    if [[ "$has_cred" != "1" ]]; then
      cred_warn=" ${C_RED}[凭证缺失]${C_RESET}"
    fi
    local sess_info="本地会话: 0"
    if [[ "${scount:-0}" -gt 0 ]]; then
      sess_info="${C_YELLOW}本地活跃会话: ${scount} (${snames})${C_RESET}"
    fi
    printf '    %s%s %d. %-16s [%-6s] %-28s (%s)%s%s\n' \
      "$color" "$marker" "$idx" "$name" "$mode" "$email_disp" "$sess_info" "$cred_warn" "$end_color"
    idx=$((idx + 1))
  done <<< "$rows"
  return 0
}

resolve_profile_by_index_or_name() {
  local query="$1"
  [[ -z "$query" ]] && return 1

  if account_store exists "$ACCOUNTS_DIR" "$query" >/dev/null 2>&1; then
    echo "$query"
    return 0
  fi

  if [[ "$query" =~ ^[0-9]+$ ]]; then
    local rows=""
    rows="$(account_store list "$ACCOUNTS_DIR" 2>/dev/null || true)"
    local idx=1
    local name
    while IFS=$'\t' read -r name _; do
      [[ -z "$name" ]] && continue
      if [[ "$idx" -eq "$query" ]]; then
        echo "$name"
        return 0
      fi
      idx=$((idx + 1))
    done <<< "$rows"
  fi
  return 1
}

do_save_current_account() {
  local alias_arg="${1:-}"
  if ! resolve_colab_bin >/dev/null 2>&1; then
    echo "${C_RED}[错误] 请先运行 'colabd env setup' 初始化独立 uv 运行环境。${C_RESET}"
    return 1
  fi

  if ! refresh_colab_auth_status 6 1; then
    echo "${C_RED}[错误] 当前未检测到有效的 Colab 登录态 (${AUTH_DETAIL})，无法归档。${C_RESET}"
    return 1
  fi

  local suggested=""
  if [[ -n "$ACTIVE_ACCOUNT" ]]; then
    suggested="$ACTIVE_ACCOUNT"
  else
    suggested="$(suggest_alias_from_email "$AUTH_EMAIL")"
  fi

  local alias="$alias_arg"
  if [[ -z "$alias" ]]; then
    echo ""
    echo "${C_CYAN}[归档当前账号]${C_RESET} 认证模式: ${COLAB_AUTH_MODE} | 邮箱: ${AUTH_EMAIL:-未知}"
    read -r -p "请输入账号槽位名称 (仅字母/数字/._-，回车使用 '${suggested}'): " alias
    alias="${alias:-$suggested}"
  fi

  if ! account_store validate-name "$alias"; then
    return 1
  fi

  if [[ "$alias" != "$ACTIVE_ACCOUNT" ]] && account_store exists "$ACCOUNTS_DIR" "$alias" >/dev/null 2>&1; then
    read -r -p "槽位 '${alias}' 已存在，是否覆盖保存? [y/N]: " ov_yn
    if [[ ! "${ov_yn:-N}" =~ ^[Yy]$ ]]; then
      echo "${C_YELLOW}[已取消] 未覆盖槽位 '${alias}'。${C_RESET}"
      return 1
    fi
  fi

  local storage_kind=""
  if [[ "$COLAB_AUTH_MODE" == "oauth2" ]]; then
    if ! storage_kind="$(account_store oauth-save-profile "$ACCOUNTS_DIR" "$alias" --email "$AUTH_EMAIL")"; then
      echo "${C_RED}[失败] 无法读取或保存当前 OAuth 2.0 令牌。${C_RESET}"
      return 1
    fi
  else
    local adc_src
    adc_src="$(colab_adc_credentials_path "$ACTIVE_ACCOUNT")"
    if ! storage_kind="$(account_store adc-save-profile "$ACCOUNTS_DIR" "$alias" "$adc_src" --email "$AUTH_EMAIL")"; then
      echo "${C_RED}[失败] 无法保存当前 ADC 凭证文件 (${adc_src})。${C_RESET}"
      return 1
    fi
  fi

  local old_sess_cfg new_sess_cfg
  old_sess_cfg="$(colab_session_config_path "$ACTIVE_ACCOUNT")"
  new_sess_cfg="$(colab_session_config_path "$alias")"
  if [[ "$old_sess_cfg" != "$new_sess_cfg" ]]; then
    account_store sessions-migrate "$old_sess_cfg" "$new_sess_cfg" >/dev/null 2>&1 || true
  fi

  if [[ "$MANAGED_SESSION" -eq 1 && "$ACTIVE_SESSION_HAS_OWNER" -eq 1 && "$ACTIVE_SESSION_ACCOUNT" == "$ACTIVE_ACCOUNT" ]]; then
    ACTIVE_SESSION_ACCOUNT="$alias"
  fi

  ACTIVE_ACCOUNT="$alias"
  save_config
  echo "${C_GREEN}[已保存] 账号槽位 '${alias}' 已归档 (模式: ${COLAB_AUTH_MODE} | 存储: ${storage_kind} | 邮箱: ${AUTH_EMAIL:-未知})。${C_RESET}"
  echo "  独立会话文件: ${new_sess_cfg}"
  return 0
}

offer_save_unsaved_oauth_before_replace() {
  if [[ -n "$ACTIVE_ACCOUNT" ]]; then
    return 0
  fi
  if ! account_store oauth-has-active >/dev/null 2>&1; then
    return 0
  fi
  echo ""
  echo "${C_YELLOW}[提示] 当前存在尚未保存为槽位的 Google OAuth 2.0 登录态，切换或新增账号将覆盖当前活跃令牌。${C_RESET}"
  read -r -p "是否先将当前登录账号保存为槽位（便于随时切回）? [Y/n]: " save_yn
  if [[ ! "${save_yn:-Y}" =~ ^[Nn]$ ]]; then
    do_save_current_account || true
  fi
  return 0
}

do_oauth2_login() {
  if ! resolve_colab_bin >/dev/null 2>&1; then
    echo "${C_RED}[错误] 请先初始化独立 uv 运行环境（可在账号页选 [9] 或执行 colabd env setup）。${C_RESET}"
    return 1
  fi
  if [[ -n "$ACTIVE_ACCOUNT" ]]; then
    local pmode=""
    pmode="$(account_store meta-get "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" auth_mode 2>/dev/null || true)"
    if [[ "$pmode" != "oauth2" ]]; then
      ACTIVE_ACCOUNT=""
      AUTH_EMAIL=""
    fi
  fi
  COLAB_AUTH_MODE="oauth2"
  save_config
  echo ""
  echo "${C_CYAN}[登录] 正在拉起 Google Colab OAuth 2.0 授权流程...${C_RESET}"
  if colab_cli sessions; then
    refresh_colab_auth_status 6 1 || true
    sync_active_oauth_to_profile || true
    echo "${C_GREEN}[成功] Google Colab OAuth 2.0 登录验证通过！(${AUTH_EMAIL:-凭证有效})${C_RESET}"
    return 0
  else
    AUTH_STATE="unauth"
    echo "${C_RED}[失败] OAuth 2.0 登录未完成或被取消。${C_RESET}"
    return 1
  fi
}

do_adc_login() {
  if ! command -v gcloud >/dev/null 2>&1; then
    echo "${C_RED}[错误] 本机未检测到 Google Cloud SDK ('gcloud' 命令)，无法发起 ADC 登录。${C_RESET}"
    return 1
  fi
  if [[ -n "$ACTIVE_ACCOUNT" ]]; then
    local pmode=""
    pmode="$(account_store meta-get "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" auth_mode 2>/dev/null || true)"
    if [[ "$pmode" != "adc" ]]; then
      ACTIVE_ACCOUNT=""
      AUTH_EMAIL=""
    fi
  fi
  echo ""
  echo "${C_CYAN}[ADC 登录] 正在调用 gcloud 申请包含 colaboratory 权限域的应用默认凭证...${C_RESET}"
  if gcloud auth application-default login --scopes="$ADC_SCOPES"; then
    COLAB_AUTH_MODE="adc"
    if [[ -n "$ACTIVE_ACCOUNT" ]]; then
      local adc_src="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"
      if [[ -f "$adc_src" ]]; then
        account_store adc-save-profile "$ACCOUNTS_DIR" "$ACTIVE_ACCOUNT" "$adc_src" >/dev/null 2>&1 || true
      fi
    fi
    save_config
    if resolve_colab_bin >/dev/null 2>&1 && colab_cli sessions; then
      refresh_colab_auth_status 6 1 || true
      echo "${C_GREEN}[成功] GCP ADC 登录并验证 Colab 访问通过！(${AUTH_EMAIL:-凭证有效})${C_RESET}"
      return 0
    fi
  fi
  AUTH_STATE="unauth"
  echo "${C_RED}[失败] GCP ADC 登录未完成或缺少 colaboratory 权限域。${C_RESET}"
  return 1
}

do_add_new_account() {
  local alias_arg="${1:-}"
  local mode_arg="${2:-}"
  local auto_release_mode="${3:-prompt}"

  if ! resolve_colab_bin >/dev/null 2>&1; then
    echo "${C_RED}[错误] 请先初始化独立 uv 运行环境（可在账号页选 [9] 或执行 colabd env setup）。${C_RESET}"
    return 1
  fi

  if ! guard_release_before_account_change "新增并切换账号" "" "$auto_release_mode" "0"; then
    return 1
  fi

  local alias="$alias_arg"
  if [[ -z "$alias" ]]; then
    echo ""
    read -r -p "输入新账号槽位名称 (如 pro1 / personal / work-gcp): " alias
    if [[ -z "$alias" ]]; then
      echo "${C_YELLOW}[已取消] 未输入槽位名称。${C_RESET}"
      return 1
    fi
  fi

  if ! account_store validate-name "$alias"; then
    return 1
  fi

  if account_store exists "$ACCOUNTS_DIR" "$alias" >/dev/null 2>&1; then
    if [[ "$auto_release_mode" == "prompt" ]]; then
      read -r -p "槽位 '${alias}' 已存在，是否释放其残留会话并重新登录覆盖? [y/N]: " ov_yn
      if [[ ! "${ov_yn:-N}" =~ ^[Yy]$ ]]; then
        echo "${C_YELLOW}[已取消] 未覆盖槽位 '${alias}'。${C_RESET}"
        return 1
      fi
    fi
    if [[ "$alias" != "$ACTIVE_ACCOUNT" ]]; then
      if ! guard_release_before_account_change "覆盖已有槽位 '${alias}'" "$alias" "$auto_release_mode" "1"; then
        return 1
      fi
    fi
  fi

  local mode="$mode_arg"
  if [[ -z "$mode" ]]; then
    echo ""
    echo "选择新账号的认证方式:"
    echo "  1) Google OAuth 2.0 个人账号 (Free / Pro / Pro+ 推荐，令牌加密存于系统钥匙串)"
    echo "  2) GCP ADC 登录 (gcloud auth application-default login，独立凭证文件)"
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

  if [[ "$mode" == "oauth2" ]]; then
    if [[ "$auto_release_mode" == "prompt" ]]; then
      offer_save_unsaved_oauth_before_replace
    fi
    sync_active_oauth_to_profile || true

    local backup_file="${STATE_DIR}/prev_oauth.$$.json"
    local had_prev=0
    if account_store oauth-export-active "$backup_file" >/dev/null 2>&1; then
      had_prev=1
    fi

    echo ""
    echo "${C_CYAN}[清理旧令牌] 正在清除当前活跃 OAuth 2.0 令牌以便登录新账号 '${alias}'...${C_RESET}"
    account_store oauth-clear-active >/dev/null 2>&1 || true

    echo "${C_CYAN}[登录新账号] 请在浏览器中登录目标 Google 账号并粘贴授权码...${C_RESET}"
    if colab_cli_for "oauth2" "$alias" sessions; then
      local new_email=""
      new_email="$(probe_colab_email_for "oauth2" "$alias" 6 || true)"
      local storage_kind=""
      if storage_kind="$(account_store oauth-save-profile "$ACCOUNTS_DIR" "$alias" --email "$new_email")"; then
        rm -f "$backup_file"
        ACTIVE_ACCOUNT="$alias"
        COLAB_AUTH_MODE="oauth2"
        AUTH_EMAIL="$new_email"
        save_config
        refresh_colab_auth_status 6 0 || true
        echo "${C_GREEN}[成功] 新账号槽位 '${alias}' (${AUTH_EMAIL:-已授权}) 已创建并激活！(存储: ${storage_kind})${C_RESET}"
        return 0
      fi
    fi

    echo "${C_RED}[失败] 新账号 '${alias}' 登录未完成，正在恢复原账号凭证...${C_RESET}"
    if [[ "$had_prev" -eq 1 ]]; then
      account_store oauth-import-active "$backup_file" >/dev/null 2>&1 || true
    fi
    rm -f "$backup_file"
    refresh_colab_auth_status 4 0 || true
    return 1
  else
    if ! command -v gcloud >/dev/null 2>&1; then
      echo "${C_RED}[错误] 本机未检测到 'gcloud' 命令，无法新增 ADC 账号。${C_RESET}"
      return 1
    fi
    echo ""
    echo "${C_CYAN}[ADC 登录] 正在为槽位 '${alias}' 拉起 gcloud ADC 授权...${C_RESET}"
    if ! gcloud auth application-default login --scopes="$ADC_SCOPES"; then
      echo "${C_RED}[失败] gcloud ADC 登录未完成。${C_RESET}"
      return 1
    fi
    local adc_src="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"
    if [[ ! -f "$adc_src" ]]; then
      echo "${C_RED}[失败] 未在 ${adc_src} 找到新生成的 ADC 凭证文件。${C_RESET}"
      return 1
    fi
    if ! account_store adc-save-profile "$ACCOUNTS_DIR" "$alias" "$adc_src"; then
      echo "${C_RED}[失败] 保存 ADC 凭证到槽位 '${alias}' 失败。${C_RESET}"
      return 1
    fi
    if colab_cli_for "adc" "$alias" sessions; then
      local new_email=""
      new_email="$(probe_colab_email_for "adc" "$alias" 6 || true)"
      if [[ -n "$new_email" ]]; then
        account_store meta-set "$ACCOUNTS_DIR" "$alias" --email "$new_email" >/dev/null 2>&1 || true
      fi
      ACTIVE_ACCOUNT="$alias"
      COLAB_AUTH_MODE="adc"
      AUTH_EMAIL="$new_email"
      save_config
      refresh_colab_auth_status 6 0 || true
      echo "${C_GREEN}[成功] ADC 账号槽位 '${alias}' (${AUTH_EMAIL:-已授权}) 已创建并激活！${C_RESET}"
      return 0
    fi
    echo "${C_RED}[失败] 新 ADC 凭证未能通过 Colab 访问校验（请确认包含 colaboratory 权限域）。${C_RESET}"
    return 1
  fi
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
    echo "${C_BOLD}已保存的账号槽位:${C_RESET}"
    if ! print_saved_accounts_table; then
      return 1
    fi
    read -r -p "输入要切换的槽位编号或名称 (回车取消): " target_query
    [[ -z "$target_query" ]] && return 1
  fi

  local target_alias=""
  if ! target_alias="$(resolve_profile_by_index_or_name "$target_query")"; then
    echo "${C_RED}[错误] 未找到账号槽位: '${target_query}'。${C_RESET}"
    return 1
  fi

  local target_mode target_email
  target_mode="$(account_store meta-get "$ACCOUNTS_DIR" "$target_alias" auth_mode 2>/dev/null || echo "oauth2")"
  target_email="$(account_store meta-get "$ACCOUNTS_DIR" "$target_alias" email 2>/dev/null || true)"

  if [[ "$target_alias" == "$ACTIVE_ACCOUNT" ]]; then
    if [[ "$target_mode" == "oauth2" ]]; then
      account_store oauth-activate-profile "$ACCOUNTS_DIR" "$target_alias" >/dev/null 2>&1 || true
    fi
    COLAB_AUTH_MODE="$target_mode"
    save_config
    refresh_colab_auth_status 6 1 || true
    echo "${C_GREEN}[提示] 当前已位于账号槽位 '${target_alias}' (${AUTH_EMAIL:-$target_mode})，状态已刷新。${C_RESET}"
    return 0
  fi

  if ! guard_release_before_account_change "切换至账号槽位 '${target_alias}'" "" "$auto_release_mode" "0"; then
    return 1
  fi

  if [[ "$target_mode" == "oauth2" && "$auto_release_mode" == "prompt" ]]; then
    offer_save_unsaved_oauth_before_replace
  fi

  sync_active_oauth_to_profile || true

  if [[ "$target_mode" == "oauth2" ]]; then
    local act_store=""
    if ! act_store="$(account_store oauth-activate-profile "$ACCOUNTS_DIR" "$target_alias")"; then
      echo "${C_RED}[失败] 无法加载槽位 '${target_alias}' 的 OAuth 2.0 令牌（可能已从钥匙串删除，请重新登录）。${C_RESET}"
      return 1
    fi
    if [[ "$act_store" == "legacy" ]]; then
      echo "${C_YELLOW}[提示] 当前环境无可用系统钥匙串，已回退写入 0600 权限 token.json（无头服务器建议使用 ADC 模式）。${C_RESET}"
    fi
  else
    if [[ ! -f "${ACCOUNTS_DIR}/${target_alias}/adc.json" ]]; then
      echo "${C_RED}[失败] 槽位 '${target_alias}' 缺少 ADC 凭证文件 (${ACCOUNTS_DIR}/${target_alias}/adc.json)。${C_RESET}"
      return 1
    fi
  fi

  ACTIVE_ACCOUNT="$target_alias"
  COLAB_AUTH_MODE="$target_mode"
  AUTH_EMAIL="$target_email"
  save_config

  if refresh_colab_auth_status 6 1; then
    echo "${C_GREEN}[切号成功] 当前激活账号: $(format_account_label "$ACTIVE_ACCOUNT" "$COLAB_AUTH_MODE" "$AUTH_EMAIL")${C_RESET}"
    return 0
  else
    echo "${C_YELLOW}[已切换但令牌需刷新] 槽位 '${ACTIVE_ACCOUNT}' 校验未通过 (${AUTH_DETAIL})，请重新授权该槽位。${C_RESET}"
    return 1
  fi
}

do_colab_logout() {
  local auto_release_mode="${1:-prompt}"
  local interactive_post="${2:-1}"

  if ! resolve_colab_bin >/dev/null 2>&1; then
    echo "${C_RED}[错误] 本机尚未初始化独立 uv 运行环境或未安装 google-colab-cli。${C_RESET}"
    return 1
  fi

  if ! guard_release_before_account_change "登出当前账号" "" "$auto_release_mode" "1"; then
    return 1
  fi

  local prev_acct="$ACTIVE_ACCOUNT"
  local prev_mode="$COLAB_AUTH_MODE"

  sync_active_oauth_to_profile || true

  echo "${C_CYAN}[登出] 正在清除本地 Colab 活跃凭证 (模式: ${prev_mode})...${C_RESET}"
  if [[ "$prev_mode" == "oauth2" ]]; then
    if account_store oauth-clear-active; then
      echo "${C_GREEN}[已清理] 已清除系统钥匙串 (google-colab-cli/oauth_token) 与旧版 token.json。${C_RESET}"
    else
      echo "${C_YELLOW}[警告] 未能确认清除系统钥匙串条目，请手动检查钥匙串。${C_RESET}"
    fi
  else
    if [[ -z "$prev_acct" ]]; then
      if command -v gcloud >/dev/null 2>&1; then
        gcloud auth application-default revoke --quiet >/dev/null 2>&1 || true
      fi
      local adc_file
      adc_file="$(colab_adc_credentials_path "")"
      rm -f "$adc_file" 2>/dev/null || true
      echo "${C_GREEN}[已清理] 已撤销并清理全局 GCP ADC 凭证。${C_RESET}"
    else
      echo "${C_GREEN}[已登出] 已解除当前激活的 ADC 账号槽位 '${prev_acct}'。${C_RESET}"
    fi
  fi

  if [[ "$LAST_GUARD_KEPT_REMOTE" -ne 1 ]]; then
    account_store sessions-clear "$(colab_session_config_path "$prev_acct")" >/dev/null 2>&1 || true
  else
    echo "${C_YELLOW}[提示] 因你选择保留远端实例运行，已保留 '${prev_acct:-默认}' 的 sessions.json 以便后续释放。${C_RESET}"
  fi

  ACTIVE_ACCOUNT=""
  AUTH_STATE="unauth"
  AUTH_EMAIL=""
  AUTH_DETAIL="已登出"
  save_config

  if [[ -n "$prev_acct" ]]; then
    echo "${C_DIM}[说明] 槽位 '${prev_acct}' 的归档备份仍保留在本地，随时可在 [2] 一键切回或 [5] 彻底删除。${C_RESET}"
  fi

  if [[ "$interactive_post" == "1" ]]; then
    echo ""
    echo "接下来要做什么?"
    echo "  1) 切换至其他已保存的账号槽位"
    echo "  2) 登录并添加一个全新的 Google 账号槽位"
    echo "  0) 保持登出状态"
    read -r -p "请选择 [0]: " post_opt
    case "${post_opt:-0}" in
      1) do_switch_account "" "prompt" || true ;;
      2) do_add_new_account "" "" "prompt" || true ;;
      *) ;;
    esac
  fi
  return 0
}

do_delete_account() {
  local target_query="${1:-}"
  local auto_release_mode="${2:-prompt}"

  if [[ -z "$target_query" ]]; then
    echo ""
    echo "${C_BOLD}已保存的账号槽位:${C_RESET}"
    if ! print_saved_accounts_table; then
      return 1
    fi
    read -r -p "输入要删除的槽位编号或名称 (回车取消): " target_query
    [[ -z "$target_query" ]] && return 1
  fi

  local target_alias=""
  if ! target_alias="$(resolve_profile_by_index_or_name "$target_query")"; then
    echo "${C_RED}[错误] 未找到账号槽位: '${target_query}'。${C_RESET}"
    return 1
  fi

  if [[ "$auto_release_mode" == "prompt" ]]; then
    read -r -p "确认删除账号槽位 '${target_alias}' 及其保存的本地凭证? [y/N]: " del_yn
    if [[ ! "${del_yn:-N}" =~ ^[Yy]$ ]]; then
      echo "${C_YELLOW}[已取消] 未删除槽位 '${target_alias}'。${C_RESET}"
      return 1
    fi
  fi

  if ! guard_release_before_account_change "删除账号槽位 '${target_alias}'" "$target_alias" "$auto_release_mode" "1"; then
    return 1
  fi

  local target_mode=""
  target_mode="$(account_store meta-get "$ACCOUNTS_DIR" "$target_alias" auth_mode 2>/dev/null || echo "oauth2")"

  if [[ "$target_alias" == "$ACTIVE_ACCOUNT" ]]; then
    if [[ "$target_mode" == "oauth2" ]]; then
      account_store oauth-clear-active >/dev/null 2>&1 || true
    fi
    ACTIVE_ACCOUNT=""
    AUTH_STATE="unauth"
    AUTH_EMAIL=""
    AUTH_DETAIL="当前账号槽位已删除"
    save_config
  fi

  account_store delete-profile "$ACCOUNTS_DIR" "$target_alias"
  echo "${C_GREEN}[已删除] 账号槽位 '${target_alias}' 的钥匙串令牌与本地配置已彻底清除。${C_RESET}"
  return 0
}

do_remote_gcp_auth() {
  if ! resolve_colab_bin >/dev/null 2>&1; then
    echo "${C_RED}[错误] 本机尚未初始化独立 uv 运行环境或未安装 google-colab-cli。${C_RESET}"
    return 1
  fi
  local target="${ACTIVE_SESSION_NAME:-$SESSION_NAME}"
  if ! colab_cli status -s "$target" >/dev/null 2>&1; then
    echo "${C_YELLOW}[提示] 当前会话 '${target}' 尚未运行，无法立即向远端 VM 注入凭证。${C_RESET}"
    read -r -p "是否开启【每次启动实例时自动执行 colab auth】开关? [Y/n]: " auto_yn
    if [[ ! "${auto_yn:-Y}" =~ ^[Nn]$ ]]; then
      AUTO_GCP_AUTH="1"
      save_config
      echo "${C_GREEN}[已开启] 后续启动实例时将自动执行远端 GCP 授权。${C_RESET}"
    fi
    return 0
  fi

  echo "${C_CYAN}[远端授权] 正在为账号 '$(format_account_label "$ACTIVE_ACCOUNT" "$COLAB_AUTH_MODE" "$AUTH_EMAIL")' 执行 colab auth -s ${target} ...${C_RESET}"
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
  refresh_colab_auth_status 5 0 || true
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

  if ! refresh_colab_auth_status 5 0; then
    echo ""
    echo "${C_YELLOW}[需要登录] 当前 Google Colab 尚未登录或令牌已过期 (${AUTH_DETAIL})。${C_RESET}"
    local has_profiles=0
    if [[ -n "$(account_store list "$ACCOUNTS_DIR" 2>/dev/null || true)" ]]; then
      has_profiles=1
    fi
    echo "  1) 立即拉起 Google OAuth 2.0 浏览器登录 (推荐)"
    echo "  2) 拉起 GCP ADC 登录 (gcloud auth application-default login)"
    if [[ "$has_profiles" -eq 1 ]]; then
      echo "  3) 从已保存的账号槽位中一键切换登录"
    fi
    echo "  0) 取消并返回主菜单"
    read -r -p "请选择 [1]: " auth_choice
    case "${auth_choice:-1}" in
      1) do_oauth2_login || return 1 ;;
      2) do_adc_login || return 1 ;;
      3)
        if [[ "$has_profiles" -eq 1 ]]; then
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
