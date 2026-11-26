#!/usr/bin/env bash
# ==============================================================================
# colabd - Interactive TUI pages (Main Menu, Status, Logs, Settings, Multi-Account Auth)
# Compatible with Bash 3.2+ (macOS and Linux)
# ==============================================================================

page_account_auth() {
  refresh_colab_auth_status 5 0 || true
  while true; do
    clear 2>/dev/null || true
    local cli_ver="未安装"
    if command -v colab >/dev/null 2>&1; then
      cli_ver="$(colab version 2>/dev/null | head -n 1 || echo "已安装")"
    fi

    echo "${C_BOLD}${C_CYAN}================ Google Colab 多账号切换与 GCP 授权中心 ================${C_RESET}"
    echo "  Colab CLI 版本 : ${cli_ver}"
    echo "  当前激活槽位   : ${C_BOLD}$(format_account_label "$ACTIVE_ACCOUNT" "$COLAB_AUTH_MODE" "$AUTH_EMAIL")${C_RESET}"
    echo "  当前认证模式   : ${C_GREEN}${COLAB_AUTH_MODE}${C_RESET} - $(auth_mode_desc "$COLAB_AUTH_MODE")"
    echo "  当前登录状态   : $(format_auth_badge)"
    [[ -n "$AUTH_DETAIL" ]] && echo "  状态探测摘要   : ${AUTH_DETAIL}"
    echo "  远端 GCP 授权  : 启动实例时自动执行 colab auth = $( [[ "$AUTO_GCP_AUTH" == "1" ]] && echo "${C_GREEN}开启${C_RESET}" || echo "关闭" )"
    echo ""
    echo "  ${C_BOLD}已保存账号槽位${C_RESET} (* 表示当前激活，各槽位拥有独立 sessions.json):"
    print_saved_accounts_table || true
    echo "${C_CYAN}------------------------------------------------------------------------${C_RESET}"
    echo "  1) 刷新检测登录状态、当前邮箱与算力余额 (whoami / sessions / usage)"
    echo "  2) 快速切换已保存的账号槽位 (带活跃实例释放保护 -> 一键秒切)"
    echo "  3) 添加并登录新的 Google 账号槽位 (支持 OAuth 2.0 / gcloud ADC)"
    echo "  4) 将当前已登录账号归档为槽位 / 更新当前槽位备份"
    echo "  5) 删除已保存的账号槽位 (先释放该账号活跃实例再彻底清除)"
    echo "  6) 彻底登出当前账号 (先释放活跃实例 -> 清除系统钥匙串 / ADC 凭证)"
    echo "  7) 扫描并一键释放所有已保存账号的残留 Colab 实例 (全局防扣费清理)"
    echo "  8) 远端 Colab 实例 GCP 服务授权 (colab auth) / 切换自动授权开关"
    echo "  9) 一键安装或升级官方 google-colab-cli"
    echo "  0) 返回上级菜单"
    echo "${C_CYAN}========================================================================${C_RESET}"
    read -r -p "请选择操作编号 [0-9]: " a_opt

    case "${a_opt:-0}" in
      1)
        echo ""
        if refresh_colab_auth_status 6 1; then
          echo "${C_GREEN}[有效] 当前账号已正常登录: $(format_account_label "$ACTIVE_ACCOUNT" "$COLAB_AUTH_MODE" "$AUTH_EMAIL")${C_RESET}"
          echo "${C_DIM}--- colab whoami ---${C_RESET}"
          colab_cli whoami 2>&1 | sed 's/^/  /' || true
          echo "${C_DIM}--- colab sessions ---${C_RESET}"
          colab_cli sessions 2>&1 | sed 's/^/  /' || true
          echo "${C_DIM}--- colab usage ---${C_RESET}"
          colab_cli usage 2>&1 | sed 's/^/  /' || true
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
        do_add_new_account "" "" "prompt" || true
        read -r -p "按回车继续..." _
        ;;
      4)
        do_save_current_account "" || true
        read -r -p "按回车继续..." _
        ;;
      5)
        do_delete_account "" "prompt" || true
        read -r -p "按回车继续..." _
        ;;
      6)
        do_colab_logout "prompt" "1" || true
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
        echo "  3) 直接拉起 Google OAuth 2.0 登录 (不新建槽位)"
        echo "  4) 直接拉起 GCP ADC 登录 (不新建槽位)"
        read -r -p "请选择 [1-4，回车取消]: " g_opt
        case "${g_opt:-}" in
          1) do_remote_gcp_auth ;;
          2)
            if [[ "$AUTO_GCP_AUTH" == "1" ]]; then AUTO_GCP_AUTH="0"; else AUTO_GCP_AUTH="1"; fi
            save_config
            echo "${C_GREEN}[已更新] 启动自动 colab auth = $( [[ "$AUTO_GCP_AUTH" == "1" ]] && echo "开启" || echo "关闭" )${C_RESET}"
            ;;
          3) do_oauth2_login || true ;;
          4) do_adc_login || true ;;
        esac
        read -r -p "按回车继续..." _
        ;;
      9)
        do_install_or_update_cli
        read -r -p "按回车继续..." _
        ;;
      0|"") break ;;
    esac
  done
}

