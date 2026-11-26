#!/usr/bin/env bash
# ==============================================================================
# colabd - Core configuration, state paths, multi-account CLI wrapper, metadata
# Compatible with Bash 3.2+ (macOS and Linux)
# ==============================================================================

COLABD_VERSION="0.1.0"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/colabd"
ACCOUNTS_DIR="${CONFIG_DIR}/accounts"
COLAB_CLI_CONFIG_DIR="${COLAB_CLI_CONFIG_DIR:-$HOME/.config/colab-cli}"
LEGACY_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/colab-maya/config.env"
CONFIG_FILE="${CONFIG_DIR}/config.env"

STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/colabd.XXXXXX")"
RUNNER_PY="${STATE_DIR}/session_runner.py"
REMOTE_LOG="${STATE_DIR}/remote.log"
SSH_LOG="${STATE_DIR}/ssh.log"

EXEC_PID=""
SSH_PID=""
MANAGED_SESSION=0
ACTIVE_SESSION_NAME=""
ACTIVE_SESSION_HAS_OWNER=0
ACTIVE_SESSION_ACCOUNT=""
ACTIVE_SESSION_AUTH_MODE=""

# Signal-safe OAuth2 keyring swap recovery state (restored by cleanup_on_exit on Ctrl+C)
OAUTH_SWAP_ACTIVE=0
OAUTH_SWAP_BACKUP_FILE=""
OAUTH_SWAP_HAD_PREV=0

# Auth probe cache: missing_cli | unauth | insufficient_scope | ok | unknown
AUTH_STATE="unknown"
AUTH_DETAIL=""
AUTH_EMAIL=""
AUTH_NOTE=""
AUTH_MISSING_REQ_SCOPES=""
AUTH_MISSING_OPT_SCOPES=""

ADC_SCOPES="openid,https://www.googleapis.com/auth/cloud-platform,https://www.googleapis.com/auth/userinfo.email,https://www.googleapis.com/auth/colaboratory"
FIELD_SEP=$'\037'

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_CYAN=$'\033[36m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
else
  C_RESET="" C_BOLD="" C_DIM="" C_CYAN="" C_GREEN="" C_YELLOW="" C_RED=""
fi

generate_api_key() {
  if command -v openssl >/dev/null 2>&1; then
    echo "sk-colabd-$(openssl rand -hex 16)"
  else
    echo "sk-colabd-$(date +%s)-$RANDOM$RANDOM"
  fi
}

reset_defaults() {
  SESSION_NAME="colabd-llm"
  ACTIVE_ACCOUNT=""                            # Canonical account ID: <email> (oauth2) or adc:<email> (adc)
  COLAB_AUTH_MODE="oauth2"                     # oauth2 | adc
  AUTO_ADOPT_EXTERNAL="1"                      # 1: auto-adopt pre-existing external login; 0 after explicit logout/remove
  AUTO_GCP_AUTH="0"                            # 1: run `colab auth` on session start
  GPU_TYPE="G4"                                # G4 (RTX PRO 6000 96GB) | H100 | A100 | L4 | T4
  HIGH_MEM="1"                                 # 1: pass --high-mem, 0: standard RAM
  MODEL_PRESET="ds4-abliterated-128g"          # Default uncensored Mix-128G
  MAYA_CONTEXT="65536"                         # 32768 | 65536 | 131072 | 262144
  MAYA_DRAFTING="on"                           # on | off | measure

  STORAGE_MODE="auto"                          # auto | nvme_engram | drive_engram | drive_full | local_nvme
  DRIVE_PREFETCH="1"                           # 1: search Google Drive shards first and pull to NVMe
  DRIVE_SAVE_POLICY="both"                     # both | weights_only | engram_only | none
  EXPERT_RAM_POLICY="auto"                     # auto | force_ram | allow_disk

  CUSTOM_MODELS_DIR="/content/maya-models"
  DRIVE_CACHE_DIR="/content/drive/MyDrive/maya-models"

  TUNNEL_MODE="cf_quick"                       # cf_quick | cf_named | ssh
  CF_TUNNEL_TOKEN=""
  CF_PUBLIC_HOSTNAME=""
  HF_TOKEN="${HF_TOKEN:-}"
  MAYA_API_KEY="$(generate_api_key)"
  MAYA_PORT="8080"
  LOCAL_BIND="127.0.0.1"
  NO_VISION="0"
  WEB_UI="1"
}

