#!/usr/bin/env bash
# ==============================================================================
# colabd - Interactive TUI pages (Main Menu, Status, Logs, Settings, Multi-Account Auth)
# Compatible with Bash 3.2+ (macOS and Linux)
# ==============================================================================

page_account_auth() {
  refresh_colab_auth_status "" 0 || true
  while true; do
    clear 2>/dev/null || true
    local cli_ver="未安装"
    local colab_bin=""
    colab_bin="$(resolve_colab_bin 2>/dev/null || true)"
    if [[ -n "$colab_bin" ]]; then
      cli_ver="$("$colab_bin" version 2>/dev/null | head -n 1 || echo "已安装")"
    fi

    echo "${C_BOLD}${C_CYAN}================ Google Colab 账号管理与 GCP 授权中心 ================${C_RESET}"
    echo "  运行环境       : $(format_runtime_badge)"
    echo "  Colab CLI 版本 : ${cli_ver}"
    echo "  当前登录账号   : ${C_BOLD}$(format_account_label "$ACTIVE_ACCOUNT" "$COLAB_AUTH_MODE" "$AUTH_NOTE")${C_RESET}"
    echo "  当前认证状态   : $(format_auth_badge)"
    [[ -n "$AUTH_DETAIL" ]] && echo "  状态探测摘要   : ${AUTH_DETAIL}"
    echo "  远端 GCP 授权  : 启动实例时自动执行 colab auth = $( [[ "$AUTO_GCP_AUTH" == "1" ]] && echo "${C_GREEN}开启${C_RESET}" || echo "关闭" )"
    echo ""
    echo "  ${C_BOLD}已登录账号列表${C_RESET} (* 当前激活，按邮箱唯一去重，独立隔离 sessions.json):"
    print_saved_accounts_table || true
    echo "${C_CYAN}------------------------------------------------------------------------${C_RESET}"
    echo "  1) 刷新检测当前账号登录态、权限域 (Scopes) 与算力余额"
    echo "  2) 切换账号 (带防扣费释放保护 -> 一键秒切)"
    echo "  3) 登录 / 添加 Google 账号 (自动识别邮箱去重 + 校验必需权限域)"
    echo "  4) 重新授权 / 补齐账号权限域 (auth refresh，不丢会话记录)"
    echo "  5) 编辑账号备注 (纯展示标签，不改变唯一账号 ID)"
    echo "  6) 移除账号 / 登出 (前置探测 + 强制释放活跃实例成功后再清凭证)"
    echo "  7) 扫描并一键释放所有账号的残留 Colab 实例 (全局防扣费清理)"
    echo "  8) 远端 Colab 实例 GCP 服务授权 (colab auth) / 切换启动自动授权"
    echo "  9) 初始化 / 升级独立 uv 隔离环境 (Python ${COLABD_PYTHON_VERSION} + google-colab-cli)"
    echo "  0) 返回上级菜单"
    echo "${C_CYAN}========================================================================${C_RESET}"
    read -r -p "请选择操作编号 [0-9]: " a_opt

    case "${a_opt:-0}" in
      1)
        echo ""
        if refresh_colab_auth_status "" 1; then
          echo "${C_GREEN}[有效] 当前账号已正常登录: $(format_account_label "$ACTIVE_ACCOUNT" "$COLAB_AUTH_MODE" "$AUTH_NOTE")${C_RESET}"
          echo "${C_DIM}--- colab whoami ---${C_RESET}"
          colab_cli whoami 2>&1 | sed 's/^/  /' || true
          echo "${C_DIM}--- colab sessions ---${C_RESET}"
          colab_cli sessions 2>&1 | sed 's/^/  /' || true
          echo "${C_DIM}--- colab usage ---${C_RESET}"
          colab_cli usage 2>&1 | sed 's/^/  /' || true
        elif [[ "$AUTH_STATE" == "insufficient_scope" ]]; then
          echo "${C_RED}[权限域不足] ${AUTH_DETAIL}${C_RESET}"
          echo "${C_DIM}--- colab whoami ---${C_RESET}"
          colab_cli whoami 2>&1 | sed 's/^/  /' || true
        elif [[ "$AUTH_STATE" == "timeout" ]]; then
          echo "${C_YELLOW}[探测超时] ${AUTH_DETAIL}${C_RESET}"
        else
          echo "${C_YELLOW}[未授权] ${AUTH_DETAIL}${C_RESET}"
        fi
        read -r -p "按回车继续..." _
        ;;
      2)
        do_switch_account "" "prompt" || true
        read -r -p "按回车继续..." _
        ;;
      3)
        do_login_account "" "" "prompt" || true
        read -r -p "按回车继续..." _
        ;;
      4)
        echo ""
        local ref_q=""
        if [[ -n "$ACTIVE_ACCOUNT" ]]; then
          print_saved_accounts_table || true
          read -r -p "输入要重新授权/补齐权限的账号 ID [回车默认当前 ${ACTIVE_ACCOUNT}]: " ref_q
        fi
        do_refresh_account "$ref_q" "1" || true
        read -r -p "按回车继续..." _
        ;;
      5)
        do_edit_account_note "" "__UNSET__" || true
        read -r -p "按回车继续..." _
        ;;
      6)
        do_remove_account "" "prompt" "1" || true
        read -r -p "按回车继续..." _
        ;;
      7)
        release_all_accounts_runtimes "1" || true
        read -r -p "按回车继续..." _
        ;;
      8)
        echo ""
        echo "  1) 立即为当前运行中的远端实例执行 GCP 授权 (colab auth)"
        echo "  2) 切换【启动实例时自动执行 colab auth】开关 (当前: $( [[ "$AUTO_GCP_AUTH" == "1" ]] && echo "开启" || echo "关闭" ))"
        read -r -p "请选择 [1-2，回车取消]: " g_opt
        case "${g_opt:-}" in
          1) do_remote_gcp_auth ;;
          2)
            if [[ "$AUTO_GCP_AUTH" == "1" ]]; then AUTO_GCP_AUTH="0"; else AUTO_GCP_AUTH="1"; fi
            save_config
            echo "${C_GREEN}[已更新] 启动自动 colab auth = $( [[ "$AUTO_GCP_AUTH" == "1" ]] && echo "开启" || echo "关闭" )${C_RESET}"
            ;;
        esac
        read -r -p "按回车继续..." _
        ;;
      9)
        do_install_or_update_cli || true
        read -r -p "按回车继续..." _
        ;;
      0|"") break ;;
    esac
  done
}