page_status() {
  refresh_colab_auth_status 4 0 || true
  while true; do
    clear 2>/dev/null || true
    local phase gpu ram_gb local_free drive_free models_dir api_ok ep ram_res sync_st sync_msg
    phase="$(read_telemetry_field phase)"
    gpu="$(read_telemetry_field gpu)"
    ram_gb="$(read_telemetry_field ram_gb)"
    local_free="$(read_telemetry_field local_free_gb)"
    drive_free="$(read_telemetry_field drive_free_gb)"
    models_dir="$(read_telemetry_field models_dir)"
    ram_res="$(read_telemetry_field ram_resident_active)"
    sync_st="$(read_telemetry_field cache_sync_state)"
    sync_msg="$(read_telemetry_field cache_sync_detail)"
    api_ok="$(read_telemetry_field api_healthy)"
    ep="$(resolve_current_endpoint)"

    echo "${C_BOLD}${C_CYAN}==================== colabd 状态监控面板 (v${COLABD_VERSION}) ====================${C_RESET}"
    echo "  Colab 账号态 : $(format_auth_badge)"
    if is_bg_running; then
      echo "  守护进程状态 : ${C_GREEN}运行中${C_RESET} (本地 PID: ${EXEC_PID}, 远端会话: ${ACTIVE_SESSION_NAME:-$SESSION_NAME})"
    else
      echo "  守护进程状态 : ${C_YELLOW}未运行${C_RESET} (预设会话: ${SESSION_NAME})"
    fi
    echo "  当前执行阶段 : ${phase:-尚未启动}"
    echo "  远端硬件信息 : GPU=${gpu:-未知} | 系统RAM=${ram_gb:-0} GiB"
    echo "  专家内存常驻 : $( [[ "$ram_res" == "True" || "$ram_res" == "true" ]] && echo "${C_GREEN}已激活 (--mmap-experts off，零专家交换)${C_RESET}" || echo "默认按需映射 (${EXPERT_RAM_POLICY})" )"
    echo "  远端磁盘余量 : 本地 /content 剩余 ${local_free:-未知} GiB | 云盘剩余 ${drive_free:-未挂载} GiB"
    echo "  工作目录拓扑 : ${models_dir:-尚未挂载} (模式: ${STORAGE_MODE})"
    echo "  云盘分片回存 : ${sync_msg:-等待模型就绪后检查} (${sync_st:-idle} | 策略: ${DRIVE_SAVE_POLICY})"
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
      if curl -fsS --max-time 3 -H "Authorization: Bearer ${MAYA_API_KEY}" "${ep}/health" >/dev/null 2>&1; then
        echo "  实时健康探测 : ${C_GREEN}HTTP 200 在线可用 (模型已加载完毕)${C_RESET}"
      elif [[ "$api_ok" == "True" || "$api_ok" == "true" ]]; then
        echo "  实时健康探测 : ${C_YELLOW}远端引擎已就绪，隧道连接建立中...${C_RESET}"
      else
        echo "  实时健康探测 : ${C_YELLOW}正在拉取分片/下载/编译预热中 (可按 l 查看实时进度)${C_RESET}"
      fi
    fi

    echo ""
    echo "${C_BOLD}[Colab 会话状态 & 算力单元消耗 (colab status / colab usage)]${C_RESET}"
    if [[ "$AUTH_STATE" == "ok" ]]; then
      local target="${ACTIVE_SESSION_NAME:-$SESSION_NAME}"
      echo "${C_DIM}--- colab status -s ${target} ($(format_account_label "$ACTIVE_ACCOUNT" "$COLAB_AUTH_MODE" "$AUTH_EMAIL")) ---${C_RESET}"
      colab_cli status -s "$target" 2>&1 | sed 's/^/  /' || echo "  (当前无活跃会话记录)"
      echo "${C_DIM}--- colab usage ---${C_RESET}"
      colab_cli usage 2>&1 | sed 's/^/  /' || echo "  (无法获取算力单元用量)"
    else
      echo "  (账号尚未登录或未安装 CLI，可按 a 进入多账号中心登录)"
    fi
    echo "${C_CYAN}=========================================================================${C_RESET}"
    echo "操作: [r] 刷新  [t] 测试对话  [l] 实时日志  [g] 注入远端 GCP 授权  [a] 多账号中心  [回车/b] 返回"
    read -r -p "请选择: " sub
    case "${sub:-b}" in
      r|R) refresh_colab_auth_status 4 1 || true; continue ;;
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

  local payload
  payload="$(python3 -c 'import json,sys; print(json.dumps({"messages":[{"role":"user","content":sys.argv[1]}],"stream":True}, ensure_ascii=False))' "$prompt_txt")"

  echo "${C_CYAN}[请求] POST ${ep}/v1/chat/completions ...${C_RESET}"
  curl -sS --no-buffer "${ep}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${MAYA_API_KEY}" \
    -d "$payload" || echo "${C_RED}[请求失败，模型可能仍在拉取分片或编译预热中]${C_RESET}"
  echo ""
  echo ""
  read -r -p "按回车继续..." _
}