save_config() {
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR" 2>/dev/null || true
  local tmp_cfg="${CONFIG_FILE}.tmp.$$"
  (
    umask 077
    {
      echo "# colabd local configuration (mode 0600, do not commit)"
      printf 'SESSION_NAME=%q\n' "$SESSION_NAME"
      printf 'ACTIVE_ACCOUNT=%q\n' "$ACTIVE_ACCOUNT"
      printf 'COLAB_AUTH_MODE=%q\n' "$COLAB_AUTH_MODE"
      printf 'AUTO_ADOPT_EXTERNAL=%q\n' "$AUTO_ADOPT_EXTERNAL"
      printf 'AUTO_GCP_AUTH=%q\n' "$AUTO_GCP_AUTH"
      printf 'GPU_TYPE=%q\n' "$GPU_TYPE"
      printf 'HIGH_MEM=%q\n' "$HIGH_MEM"
      printf 'MODEL_PRESET=%q\n' "$MODEL_PRESET"
      printf 'MAYA_CONTEXT=%q\n' "$MAYA_CONTEXT"
      printf 'MAYA_DRAFTING=%q\n' "$MAYA_DRAFTING"
      printf 'STORAGE_MODE=%q\n' "$STORAGE_MODE"
      printf 'DRIVE_PREFETCH=%q\n' "$DRIVE_PREFETCH"
      printf 'DRIVE_SAVE_POLICY=%q\n' "$DRIVE_SAVE_POLICY"
      printf 'EXPERT_RAM_POLICY=%q\n' "$EXPERT_RAM_POLICY"
      printf 'CUSTOM_MODELS_DIR=%q\n' "$CUSTOM_MODELS_DIR"
      printf 'DRIVE_CACHE_DIR=%q\n' "$DRIVE_CACHE_DIR"
      printf 'TUNNEL_MODE=%q\n' "$TUNNEL_MODE"
      printf 'CF_TUNNEL_TOKEN=%q\n' "$CF_TUNNEL_TOKEN"
      printf 'CF_PUBLIC_HOSTNAME=%q\n' "$CF_PUBLIC_HOSTNAME"
      printf 'HF_TOKEN=%q\n' "$HF_TOKEN"
      printf 'MAYA_API_KEY=%q\n' "$MAYA_API_KEY"
      printf 'MAYA_PORT=%q\n' "$MAYA_PORT"
      printf 'LOCAL_BIND=%q\n' "$LOCAL_BIND"
      printf 'NO_VISION=%q\n' "$NO_VISION"
      printf 'WEB_UI=%q\n' "$WEB_UI"
    } > "$tmp_cfg"
  )
  chmod 600 "$tmp_cfg" 2>/dev/null || true
  mv "$tmp_cfg" "$CONFIG_FILE"
}

load_config() {
  reset_defaults
  if [[ ! -f "$CONFIG_FILE" && -f "$LEGACY_CONFIG_FILE" ]]; then
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR" 2>/dev/null || true
    cp "$LEGACY_CONFIG_FILE" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    case "$STORAGE_MODE" in
      drive_hybrid) STORAGE_MODE="nvme_engram" ;;
      custom_ssd)   STORAGE_MODE="local_nvme" ;;
    esac
  else
    save_config
  fi
}

account_dir_path() {
  local acct="${1-}"
  [[ -z "$acct" ]] && return 1
  account_store path "$ACCOUNTS_DIR" "$acct" 2>/dev/null
}

colab_session_config_path() {
  local acct="${1-}"
  if [[ -n "$acct" ]]; then
    local pdir=""
    if pdir="$(account_dir_path "$acct")"; then
      echo "${pdir}/sessions.json"
      return 0
    fi
  fi
  echo "${COLAB_CLI_CONFIG_DIR}/sessions.json"
}

