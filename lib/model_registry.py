#!/usr/bin/env python3
"""
colabd model & engine registry (single source of truth for bash CLI/TUI & remote supervisor).
Pure Python standard library (Python 3.9+ compatible).
"""

from __future__ import annotations

import json
import os
import re
import sys
from typing import Any, Dict, List, Optional

FIELD_SEP = "\x1f"

ENGINES: Dict[str, Dict[str, Any]] = {
    "strata": {
        "id": "strata",
        "name": "Strata",
        "repo": "https://github.com/Niko1221/Strata",
        "desc": "Niko1221/Strata — 预编译 CUDA 极速启动（驱动低时自动源码回退），适配 Free T4 Inkling-2-Mini / Qwen3.8 / Qwen3.6 / Hy4-Flash",
        "min_prebuilt_driver": [575, 51],
    },
    "maya": {
        "id": "maya",
        "name": "Project Maya",
        "repo": "https://github.com/mw00/project-maya",
        "desc": "mw00/project-maya — 300B–750B 旗舰 MoE 三层内存引擎，支持 DeepSeek-V4.1 / GLM-5.3 / MiniMax-M3.1 / Hy4-Flash / Inkling-2-Mini",
    },
}

TIERS: List[Dict[str, str]] = [
    {
        "id": "free",
        "title": "Free / 入门卡推荐 (T4 16GB, 标准内存)",
        "short": "Free T4",
    },
    {
        "id": "mid",
        "title": "中端卡推荐 (L4 24GB / A100 40GB / High-RAM)",
        "short": "中端 L4",
    },
    {
        "id": "flagship",
        "title": "旗舰卡推荐 (A100 80GB / G4 96GB / H100 80GB)",
        "short": "旗舰 G4/A100",
    },
    {
        "id": "custom",
        "title": "自定义 Hugging Face 仓库 / 量化模型",
        "short": "自定义",
    },
]

ALIASES: Dict[str, str] = {
    "inkling-2-mini": "maya-inkling-2-mini",
}