page_settings() {
  while true; do
    clear 2>/dev/null || true
    echo "${C_BOLD}${C_CYAN}====================== 设置页 (自动持久化至本机 600 配置) ======================${C_RESET}"
    echo "  配置文件路径: ${CONFIG_FILE}"
    echo ""
    echo "  1) 模型档位选择     : ${C_GREEN}${MODEL_PRESET}${C_RESET} — $(model_desc "$MODEL_PRESET")"
    echo "  2) GPU 与内存规格   : ${C_GREEN}${GPU_TYPE}${C_RESET} (高内存 --high-mem: $( [[ "$HIGH_MEM" == "1" ]] && echo "开启" || echo "关闭" ))"
    echo "  3) 运行期存储拓扑   : ${C_GREEN}${STORAGE_MODE}${C_RESET} — $(storage_desc "$STORAGE_MODE")"
    echo "  4) 云盘查找与回存   : 预查拉取=$( [[ "$DRIVE_PREFETCH" == "1" ]] && echo "${C_GREEN}开启${C_RESET}" || echo "关闭" ) | 回存策略=${C_GREEN}${DRIVE_SAVE_POLICY}${C_RESET} ($(save_policy_desc "$DRIVE_SAVE_POLICY"))"
    echo "  5) 专家全内存常驻   : ${C_GREEN}${EXPERT_RAM_POLICY}${C_RESET} — $(ram_policy_desc "$EXPERT_RAM_POLICY")"
    echo "  6) 修改存储目录路径 : 本地 NVMe=${CUSTOM_MODELS_DIR} | 云盘=${DRIVE_CACHE_DIR}"
    echo "  7) 暴露隧道模式     : ${C_GREEN}${TUNNEL_MODE}${C_RESET} — $(tunnel_desc "$TUNNEL_MODE")"
    echo "  8) Cloudflare 固定域: Token=$(mask_secret "$CF_TUNNEL_TOKEN") | 域名=${CF_PUBLIC_HOSTNAME:-(未填)}"
    echo "  9) HuggingFace Token: $(mask_secret "$HF_TOKEN") (orcarouter 去审查版必填)"
    echo "  10) API Key 与端口  : Key=$(mask_secret "$MAYA_API_KEY") | 端口=${MAYA_PORT} | 本地绑定=${LOCAL_BIND}"
    echo "  11) 上下文与界面开关: ${MAYA_CONTEXT} tok | 视觉=$( [[ "$NO_VISION" == "0" ]] && echo "开" || echo "关" ) | Web面板=$( [[ "$WEB_UI" == "1" ]] && echo "开" || echo "仅API" )"
    echo "  12) Colab 账号与认证: 槽位=${C_GREEN}${ACTIVE_ACCOUNT:-(未归档)}${C_RESET} | 模式=${C_GREEN}${COLAB_AUTH_MODE}${C_RESET} | 启动自动 colab auth=$( [[ "$AUTO_GCP_AUTH" == "1" ]] && echo "开启" || echo "关闭" )"
    echo "  13) 恢复默认设置"
    echo "  0) 返回主菜单"
    echo "${C_CYAN}================================================================================${C_RESET}"
    read -r -p "请输入要修改的编号 [0-13]: " choice

    case "${choice:-0}" in
      1)
        echo ""
        echo "可选模型档位:"
        echo "  1) ds4-abliterated-128g : DeepSeek-V4.1-Flash-1017 Uncensored Mix-128G (~114GB + 161GB Engram, 推荐)"
        echo "  2) ds4-abliterated-256g : DeepSeek-V4.1-Flash-1017 Uncensored Mix-256G (~236GB + 161GB Engram, 高精度)"
        echo "  3) glm-maya-m-derisked  : GLM-5.3-Flash 321B 去拒绝权重版 (~116GB, 无 Engram 表, 免 HF Token)"
        echo "  4) glm-maya-xs          : GLM-5.3-Flash 321B 轻量测试档 (~73.4GB)"
        echo "  5) inkling-2-mini       : Inkling 2 Mini 26B 极速验证档 (~18.3GB)"
        read -r -p "选择编号 [1-5]: " m_idx
        case "$m_idx" in
          1) MODEL_PRESET="ds4-abliterated-128g" ;;
          2) MODEL_PRESET="ds4-abliterated-256g" ;;
          3) MODEL_PRESET="glm-maya-m-derisked" ;;
          4) MODEL_PRESET="glm-maya-xs" ;;
          5) MODEL_PRESET="inkling-2-mini" ;;
        esac
        save_config
        ;;
      2)
        echo ""
        echo "可选 Colab GPU 类型:  1) G4 (RTX PRO 6000 96GB)  2) H100 (80GB)  3) A100 (80GB)  4) L4 (24GB)  5) T4 (16GB)"
        read -r -p "选择编号 [1-5，回车保持 ${GPU_TYPE}]: " g_idx
        case "$g_idx" in
          1) GPU_TYPE="G4" ;;
          2) GPU_TYPE="H100" ;;
          3) GPU_TYPE="A100" ;;
          4) GPU_TYPE="L4" ;;
          5) GPU_TYPE="T4" ;;
        esac
        read -r -p "是否启用高内存形状 (--high-mem)? [Y/n]: " hm
        if [[ "${hm:-Y}" =~ ^[Nn]$ ]]; then HIGH_MEM="0"; else HIGH_MEM="1"; fi
        save_config
        ;;
      3)
        echo ""
        echo "可选运行期存储拓扑 (均支持配合第 4 项的云盘预查找与回存):"
        echo "  1) auto         : 智能匹配 (235GB 本地盘跑 DeepSeek 时默认选反向跨盘 nvme_engram)"
        echo "  2) nvme_engram  : 反向跨盘推荐 — Engram 拉取到本地高速 NVMe 跑 + 主权重挂云盘全进内存 (推理零网盘 I/O)"
        echo "  3) drive_engram : 正向跨盘 — 主权重放本地 NVMe + 161GB Engram 软链在云盘上按需查表"
        echo "  4) drive_full   : 全量云盘直连 — 所有权重与表均直接在 Google Drive 目录读写"
        echo "  5) local_nvme   : 纯本地/Enterprise 高速盘 — 所有文件在本地盘运行 (仍可从云盘拉取/回存)"
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
        read -r -p "启动时是否先在 Google Drive 查找已有分片并拉取至本地 NVMe? [Y/n]: " pf
        if [[ "${pf:-Y}" =~ ^[Nn]$ ]]; then DRIVE_PREFETCH="0"; else DRIVE_PREFETCH="1"; fi
        echo ""
        echo "当云盘缺失分片并触发公网回退下载后，是否将新分片持久化回存云盘?"
        echo "  1) both         : 主权重与 161GB Engram 均同步回存云盘 (适合 300GB+ 云盘，下次全免下载)"
        echo "  2) weights_only : 仅将主权重 (~114GB) 存云盘，161GB Engram 仅在本地临时盘用 (适合 200GB 云盘)"
        echo "  3) engram_only  : 仅将 161GB Engram 回存云盘"
        echo "  4) none         : 不向云盘写入任何新下载分片 (云盘仅作只读缓存源或完全不写)"
        read -r -p "选择回存策略 [1-4，回车保持 ${DRIVE_SAVE_POLICY}]: " sp_idx
        case "$sp_idx" in
          1) DRIVE_SAVE_POLICY="both" ;;
          2) DRIVE_SAVE_POLICY="weights_only" ;;
          3) DRIVE_SAVE_POLICY="engram_only" ;;
          4) DRIVE_SAVE_POLICY="none" ;;
        esac
        save_config
        ;;
      5)
        echo ""
        echo "可选 MoE 专家全内存常驻策略:"
        echo "  1) auto       : 智能判断 (当显存+内存充足如 G4 272GB 时自动设置 --mmap-experts off 全载入内存)"
        echo "  2) force_ram  : 强制锁死全内存 (注入 DS4_REQUIRE_ALL_RAM=1 / MAYA_GLM_RAM_RESIDENT=1，严禁落盘)"
        echo "  3) allow_disk : 允许保留文件映射按需读盘 (--mmap-experts on，适合小内存环境)"
        read -r -p "选择编号 [1-3]: " rp_idx
        case "$rp_idx" in
          1) EXPERT_RAM_POLICY="auto" ;;
          2) EXPERT_RAM_POLICY="force_ram" ;;
          3) EXPERT_RAM_POLICY="allow_disk" ;;
        esac
        save_config
        ;;
      6)
        echo ""
        read -r -p "本地 NVMe 或自定义高速盘路径 [当前: ${CUSTOM_MODELS_DIR}]: " v1
        CUSTOM_MODELS_DIR="${v1:-$CUSTOM_MODELS_DIR}"
        read -r -p "Google Drive 分片缓存根路径 [当前: ${DRIVE_CACHE_DIR}]: " v2
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
        echo "提示: 下载 orcarouter 去审查版需先在 Hugging Face 网页同意受限仓库条款。"
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
        MAYA_PORT="${np:-$MAYA_PORT}"
        read -r -p "SSH 模式本地绑定地址 (127.0.0.1 或 0.0.0.0) [当前: ${LOCAL_BIND}]: " nb
        LOCAL_BIND="${nb:-$LOCAL_BIND}"
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
        SESSION_NAME="${nsess:-$SESSION_NAME}"
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
              if guard_release_before_account_change "切换认证策略为 oauth2" "" "prompt" "0"; then
                ACTIVE_ACCOUNT=""
                AUTH_EMAIL=""
                COLAB_AUTH_MODE="oauth2"
                save_config
                refresh_colab_auth_status 4 0 || true
              fi
            fi
            ;;
          2)
            if [[ "$COLAB_AUTH_MODE" != "adc" ]]; then
              if guard_release_before_account_change "切换认证策略为 adc" "" "prompt" "0"; then
                ACTIVE_ACCOUNT=""
                AUTH_EMAIL=""
                COLAB_AUTH_MODE="adc"
                save_config
                refresh_colab_auth_status 4 0 || true
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
        read -r -p "确认清空并恢复所有默认设置 (已保存的多账号槽位将保留)? [y/N]: " yn
        if [[ "${yn:-N}" =~ ^[Yy]$ ]]; then
          local keep_acct="$ACTIVE_ACCOUNT"
          HF_TOKEN=""
          reset_defaults
          ACTIVE_ACCOUNT="$keep_acct"
          save_config
          refresh_colab_auth_status 4 0 || true
        fi
        ;;
      0|"")
        break
        ;;
    esac
  done
}