probe_endpoint_health() {
  local ep="$1"
  local body=""
  if ! body="$(curl -fsS --max-time 3 -H "Authorization: Bearer ${MAYA_API_KEY}" "${ep}/health" 2>/dev/null)"; then
    echo "unreachable"
    return 1
  fi
  local host_py=""
  host_py="$(resolve_host_python 2>/dev/null || command -v python3 2>/dev/null || true)"
  if [[ -n "$host_py" && -n "$body" ]]; then
    "$host_py" - "$body" <<'PYH' 2>/dev/null || echo "ready"
import json, sys
raw = sys.argv[1].strip()
if raw.startswith("{"):
    try:
        data = json.loads(raw)
        if isinstance(data, dict) and "loaded" in data:
            print("ready" if bool(data.get("loaded")) else "loading")
            sys.exit(0)
    except Exception:
        pass
print("ready")
PYH
    return 0
  fi
  echo "ready"
  return 0
}

page_status() {
  refresh_colab_auth_status "" 0 || true
  while true; do
    clear 2>/dev/null || true
    local phase gpu drv_ver ram_gb local_free drive_free models_dir api_ok ep ram_res dio_st dio_msg dfs_gb eng_telem eff_eng
    phase="$(read_telemetry_field phase)"
    eng_telem="$(read_telemetry_field engine)"
    eff_eng="${eng_telem:-$(resolve_effective_engine "$MODEL_PRESET")}"
    gpu="$(read_telemetry_field gpu)"
    drv_ver="$(read_telemetry_field driver_version)"
    ram_gb="$(read_telemetry_field ram_gb)"
    local_free="$(read_telemetry_field local_free_gb)"
    drive_free="$(read_telemetry_field drive_free_gb)"
    models_dir="$(read_telemetry_field models_dir)"
    ram_res="$(read_telemetry_field ram_resident_active)"
    dio_st="$(read_telemetry_field drive_io_state)"
    dio_msg="$(read_telemetry_field drive_io_detail)"
    dfs_gb="$(read_telemetry_field drivefs_cache_gb)"
    api_ok="$(read_telemetry_field api_healthy)"
    ep="$(resolve_current_endpoint)"

    echo "${C_BOLD}${C_CYAN}==================== colabd 状态监控面板 (v${COLABD_VERSION}) ====================${C_RESET}"
    echo "  Colab 账号态 : $(format_auth_badge)"
    if is_bg_running; then
      echo "  守护进程状态 : ${C_GREEN}运行中${C_RESET} (本地 PID: ${EXEC_PID}, 远端会话: ${ACTIVE_SESSION_NAME:-$SESSION_NAME})"
    else
      echo "  守护进程状态 : ${C_YELLOW}未运行${C_RESET} (预设会话: ${SESSION_NAME})"
    fi
    echo "  引擎与模型   : ${C_BOLD}$(engine_label "$eff_eng")${C_RESET}  |  ${MODEL_PRESET}"
    echo "  当前执行阶段 : ${phase:-尚未启动}"
    echo "  远端硬件信息 : GPU=${gpu:-未知}$( [[ -n "$drv_ver" ]] && echo " | Driver=${drv_ver}" ) | 系统RAM=${ram_gb:-0} GiB"
    if [[ "$eff_eng" == "strata" ]]; then
      echo "  Strata 参数  : KV Cache=${STRATA_KV_FORMAT} | 并发=${STRATA_PARALLEL} | 驱动构建策略=${STRATA_BUILD_FALLBACK} | 投机解码=${MAYA_DRAFTING}"
    else
      echo "  专家内存常驻 : $( [[ "$ram_res" == "True" || "$ram_res" == "true" ]] && echo "${C_GREEN}已激活 (--mmap-experts off，零专家交换)${C_RESET}" || echo "默认按需映射 (${EXPERT_RAM_POLICY})" )"
      echo "  Maya 参数    : KV Cache=${STRATA_KV_FORMAT} | 投机解码=${MAYA_DRAFTING} | $(maya_ablation_desc)"
    fi
    echo "  远端磁盘余量 : 本地 /content 剩余 ${local_free:-未知} GiB | 云盘剩余 ${drive_free:-未挂载} GiB$( [[ -n "$dfs_gb" && "$dfs_gb" != "0" && "$dfs_gb" != "0.0" ]] && echo " | DriveFS缓存 ${dfs_gb} GiB" )"
    echo "  工作目录拓扑 : ${models_dir:-尚未初始化} (模式: ${STORAGE_MODE} | HF并发: ${HF_DOWNLOAD_CONCURRENCY} 线程)"
    if [[ "$dio_st" == "disabled" || ( -z "$dio_st" && "$STORAGE_MODE" == "local_nvme" ) ]]; then
      echo "  云盘直落通道 : 未启用 (纯本地高速 NVMe 模式，免挂云盘)"
    else
      echo "  云盘直落通道 : ${dio_msg:-等待扩容写入或原地复用} (${dio_st:-idle} | 策略: ${DRIVE_WRITE_MODE})"
    fi
    echo ""
    echo "${C_BOLD}[服务与隧道连通性]${C_RESET}"
    echo "  暴露模式     : $(tunnel_desc "$TUNNEL_MODE")"
    echo "  根访问地址   : ${C_BOLD}${ep:-(等待生成或尚未启动)}${C_RESET}"
    if [[ -n "$ep" ]]; then
      echo "  OpenAI 端点  : ${ep}/v1/chat/completions  |  ${ep}/v1/responses"
      echo "  Anthropic端点: ${ep}/v1/messages"
    fi
    echo "  API Key      : ${MAYA_API_KEY}"

    if [[ -n "$ep" && "$ep" != *"<"* ]]; then
      local hstate=""
      hstate="$(probe_endpoint_health "$ep" || true)"
      if [[ "$hstate" == "ready" ]]; then
        echo "  实时健康探测 : ${C_GREEN}HTTP 200 在线可用 (模型已加载完毕)${C_RESET}"
      elif [[ "$hstate" == "loading" ]]; then
        echo "  实时健康探测 : ${C_YELLOW}引擎 HTTP 已启动，模型权重正在加载入显存中...${C_RESET}"
      elif [[ "$api_ok" == "True" || "$api_ok" == "true" ]]; then
        echo "  实时健康探测 : ${C_YELLOW}远端引擎已就绪，隧道连接建立中...${C_RESET}"
      else
        echo "  实时健康探测 : ${C_YELLOW}正在拉取分片/下载/初始化引擎中 (可按 l 查看实时进度)${C_RESET}"
      fi
    fi

    echo ""
    echo "${C_BOLD}[Colab 会话状态 & 算力单元消耗 (colab status / colab usage)]${C_RESET}"
    if [[ "$AUTH_STATE" == "ok" ]]; then
      local target="${ACTIVE_SESSION_NAME:-$SESSION_NAME}"
      echo "${C_DIM}--- colab status -s ${target} ($(format_account_label "$ACTIVE_ACCOUNT" "$COLAB_AUTH_MODE" "$AUTH_NOTE")) ---${C_RESET}"
      colab_cli status -s "$target" 2>&1 | sed 's/^/  /' || echo "  (当前无活跃会话记录)"
      echo "${C_DIM}--- colab usage ---${C_RESET}"
      colab_cli usage 2>&1 | sed 's/^/  /' || echo "  (无法获取算力单元用量)"
    elif [[ "$AUTH_STATE" == "timeout" ]]; then
      echo "  (认证状态探测超时，本地凭证仍在；按 r 重试刷新，或检查网络/代理)"
    else
      echo "  (账号尚未登录或未安装 CLI，可按 a 进入多账号中心登录)"
    fi
    echo "${C_CYAN}=========================================================================${C_RESET}"
    echo "操作: [r] 刷新  [t] 测试对话  [l] 实时日志  [g] 注入远端 GCP 授权  [a] 多账号中心  [回车/b] 返回"
    read -r -p "请选择: " sub
    case "${sub:-b}" in
      r|R) refresh_colab_auth_status "" 1 || true; continue ;;
      t|T) action_test_request ;;
      l|L) action_view_logs ;;
      g|G) do_remote_gcp_auth; read -r -p "按回车继续..." _ ;;
      a|A) page_account_auth ;;
      *)   break ;;
    esac
  done
}