PRESETS: List[Dict[str, Any]] = [
    # ------------------------------------------------------------------
    # Tier 1: Free / Entry (T4 16GB, Standard RAM)
    # ------------------------------------------------------------------
    {
        "id": "strata-inkling-uncensored-sq10",
        "engine": "strata",
        "tier": "free",
        "title": "Inkling-2-Mini Uncensored · SQ-10",
        "desc": "SC117 去审查原生 .strata SQ-10 (~9.75 GiB, Free T4 16GB 全显存直装首选, 含 DSpark 与 BF16 视觉)",
        "recommended_gpu": "T4",
        "recommended_high_mem": False,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 13,
        "mem_gb": 12,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "Inkling-2-Mini-Abliterated-Strata",
        "strata": {
            "family": "inkling-2-mini",
            "model": "SQ-10",
            "source": "hf_files",
            "hf_repo": "SC117/Inkling-2-Mini-abliterated-Strata",
            "model_file": "Inkling-2-Mini-SQ-10-abliterated.strata",
            "extra_files": [
                "Inkling-2-Mini-Vision.strata",
                "tokenizer.json",
                "chat_template.jinja",
            ],
            "vision_file": "Inkling-2-Mini-Vision.strata",
        },
    },
    {
        "id": "strata-inkling-uncensored-sq15",
        "engine": "strata",
        "tier": "free",
        "title": "Inkling-2-Mini Uncensored · SQ-15",
        "desc": "SC117 去审查原生 .strata SQ-15 (~13.36 GiB, 高精度档, 适配 T4 16GB / L4 24GB)",
        "recommended_gpu": "T4",
        "recommended_high_mem": False,
        "recommended_context": 32768,
        "recommended_storage": "local_nvme",
        "disk_gb": 17,
        "mem_gb": 16,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "Inkling-2-Mini-Abliterated-Strata",
        "strata": {
            "family": "inkling-2-mini",
            "model": "SQ-15",
            "source": "hf_files",
            "hf_repo": "SC117/Inkling-2-Mini-abliterated-Strata",
            "model_file": "Inkling-2-Mini-SQ-15-abliterated.strata",
            "extra_files": [
                "Inkling-2-Mini-Vision.strata",
                "tokenizer.json",
                "chat_template.jinja",
            ],
            "vision_file": "Inkling-2-Mini-Vision.strata",
        },
    },
    {
        "id": "strata-inkling-uncensored-gguf",
        "engine": "strata",
        "tier": "free",
        "title": "Inkling-2-Mini Uncensored · AD-IQ3_S GGUF",
        "desc": "AtomicChat 去审查 GGUF AD-IQ3_S (~13.34 GB, Strata 引擎自动配 Vision 与 DSpark)",
        "recommended_gpu": "T4",
        "recommended_high_mem": False,
        "recommended_context": 32768,
        "recommended_storage": "local_nvme",
        "disk_gb": 17,
        "mem_gb": 16,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "Inkling-2-Mini-Uncensored-GGUF",
        "strata": {
            "family": "inkling-2-mini",
            "model": "UD-Q3_K_XL",
            "source": "hf_files",
            "hf_repo": "AtomicChat/Inkling-2-Mini-Uncensored-GGUF",
            "model_file": "Inkling-2-Mini-Uncensored-AD-IQ3_S.gguf",
            "extra_files": [],
        },
    },
    {
        "id": "strata-inkling-sq10",
        "engine": "strata",
        "tier": "free",
        "title": "Inkling-2-Mini 官方 · SQ-10",
        "desc": "Strata 官方目录原版 SQ-10 (~10.5 GB, Free T4 16GB 全卡极速运行)",
        "recommended_gpu": "T4",
        "recommended_high_mem": False,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 13,
        "mem_gb": 12,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "strata-data/models/inkling-2-mini",
        "strata": {
            "family": "inkling-2-mini",
            "model": "SQ-10",
            "source": "catalog",
        },
    },
    {
        "id": "strata-inkling-sq15",
        "engine": "strata",
        "tier": "free",
        "title": "Inkling-2-Mini 官方 · SQ-15",
        "desc": "Strata 官方目录原版 SQ-15 (~14.3 GB, 旗舰质量档, 适合 T4 混合 / L4 全卡)",
        "recommended_gpu": "T4",
        "recommended_high_mem": False,
        "recommended_context": 32768,
        "recommended_storage": "local_nvme",
        "disk_gb": 18,
        "mem_gb": 16,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "strata-data/models/inkling-2-mini",
        "strata": {
            "family": "inkling-2-mini",
            "model": "SQ-15",
            "source": "catalog",
        },
    },
    {
        "id": "maya-inkling-2-mini",
        "engine": "maya",
        "tier": "free",
        "title": "Inkling-2-Mini 26B (Project Maya)",
        "desc": "Project Maya 版 Unsloth UD-Q4_K_XL (~18.3 GB, 内置拒绝消融向量 --ablation on)",
        "recommended_gpu": "T4",
        "recommended_high_mem": False,
        "recommended_context": 32768,
        "recommended_storage": "local_nvme",
        "disk_gb": 22,
        "mem_gb": 24,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "Inkling-2-Mini",
        "maya": {
            "model_arg": "inkling-2-mini",
            "family": "ik2",
        },
    },
    # ------------------------------------------------------------------
    # Tier 2: Mid-range (L4 24GB / A100 40GB / High-RAM)
    # ------------------------------------------------------------------
    {
        "id": "strata-inkling-uncensored-sq20",
        "engine": "strata",
        "tier": "mid",
        "title": "Inkling-2-Mini Uncensored · SQ-20 无损",
        "desc": "SC117 去审查无损 BF16 SQ-20 (~18.02 GiB, L4 24GB 全卡满速)",
        "recommended_gpu": "L4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 22,
        "mem_gb": 22,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "Inkling-2-Mini-Abliterated-Strata",
        "strata": {
            "family": "inkling-2-mini",
            "model": "SQ-20",
            "source": "hf_files",
            "hf_repo": "SC117/Inkling-2-Mini-abliterated-Strata",
            "model_file": "Inkling-2-Mini-SQ-20-abliterated.strata",
            "extra_files": [
                "Inkling-2-Mini-Vision.strata",
                "tokenizer.json",
                "chat_template.jinja",
            ],
            "vision_file": "Inkling-2-Mini-Vision.strata",
        },
    },
    {
        "id": "strata-qwen36-q4",
        "engine": "strata",
        "tier": "mid",
        "title": "Qwen3.6-35B-A3B · UD-Q4_K_XL",
        "desc": "Qwen3.6-35B-A3B Unsloth 4-bit MoE (~22.9 GB, 支持图片与多路并发, 推荐 L4 24GB)",
        "recommended_gpu": "L4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 28,
        "mem_gb": 32,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "strata-data/models/qwen36",
        "strata": {
            "family": "qwen36",
            "model": "UD-Q4_K_XL",
            "source": "catalog",
        },
    },
    {
        "id": "strata-qwen38-coder",
        "engine": "strata",
        "tier": "mid",
        "title": "Qwen3.8-Flash-Next Coder · IQ1_M",
        "desc": "ISTA-DASLab 代码专精版 (~66 GB 含查表, SWE-bench 91% 保留, 需 High-RAM)",
        "recommended_gpu": "L4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 70,
        "mem_gb": 36,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "strata-data/models/coder",
        "strata": {
            "family": "coder",
            "model": "IQ1_M",
            "source": "catalog",
        },
    },
    {
        "id": "strata-qwen38-gyro-s",
        "engine": "strata",
        "tier": "mid",
        "title": "Qwen3.8-Flash-Next · Gyro-S",
        "desc": "agentionai Gyro-S 最小内存通用版 (~58.5 GB 含查表, 约 30 GB RAM+VRAM)",
        "recommended_gpu": "L4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 66,
        "mem_gb": 32,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "strata-data/models/gyro",
        "strata": {
            "family": "gyro",
            "model": "Gyro-S",
            "source": "catalog",
        },
    },
    {
        "id": "strata-qwen38-q2",
        "engine": "strata",
        "tier": "mid",
        "title": "Qwen3.8-Flash-Next · ISTA Q2_0",
        "desc": "ISTA-DASLab Q2_0 极速通用版 (~74 GB 含查表与 MTP, 适合 L4 High-RAM / A100)",
        "recommended_gpu": "L4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 80,
        "mem_gb": 48,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "strata-data/models/qwen",
        "strata": {
            "family": "qwen",
            "model": "Q2_0",
            "source": "catalog",
        },
    },
    {
        "id": "glm-maya-xs",
        "engine": "maya",
        "tier": "mid",
        "title": "GLM-5.3-Flash 321B · Maya-XS",
        "desc": "GLM-5.3-Flash 321B Maya-XS 轻量测试档 (~73.4 GB, 无 Engram 外挂表)",
        "recommended_gpu": "L4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 78,
        "mem_gb": 84,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "Maya-XS",
        "maya": {
            "model_arg": "glm-maya-xs",
            "family": "glm",
        },
    },
    {
        "id": "glm-maya-s24",
        "engine": "maya",
        "tier": "mid",
        "title": "GLM-5.3-Flash 321B · Maya-S24",
        "desc": "GLM-5.3-Flash 321B Maya-S24 (~94.7 GB, 专为 24GB 显存 L4 优化 4-bit Attention)",
        "recommended_gpu": "L4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 102,
        "mem_gb": 108,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "Maya-S24",
        "maya": {
            "model_arg": "glm-maya-s24",
            "family": "glm",
        },
    },
    {
        "id": "hy4-flash-maya-xs",
        "engine": "maya",
        "tier": "mid",
        "title": "Tencent Hy4-Flash 220B · Maya-XS",
        "desc": "腾讯 Hy4-Flash 220B Maya-XS (~44.8 GB 权重 + 63.4 GB SSD Engram, ~64 GB 内存池)",
        "recommended_gpu": "L4",
        "recommended_high_mem": True,
        "recommended_context": 32768,
        "recommended_storage": "local_nvme",
        "disk_gb": 116,
        "mem_gb": 64,
        "has_engram": False,
        "engram_gb": 63,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "Hy4-Flash-Maya-XS",
        "maya": {
            "model_arg": "hy4-flash-maya-xs",
            "family": "hy4",
        },
    },
    # ------------------------------------------------------------------
    # Tier 3: Flagship (A100 80GB / G4 96GB / H100 80GB)
    # ------------------------------------------------------------------
    {
        "id": "ds4-abliterated-128g",
        "engine": "maya",
        "tier": "flagship",
        "title": "DeepSeek-V4.1-Flash Uncensored · Mix-128G",
        "desc": "DeepSeek-V4.1-Flash-1017 Uncensored Mix-128G (~114 GB 权重 + 161 GB Engram, 需 HF Token)",
        "recommended_gpu": "G4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "auto",
        "disk_gb": 285,
        "mem_gb": 128,
        "has_engram": True,
        "engram_gb": 161,
        "requires_hf_token": True,
        "hf_gated_url": "https://huggingface.co/orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF",
        "cache_subdir": "DeepSeek-V4.1-Flash-1017-abliterated-GGUF/Mix-128G",
        "maya": {
            "model_arg": "DeepSeek-V4.1-Flash-1017",
            "ds4_quant": "abliterated-128g",
            "family": "ds4",
            "drive_direct_hf": {
                "hf_repo": "orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF",
                "hf_subdir": "Mix-128G",
            },
        },
    },
    {
        "id": "ds4-abliterated-256g",
        "engine": "maya",
        "tier": "flagship",
        "title": "DeepSeek-V4.1-Flash Uncensored · Mix-256G",
        "desc": "DeepSeek-V4.1-Flash-1017 Uncensored Mix-256G (~236 GB 权重 + 161 GB Engram, 高精度需 HF Token)",
        "recommended_gpu": "G4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "auto",
        "disk_gb": 405,
        "mem_gb": 256,
        "has_engram": True,
        "engram_gb": 161,
        "requires_hf_token": True,
        "hf_gated_url": "https://huggingface.co/orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF",
        "cache_subdir": "DeepSeek-V4.1-Flash-1017-abliterated-GGUF/Mix-256G",
        "maya": {
            "model_arg": "DeepSeek-V4.1-Flash-1017",
            "ds4_quant": "abliterated-256g",
            "family": "ds4",
            "drive_direct_hf": {
                "hf_repo": "orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF",
                "hf_subdir": "Mix-256G",
            },
        },
    },
    {
        "id": "deepseek-maya-xs",
        "engine": "maya",
        "tier": "flagship",
        "title": "DeepSeek-V4.1-Flash 748B · Maya-XS",
        "desc": "DeepSeek-V4.1-Flash-1017 Maya-XS (~116 GB 权重 + 161 GB Engram, 免 HF Token, 自带 2-bit 投机器)",
        "recommended_gpu": "G4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "auto",
        "disk_gb": 280,
        "mem_gb": 128,
        "has_engram": True,
        "engram_gb": 161,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "DeepSeek-V4.1-Flash-1017-Maya-XS",
        "maya": {
            "model_arg": "deepseek-maya-xs",
            "family": "ds4",
        },
    },
    {
        "id": "deepseek-maya-s",
        "engine": "maya",
        "tier": "flagship",
        "title": "DeepSeek-V4.1-Flash 748B · Maya-S",
        "desc": "DeepSeek-V4.1-Flash-1017 Maya-S (~179 GB 权重 + 161 GB Engram, 免 HF Token, 92.6% 首字一致)",
        "recommended_gpu": "G4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "auto",
        "disk_gb": 345,
        "mem_gb": 192,
        "has_engram": True,
        "engram_gb": 161,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "DeepSeek-V4.1-Flash-1017-Maya-S",
        "maya": {
            "model_arg": "deepseek-maya-s",
            "family": "ds4",
        },
    },
    {
        "id": "glm-5.3-maya-xs",
        "engine": "maya",
        "tier": "flagship",
        "title": "GLM-5.3 744B · Maya-XS",
        "desc": "GLM-5.3 744B 满血旗舰 Maya-XS (~170 GB, G4 272GB 内存池全内存常驻, 免 HF Token)",
        "recommended_gpu": "G4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 178,
        "mem_gb": 192,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "GLM-5.3-Maya-XS",
        "maya": {
            "model_arg": "glm-5.3-maya-xs",
            "family": "glm",
        },
    },
    {
        "id": "glm-maya-m-derisked",
        "engine": "maya",
        "tier": "flagship",
        "title": "GLM-5.3-Flash 321B · Maya-M-Derisked",
        "desc": "GLM-5.3-Flash 321B 去拒绝权重版 (~116 GB, 无 Engram 外挂表, 免 HF Token)",
        "recommended_gpu": "G4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 122,
        "mem_gb": 140,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "Maya-M-Derisked",
        "maya": {
            "model_arg": "glm-maya-m-derisked",
            "family": "glm",
        },
    },
    {
        "id": "glm-maya-l",
        "engine": "maya",
        "tier": "flagship",
        "title": "GLM-5.3-Flash 321B · Maya-L",
        "desc": "GLM-5.3-Flash 321B Maya-L (~156.3 GB, 99.2% FP8 零样本精度)",
        "recommended_gpu": "G4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 164,
        "mem_gb": 176,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "Maya-L",
        "maya": {
            "model_arg": "glm-maya-l",
            "family": "glm",
        },
    },
    {
        "id": "minimax-maya-xs",
        "engine": "maya",
        "tier": "flagship",
        "title": "MiniMax-M3.1-Flash 428B · Maya-XS",
        "desc": "MiniMax-M3.1-Flash 428B Maya-XS (~93 GB, 多模态 + DSpark 投机解码, 1M 上下文)",
        "recommended_gpu": "G4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 100,
        "mem_gb": 112,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "MiniMax-M3.1-Flash-Maya-XS",
        "maya": {
            "model_arg": "minimax-maya-xs",
            "family": "mm3",
        },
    },
    {
        "id": "minimax-maya-s",
        "engine": "maya",
        "tier": "flagship",
        "title": "MiniMax-M3.1-Flash 428B · Maya-S",
        "desc": "MiniMax-M3.1-Flash 428B Maya-S (~122 GB, 更高精度 ~2.1 bit 专家)",
        "recommended_gpu": "G4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 130,
        "mem_gb": 144,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "MiniMax-M3.1-Flash-Maya-S",
        "maya": {
            "model_arg": "minimax-maya-s",
            "family": "mm3",
        },
    },
    {
        "id": "hy4-flash-maya-m",
        "engine": "maya",
        "tier": "flagship",
        "title": "Tencent Hy4-Flash 220B · Maya-M",
        "desc": "腾讯 Hy4-Flash 220B Maya-M (~68.4 GB 权重 + 63.4 GB SSD Engram, 3–4 bit 专家)",
        "recommended_gpu": "A100",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 138,
        "mem_gb": 96,
        "has_engram": False,
        "engram_gb": 63,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "Hy4-Flash-Maya-M",
        "maya": {
            "model_arg": "hy4-flash-maya-m",
            "family": "hy4",
        },
    },
    {
        "id": "hy4-flash-maya-l",
        "engine": "maya",
        "tier": "flagship",
        "title": "Tencent Hy4-Flash 220B · Maya-L",
        "desc": "腾讯 Hy4-Flash 220B Maya-L (~89.5 GB 权重 + 63.4 GB SSD Engram, 4–5 bit 高精度)",
        "recommended_gpu": "G4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 160,
        "mem_gb": 128,
        "has_engram": False,
        "engram_gb": 63,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "Hy4-Flash-Maya-L",
        "maya": {
            "model_arg": "hy4-flash-maya-l",
            "family": "hy4",
        },
    },
    {
        "id": "strata-qwen38-iq3s",
        "engine": "strata",
        "tier": "flagship",
        "title": "Qwen3.8-Flash-Next · ISTA IQ3_S",
        "desc": "ISTA-DASLab IQ3_S 最佳通用质量档 (~82 GB 含查表与 MTP, 推荐 A100 / G4)",
        "recommended_gpu": "A100",
        "recommended_high_mem": True,
        "recommended_context": 131072,
        "recommended_storage": "local_nvme",
        "disk_gb": 86,
        "mem_gb": 64,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "strata-data/models/qwen",
        "strata": {
            "family": "qwen",
            "model": "IQ3_S",
            "source": "catalog",
        },
    },
    {
        "id": "strata-qwen38-unsloth-q4",
        "engine": "strata",
        "tier": "flagship",
        "title": "Qwen3.8-Flash-Next · Unsloth UD-Q4_K_XL",
        "desc": "Unsloth 4-bit 动态量化 (~111 GB, 93.1% Q8 首字一致, 推荐 G4 / A100 High-RAM)",
        "recommended_gpu": "G4",
        "recommended_high_mem": True,
        "recommended_context": 131072,
        "recommended_storage": "local_nvme",
        "disk_gb": 120,
        "mem_gb": 96,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "strata-data/models/unsloth",
        "strata": {
            "family": "unsloth",
            "model": "UD-Q4_K_XL",
            "source": "catalog",
        },
    },
    {
        "id": "strata-hy4-sq96",
        "engine": "strata",
        "tier": "flagship",
        "title": "Tencent Hy4-Flash · Strata SQ-96",
        "desc": "Strata 原生 strata-hy4 SQ-96 (~89.6 GB + 67.6 GB Engram, 内置 DFly2 投机解码)",
        "recommended_gpu": "G4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 164,
        "mem_gb": 96,
        "has_engram": False,
        "engram_gb": 68,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "strata-data/models/hy4-flash",
        "strata": {
            "family": "hy4-flash",
            "model": "SQ-96",
            "source": "catalog",
        },
    },
    # ------------------------------------------------------------------
    # Tier 4: Custom HF Repo / Quant
    # ------------------------------------------------------------------
    {
        "id": "strata-custom-hf",
        "engine": "strata",
        "tier": "custom",
        "title": "Strata 自定义 Hugging Face 仓库 / 文件",
        "desc": "自定义 HF Repo + .strata/.gguf 文件名 (或 Strata 家族/量化)，并发直落目标盘",
        "recommended_gpu": "T4",
        "recommended_high_mem": False,
        "recommended_context": 32768,
        "recommended_storage": "local_nvme",
        "disk_gb": 30,
        "mem_gb": 24,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "Custom-Strata",
        "strata": {
            "family": "inkling-2-mini",
            "model": "SQ-15",
            "source": "custom_hf",
        },
    },
    {
        "id": "maya-custom",
        "engine": "maya",
        "tier": "custom",
        "title": "Project Maya 自定义模型 ID / HF 仓库",
        "desc": "直接传递 Project Maya --model/--ds4-quant 参数，或从自定义 HF Repo 拉取权重并 --model-dir 运行",
        "recommended_gpu": "G4",
        "recommended_high_mem": True,
        "recommended_context": 65536,
        "recommended_storage": "local_nvme",
        "disk_gb": 140,
        "mem_gb": 140,
        "has_engram": False,
        "engram_gb": 0,
        "requires_hf_token": False,
        "hf_gated_url": "",
        "cache_subdir": "Custom-Maya",
        "maya": {
            "model_arg": "",
            "family": "custom",
        },
    },
]

