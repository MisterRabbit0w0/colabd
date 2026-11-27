# colabd

[![CI](https://github.com/MisterRabbit0w0/colabd/actions/workflows/ci.yml/badge.svg)](https://github.com/MisterRabbit0w0/colabd/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS-lightgrey.svg)](https://github.com/googlecolab/google-colab-cli)

[English](README.md) | 简体中文

The endgame for multi-engine LLM serving on Google Colab.

`colabd` 基于官方 [`google-colab-cli`](https://github.com/googlecolab/google-colab-cli)，统一整合 **[`Niko1221/Strata`](https://github.com/Niko1221/Strata)** 与 **[`mw00/project-maya`](https://github.com/mw00/project-maya)** 双推理引擎，在本地 Linux 或 macOS 终端将 Google Colab GPU 实例（覆盖 **Free 免费号 T4 16GB** 到 **Pro / Pro+ L4、A100、G4、H100**）托管为受生命周期绑定的大模型推理服务端。支持内置分级预设（`colabd models`）与任意自定义 Hugging Face 仓库，通过 Cloudflare 或官方 WebSocket SSH 暴露带鉴权的 OpenAI 与 Anthropic 兼容接口，并在退出面板或按下 `Ctrl+C` 时自动执行 `colab stop` 销毁实例。

## 解决的核心工程痛点

在 Google Colab 上部署开源大模型通常会遇到三个实际瓶颈：

1. **本地磁盘容量与网盘 I/O 矛盾。** 超大模型的分片权重与外挂查表容易超出 Colab `/content` 本地 NVMe 容量；若把需要实时随机查表的权重直接挂在 Google Drive 网络盘上读取，冷页高延迟会导致吐字卡顿甚至触发限流。
2. **后台孤儿实例漏扣费。** 脚本异常退出、终端断开或切换 Google 账号时若未及时销毁会话，远端 GPU 实例会持续消耗计算单元。
3. **纯 SSH 空闲断连与硬件规格差异。** 仅通过 SSH 运行进程会让 Jupyter 内核处于空闲态触发回收；同时在 Free 标准内存与 Pro/Pro+ 高内存多卡规格间切换时，驱动版本、引擎二进制与启动参数容易冲突。

`colabd` 的对应机制如下：

- **双引擎自适应调度与硬件分级预设。** 统一支持 **Strata**（驱动满足要求走官方预编译秒装，旧驱动自动回退源码编译）与 **Project Maya**（三层 VRAM/RAM/NVMe MoE 引擎与拒绝消融开关），并支持自定义 Hugging Face `.strata` / `.gguf` / Safetensors 仓库。切换预设时自动匹配推荐 GPU、`--high-mem`（Free `T4` 自动关闭并在误开时降级重试）、上下文长度与存储模式。
- **按拓扑直落目标盘与并发高速下载。** 本地 `/content` NVMe 装得下的常规模型默认走 `local_nvme`（**完全不挂载 Google Drive**），通过多线程 HTTP Range 并发下载并开启 `HF_HUB_ENABLE_HF_TRANSFER=1` / `HF_XET_HIGH_PERFORMANCE=1` 拉满机房带宽；超容大模型彻底废弃“先下本地再事后拷贝回存”，改为**缺失分片直接下载到 Google Drive 扩容目录**（已有文件原地复用）——远端具备 `colab auth` 凭证时优先走 **Google Drive REST API v3 流式直传（0 本地写缓存、HTTP 200 真落盘）**，否则自动回退 FUSE 顺序直写并启用本地根盘水位背压与退出前刷盘保护，内存池充足时专家层全量常驻显存+内存（`--mmap-experts off`）。
- **独立托管的 `uv` 隔离运行环境。** 安装脚本与 `colabd env setup` 会自动在 `~/.local/share/colabd-runtime/venv` 创建独立的 Python 3.12 虚拟环境并安装 `google-colab-cli`（若本机无 `uv`，自动安装至私有目录且不修改 shell 配置）。`colabd` 所有本地 Python 逻辑、`keyring` 多账号令牌管理、`colab` 命令与 SSH `ProxyCommand` 均统一运行在该隔离环境内，不受系统 Python 版本（如 macOS 3.9 / Ubuntu 22.04 3.10）、PEP 668、`conda`/`pyenv` shim 或 `PATH` 变动影响。
- **内核保活与多账号系留回收。** 远端守护程序通过 `colab exec` 在 Jupyter 内核内运行以维持官方保活；本机注册 `EXIT`、`INT`、`TERM`、`HUP` 信号钩子，退出面板自动按实例归属账号调用 `colab stop`。内置基于真实邮箱唯一去重的账号管理（`oauth2` 钥匙串 + 独立 `adc.json` + 隔离 `sessions.json`），支持必需 `Scopes` 校验与 `colabd auth refresh` 原地补齐权限；移除账号或登出时采用严格硬门禁（先探测并释放全部活跃实例且校验成功，失败则中止移除并保留凭证），并支持 `colabd down --all` 一键全局清理。

## 支持的双引擎与硬件分级

运行 `colabd models` 查看完整内置预设目录，或在设置页配置自定义 Hugging Face 仓库：

| 硬件层级 | 支持引擎 | 特性说明 |
| :--- | :--- | :--- |
| **Free / 入门卡 (`T4 16GB`, 标准内存)** | `strata`、`maya` | 支持官方预编译极速启动与旧驱动自动源码回退，自动关闭 `--high-mem` 并在误开时降级重试，本地盘直跑无需强制挂载云盘 |
| **中端卡 (`L4 24GB` / High-RAM)** | `strata`、`maya` | 支持更高精度量化、多模态视觉输入、投机解码与多路并发槽位 |
| **旗舰卡 (`A100` / `G4` / `H100`)** | `maya`、`strata` | 支持超大 MoE 三层内存管理、专家全内存常驻与反向跨盘缓存拓扑 |
| **自定义 HF 仓库 / 量化** | `strata`、`maya` | 自由指定任意 Hugging Face `.strata` / `.gguf` / Safetensors 仓库或上游引擎量化参数，支持多线程 NVMe 直下与云盘直落扩容 |

## 快速上手

克隆并安装到 `~/.local/bin/colabd`：

```bash
git clone https://github.com/MisterRabbit0w0/colabd.git
cd colabd
make install
```

或使用一键安装命令：

```bash
curl -fsSL https://raw.githubusercontent.com/MisterRabbit0w0/colabd/main/scripts/install.sh | bash
```

通过命令行一键选型并启动：

```bash
colabd auth login              # 登录 Google Colab (OAuth 2.0 或 ADC)
colabd models                  # 按硬件层级浏览全部内置预设
colabd use <preset-id>         # 切换预设并自动匹配推荐 GPU / 内存规格
colabd up                      # 申请实例、启动引擎并建立隧道
```

或直接启动交互式控制台：

```bash
colabd
```

1. 按 `6` 进入账号与授权中心，一键完成 Google OAuth 2.0 或 [`gcloud`](https://docs.cloud.google.com/sdk/gcloud/reference/colab) ADC 登录。
2. 按 `5` 进入设置页，选择引擎与模型预设（或配置自定义 HF 仓库），如需访问受限/私有仓库可在第 `9` 项填入 `HF_TOKEN`，按需调整存储拓扑、HF 并发下载线程、云盘直落通道与隧道方式（配置以 `0600` 权限自动保存在 `~/.config/colabd/config.env`）。
3. 按 `1` 启动实例，在菜单 `2`（状态监控页）查看 GPU/驱动/内存遥测、云盘直落通道状态与 `colab usage` 算力余额，在菜单 `3` 查看实时运行日志。
4. 使用完按 `0` 或直接 `Ctrl+C`，面板会自动清理本地隧道并执行 `colab stop` 释放算力。

## 存储拓扑与云盘直落扩容对照

| 存储模式 (`STORAGE_MODE`) | 运行期文件分布 | 适用场景 |
| :--- | :--- | :--- |
| `auto` | 本地盘足够时自动选 `local_nvme`（免挂载云盘），超容外挂表模型自动选 `nvme_engram` 扩容 | 通用默认推荐（适配 Free 与 Pro+） |
| `local_nvme` | 全部文件多线程直落本地 `/content` NVMe，**不挂载 Google Drive** | 总大小小于当前实例本地磁盘余量的模型 |
| `nvme_engram` | 外挂查表直落本地 `/content` NVMe；主权重直落 Google Drive（原地复用）并全载入内存 | 外挂查表与主权重总大小超出本地盘空间的超大模型 |
| `drive_engram` | 主权重直落本地 NVMe；外挂查表直落 Google Drive 软链读取 | 需保留本地空间给主权重且可接受冷页查表延迟的场景 |
| `drive_full` | 全部文件直接落盘并读取于 `/content/drive/MyDrive` 目录 | 本地盘余量极小或需全量直落云盘扩容的场景 |

| 云盘直落通道 (`DRIVE_WRITE_MODE`) | 需要云盘扩容时的直落写入方式 |
| :--- | :--- |
| `auto` | 智能双通道：远端有 `colab auth` 凭证时优先走 **Drive REST API v3 流式直传（0 本地写缓存、HTTP 200 真落盘）**；否则自动回退 FUSE 顺序直写 + 本地根盘水位背压与退出前刷盘 |
| `api_stream` | 强制走 Drive REST API v3 零本地缓存流式直传（启动扩容时自动触发 `colab auth`） |
| `fuse` | 纯 FUSE 顺序直写 `/content/drive` + 本地根盘水位背压暂停与退出前刷盘（无需 `colab auth`） |

## 命令行子命令

```bash
colabd                         # 启动交互式数字菜单控制台 (默认)
colabd up [--model ID] [--engine strata|maya] [--gpu T4|L4|A100|G4|H100] [--standard-mem|--high-mem] [--kv PRECISION]
                               # 直接拉起配置的 Colab 实例并进入控制台保活 (支持命令行快速覆盖)
colabd models [--tier free|mid|flagship|custom] [--engine strata|maya]
                               # 按硬件层级查看全部内置模型与引擎预设
colabd use <preset-id> [--engine strata|maya] [--kv PRECISION] [--keep-hw]
                               # 一键切换模型预设并自动匹配推荐 GPU / High-RAM 规格
colabd auth                    # 打开账号管理、权限域校验与远端 GCP 授权中心
colabd auth list               # 按唯一账号 ID (邮箱) 查看已登录账号、权限状态与活跃实例
colabd auth login              # 登录新账号 (自动按邮箱去重 + 校验必需 Scopes，支持 --oauth2 / --adc)
colabd auth refresh [id]       # 原地重新授权并补齐缺失权限域 (保留 sessions.json 与备注)
colabd auth use <id>           # 释放当前账号活跃实例后一键秒切目标账号 (简写: colabd switch <id>)
colabd auth note <id> <text>   # 编辑账号纯展示备注 (不改变唯一 ID)
colabd auth remove <id>        # 失败关闭门禁释放活跃实例并核验后移除账号 (可选 --revoke / --force)
colabd auth logout             # 安全释放并移除当前激活账号 (可选 --revoke / --force)
colabd settings                # 打开本地持久化设置页
colabd down                    # 立即销毁当前激活账号的活跃实例
colabd down -a <id>            # 销毁指定账号的活跃实例
colabd down --all              # 扫描并释放所有账号的残留 Colab 实例
colabd env [status|setup|upgrade|reset]
                               # 查看、初始化、升级或重建独立 uv Python 3.12 隔离环境
colabd doctor                  # 等同于 colabd env status，诊断本地运行环境与依赖
colabd version                 # 查看版本号
```

## 本地校验与测试

```bash
make lint
make test
```

## 开源许可

本项目基于 [MIT License](LICENSE) 发布。