action_view_logs() {
  if [[ ! -f "$REMOTE_LOG" ]]; then
    echo "${C_YELLOW}[提示] 当前还没有产生远端运行日志，请先在主菜单选择 [1] 启动服务。${C_RESET}"
    sleep 1
    return
  fi
  echo ""
  echo "${C_CYAN}================ 实时构建与分片拉取日志 (按 Ctrl+C 仅返回菜单，不会销毁实例) ================${C_RESET}"
  trap ':' INT
  tail -n 60 -f "$REMOTE_LOG" | grep -v '^\[TELEMETRY\] ' || true
  trap 'exit 130' INT
  echo ""
  echo "${C_GREEN}[已退出日志视图，后台服务仍在继续运行]${C_RESET}"
  sleep 1
}

action_test_request() {
  local ep
  ep="$(resolve_current_endpoint)"
  if [[ -z "$ep" || "$ep" == *"<"* ]]; then
    echo "${C_RED}[错误] 当前尚未获取到有效的隧道或本地代理地址，请先确认服务已启动。${C_RESET}"
    read -r -p "按回车继续..." _
    return
  fi
  echo ""
  read -r -p "输入测试提问 [默认: 你好，请用两句话介绍你当前的模型架构]: " prompt_txt
  prompt_txt="${prompt_txt:-你好，请用两句话介绍你当前的模型架构}"

  local host_py=""
  host_py="$(resolve_host_python 2>/dev/null || command -v python3)"
  local payload
  payload="$("$host_py" -c 'import json,sys; print(json.dumps({"messages":[{"role":"user","content":sys.argv[1]}],"stream":True}, ensure_ascii=False))' "$prompt_txt")"

  echo "${C_CYAN}[请求] POST ${ep}/v1/chat/completions ...${C_RESET}"
  curl -sS --no-buffer "${ep}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${MAYA_API_KEY}" \
    -d "$payload" || echo "${C_RED}[请求失败，模型可能仍在拉取分片或编译预热中]${C_RESET}"
  echo ""
  echo ""
  read -r -p "按回车继续..." _
}

prompt_sync_recommended_hw() {
  local preset="$1"
  local rec_gpu="" rec_hm="" rec_ctx="" rec_st=""
  rec_gpu="$(model_recommended_gpu "$preset")"
  rec_hm="$(model_recommended_high_mem "$preset")"
  rec_ctx="$(model_recommended_context "$preset")"
  rec_st="$(model_recommended_storage "$preset")"
  local hm_txt="关闭 (Free 兼容)"
  [[ "$rec_hm" == "1" ]] && hm_txt="开启 (--high-mem)"
  echo ""
  echo "该预设推荐硬件参数: GPU=${C_GREEN}${rec_gpu}${C_RESET} | High-RAM=${C_GREEN}${hm_txt}${C_RESET} | 上下文=${rec_ctx} | 存储=${rec_st}"
  read -r -p "是否同步应用推荐硬件配置? [Y/n]: " sync_hw
  if [[ ! "${sync_hw:-Y}" =~ ^[Nn]$ ]]; then
    GPU_TYPE="$rec_gpu"
    HIGH_MEM="$rec_hm"
    MAYA_CONTEXT="$rec_ctx"
    STORAGE_MODE="$rec_st"
  fi
}

select_preset_from_tier() {
  local tier_id="$1"
  local tier_title="$2"
  local rows=""
  rows="$(model_registry list --tier "$tier_id" 2>/dev/null || true)"
  if [[ -z "$rows" ]]; then
    echo "${C_YELLOW}[提示] 该分组暂无内置预设。${C_RESET}"
    sleep 1
    return 1
  fi

  local ids=()
  local idx=0
  local pid peng pdesc pgpu phm pdisk ptok
  echo ""
  echo "${C_BOLD}${C_CYAN}--- ${tier_title} ---${C_RESET}"
  while IFS="$FIELD_SEP" read -r pid peng _ _ pdesc pgpu phm pdisk _ ptok; do
    [[ -z "$pid" ]] && continue
    idx=$((idx + 1))
    ids+=("$pid")
    local mark=" "
    [[ "$pid" == "$MODEL_PRESET" ]] && mark="*"
    local hw_tag="${pgpu} Std-RAM"
    if [[ "$phm" == "1" ]]; then
      hw_tag="${pgpu} High-RAM"
    fi
    local tok_tag=""
    [[ "$ptok" == "1" ]] && tok_tag=" ${C_YELLOW}[需HF_TOKEN]${C_RESET}"
    printf " %s%2d) %-32s [%s | %s | ~%sGB]%s\n" "$mark" "$idx" "$pid" "$peng" "$hw_tag" "$pdisk" "$tok_tag"
    echo "      ${C_DIM}${pdesc}${C_RESET}"
  done <<< "$rows"

  echo "   0) 返回"
  read -r -p "请选择预设编号 [0-${idx}]: " pick
  if [[ -z "$pick" || "$pick" == "0" ]]; then
    return 1
  fi
  if [[ "$pick" =~ ^[0-9]+$ && "$pick" -ge 1 && "$pick" -le "$idx" ]]; then
    local chosen="${ids[$((pick - 1))]}"
    MODEL_PRESET="$chosen"
    ENGINE_TYPE="auto"
    prompt_sync_recommended_hw "$MODEL_PRESET"
    save_config
    return 0
  fi
  echo "${C_RED}[无效编号] ${pick}${C_RESET}"
  sleep 1
  return 1
}