# Strictly resolves ADC credentials path.
# When an explicit managed account ID is supplied, NEVER silently falls back to host global ADC!
colab_adc_credentials_path() {
  local acct="${1-}"
  if [[ -n "$acct" ]]; then
    local pdir=""
    if pdir="$(account_dir_path "$acct")" && [[ -f "${pdir}/adc.json" ]]; then
      echo "${pdir}/adc.json"
      return 0
    fi
    return 1
  fi
  echo "${GOOGLE_APPLICATION_CREDENTIALS:-${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json}"
  return 0
}

colab_cli_for() {
  local auth_mode="$1"
  local acct="$2"
  shift 2

  local colab_bin=""
  if ! colab_bin="$(resolve_colab_bin 2>/dev/null)"; then
    echo "${C_RED}[错误] 未找到 colab 命令，请运行 'colabd env setup' 初始化独立 uv 运行环境。${C_RESET}" >&2
    return 127
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
  if [[ "$auth_mode" == "adc" && -n "$acct" ]]; then
    if ! adc_override="$(colab_adc_credentials_path "$acct")"; then
      echo "${C_RED}[错误] 账号 '${acct}' 缺少本地 ADC 凭证文件 (adc.json)，已拒绝回退至宿主机全局 ADC（防止串号）。请运行 'colabd auth refresh ${acct}'。${C_RESET}" >&2
      return 1
    fi
  fi

  if [[ -n "$adc_override" && -n "$sess_cfg" ]]; then
    GOOGLE_APPLICATION_CREDENTIALS="$adc_override" "$colab_bin" --config "$sess_cfg" --auth "$auth_mode" "$@"
  elif [[ -n "$adc_override" ]]; then
    GOOGLE_APPLICATION_CREDENTIALS="$adc_override" "$colab_bin" --auth "$auth_mode" "$@"
  elif [[ -n "$sess_cfg" ]]; then
    "$colab_bin" --config "$sess_cfg" --auth "$auth_mode" "$@"
  else
    "$colab_bin" --auth "$auth_mode" "$@"
  fi
}

colab_cli() {
  colab_cli_for "$COLAB_AUTH_MODE" "$ACTIVE_ACCOUNT" "$@"
}

format_account_label() {
  local acct="${1-}"
  local mode="${2:-$COLAB_AUTH_MODE}"
  local note="${3-}"
  if [[ -n "$acct" ]]; then
    if [[ -n "$note" ]]; then
      echo "${acct} (${mode} | ${note})"
    else
      echo "${acct} (${mode})"
    fi
  else
    echo "未登录 (${mode})"
  fi
}

mask_secret() {
  local s="${1:-}"
  local len=${#s}
  if [[ $len -eq 0 ]]; then
    echo "(未配置)"
  elif [[ $len -le 8 ]]; then
    echo "****"
  else
    echo "${s:0:4}****${s:$((len - 4)):4}"
  fi
}

model_desc() {
  case "$1" in
    ds4-abliterated-128g) echo "DeepSeek-V4.1-Flash-1017 Uncensored Mix-128G (~114GB 权重 + 161GB Engram)" ;;
    ds4-abliterated-256g) echo "DeepSeek-V4.1-Flash-1017 Uncensored Mix-256G (~236GB 权重 + 161GB Engram)" ;;
    glm-maya-m-derisked)  echo "GLM-5.3-Flash 321B Maya-M-Derisked 去拒绝版 (~116GB, 无 Engram 外挂表)" ;;
    glm-maya-xs)          echo "GLM-5.3-Flash 321B Maya-XS 轻量测试档 (~73.4GB)" ;;
    inkling-2-mini)       echo "Inkling 2 Mini 26B 极速链路验证档 (~18.3GB)" ;;
    *)                    echo "$1" ;;
  esac
}

model_requires_hf_token() {
  case "$1" in
    ds4-abliterated-128g|ds4-abliterated-256g) return 0 ;;
    *) return 1 ;;
  esac
}

model_has_engram() {
  case "$1" in
    ds4-abliterated-128g|ds4-abliterated-256g) return 0 ;;
    *) return 1 ;;
  esac
}