PRESET_BY_ID: Dict[str, Dict[str, Any]] = {p["id"]: p for p in PRESETS}


def canonical_preset_id(preset_id: str) -> str:
    pid = (preset_id or "").strip()
    return ALIASES.get(pid, pid)


def _safe_subdir_name(name: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", (name or "").strip()).strip("._-")
    return cleaned or "custom"


def infer_strata_size_hint(filename: str, family: str) -> str:
    low = (filename or "").lower()
    fam = (family or "inkling-2-mini").lower()
    if fam == "inkling-2-mini":
        for tag in ("SQ-20", "SQ-15", "SQ-10"):
            if tag.lower() in low:
                return tag
        for tag in (
            "UD-Q8_K_XL",
            "UD-Q4_K_XL",
            "UD-Q4_K_M",
            "UD-IQ4_XS",
            "UD-Q3_K_XL",
            "UD-IQ3_XXS",
            "UD-Q2_K_XL",
            "UD-IQ2_XXS",
            "UD-IQ1_M",
            "UD-IQ1_S",
        ):
            if tag.lower() in low:
                return tag
        if "q4" in low:
            return "UD-Q4_K_M"
        if "iq3" in low or "q3" in low:
            return "UD-Q3_K_XL"
        if "iq2" in low or "q2" in low:
            return "UD-Q2_K_XL"
        if "iq1" in low:
            return "UD-IQ1_M"
        return "SQ-15"
    if fam == "hy4-flash":
        for tag in ("SQ-128", "SQ-96", "SQ-64"):
            if tag.lower() in low:
                return tag
        return "SQ-64"
    if fam == "qwen36":
        for tag in ("Q8_0", "UD-Q6_K_XL", "UD-Q4_K_XL"):
            if tag.lower() in low:
                return tag
        return "UD-Q4_K_XL"
    if fam == "gyro":
        return "Gyro-M" if "gyro-m" in low else "Gyro-S"
    if fam == "coder":
        return "IQ1_M"
    for tag in ("IQ3_S", "IQ3_XXS", "IQ2_XS", "Q2_0", "UD-IQ4_XS", "UD-Q4_K_XL", "UD-Q5_K_XL", "UD-Q6_K_XL", "Q8_0"):
        if tag.lower() in low:
            return tag
    return "IQ2_XS"


def resolve_spec(
    preset_id: str,
    engine_override: str = "auto",
    custom_hf_repo: str = "",
    custom_hf_file: str = "",
    custom_engine_family: str = "",
) -> Dict[str, Any]:
    """Resolve complete runtime spec for a preset (including custom HF presets and unknown fallback)."""
    cid = canonical_preset_id(preset_id)
    base = PRESET_BY_ID.get(cid)
    if base is not None:
        spec = json.loads(json.dumps(base))
    else:
        eng = engine_override if engine_override in ENGINES else "maya"
        spec = {
            "id": cid or "ds4-abliterated-128g",
            "engine": eng,
            "tier": "custom",
            "title": cid or "custom",
            "desc": f"自定义模型 ({cid})",
            "recommended_gpu": "T4" if eng == "strata" else "G4",
            "recommended_high_mem": eng != "strata",
            "recommended_context": 32768 if eng == "strata" else 65536,
            "recommended_storage": "local_nvme",
            "disk_gb": 30 if eng == "strata" else 120,
            "mem_gb": 24 if eng == "strata" else 140,
            "has_engram": False,
            "engram_gb": 0,
            "requires_hf_token": False,
            "hf_gated_url": "",
            "cache_subdir": _safe_subdir_name(cid),
        }
        if eng == "strata":
            spec["strata"] = {
                "family": custom_engine_family or "inkling-2-mini",
                "model": cid,
                "source": "catalog",
            }
        else:
            spec["maya"] = {
                "model_arg": cid,
                "family": "custom",
            }

    if engine_override in ENGINES:
        spec["engine"] = engine_override

    if spec["id"] == "strata-custom-hf":
        fam = (custom_engine_family or "inkling-2-mini").strip() or "inkling-2-mini"
        repo = (custom_hf_repo or "").strip()
        mfile = (custom_hf_file or "").strip()
        if repo:
            size_hint = infer_strata_size_hint(mfile, fam)
            spec["cache_subdir"] = "Custom-Strata/" + _safe_subdir_name(repo.replace("/", "__"))
            spec["title"] = f"Strata 自定义 · {repo}" + (f" ({mfile})" if mfile else "")
            spec["desc"] = f"Strata [{fam}] HF: {repo}" + (f" / {mfile}" if mfile else "")
            spec["strata"] = {
                "family": fam,
                "model": size_hint,
                "source": "hf_files",
                "hf_repo": repo,
                "model_file": mfile,
                "extra_files": [],
            }
        elif mfile:
            # Allow using custom_hf_file as a direct Strata catalog model tag (e.g. family=qwen, file=IQ2_XS)
            spec["title"] = f"Strata 目录 · {fam}/{mfile}"
            spec["desc"] = f"Strata 官方目录模型 --family {fam} --model {mfile}"
            spec["strata"] = {
                "family": fam,
                "model": mfile,
                "source": "catalog",
            }
        else:
            spec["strata"] = {
                "family": fam,
                "model": "SQ-15" if fam == "inkling-2-mini" else "IQ2_XS",
                "source": "custom_hf",
                "hf_repo": "",
                "model_file": "",
                "extra_files": [],
            }

    elif spec["id"] == "maya-custom":
        raw_arg = (custom_engine_family or "").strip()
        repo = (custom_hf_repo or "").strip()
        mfile = (custom_hf_file or "").strip()
        maya_cfg: Dict[str, Any] = {"model_arg": raw_arg, "family": "custom"}
        if raw_arg.startswith("ds4:"):
            maya_cfg["model_arg"] = "DeepSeek-V4.1-Flash-1017"
            maya_cfg["ds4_quant"] = raw_arg[4:].strip()
            maya_cfg["family"] = "ds4"
            spec["has_engram"] = True
            spec["engram_gb"] = 161
            spec["disk_gb"] = 300
        elif raw_arg.startswith("hy4:"):
            maya_cfg["model_arg"] = "Hy4-Flash"
            maya_cfg["hy4_quant"] = raw_arg[4:].strip()
            maya_cfg["family"] = "hy4"
        if repo:
            maya_cfg["hf_repo"] = repo
            maya_cfg["model_file"] = mfile
            spec["cache_subdir"] = "Custom-Maya/" + _safe_subdir_name(repo.replace("/", "__"))
            spec["title"] = f"Maya 自定义 · {repo}"
            spec["desc"] = f"Project Maya HF: {repo}" + (f" ({mfile})" if mfile else "") + (f" [--model {raw_arg}]" if raw_arg else "")
        elif raw_arg:
            spec["title"] = f"Maya 自定义 · {raw_arg}"
            spec["desc"] = f"Project Maya 自定义模型参数: {raw_arg}"
            spec["cache_subdir"] = "Custom-Maya/" + _safe_subdir_name(raw_arg)
        spec["maya"] = maya_cfg

    return spec


def _print_field(spec: Dict[str, Any], field: str) -> int:
    if field == "high_mem_flag":
        print("1" if spec.get("recommended_high_mem") else "0")
        return 0
    if field == "has_engram_flag":
        print("1" if spec.get("has_engram") else "0")
        return 0
    if field == "requires_hf_token_flag":
        print("1" if spec.get("requires_hf_token") else "0")
        return 0
    val = spec.get(field, "")
    if isinstance(val, bool):
        print("1" if val else "0")
    elif isinstance(val, (dict, list)):
        print(json.dumps(val, ensure_ascii=False))
    else:
        print("" if val is None else str(val))
    return 0


def _print_table(tier_filter: str = "", engine_filter: str = "") -> None:
    tier_order = [t["id"] for t in TIERS]
    tier_titles = {t["id"]: t["title"] for t in TIERS}
    shown = 0
    for tid in tier_order:
        if tier_filter and tid != tier_filter:
            continue
        items = [
            p
            for p in PRESETS
            if p["tier"] == tid and (not engine_filter or p["engine"] == engine_filter)
        ]
        if not items:
            continue
        print(f"\n[{tier_titles[tid]}]")
        for p in items:
            hw = f"{p['recommended_gpu']}" + (" High-RAM" if p["recommended_high_mem"] else " Std-RAM")
            token_tag = " [需HF_TOKEN]" if p.get("requires_hf_token") else ""
            print(
                f"  • {p['id']:<32s} | 引擎: {p['engine']:<6s} | 推荐: {hw:<12s} | "
                f"盘~{p['disk_gb']:>3d}GB{token_tag}"
            )
            print(f"    {p['desc']}")
            shown += 1
    if shown == 0:
        print("(未匹配到任何模型预设)")


def main(argv: List[str]) -> int:
    if not argv:
        print("Usage: model_registry.py <list|table|resolve|field|exists|tiers> ...", file=sys.stderr)
        return 2

    cmd = argv[0]
    args = argv[1:]

    if cmd == "tiers":
        for t in TIERS:
            print(FIELD_SEP.join([t["id"], t["title"], t["short"]]))
        return 0

    if cmd == "list":
        tier_filter = ""
        engine_filter = ""
        i = 0
        while i < len(args):
            if args[i] == "--tier" and i + 1 < len(args):
                tier_filter = args[i + 1].strip().lower()
                i += 2
            elif args[i] == "--engine" and i + 1 < len(args):
                engine_filter = args[i + 1].strip().lower()
                i += 2
            else:
                i += 1
        for p in PRESETS:
            if tier_filter and p["tier"] != tier_filter:
                continue
            if engine_filter and p["engine"] != engine_filter:
                continue
            print(
                FIELD_SEP.join(
                    [
                        p["id"],
                        p["engine"],
                        p["tier"],
                        p["title"],
                        p["desc"],
                        p["recommended_gpu"],
                        "1" if p["recommended_high_mem"] else "0",
                        str(p["disk_gb"]),
                        str(p["mem_gb"]),
                        "1" if p.get("requires_hf_token") else "0",
                    ]
                )
            )
        return 0

    if cmd == "table":
        tier_filter = ""
        engine_filter = ""
        i = 0
        while i < len(args):
            if args[i] == "--tier" and i + 1 < len(args):
                tier_filter = args[i + 1].strip().lower()
                i += 2
            elif args[i] == "--engine" and i + 1 < len(args):
                engine_filter = args[i + 1].strip().lower()
                i += 2
            else:
                i += 1
        _print_table(tier_filter=tier_filter, engine_filter=engine_filter)
        return 0

    if cmd == "exists":
        if not args:
            return 1
        cid = canonical_preset_id(args[0])
        if cid in PRESET_BY_ID:
            print(cid)
            return 0
        return 1

    if cmd in ("resolve", "field"):
        preset_id = args[0] if args else ""
        field_name = args[1] if (cmd == "field" and len(args) > 1) else ""
        start_idx = 2 if cmd == "field" else 1
        engine_ov = os.environ.get("COLABD_ENGINE_TYPE", "auto")
        hf_repo = os.environ.get("COLABD_CUSTOM_HF_REPO", "")
        hf_file = os.environ.get("COLABD_CUSTOM_HF_FILE", "")
        eng_fam = os.environ.get("COLABD_CUSTOM_ENGINE_FAMILY", "")
        i = start_idx
        while i < len(args):
            if args[i] == "--engine" and i + 1 < len(args):
                engine_ov = args[i + 1]
                i += 2
            elif args[i] == "--hf-repo" and i + 1 < len(args):
                hf_repo = args[i + 1]
                i += 2
            elif args[i] == "--hf-file" and i + 1 < len(args):
                hf_file = args[i + 1]
                i += 2
            elif args[i] == "--family" and i + 1 < len(args):
                eng_fam = args[i + 1]
                i += 2
            else:
                i += 1
        spec = resolve_spec(
            preset_id,
            engine_override=engine_ov,
            custom_hf_repo=hf_repo,
            custom_hf_file=hf_file,
            custom_engine_family=eng_fam,
        )
        if cmd == "resolve":
            print(json.dumps(spec, ensure_ascii=False))
            return 0
        return _print_field(spec, field_name)

    print(f"Unknown model_registry command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