configure_custom_model_interactive() {
  echo ""
  echo "${C_BOLD}${C_CYAN}--- 自定义 Hugging Face 仓库 / 量化模型 ---${C_RESET}"
  echo "  1) Strata 引擎自定义 HF 模型 (.strata / .gguf / Safetensors，或官方目录量化)"
  echo "  2) Project Maya 引擎自定义模型参数 / HF 仓库"
  echo "  0) 返回"
  read -r -p "选择引擎 [1-2，回车取消]: " c_eng
  case "${c_eng:-0}" in
    1)
      echo ""
      echo "选择 Strata 模型家族 (或输入自定义家族名):"
      echo "  1) inkling-2-mini"
      echo "  2) qwen"
      echo "  3) qwen36"
      echo "  4) hy4-flash"
      echo "  5) unsloth"
      echo "  6) gyro"
      read -r -p "选择家族 [1-6，回车保持 ${CUSTOM_ENGINE_FAMILY:-inkling-2-mini}]: " f_idx
      case "$f_idx" in
        1) CUSTOM_ENGINE_FAMILY="inkling-2-mini" ;;
        2) CUSTOM_ENGINE_FAMILY="qwen" ;;
        3) CUSTOM_ENGINE_FAMILY="qwen36" ;;
        4) CUSTOM_ENGINE_FAMILY="hy4-flash" ;;
        5) CUSTOM_ENGINE_FAMILY="unsloth" ;;
        6) CUSTOM_ENGINE_FAMILY="gyro" ;;
      esac
      echo ""
      echo "填写 Hugging Face 仓库 (<org>/<repo>，留空则直接按 Strata 官方目录 --family + --model 拉取):"
      read -r -p "Hugging Face 仓库 (输入 CLEAR 清空) [当前: ${CUSTOM_HF_REPO}]: " in_repo
      if [[ "$in_repo" == "CLEAR" ]]; then
        CUSTOM_HF_REPO=""
      elif [[ -n "$in_repo" ]]; then
        CUSTOM_HF_REPO="$in_repo"
      fi
      read -r -p "文件名 (.strata/.gguf) 或 Strata 官方量化名 (留空自动探测，输入 CLEAR 清空) [当前: ${CUSTOM_HF_FILE}]: " in_file
      if [[ "$in_file" == "CLEAR" ]]; then
        CUSTOM_HF_FILE=""
      elif [[ -n "$in_file" ]]; then
        CUSTOM_HF_FILE="$in_file"
      fi
      MODEL_PRESET="strata-custom-hf"
      ENGINE_TYPE="strata"
      prompt_sync_recommended_hw "$MODEL_PRESET"
      save_config
      ;;
    2)
      echo ""
      echo "输入 Project Maya 上游模型参数 (模型 ID 或 <family>:<quant> 简写；留空则配合下方自定义 HF 仓库使用):"
      read -r -p "Maya 模型参数 (输入 CLEAR 清空) [当前: ${CUSTOM_ENGINE_FAMILY}]: " in_marg
      if [[ "$in_marg" == "CLEAR" ]]; then
        CUSTOM_ENGINE_FAMILY=""
      elif [[ -n "$in_marg" ]]; then
        CUSTOM_ENGINE_FAMILY="$in_marg"
      fi
      read -r -p "可选自定义 HF 仓库 (下载后自动传 --model-dir，留空跳过，CLEAR 清空) [当前: ${CUSTOM_HF_REPO}]: " in_mrepo
      if [[ "$in_mrepo" == "CLEAR" ]]; then
        CUSTOM_HF_REPO=""
      elif [[ -n "$in_mrepo" ]]; then
        CUSTOM_HF_REPO="$in_mrepo"
      fi
      if [[ -n "$CUSTOM_HF_REPO" ]]; then
        read -r -p "可选指定仓库内文件名 (留空自动拉取全部权重，CLEAR 清空) [当前: ${CUSTOM_HF_FILE}]: " in_mfile
        if [[ "$in_mfile" == "CLEAR" ]]; then
          CUSTOM_HF_FILE=""
        elif [[ -n "$in_mfile" ]]; then
          CUSTOM_HF_FILE="$in_mfile"
        fi
      fi
      MODEL_PRESET="maya-custom"
      ENGINE_TYPE="maya"
      prompt_sync_recommended_hw "$MODEL_PRESET"
      save_config
      ;;
  esac
}

select_model_preset_interactive() {
  echo ""
  echo "${C_BOLD}${C_CYAN}请选择模型硬件分组 (当前引擎: $(resolve_effective_engine "$MODEL_PRESET") | 当前预设: ${MODEL_PRESET}):${C_RESET}"
  echo "  1) Free / 入门卡推荐 (T4 16GB, Std-RAM)"
  echo "  2) 中端卡推荐 (L4 24GB / High-RAM)"
  echo "  3) 旗舰卡推荐 (A100 / G4 / H100)"
  echo "  4) 自定义 Hugging Face 仓库 / 量化模型"
  echo "  5) 直接输入预设 ID"
  echo "  0) 返回"
  read -r -p "选择分组 [0-5]: " t_opt
  case "${t_opt:-0}" in
    1) select_preset_from_tier "free" "Free / 入门卡推荐 (T4 16GB, 标准内存)" || true ;;
    2) select_preset_from_tier "mid" "中端卡推荐 (L4 24GB / A100 40GB / High-RAM)" || true ;;
    3) select_preset_from_tier "flagship" "旗舰卡推荐 (A100 80GB / G4 96GB / H100 80GB)" || true ;;
    4) configure_custom_model_interactive ;;
    5)
      read -r -p "输入预设 ID (可先运行 'colabd models' 查看全部 ID): " raw_id
      if [[ -n "$raw_id" ]]; then
        local resolved=""
        if resolved="$(model_registry exists "$raw_id" 2>/dev/null)"; then
          MODEL_PRESET="$resolved"
          ENGINE_TYPE="auto"
          prompt_sync_recommended_hw "$MODEL_PRESET"
          save_config
        else
          echo "${C_RED}[无效预设] 未找到 '${raw_id}'。${C_RESET}"
          sleep 1
        fi
      fi
      ;;
  esac
}