model_total_gb() {
  case "$1" in
    ds4-abliterated-128g) echo 285 ;;
    ds4-abliterated-256g) echo 405 ;;
    glm-maya-m-derisked)  echo 122 ;;
    glm-maya-xs)          echo 78  ;;
    inkling-2-mini)       echo 22  ;;
    *)                    echo 120 ;;
  esac
}

storage_desc() {
  case "$1" in
    auto)         echo "自动匹配 (235GB 盘跑 DeepSeek 自动选反向跨盘: 本地 NVMe 放 Engram)" ;;
    nvme_engram)  echo "反向跨盘推荐 (Engram 拉取到本地 NVMe + 主权重云盘软链全进内存，推理零网盘 I/O)" ;;
    drive_engram) echo "正向跨盘 (主权重放本地 NVMe + 161GB Engram 软链在云盘运行)" ;;
    drive_full)   echo "全量云盘直连 (所有文件直接挂载于 ${DRIVE_CACHE_DIR})" ;;
    local_nvme)   echo "纯本地/自定义高速盘 (${CUSTOM_MODELS_DIR}，仍可配合云盘拉取/回存)" ;;
    *)            echo "$1" ;;
  esac
}

save_policy_desc() {
  case "$1" in
    both)         echo "主权重与 Engram 新下载分片均回存云盘" ;;
    weights_only) echo "仅主权重存云盘 (161GB Engram 仅在本地临时使用)" ;;
    engram_only)  echo "仅 161GB Engram 回存云盘" ;;
    none)         echo "不向云盘写入任何新分片 (仅只读查找或纯本地)" ;;
    *)            echo "$1" ;;
  esac
}

ram_policy_desc() {
  case "$1" in
    auto)       echo "智能常驻 (内存池充足时自动 --mmap-experts off 全载入 RAM)" ;;
    force_ram)  echo "强制全内存锁死 (开启 DS4_REQUIRE_ALL_RAM=1 / --mmap-experts off)" ;;
    allow_disk) echo "允许文件映射交换 (--mmap-experts on，省系统内存)" ;;
    *)          echo "$1" ;;
  esac
}

tunnel_desc() {
  case "$1" in
    cf_quick) echo "Cloudflare 临时公网隧道 (*.trycloudflare.com, 免配置)" ;;
    cf_named) echo "Cloudflare 固定域名隧道 (${CF_PUBLIC_HOSTNAME:-已配 Token})" ;;
    ssh)      echo "Colab 官方 WebSocket SSH 端口转发 (http://${LOCAL_BIND}:${MAYA_PORT})" ;;
    *)        echo "$1" ;;
  esac
}

is_bg_running() {
  [[ -n "$EXEC_PID" ]] && kill -0 "$EXEC_PID" 2>/dev/null
}

read_telemetry_field() {
  local field="$1"
  if [[ ! -f "$REMOTE_LOG" ]]; then
    echo ""
    return
  fi
  local host_py=""
  host_py="$(resolve_host_python 2>/dev/null || command -v python3 2>/dev/null || true)"
  [[ -z "$host_py" ]] && return 0
  "$host_py" - "$REMOTE_LOG" "$field" <<'PY' 2>/dev/null || true
import json, sys, pathlib
log_path = pathlib.Path(sys.argv[1])
field = sys.argv[2]
latest = {}
for line in reversed(log_path.read_text(errors="replace").splitlines()):
    if line.startswith("[TELEMETRY] "):
        try:
            latest = json.loads(line[len("[TELEMETRY] "):])
            break
        except Exception:
            pass
val = latest.get(field, "")
print("" if val is None else val)
PY
}

resolve_current_endpoint() {
  if [[ "$TUNNEL_MODE" == "ssh" ]]; then
    local host_for_client="$LOCAL_BIND"
    if [[ "$host_for_client" == "0.0.0.0" ]]; then
      host_for_client="127.0.0.1"
    fi
    echo "http://${host_for_client}:${MAYA_PORT}"
    return
  fi
  if [[ "$TUNNEL_MODE" == "cf_named" && -n "$CF_PUBLIC_HOSTNAME" ]]; then
    local url="$CF_PUBLIC_HOSTNAME"
    [[ "$url" != http* ]] && url="https://${url}"
    echo "${url%/}"
    return
  fi
  read_telemetry_field "public_url"
}
