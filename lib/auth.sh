#!/usr/bin/env bash
# ==============================================================================
# colabd - Google Colab authentication, account switching, and GCP VM auth
# ==============================================================================

refresh_colab_auth_status() {
  local timeout_sec="${1:-4}"
  if ! command -v colab >/dev/null 2>&1; then
    AUTH_STATE="missing_cli"
    AUTH_DETAIL="未安装 google-colab-cli"
    return 1
  fi

  if [[ "$COLAB_AUTH_MODE" == "adc" ]]; then
    local adc_file="${GOOGLE_APPLICATION_CREDENTIALS:-${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json}"
    if [[ ! -f "$adc_file" ]]; then
      AUTH_STATE="unauth"
      AUTH_DETAIL="未找到 ADC 凭证文件 (${adc_file})"
      return 1
    fi
  fi

  local colab_bin
  colab_bin="$(command -v colab)"
  local probe_out
  probe_out="$(python3 - "$colab_bin" "$COLAB_AUTH_MODE" "$timeout_sec" <<'PY' 2>/dev/null
import os
import sys
import signal
import subprocess

colab_bin, auth_mode, timeout_s = sys.argv[1], sys.argv[2], float(sys.argv[3])
env = os.environ.copy()
env["BROWSER"] = "/usr/bin/false"

try:
    p = subprocess.Popen(
        [colab_bin, "--auth", auth_mode, "sessions"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
        start_new_session=True,
    )
    out, _ = p.communicate(timeout=timeout_s)
    if p.returncode == 0:
        first_line = next((ln.strip() for ln in out.splitlines() if ln.strip()), "凭证有效")
        print(f"OK|{first_line[:60]}")
    else:
        err_line = next((ln.strip() for ln in reversed(out.splitlines()) if ln.strip()), "未授权或令牌失效")
        print(f"UNAUTH|{err_line[:60]}")
except subprocess.TimeoutExpired:
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except Exception:
        pass
    print("UNAUTH|等待浏览器登录授权")
except Exception as exc:
    print(f"UNAUTH|{exc}")
PY
)"

  local tag="${probe_out%%|*}"
  local msg="${probe_out#*|}"
  if [[ "$tag" == "OK" ]]; then
    AUTH_STATE="ok"
    AUTH_DETAIL="$msg"
    return 0
  else
    AUTH_STATE="unauth"
    AUTH_DETAIL="${msg:-未登录}"
    return 1
  fi
}

format_auth_badge() {
  case "$AUTH_STATE" in
    ok)
      echo "${C_GREEN}● 已登录${C_RESET} (模式: ${COLAB_AUTH_MODE} | GCP自动授权: $( [[ "$AUTO_GCP_AUTH" == "1" ]] && echo "开" || echo "关" ))"
      ;;
    missing_cli)
      echo "${C_RED}✗ 未安装 google-colab-cli${C_RESET} (请进菜单 [6] 一键安装并登录)"
      ;;
    unauth)
      echo "${C_YELLOW}○ 未登录或凭证待授权${C_RESET} (模式: ${COLAB_AUTH_MODE} — 请进菜单 [6] 登录)"
      ;;
    *)
      echo "${C_DIM}○ 待检测${C_RESET} (模式: ${COLAB_AUTH_MODE})"
      ;;
  esac
}

do_oauth2_login() {
  if ! command -v colab >/dev/null 2>&1; then
    echo "${C_RED}[错误] 请先安装 google-colab-cli（可在账号页选 [7] 一键安装）。${C_RESET}"
    return 1
  fi
  COLAB_AUTH_MODE="oauth2"
  save_config
  echo ""
  echo "${C_CYAN}[登录] 正在拉起 Google Colab OAuth 2.0 授权流程...${C_RESET}"
  if colab --auth oauth2 sessions; then
    refresh_colab_auth_status 6 || true
    echo "${C_GREEN}[成功] Google Colab OAuth 2.0 登录验证通过！${C_RESET}"
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
  echo ""
  echo "${C_CYAN}[ADC 登录] 正在调用 gcloud 申请包含 colaboratory 权限域的应用默认凭证...${C_RESET}"
  if gcloud auth application-default login --scopes="$ADC_SCOPES"; then
    COLAB_AUTH_MODE="adc"
    save_config
    if command -v colab >/dev/null 2>&1 && colab --auth adc sessions; then
      refresh_colab_auth_status 6 || true
      echo "${C_GREEN}[成功] GCP ADC 登录并验证 Colab 访问通过！${C_RESET}"
      return 0
    fi
  fi
  AUTH_STATE="unauth"
  echo "${C_RED}[失败] GCP ADC 登录未完成或缺少 colaboratory 权限域。${C_RESET}"
  return 1
}