configure_engine_tuning_interactive() {
  local eff_eng=""
  eff_eng="$(resolve_effective_engine "$MODEL_PRESET")"
  echo ""
  echo "${C_BOLD}${C_CYAN}--- 引擎专属参数调优 (当前生效引擎: $(engine_label "$eff_eng")) ---${C_RESET}"
  echo "  [通用 Cache / Strata 参数]"
  echo "    1) KV Cache 精度策略      : ${C_GREEN}${STRATA_KV_FORMAT}${C_RESET} (auto | int8 | k8v4 | q4_0 | fp8 | fp16 | 自定义)"
  echo "    2) Strata 并发槽数        : ${C_GREEN}${STRATA_PARALLEL}${C_RESET} (1..64，取决于模型与显存容量)"
  echo "    3) Strata 预编译/源码策略 : ${C_GREEN}${STRATA_BUILD_FALLBACK}${C_RESET} — $(strata_fallback_desc "$STRATA_BUILD_FALLBACK")"
  echo "  [Project Maya 参数]"
  echo "    4) MoE 专家全内存常驻策略 : ${C_GREEN}${EXPERT_RAM_POLICY}${C_RESET} — $(ram_policy_desc "$EXPERT_RAM_POLICY")"
  echo "    5) Maya 拒绝消融开关      : $(maya_ablation_desc)"
  echo "  [通用推理参数]"
  echo "    6) 投机解码 (Drafting)    : ${C_GREEN}${MAYA_DRAFTING}${C_RESET} (on | off | measure)"
  echo "    0) 返回"
  read -r -p "请选择要修改的编号 [0-6]: " e_opt
  case "${e_opt:-0}" in
    1)
      echo "可选 KV Cache 精度 (同时作用于 Strata 与 Project Maya --kv):"
      echo "  1) auto  : 引擎默认自适应"
      echo "  2) int8  : 8-bit 整型量化 (较 fp16 省约一半显存)"
      echo "  3) k8v4  : Key 8-bit + Value 4-bit 混合压缩 (较 int8 再省 ~23% 显存)"
      echo "  4) q4_0  : 4-bit Hadamard 压缩 (较 int8 再省约一半显存，T4 / 大上下文推荐)"
      echo "  5) fp8   : 8-bit 浮点量化"
      echo "  6) fp16  : 半精度无损浮点"
      echo "  7) 自定义输入 (例如 q8_0 / bf16 / fp8_e4m3)"
      read -r -p "选择编号 [1-7，或直接输入精度名，回车保持 ${STRATA_KV_FORMAT}]: " kv_i
      local kv_cand=""
      case "$kv_i" in
        "") ;;
        1) kv_cand="auto" ;;
        2) kv_cand="int8" ;;
        3) kv_cand="k8v4" ;;
        4) kv_cand="q4_0" ;;
        5) kv_cand="fp8" ;;
        6) kv_cand="fp16" ;;
        7)
          read -r -p "输入自定义 KV Cache 精度 (如 q8_0、k8v4、q4_0、bf16): " kv_cand
          ;;
        *)
          kv_cand="$kv_i"
          ;;
      esac
      if [[ -n "$kv_cand" ]]; then
        if set_kv_format_validated "$kv_cand"; then
          save_config
        else
          echo "${C_RED}[忽略] Cache 精度 '${kv_cand}' 无效（仅允许字母、数字、.、_、+、-）。${C_RESET}"
          sleep 1
        fi
      fi
      ;;
    2)
      read -r -p "输入并发请求槽数 (1-64) [当前: ${STRATA_PARALLEL}]: " sp_n
      if [[ -n "$sp_n" ]]; then
        if [[ "$sp_n" =~ ^[0-9]+$ && "$sp_n" -ge 1 && "$sp_n" -le 64 ]]; then
          STRATA_PARALLEL="$sp_n"
          save_config
        else
          echo "${C_RED}[忽略] 并发槽数需为 1-64。${C_RESET}"
          sleep 1
        fi
      fi
      ;;
    3)
      echo "  1) auto     : 驱动 >= 575.51 用官方预编译秒装，旧驱动自动回退源码编译 (推荐)"
      echo "  2) prebuilt : 仅官方预编译包"
      echo "  3) source   : 强制克隆仓库按当前节点 nvcc 原生架构源码编译"
      read -r -p "选择编号 [1-3]: " sb_i
      case "$sb_i" in
        1) STRATA_BUILD_FALLBACK="auto" ;;
        2) STRATA_BUILD_FALLBACK="prebuilt" ;;
        3) STRATA_BUILD_FALLBACK="source" ;;
      esac
      save_config
      ;;
    4)
      echo "可选 MoE 专家全内存常驻策略:"
      echo "  1) auto       : 智能判断 (当显存+内存充足如 G4 272GB 时自动设置 --mmap-experts off 全载入内存)"
      echo "  2) force_ram  : 强制锁死全内存 (启用全内存常驻环境变量与 --mmap-experts off，严禁落盘)"
      echo "  3) allow_disk : 允许保留文件映射按需读盘 (--mmap-experts on，适合小内存环境)"
      read -r -p "选择编号 [1-3]: " rp_idx
      case "$rp_idx" in
        1) EXPERT_RAM_POLICY="auto" ;;
        2) EXPERT_RAM_POLICY="force_ram" ;;
        3) EXPERT_RAM_POLICY="allow_disk" ;;
      esac
      save_config
      ;;
    5)
      echo "Project Maya 拒绝方向消融 (--ablation / --ablate-default):"
      echo "  1) 加载向量，按请求开启 (--ablation on, --ablate-default off，上游默认)"
      echo "  2) 加载向量，所有请求全局默认去拒绝 (--ablation on + --ablate-default on)"
      echo "  3) 完全关闭 (--ablation off)"
      read -r -p "选择编号 [1-3]: " ab_i
      case "$ab_i" in
        1) MAYA_ABLATION="on";  MAYA_ABLATE_DEFAULT="off" ;;
        2) MAYA_ABLATION="on";  MAYA_ABLATE_DEFAULT="on" ;;
        3) MAYA_ABLATION="off"; MAYA_ABLATE_DEFAULT="off" ;;
      esac
      save_config
      ;;
    6)
      echo "投机解码策略:  1) on (启用 DSpark/MTP)   2) off (关闭省显存)   3) measure (自动实测决定)"
      read -r -p "选择编号 [1-3]: " dr_i
      case "$dr_i" in
        1) MAYA_DRAFTING="on" ;;
        2) MAYA_DRAFTING="off" ;;
        3) MAYA_DRAFTING="measure" ;;
      esac
      save_config
      ;;
  esac
}

