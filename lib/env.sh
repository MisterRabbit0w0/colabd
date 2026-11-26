#!/usr/bin/env bash
# ==============================================================================
# colabd - Managed isolated uv Python runtime & google-colab-cli resolver
# Compatible with Bash 3.2+ (macOS and Linux)
# ==============================================================================

COLABD_RUNTIME_DIR="${COLABD_RUNTIME_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/colabd-runtime}"
COLABD_VENV_DIR="${COLABD_VENV_DIR:-${COLABD_RUNTIME_DIR}/venv}"
COLABD_UV_BIN_DIR="${COLABD_UV_BIN_DIR:-${COLABD_RUNTIME_DIR}/bin}"
COLABD_PYTHON_VERSION="${COLABD_PYTHON_VERSION:-3.12}"
COLABD_COLAB_PACKAGE="${COLABD_COLAB_PACKAGE:-google-colab-cli}"
COLABD_UV_INSTALL_URL="${COLABD_UV_INSTALL_URL:-https://astral.sh/uv/install.sh}"

resolve_symlink_target() {
  local src="$1"
  local guard=0
  while [[ -L "$src" && "$guard" -lt 32 ]]; do
    local dir=""
    dir="$(cd -P "$(dirname "$src")" 2>/dev/null && pwd)" || break
    local next=""
    next="$(readlink "$src" 2>/dev/null)" || break
    if [[ "$next" == /* ]]; then
      src="$next"
    else
      src="${dir}/${next}"
    fi
    guard=$((guard + 1))
  done
  echo "$src"
}

resolve_uv_bin() {
  if [[ -n "${COLABD_UV_BIN:-}" && -x "${COLABD_UV_BIN}" ]]; then
    echo "${COLABD_UV_BIN}"
    return 0
  fi
  if [[ -x "${COLABD_UV_BIN_DIR}/uv" ]]; then
    echo "${COLABD_UV_BIN_DIR}/uv"
    return 0
  fi
  if command -v uv >/dev/null 2>&1; then
    command -v uv
    return 0
  fi
  if [[ -x "${HOME}/.local/bin/uv" ]]; then
    echo "${HOME}/.local/bin/uv"
    return 0
  fi
  if [[ -x "${HOME}/.cargo/bin/uv" ]]; then
    echo "${HOME}/.cargo/bin/uv"
    return 0
  fi
  return 1
}

resolve_colab_bin() {
  if [[ -n "${COLABD_COLAB_BIN:-}" && -x "${COLABD_COLAB_BIN}" ]]; then
    echo "${COLABD_COLAB_BIN}"
    return 0
  fi
  if [[ -x "${COLABD_VENV_DIR}/bin/colab" ]]; then
    echo "${COLABD_VENV_DIR}/bin/colab"
    return 0
  fi
  if command -v colab >/dev/null 2>&1; then
    command -v colab
    return 0
  fi
  if [[ -x "${HOME}/.local/bin/colab" ]]; then
    echo "${HOME}/.local/bin/colab"
    return 0
  fi
  return 1
}

colab_runtime_source() {
  if [[ -n "${COLABD_COLAB_BIN:-}" && -x "${COLABD_COLAB_BIN}" ]]; then
    echo "override"
  elif [[ -x "${COLABD_VENV_DIR}/bin/colab" ]]; then
    echo "managed_venv"
  elif command -v colab >/dev/null 2>&1 || [[ -x "${HOME}/.local/bin/colab" ]]; then
    echo "external"
  else
    echo "missing"
  fi
}

resolve_colab_python() {
  local colab_bin="${1:-}"
  if [[ -z "$colab_bin" ]]; then
    colab_bin="$(resolve_colab_bin 2>/dev/null || true)"
  fi
  [[ -z "$colab_bin" || ! -f "$colab_bin" ]] && return 1

  local first_line=""
  IFS= read -r first_line < "$colab_bin" 2>/dev/null || true
  if [[ "$first_line" == "#!"* ]]; then
    local shebang="${first_line#\#!}"
    shebang="${shebang#"${shebang%%[![:space:]]*}"}"
    case "$shebang" in
      "/usr/bin/env "*)
        local rest="${shebang#/usr/bin/env }"
        rest="${rest#-S }"
        local py_cmd="${rest%% *}"
        if [[ "$py_cmd" == *python* ]] && command -v "$py_cmd" >/dev/null 2>&1; then
          command -v "$py_cmd"
          return 0
        fi
        ;;
      *python*)
        local py_path="${shebang%% *}"
        if [[ -x "$py_path" ]]; then
          echo "$py_path"
          return 0
        fi
        ;;
    esac
  fi

  local real_bin=""
  real_bin="$(resolve_symlink_target "$colab_bin")"
  local bin_dir=""
  bin_dir="$(dirname "$real_bin")"
  if [[ -x "${bin_dir}/python3" ]]; then
    echo "${bin_dir}/python3"
    return 0
  elif [[ -x "${bin_dir}/python" ]]; then
    echo "${bin_dir}/python"
    return 0
  fi

  return 1
}

resolve_host_python() {
  if [[ -n "${COLABD_PYTHON_BIN:-}" && -x "${COLABD_PYTHON_BIN}" ]]; then
    echo "${COLABD_PYTHON_BIN}"
    return 0
  fi
  if [[ -n "${COLABD_COLAB_BIN:-}" && -x "${COLABD_COLAB_BIN}" ]]; then
    local override_py=""
    override_py="$(resolve_colab_python "${COLABD_COLAB_BIN}" 2>/dev/null || true)"
    if [[ -n "$override_py" && -x "$override_py" ]]; then
      echo "$override_py"
      return 0
    fi
  fi
  if [[ -x "${COLABD_VENV_DIR}/bin/python" ]]; then
    echo "${COLABD_VENV_DIR}/bin/python"
    return 0
  fi
  local ext_py=""
  ext_py="$(resolve_colab_python 2>/dev/null || true)"
  if [[ -n "$ext_py" && -x "$ext_py" ]]; then
    echo "$ext_py"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi
  return 1
}

format_runtime_badge() {
  local src=""
  src="$(colab_runtime_source)"
  case "$src" in
    managed_venv)
      local py_ver=""
      py_ver="$("${COLABD_VENV_DIR}/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")' 2>/dev/null || echo "Python ${COLABD_PYTHON_VERSION}")"
      echo "${C_GREEN}● 独立 uv 隔离环境${C_RESET} (${COLABD_VENV_DIR} | Python ${py_ver})"
      ;;
    override)
      echo "${C_CYAN}● 自定义覆盖${C_RESET} (${COLABD_COLAB_BIN})"
      ;;
    external)
      local ext_bin=""
      ext_bin="$(resolve_colab_bin 2>/dev/null || true)"
      echo "${C_YELLOW}○ 外部 colab CLI${C_RESET} (${ext_bin} — 建议运行 'colabd env setup' 切换至独立 uv 环境)"
      ;;
    *)
      echo "${C_RED}✗ 尚未初始化独立 uv 环境${C_RESET} (请运行 'colabd env setup' 或选菜单 [9])"
      ;;
  esac
}

ensure_uv_available() {
  local uv_bin=""
  if uv_bin="$(resolve_uv_bin 2>/dev/null)"; then
    echo "$uv_bin"
    return 0
  fi

  echo "${C_CYAN}[uv] 未检测到 uv，正在安装独立 uv 至 ${COLABD_UV_BIN_DIR} (不修改 shell 配置文件)...${C_RESET}" >&2
  mkdir -p "$COLABD_UV_BIN_DIR"
  if command -v curl >/dev/null 2>&1; then
    if ! curl -LsSf "$COLABD_UV_INSTALL_URL" | env UV_UNMANAGED_INSTALL="$COLABD_UV_BIN_DIR" sh >&2; then
      echo "${C_RED}[错误] 自动安装 uv 失败，请检查网络或手动安装 https://docs.astral.sh/uv/。${C_RESET}" >&2
      return 1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget -qO- "$COLABD_UV_INSTALL_URL" | env UV_UNMANAGED_INSTALL="$COLABD_UV_BIN_DIR" sh >&2; then
      echo "${C_RED}[错误] 自动安装 uv 失败，请检查网络或手动安装 https://docs.astral.sh/uv/。${C_RESET}" >&2
      return 1
    fi
  else
    echo "${C_RED}[错误] 本机缺少 curl 与 wget，无法自动下载 uv。${C_RESET}" >&2
    return 1
  fi

  if uv_bin="$(resolve_uv_bin 2>/dev/null)"; then
    echo "$uv_bin"
    return 0
  fi
  echo "${C_RED}[错误] uv 安装完成后未在 ${COLABD_UV_BIN_DIR} 找到可执行文件。${C_RESET}" >&2
  return 1
}

ensure_managed_uv_env() {
  local action="${1:-install}" # install | upgrade | reset

  local uv_bin=""
  if ! uv_bin="$(ensure_uv_available)"; then
    return 1
  fi

  mkdir -p "$COLABD_RUNTIME_DIR"

  if [[ "$action" == "reset" && -d "$COLABD_VENV_DIR" ]]; then
    echo "${C_YELLOW}[环境重建] 正在清理旧的独立 uv 虚拟环境 (${COLABD_VENV_DIR})...${C_RESET}"
    rm -rf "$COLABD_VENV_DIR"
  fi

  local need_venv=0
  if [[ ! -x "${COLABD_VENV_DIR}/bin/python" ]]; then
    need_venv=1
  elif ! "${COLABD_VENV_DIR}/bin/python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' >/dev/null 2>&1; then
    need_venv=1
  fi

  if [[ "$need_venv" -eq 1 ]]; then
    echo "${C_CYAN}[uv venv] 正在创建独立 Python ${COLABD_PYTHON_VERSION} 虚拟环境: ${COLABD_VENV_DIR} ...${C_RESET}"
    if ! "$uv_bin" venv --clear --python "$COLABD_PYTHON_VERSION" "$COLABD_VENV_DIR"; then
      echo "${C_RED}[失败] 创建独立 uv Python ${COLABD_PYTHON_VERSION} 虚拟环境失败。${C_RESET}"
      return 1
    fi
  fi

  if [[ "$action" == "upgrade" ]]; then
    echo "${C_CYAN}[uv pip] 正在独立环境中升级 ${COLABD_COLAB_PACKAGE} ...${C_RESET}"
    if ! "$uv_bin" pip install --python "${COLABD_VENV_DIR}/bin/python" --upgrade "$COLABD_COLAB_PACKAGE"; then
      echo "${C_RED}[失败] 在独立环境中升级 ${COLABD_COLAB_PACKAGE} 失败。${C_RESET}"
      return 1
    fi
  else
    echo "${C_CYAN}[uv pip] 正在独立环境中安装 ${COLABD_COLAB_PACKAGE} ...${C_RESET}"
    if ! "$uv_bin" pip install --python "${COLABD_VENV_DIR}/bin/python" "$COLABD_COLAB_PACKAGE"; then
      echo "${C_RED}[失败] 在独立环境中安装 ${COLABD_COLAB_PACKAGE} 失败。${C_RESET}"
      return 1
    fi
  fi

  if [[ ! -x "${COLABD_VENV_DIR}/bin/colab" ]]; then
    echo "${C_RED}[失败] 安装完成后未在 ${COLABD_VENV_DIR}/bin/colab 找到 colab 可执行文件。${C_RESET}"
    return 1
  fi

  local py_ver=""
  local cli_ver=""
  py_ver="$("${COLABD_VENV_DIR}/bin/python" --version 2>&1 | head -n 1 || true)"
  cli_ver="$("${COLABD_VENV_DIR}/bin/colab" version 2>&1 | head -n 1 || true)"
  echo "${C_GREEN}[就绪] 独立 uv 隔离环境已准备完毕！${C_RESET}"
  echo "  虚拟环境路径 : ${COLABD_VENV_DIR}"
  echo "  Python 版本  : ${py_ver}"
  echo "  Colab CLI    : ${cli_ver}"
  return 0
}

remove_managed_uv_env() {
  if [[ -d "$COLABD_VENV_DIR" ]]; then
    rm -rf "$COLABD_VENV_DIR"
    echo "${C_GREEN}[已清理] 已移除独立 uv 虚拟环境 (${COLABD_VENV_DIR})。${C_RESET}"
  else
    echo "${C_DIM}[提示] 独立 uv 虚拟环境尚未创建 (${COLABD_VENV_DIR})。${C_RESET}"
  fi
}

print_env_status() {
  local src=""
  src="$(colab_runtime_source)"
  local uv_bin=""
  uv_bin="$(resolve_uv_bin 2>/dev/null || true)"
  local uv_ver="未安装"
  if [[ -n "$uv_bin" ]]; then
    uv_ver="$("$uv_bin" --version 2>/dev/null | head -n 1 || echo "已安装") (${uv_bin})"
  fi

  local colab_bin=""
  colab_bin="$(resolve_colab_bin 2>/dev/null || true)"
  local cli_ver="未找到"
  if [[ -n "$colab_bin" ]]; then
    cli_ver="$("$colab_bin" version 2>/dev/null | head -n 1 || echo "已安装") (${colab_bin})"
  fi

  local host_py=""
  host_py="$(resolve_host_python 2>/dev/null || true)"
  local py_desc="未找到"
  local keyring_ok="未知"
  local colab_pkg_ok="未知"
  if [[ -n "$host_py" ]]; then
    local py_v=""
    py_v="$("$host_py" --version 2>&1 | head -n 1 || echo "Python")"
    py_desc="${py_v} (${host_py})"
    if "$host_py" -c 'import keyring' >/dev/null 2>&1; then
      keyring_ok="${C_GREEN}可用 (系统钥匙串模式)${C_RESET}"
    else
      keyring_ok="${C_YELLOW}不可用 (将降级为 0600 文件存储，建议运行 colabd env setup)${C_RESET}"
    fi
    if "$host_py" -c 'import colab_cli' >/dev/null 2>&1; then
      colab_pkg_ok="${C_GREEN}可用 (支持 [?] 孤儿实例回收)${C_RESET}"
    else
      colab_pkg_ok="${C_YELLOW}不可用 (建议运行 colabd env setup)${C_RESET}"
    fi
  fi

  echo "${C_BOLD}${C_CYAN}==================== colabd 本地运行环境诊断 ====================${C_RESET}"
  echo "  当前运行来源 : $(format_runtime_badge)"
  echo "  托管目录     : ${COLABD_RUNTIME_DIR}"
  echo "  独立 venv    : ${COLABD_VENV_DIR} ($( [[ -x "${COLABD_VENV_DIR}/bin/colab" ]] && echo "${C_GREEN}已初始化${C_RESET}" || echo "${C_YELLOW}未初始化${C_RESET}" ))"
  echo "  uv 工具      : ${uv_ver}"
  echo "  生效 colab   : ${cli_ver}"
  echo "  生效 Python  : ${py_desc}"
  echo "  keyring 依赖 : ${keyring_ok}"
  echo "  colab_cli 包 : ${colab_pkg_ok}"
  echo "  gcloud CLI   : $(command -v gcloud 2>/dev/null || echo "未安装 (仅 ADC 模式需要)")"
  echo "  ssh / curl   : ssh=$(command -v ssh 2>/dev/null || echo "缺失") | curl=$(command -v curl 2>/dev/null || echo "缺失")"
  echo "${C_CYAN}=================================================================${C_RESET}"

  if [[ "$src" == "missing" ]]; then
    echo "提示: 运行 'colabd env setup' 即可一键创建独立 Python ${COLABD_PYTHON_VERSION} 虚拟环境并安装 google-colab-cli。"
    return 1
  fi
  return 0
}