do_colab_logout_switch() {
  if ! command -v colab >/dev/null 2>&1; then
    echo "${C_RED}[错误] 本机未安装 google-colab-cli。${C_RESET}"
    return 1
  fi

  local target="${ACTIVE_SESSION_NAME:-$SESSION_NAME}"
  if [[ "$MANAGED_SESSION" -eq 1 ]] || colab_cli status -s "$target" >/dev/null 2>&1; then
    echo ""
    echo "${C_YELLOW}[防扣费保护] 检测到当前账号下存在活跃实例 '${target}'！${C_RESET}"
    read -r -p "是否先执行 colab stop 回收当前账号实例再登出? [Y/n]: " stop_first
    if [[ ! "${stop_first:-Y}" =~ ^[Nn]$ ]]; then
      stop_colab_instance
    fi
  fi

  echo "${C_CYAN}[登出] 正在执行 colab logout 清除本地 OAuth2 与缓存运行时令牌...${C_RESET}"
  colab logout || true
  AUTH_STATE="unauth"
  AUTH_DETAIL="已登出"
  echo "${C_GREEN}[已登出] 本地 Colab 令牌已清理完毕。${C_RESET}"

  read -r -p "是否立即登录新的 Google 账号? [Y/n]: " relogin
  if [[ ! "${relogin:-Y}" =~ ^[Nn]$ ]]; then
    echo "  1) 使用 Google OAuth 2.0 登录新账号 (推荐)"
    echo "  2) 使用 gcloud ADC 登录新账号"
    read -r -p "选择登录方式 [1]: " l_opt
    if [[ "${l_opt:-1}" == "2" ]]; then
      do_adc_login || true
    else
      do_oauth2_login || true
    fi
  fi
}

do_remote_gcp_auth() {
  if ! command -v colab >/dev/null 2>&1; then
    echo "${C_RED}[错误] 本机未安装 google-colab-cli。${C_RESET}"
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

  echo "${C_CYAN}[远端授权] 正在执行 colab --auth ${COLAB_AUTH_MODE} auth -s ${target} ...${C_RESET}"
  if colab_cli auth -s "$target"; then
    echo "${C_GREEN}[成功] 远端会话 '${target}' 已完成 GCP 服务鉴权！${C_RESET}"
  else
    echo "${C_RED}[失败] 远端 GCP 授权执行失败，请确认本地账号具备对应权限。${C_RESET}"
  fi
}

do_install_or_update_cli() {
  echo ""
  if command -v colab >/dev/null 2>&1; then
    echo "${C_CYAN}[升级] 正在检查并更新 google-colab-cli ...${C_RESET}"
    colab update --install || {
      if command -v uv >/dev/null 2>&1; then
        uv tool upgrade google-colab-cli
      else
        python3 -m pip install --upgrade google-colab-cli
      fi
    }
  else
    echo "${C_CYAN}[安装] 正在安装官方 google-colab-cli ...${C_RESET}"
    if command -v uv >/dev/null 2>&1; then
      uv tool install google-colab-cli
    else
      python3 -m pip install --user google-colab-cli
    fi
  fi
  refresh_colab_auth_status 5 || true
}

ensure_cli_and_authenticated() {
  if ! command -v colab >/dev/null 2>&1; then
    echo "${C_YELLOW}[未安装 CLI] 本机未检测到 'colab' 命令 (google-colab-cli)。${C_RESET}"
    read -r -p "是否立即自动安装 google-colab-cli? [Y/n]: " inst_yn
    if [[ "${inst_yn:-Y}" =~ ^[Nn]$ ]]; then
      return 1
    fi
    do_install_or_update_cli
    command -v colab >/dev/null 2>&1 || return 1
  fi

  if ! refresh_colab_auth_status 5; then
    echo ""
    echo "${C_YELLOW}[需要登录] 当前 Google Colab 尚未登录或令牌已过期 (${AUTH_DETAIL})。${C_RESET}"
    echo "  1) 立即拉起 Google OAuth 2.0 浏览器登录 (推荐)"
    echo "  2) 拉起 GCP ADC 登录 (gcloud auth application-default login)"
    echo "  0) 取消并返回主菜单"
    read -r -p "请选择 [1]: " auth_choice
    case "${auth_choice:-1}" in
      1) do_oauth2_login || return 1 ;;
      2) do_adc_login || return 1 ;;
      *) return 1 ;;
    esac
  fi
  return 0
}