page_settings() {
  while true; do
    clear 2>/dev/null || true
    local eff_eng=""
    eff_eng="$(resolve_effective_engine "$MODEL_PRESET")"
    echo "${C_BOLD}${C_CYAN}====================== 设置页 (自动持久化至本机 600 配置) ======================${C_RESET}"
    echo "  配置文件路径: ${CONFIG_FILE}"
    echo ""
    echo "  1) 引擎与模型选择   : [${C_CYAN}${eff_eng}${C_RESET}] ${C_GREEN}${MODEL_PRESET}${C_RESET} — $(model_title "$MODEL_PRESET")"
    echo "     ${C_DIM}$(model_desc "$MODEL_PRESET")${C_RESET}"
    echo "  2) GPU 与内存规格   : ${C_GREEN}${GPU_TYPE}${C_RESET} (高内存 --high-mem: $( [[ "$HIGH_MEM" == "1" ]] && echo "开启" || echo "关闭 / Free 兼容" ))"
    echo "  3) 运行期存储拓扑   : ${C_GREEN}${STORAGE_MODE}${C_RESET} — $(storage_desc "$STORAGE_MODE")"
    echo "  4) 下载加速与云盘写 : HF并发=${C_GREEN}${HF_DOWNLOAD_CONCURRENCY}${C_RESET} 线程 | 云盘直落=${C_GREEN}${DRIVE_WRITE_MODE}${C_RESET} ($(drive_write_mode_desc "$DRIVE_WRITE_MODE"))"
    if [[ "$eff_eng" == "strata" ]]; then
      echo "  5) 引擎专属调优     : Strata [KV=${C_GREEN}${STRATA_KV_FORMAT}${C_RESET} | 并发=${C_GREEN}${STRATA_PARALLEL}${C_RESET} | 构建=${C_GREEN}${STRATA_BUILD_FALLBACK}${C_RESET} | 投机=${MAYA_DRAFTING}]"
    else
      echo "  5) 引擎专属调优     : Maya [内存=${C_GREEN}${EXPERT_RAM_POLICY}${C_RESET} | KV=${C_GREEN}${STRATA_KV_FORMAT}${C_RESET} | 消融=${C_GREEN}${MAYA_ABLATION}/${MAYA_ABLATE_DEFAULT}${C_RESET} | 投机=${MAYA_DRAFTING}]"
    fi
    echo "  6) 修改存储目录路径 : 本地 NVMe=${CUSTOM_MODELS_DIR} | 云盘=${DRIVE_CACHE_DIR}"
    echo "  7) 暴露隧道模式     : ${C_GREEN}${TUNNEL_MODE}${C_RESET} — $(tunnel_desc "$TUNNEL_MODE")"
    echo "  8) Cloudflare 固定域: Token=$(mask_secret "$CF_TUNNEL_TOKEN") | 域名=${CF_PUBLIC_HOSTNAME:-(未填)}"
    echo "  9) HuggingFace Token: $(mask_secret "$HF_TOKEN") (受限/私有仓库必填)"
    echo "  10) API Key 与端口  : Key=$(mask_secret "$MAYA_API_KEY") | 端口=${MAYA_PORT} | 本地绑定=${LOCAL_BIND}"
    echo "  11) 上下文与界面开关: ${MAYA_CONTEXT} tok | 视觉=$( [[ "$NO_VISION" == "0" ]] && echo "开" || echo "关" ) | Web面板=$( [[ "$WEB_UI" == "1" ]] && echo "开" || echo "仅API" )"
    echo "  12) Colab 账号与认证: 账号=${C_GREEN}${ACTIVE_ACCOUNT:-(未登录)}${C_RESET} | 模式=${C_GREEN}${COLAB_AUTH_MODE}${C_RESET} | 启动自动 colab auth=$( [[ "$AUTO_GCP_AUTH" == "1" ]] && echo "开启" || echo "关闭" )"
    echo "  13) 恢复默认设置"
    echo "  0) 返回主菜单"
    echo "${C_CYAN}================================================================================${C_RESET}"
    read -r -p "请输入要修改的编号 [0-13]: " choice

    case "${choice:-0}" in
      1)
        select_model_preset_interactive
        ;;
      2)
        echo ""
        echo "可选 Colab GPU 类型:  1) G4 (RTX PRO 6000 96GB)  2) H100 (80GB)  3) A100 (80GB)  4) L4 (24GB)  5) T4 (16GB, Free 可用)"
        read -r -p "选择编号 [1-5，回车保持 ${GPU_TYPE}]: " g_idx
        case "$g_idx" in
          1) GPU_TYPE="G4" ;;
          2) GPU_TYPE="H100" ;;
          3) GPU_TYPE="A100" ;;
          4) GPU_TYPE="L4" ;;
          5) GPU_TYPE="T4" ;;
        esac
        local hm_default="Y"
        [[ "$GPU_TYPE" == "T4" ]] && hm_default="N"
        if [[ "$GPU_TYPE" == "T4" ]]; then
          read -r -p "是否启用高内存形状 (--high-mem)? (Colab Free 免费号选 N) [y/N]: " hm
        else
          read -r -p "是否启用高内存形状 (--high-mem)? [Y/n]: " hm
        fi
        if [[ "${hm:-$hm_default}" =~ ^[Nn]$ ]]; then HIGH_MEM="0"; else HIGH_MEM="1"; fi
        save_config
        ;;
      3)
        echo ""
        echo "可选运行期存储拓扑 (缺失文件直接下载至目标盘，原地复用、无后台回存):"
        echo "  1) auto         : 智能匹配 (本地盘足够走 local_nvme 免挂云盘；超大外挂表模型选 nvme_engram 扩容)"
        echo "  2) nvme_engram  : 反向跨盘扩容 — 外挂查表并发直落本地 NVMe + 主权重直落 Google Drive 全进内存 (推理零网盘 I/O)"
        echo "  3) drive_engram : 正向跨盘扩容 — 主权重并发直落本地 NVMe + 外挂查表直落 Google Drive 软链读取"
        echo "  4) drive_full   : 全量云盘扩容 — 所有权重与表直接落盘并读取于 Google Drive 目录"
        echo "  5) local_nvme   : 纯本地高速盘 — 不挂载 Google Drive，并发高速直连 Hugging Face (常规模型首选)"
        read -r -p "选择编号 [1-5]: " s_idx
        case "$s_idx" in
          1) STORAGE_MODE="auto" ;;
          2) STORAGE_MODE="nvme_engram" ;;
          3) STORAGE_MODE="drive_engram" ;;
          4) STORAGE_MODE="drive_full" ;;
          5) STORAGE_MODE="local_nvme" ;;
        esac
        save_config
        ;;
      4)
        echo ""
        read -r -p "Hugging Face 本地并发分片下载线程数 (1-16) [当前: ${HF_DOWNLOAD_CONCURRENCY}]: " hfc
        if [[ -n "$hfc" ]]; then
          if [[ "$hfc" =~ ^[0-9]+$ && "$hfc" -ge 1 && "$hfc" -le 16 ]]; then
            HF_DOWNLOAD_CONCURRENCY="$hfc"
          else
            echo "${C_RED}[忽略] 并发线程数需为 1-16。${C_RESET}"
            sleep 1
          fi
        fi
        echo ""
        echo "需要 Google Drive 扩容时，文件直接写入云盘的传输通道:"
        echo "  1) auto       : 智能双通道 (有远端 colab auth 优先走 Drive REST API 0 本地缓存流式直传，否则自动回退 FUSE 直写 + 本地水位背压)"
        echo "  2) api_stream : 强制 Drive REST API v3 流式直传 (0 本地写缓存、HTTP 200 真落盘，启动扩容时自动触发 colab auth)"
        echo "  3) fuse       : 纯 FUSE 直落 (/content/drive 顺序直写 + 本地根盘水位背压与退出刷盘，无需 colab auth)"
        read -r -p "选择云盘直落通道 [1-3，回车保持 ${DRIVE_WRITE_MODE}]: " dw_idx
        case "$dw_idx" in
          1) DRIVE_WRITE_MODE="auto" ;;
          2) DRIVE_WRITE_MODE="api_stream" ;;
          3) DRIVE_WRITE_MODE="fuse" ;;
        esac
        save_config
        ;;
      5)
        configure_engine_tuning_interactive
        ;;
      6)
        echo ""
        read -r -p "本地 NVMe 模型根目录 [当前: ${CUSTOM_MODELS_DIR}]: " v1
        CUSTOM_MODELS_DIR="${v1:-$CUSTOM_MODELS_DIR}"
        read -r -p "Google Drive 云盘扩容根目录 [当前: ${DRIVE_CACHE_DIR}]: " v2
        DRIVE_CACHE_DIR="${v2:-$DRIVE_CACHE_DIR}"
        save_config
        ;;
      7)
        echo ""
        echo "可选隧道暴露方式:"
        echo "  1) cf_quick : Cloudflare 临时公网 HTTPS (*.trycloudflare.com, 零配置)"
        echo "  2) cf_named : Cloudflare Zero Trust 固定域名隧道 (需配置 Token)"
        echo "  3) ssh      : Colab 官方 WebSocket SSH 本地端口转发 (仅本机/局域网)"
        read -r -p "选择编号 [1-3]: " t_idx
        case "$t_idx" in
          1) TUNNEL_MODE="cf_quick" ;;
          2) TUNNEL_MODE="cf_named" ;;
          3) TUNNEL_MODE="ssh" ;;
        esac
        save_config
        ;;
      8)
        echo ""
        read -r -s -p "输入 Cloudflare Tunnel Token (留空保持不变，输入 CLEAR 清空): " cft
        echo ""
        if [[ "$cft" == "CLEAR" ]]; then
          CF_TUNNEL_TOKEN=""
        elif [[ -n "$cft" ]]; then
          CF_TUNNEL_TOKEN="$cft"
        fi
        read -r -p "输入绑定的完整公网域名 (如 https://maya.example.com) [当前: ${CF_PUBLIC_HOSTNAME}]: " cfh
        CF_PUBLIC_HOSTNAME="${cfh:-$CF_PUBLIC_HOSTNAME}"
        save_config
        ;;
      9)
        echo ""
        echo "提示: 下载受限或私有 Hugging Face 仓库前，需先在网页同意条款并配置 Token。"
        read -r -s -p "输入 Hugging Face Token (hf_...，留空保持不变，输入 CLEAR 清空): " hft
        echo ""
        if [[ "$hft" == "CLEAR" ]]; then
          HF_TOKEN=""
        elif [[ -n "$hft" ]]; then
          HF_TOKEN="$hft"
        fi
        save_config
        ;;
      10)
        echo ""
        echo "  1) 自动重新生成随机 API Key"
        echo "  2) 手动输入自定义 API Key"
        echo "  3) 保持当前 API Key 不变"
        read -r -p "选择 [1-3，默认 3]: " k_idx
        case "${k_idx:-3}" in
          1) MAYA_API_KEY="$(generate_api_key)" ;;
          2) read -r -p "输入新 API Key: " nk; [[ -n "$nk" ]] && MAYA_API_KEY="$nk" ;;
        esac
        read -r -p "服务端口 [当前: ${MAYA_PORT}]: " np
        if [[ -n "$np" ]]; then
          if [[ "$np" =~ ^[0-9]+$ && "$np" -ge 1 && "$np" -le 65535 ]]; then
            MAYA_PORT="$np"
          else
            echo "${C_RED}[忽略] 端口 '${np}' 无效（需为 1-65535）。${C_RESET}"
            sleep 1
          fi
        fi
        read -r -p "SSH 模式本地绑定地址 (127.0.0.1 或 0.0.0.0) [当前: ${LOCAL_BIND}]: " nb
        if [[ -n "$nb" ]]; then
          if [[ "$nb" =~ ^[A-Za-z0-9.:_-]+$ ]]; then
            LOCAL_BIND="$nb"
          else
            echo "${C_RED}[忽略] 绑定地址 '${nb}' 含非法字符。${C_RESET}"
            sleep 1
          fi
        fi
        save_config
        ;;
      11)
        echo ""
        echo "可选上下文窗口:  1) 32768 (32K)   2) 65536 (64K, 默认)   3) 131072 (128K)   4) 262144 (256K)"
        read -r -p "选择编号 [1-4，回车保持 ${MAYA_CONTEXT}]: " c_idx
        case "$c_idx" in
          1) MAYA_CONTEXT="32768" ;;
          2) MAYA_CONTEXT="65536" ;;
          3) MAYA_CONTEXT="131072" ;;
          4) MAYA_CONTEXT="262144" ;;
        esac
        read -r -p "Colab 会话名称 [当前: ${SESSION_NAME}]: " nsess
        if [[ -n "$nsess" ]]; then
          if [[ "$nsess" =~ ^[A-Za-z0-9._-]+$ ]]; then
            SESSION_NAME="$nsess"
          else
            echo "${C_RED}[忽略] 会话名称 '${nsess}' 仅允许字母、数字、.、_、-。${C_RESET}"
            sleep 1
          fi
        fi
        read -r -p "是否开启多模态图片输入编码器? [Y/n]: " vis
        if [[ "${vis:-Y}" =~ ^[Nn]$ ]]; then NO_VISION="1"; else NO_VISION="0"; fi
        read -r -p "是否开启浏览器 Web 聊天与监控面板 (选 n 则仅保留纯 API)? [Y/n]: " wui
        if [[ "${wui:-Y}" =~ ^[Nn]$ ]]; then WEB_UI="0"; else WEB_UI="1"; fi
        save_config
        ;;
      12)
        echo ""
        echo "  1) 切换默认认证策略为 oauth2 (Google OAuth 2.0 个人账号)"
        echo "  2) 切换默认认证策略为 adc (gcloud Application Default Credentials)"
        echo "  3) 切换【启动实例时自动执行远端 colab auth】开关 (当前: $( [[ "$AUTO_GCP_AUTH" == "1" ]] && echo "开启" || echo "关闭" ))"
        echo "  4) 打开完整【Colab 多账号切换 / 真登出 / 全局释放 / GCP 授权中心】"
        read -r -p "选择编号 [1-4，默认 4]: " ca_idx
        case "${ca_idx:-4}" in
          1)
            if [[ "$COLAB_AUTH_MODE" != "oauth2" ]]; then
              if guard_release_before_account_change "切换认证策略为 oauth2" "" "prompt"; then
                ACTIVE_ACCOUNT=""
                AUTH_EMAIL=""
                AUTH_NOTE=""
                COLAB_AUTH_MODE="oauth2"
                save_config
                refresh_colab_auth_status "" 0 || true
              fi
            fi
            ;;
          2)
            if [[ "$COLAB_AUTH_MODE" != "adc" ]]; then
              if guard_release_before_account_change "切换认证策略为 adc" "" "prompt"; then
                ACTIVE_ACCOUNT=""
                AUTH_EMAIL=""
                AUTH_NOTE=""
                COLAB_AUTH_MODE="adc"
                save_config
                refresh_colab_auth_status "" 0 || true
              fi
            fi
            ;;
          3)
            if [[ "$AUTO_GCP_AUTH" == "1" ]]; then AUTO_GCP_AUTH="0"; else AUTO_GCP_AUTH="1"; fi
            save_config
            ;;
          4) page_account_auth ;;
        esac
        ;;
      13)
        read -r -p "确认清空并恢复所有默认设置 (已保存的多账号将保留)? [y/N]: " yn
        if [[ "${yn:-N}" =~ ^[Yy]$ ]]; then
          local keep_acct="$ACTIVE_ACCOUNT"
          local keep_mode="$COLAB_AUTH_MODE"
          local keep_adopt="$AUTO_ADOPT_EXTERNAL"
          HF_TOKEN=""
          reset_defaults
          ACTIVE_ACCOUNT="$keep_acct"
          COLAB_AUTH_MODE="$keep_mode"
          AUTO_ADOPT_EXTERNAL="$keep_adopt"
          save_config
          refresh_colab_auth_status "" 0 || true
        fi
        ;;
      0|"")
        break
        ;;
    esac
  done
}