run_interactive_loop() {
  refresh_colab_auth_status 4 0 || true

  while true; do
    clear 2>/dev/null || true
    local status_badge ep phase sync_st
    ep="$(resolve_current_endpoint)"
    phase="$(read_telemetry_field phase)"
    sync_st="$(read_telemetry_field cache_sync_state)"
    if is_bg_running; then
      status_badge="${C_GREEN}● 运行中${C_RESET} (${phase:-正在连接远端...})"
    else
      status_badge="${C_DIM}○ 未启动${C_RESET}"
    fi

    echo "${C_BOLD}${C_CYAN}=========================================================================${C_RESET}"
    echo "${C_BOLD}   colabd v${COLABD_VERSION}  |  Frontier LLM Serving Daemon on Google Colab${C_RESET}"
    echo "${C_CYAN}=========================================================================${C_RESET}"
    echo "  Colab 账号 : $(format_auth_badge)"
    echo "  实例状态   : ${status_badge}"
    echo "  当前模型   : ${C_BOLD}${MODEL_PRESET}${C_RESET}  |  GPU: ${C_BOLD}${GPU_TYPE}${C_RESET}$( [[ "$HIGH_MEM" == "1" ]] && echo " (High-RAM)" )"
    echo "  存储拓扑   : ${C_BOLD}${STORAGE_MODE}${C_RESET} (预查云盘: $( [[ "$DRIVE_PREFETCH" == "1" ]] && echo "开" || echo "关" ) | 回存云盘: ${DRIVE_SAVE_POLICY} | 内存策略: ${EXPERT_RAM_POLICY})"
    echo "  暴露隧道   : $(tunnel_desc "$TUNNEL_MODE")"
    if [[ -n "$ep" ]]; then
      echo "  访问入口   : ${C_GREEN}${C_BOLD}${ep}${C_RESET}"
    fi
    echo "${C_CYAN}-------------------------------------------------------------------------${C_RESET}"
    echo "  1) 启动 / 重启 Colab 实例与大模型隧道服务"
    echo "  2) 状态监控页 (硬件/内存驻留/云盘同步状态、API 探测、colab usage 余额)"
    echo "  3) 实时查看远端分片拉取、编译与推理日志 (Ctrl+C 返回菜单)"
    echo "  4) 一键发送流式对话测试请求 (curl /v1/chat/completions)"
    echo "  5) 设置页 (切换模型 / 存储拓扑 / 云盘查找与回存策略 / 隧道，自动保存)"
    echo "  6) Colab 多账号切换与授权中心 (一键秒切 / 增删槽位 / 真登出 / 全局释放)"
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
        if [[ "$sync_st" == "syncing" ]]; then
          echo ""
          echo "${C_YELLOW}[注意] 后台正在将新下载的分片回存至 Google Drive ($(read_telemetry_field cache_sync_detail))。${C_RESET}"
          read -r -p "按回车立即中止同步并销毁实例，或输入 c 取消退出等待同步完成: " quit_confirm
          if [[ "${quit_confirm:-}" =~ ^[Cc]$ ]]; then
            continue
          fi
        fi
        local other_sessions=""
        if other_sessions="$(find_other_accounts_with_local_sessions 2>/dev/null)"; then
          echo ""
          echo "${C_YELLOW}[防扣费提醒] 检测到其他已保存账号槽位仍有未释放的本地会话记录: ${other_sessions}${C_RESET}"
          read -r -p "是否在退出前一并扫描释放所有已保存账号的残留实例? [Y/n]: " rel_all_yn
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
