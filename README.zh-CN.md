# colabd

[![CI](https://github.com/MisterRabbit0w0/colabd/actions/workflows/ci.yml/badge.svg)](https://github.com/MisterRabbit0w0/colabd/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS-lightgrey.svg)](https://github.com/googlecolab/google-colab-cli)

[English](README.md) | 简体中文

The endgame for frontier LLM serving on Google Colab.

`colabd` 基于官方 [`google-colab-cli`](https://github.com/googlecolab/google-colab-cli) 与 [`mw00/project-maya`](https://github.com/mw00/project-maya)，在本地 Linux 或 macOS 终端将 Google Colab GPU 实例托管为受生命周期绑定的大模型推理服务端。默认适配 [`DeepSeek-V4.1-Flash-1017`](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017) 的去审查版本 [`orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF`](https://huggingface.co/orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF)，支持通过 Cloudflare 或官方 WebSocket SSH 暴露带鉴权的 OpenAI 与 Anthropic 兼容接口，并在退出面板或按下 `Ctrl+C` 时自动执行 `colab stop` 销毁实例。

## 解决的核心工程痛点

在消费级 Google Colab 上部署 300B 至 750B 级别的 MoE 大模型会遇到三个实际瓶颈：

1. **235 GB 本地磁盘容量限制。** Colab Pro+ 的 `G4` 实例配备了 95.6 GB 显存与 176.9 GB 系统内存，总内存池高达 272.5 GB，但 `/content` 本地 NVMe 磁盘可用空间仅约 235.7 GB。而 `abliterated-128g` 需要约 123 GB 主权重与投机解码器，外加 161 GB `Engram-Q6_K` 条件记忆表，合计约 284 GB。全放本地盘会写满报错；若把需要实时随机查表的 Engram 直接挂在 Google Drive 网络盘上读取，冷页高延迟会导致吐字卡顿甚至触发看门狗超时。
2. **后台孤儿实例漏扣费。** 脚本异常退出、终端断开或切换 Google 账号时若未及时销毁会话，`G4` 实例每小时会持续消耗 10.05 个计算单元。
3. **纯 SSH 空闲断连。** 仅通过 SSH 运行进程会让 Jupyter 内核处于空闲态，触发 Colab 回收机制。

`colabd` 的对应机制如下：

- **云盘预查找 + 本地 NVMe 跑 Engram + 专家全内存锁页。** 在推荐的 `nvme_engram` 模式下，脚本启动先检索 Google Drive 是否已有缓存分片，把 161 GB `Engram-Q6_K` 顺序拉取到本地高速 `/content` NVMe SSD，缺失分片自动回退走 Hugging Face 公网下载；同时将 114 GB 主权重软链至云盘并在启动时一次性全量锁入显存与系统内存 (`--mmap-experts off`，见 [`project-maya` 内存文档](https://github.com/mw00/project-maya/blob/main/docs/MEMORY.md))。进入服务态后，专家层计算 100% 走内存，Engram 随机查表 100% 走本地 NVMe 与约 140 GB 系统页缓存，推理期零网盘 I/O。
- **后台原子回存云盘。** 服务通过 `/health` 探测就绪后，后台线程按策略 (`both`、`weights_only`、`engram_only`、`none`) 将本次回退下载的新分片先写为 `.syncing.tmp` 再原子重命名同步回 Google Drive，中断退出绝不留半截脏文件。
- **独立托管的 `uv` 隔离运行环境。** 安装脚本与 `colabd env setup` 会自动在 `~/.local/share/colabd-runtime/venv` 创建独立的 Python 3.12 虚拟环境并安装 `google-colab-cli`（若本机无 `uv`，自动安装至私有目录且不修改 shell 配置）。`colabd` 所有本地 Python 逻辑、`keyring` 多账号令牌管理、`colab` 命令与 SSH `ProxyCommand` 均统一运行在该隔离环境内，不受系统 Python 版本（如 macOS 3.9 / Ubuntu 22.04 3.10）、PEP 668、`conda`/`pyenv` shim 或 `PATH` 变动影响。
- **内核保活与多账号系留回收。** 远端守护程序通过 `colab exec` 在 Jupyter 内核内运行以维持官方保活；本机注册 `EXIT`、`INT`、`TERM`、`HUP` 信号钩子，退出面板自动按实例归属账号调用 `colab stop`。针对官方 `google-colab-cli` 未提供 `logout` 子命令与细粒度授权漏勾权限域的问题，内置基于真实邮箱唯一去重的账号管理（`oauth2` 钥匙串 + 独立 `adc.json` + 隔离 `sessions.json`），支持必需 `Scopes` 校验与 `colabd auth refresh` 原地补齐权限；移除账号或登出时采用严格硬门禁（先探测并释放全部活跃实例且校验成功，失败则中止移除并保留凭证），并支持 `colabd down --all` 一键全局清理。

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

启动交互式控制台：

```bash
colabd
```

1. 按 `6` 进入账号与授权中心，一键完成 Google OAuth 2.0 或 [`gcloud`](https://docs.cloud.google.com/sdk/gcloud/reference/colab) ADC 登录。
2. 按 `5` 进入设置页，在第 `9` 项填入同意过协议的 `HF_TOKEN`，按需调整存储拓扑、云盘回存策略与隧道方式（配置以 `0600` 权限自动保存在 `~/.config/colabd/config.env`）。
3. 按 `1` 启动实例，在菜单 `2`（状态监控页）查看 GPU/内存遥测、云盘回存进度与 `colab usage` 算力余额，在菜单 `3` 查看实时构建日志。
4. 使用完按 `0` 或直接 `Ctrl+C`，面板会自动清理本地隧道并执行 `colab stop` 释放算力。

## 存储拓扑与云盘策略对照

| 存储模式 (`STORAGE_MODE`) | 运行期文件分布 | 适用硬件与云盘条件 |
| :--- | :--- | :--- |
| `nvme_engram` | 161 GB `Engram-Q6_K` 拉取在本地 `/content` NVMe；主权重挂云盘并全载入内存 | Colab Pro+ `G4` (235 GB 本地盘) 搭配 120 GB 至 300 GB 以上 Google Drive |
| `local_nvme` | 主权重与 Engram 均在本地高速盘运行，仍支持从云盘预拉取与回存 | 跑 `glm-maya-m-derisked` (116 GB) 或使用 350 GB 以上数据盘的 Colab Enterprise |
| `drive_engram` | 主权重放本地 NVMe；161 GB Engram 软链在云盘按需读取 | 不希望等待拉取 Engram 且可接受冷页查表延迟的场景 |
| `drive_full` | 全部文件直接在 `/content/drive/MyDrive` 目录读写 | 在 235 GB 本地盘机型上强跑 `abliterated-256g` (总计约 397 GB) |

| 回存策略 (`DRIVE_SAVE_POLICY`) | 公网回退下载后的行为 | 所需云盘空间 (`Mix-128G`) |
| :--- | :--- | :--- |
| `both` | 主权重与 `Engram-Q6_K` 新分片均原子同步回存云盘，下次全免公网下载 | 280 GB 以上 |
| `weights_only` | 仅将 114 GB 主权重存云盘，161 GB Engram 仅在本地临时使用 | 120 GB 以上 (适合 200 GB Google One) |
| `engram_only` | 仅将 161 GB `Engram-Q6_K` 回存云盘 | 165 GB 以上 |
| `none` | 不向云盘写入任何新分片，云盘仅作只读查找源 | 0 GB |

## 命令行子命令

```bash
colabd                         # 启动交互式数字菜单控制台 (默认)
colabd up                      # 直接拉起配置的 Colab 实例并进入控制台保活
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