run_interactive_loop() {
  refresh_colab_auth_status "" 0 || true

  while true; do
    clear 2>/dev/null || true
    local status_badge ep phase dio_st eff_eng
    ep="$(resolve_current_endpoint)"
    phase="$(read_telemetry_field phase)"
    dio_st="$(read_telemetry_field drive_io_state)"
    eff_eng="$(resolve_effective_engine "$MODEL_PRESET")"
    if is_bg_running; then
      status_badge="${C_GREEN}● 运行中${C_RESET} (${phase:-正在连接远端...})"
    else
      status_badge="${C_DIM}○ 未启动${C_RESET}"
    fi

    echo "${C_BOLD}${C_CYAN}=========================================================================${C_RESET}"
    echo "${C_BOLD}   colabd v${COLABD_VERSION}  |  Multi-Engine LLM Serving Daemon (Strata + Project Maya)${C_RESET}"
    echo "${C_CYAN}=========================================================================${C_RESET}"
    echo "  运行环境   : $(format_runtime_badge)"
    echo "  Colab 账号 : $(format_auth_badge)"
    echo "  实例状态   : ${status_badge}"
    echo "  引擎与模型 : ${C_CYAN}${eff_eng}${C_RESET} | ${C_BOLD}${MODEL_PRESET}${C_RESET}  |  GPU: ${C_BOLD}${GPU_TYPE}${C_RESET}$( [[ "$HIGH_MEM" == "1" ]] && echo " (High-RAM)" || echo " (Std-RAM)" )"
    if [[ "$eff_eng" == "strata" ]]; then
      echo "  存储与参数 : ${C_BOLD}${STORAGE_MODE}${C_RESET} (HF并发: ${HF_DOWNLOAD_CONCURRENCY}x | 云盘写: ${DRIVE_WRITE_MODE} | KV: ${STRATA_KV_FORMAT} | 并发: ${STRATA_PARALLEL})"
    else
      echo "  存储拓扑   : ${C_BOLD}${STORAGE_MODE}${C_RESET} (HF并发: ${HF_DOWNLOAD_CONCURRENCY}x | 云盘写: ${DRIVE_WRITE_MODE} | KV: ${STRATA_KV_FORMAT} | 内存策略: ${EXPERT_RAM_POLICY})"
    fi
    echo "  暴露隧道   : $(tunnel_desc "$TUNNEL_MODE")"
    if [[ -n "$ep" ]]; then
      echo "  访问入口   : ${C_GREEN}${C_BOLD}${ep}${C_RESET}"
    fi
    echo "${C_CYAN}-------------------------------------------------------------------------${C_RESET}"
    echo "  1) 启动 / 重启 Colab 实例与大模型隧道服务"
    echo "  2) 状态监控页 (硬件/驱动/引擎状态、云盘直落、API 探测、colab usage 余额)"
    echo "  3) 实时查看远端下载、引擎初始化与推理日志 (Ctrl+C 返回菜单)"
    echo "  4) 一键发送流式对话测试请求 (curl /v1/chat/completions)"
    echo "  5) 设置页 (切换引擎与分级模型 / 自定义 HF / 存储拓扑 / 隧道，自动保存)"
    echo "  6) Colab 账号管理与授权中心 (登录去重 / 秒切 / 权限补齐 / 安全移除 / 全局释放)"
    echo "  7) 手动销毁当前 Colab 实例 (保持面板打开以便修改配置重开)"
    echo "  0) 退出面板 (自动执行 colab stop 回收实例与释放算力)"
    echo "${C_CYAN}=========================================================================${C_RESET}"
    read -r -p "请输入选项编号 [0-7]: " main_opt

    case "${main_opt:-}" in
      1) action_start_or_restart ;;
      2) page_status ;;
      3) action_view_logs ;;
      4) action_test_request ;;
      5) page_settings ;;
      6) page_account_auth ;;
      7)
        stop_colab_instance
        read -r -p "按回车返回主菜单..." _
        ;;
      0|q|Q)
        if [[ "$dio_st" == "streaming_api" || "$dio_st" == "writing_fuse" || "$dio_st" == "flushing" ]]; then
          echo ""
          echo "${C_YELLOW}[注意] 远端正在向 Google Drive 直落写入或刷盘 ($(read_telemetry_field drive_io_detail))。${C_RESET}"
          read -r -p "按回车立即中止写入并销毁实例，或输入 c 取消退出等待写入完成: " quit_confirm
          if [[ "${quit_confirm:-}" =~ ^[Cc]$ ]]; then
            continue
          fi
        fi
        local other_sessions=""
        if other_sessions="$(find_other_accounts_with_local_sessions 2>/dev/null)"; then
          echo ""
          echo "${C_YELLOW}[防扣费提醒] 检测到其他已登录账号仍有未释放的本地会话记录: ${other_sessions}${C_RESET}"
          read -r -p "是否在退出前一并扫描释放所有账号的残留实例? [Y/n]: " rel_all_yn
          if [[ ! "${rel_all_yn:-Y}" =~ ^[Nn]$ ]]; then
            release_all_accounts_runtimes "0" || true
          fi
        fi
        echo "${C_CYAN}[退出] 正在关闭 colabd 控制台并执行自动实例回收...${C_RESET}"
        exit 0
        ;;
      *)
        ;;
    esac
  done
}
