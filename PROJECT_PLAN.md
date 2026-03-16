# VoiceMem — 项目计划与调研汇总

> **项目名称**：VoiceMem（原 VoiceMemory macOS，2026-03-16 更名）
> **GitHub**: https://github.com/DearBobby9/voicemem
> **创建日期**：2026-03-14
> **项目定位**：极简、轻量、always-on 的本地语音记忆收集器
> **目标平台**：macOS (Apple Silicon M5)
> **语言**：Swift / SwiftUI
> **关联项目**：[VoiceMemory (Python)](https://github.com/DearBobby9/VoiceMemory) — 独立仓库，不共享代码; [Perch](../Perch/) — 未来集成目标

---

## 目录

1. [项目定位与愿景](#1-项目定位与愿景)
2. [竞品分析](#2-竞品分析)
3. [硬件环境与能力](#3-硬件环境与能力)
4. [ASR 模型调研](#4-asr-模型调研)
5. [ANE 能力全图](#5-ane-能力全图)
6. [M5 GPU Neural Accelerators](#6-m5-gpu-neural-accelerators)
7. [架构设计](#7-架构设计)
8. [MVP 定义](#8-mvp-定义)
9. [技术选型](#9-技术选型)
10. [资源预算](#10-资源预算)
11. [插件扩展方向](#11-插件扩展方向)
12. [Dayflow 参考分析](#12-dayflow-参考分析)
13. [HCI 学术参考](#13-hci-学术参考)
14. [参考资料索引](#14-参考资料索引)

---

## 1. 项目定位与愿景

### 一句话

> 一个极度轻量的 macOS 原生 menu bar App，always-on 地把你周围的声音变成可检索的文本。

### 不是什么

| 不是 | 原因 |
|------|------|
| 不是 Rewind | Rewind 录屏幕+音频+OCR，太重（2-4GB RAM, 5-10% CPU） |
| 不是 Screenpipe | 同理，录屏幕+音频，Rust/Tauri 不是 macOS 原生 |
| 不是听写工具 | 听写需要用户手动触发；我们是 always-on，用户无感 |
| 不是会议记录器 | 会议记录器有明确的开始/结束；我们是持续运行 |

### 核心哲学

借鉴 Dayflow 的设计理念：

1. **极度克制的数据采集** — 只录声音，不录屏幕。VAD 过滤 70-80% 静音。
2. **原始数据是临时的，AI 结果是永久的** — 音频文件可配保留期（7天/30天/永久），转录文本永久保留。
3. **本地优先** — 所有处理在本机完成，数据不出设备。
4. **轻量后台** — 用户忘记它的存在，但需要时随时可搜。
5. **插件化扩展** — 核心只做采集+转录+存储，其他都是插件。

### 与 VoiceMemory Python 版的关系

**完全独立**。Swift App 有自己的 SQLite 数据库，自己的音频存储，自己的 ASR。不依赖 Mac Studio、不依赖 Python 服务器、不依赖网络。

未来可通过插件支持把数据同步到 VoiceMemory Python 服务器，但这不是核心功能。

---

## 2. 竞品分析

### 市场格局

| 项目 | Always-on | 全本地 | 可搜索 | macOS 原生 | 开源 | 状态 |
|------|----------|-------|--------|-----------|------|------|
| **Rewind.ai** | 是 | 是 | 是 | Swift | 否 | **已死**（2025.12 Meta 收购关停） |
| **Screenpipe** | 是 | 是 | FTS5+vec | Rust/Tauri | MIT | 活跃，17K stars，$2.8M 融资 |
| **Dayflow** | 是（屏幕） | 是 | SQLite | Swift | MIT | 活跃，5.8K stars |
| **audio-monitor** | 是 | 是 | FTS5 | Python | MIT | 极早期（3 commits） |
| **Omi** | 是 | 可自托管 | 语义 | Flutter | MIT | 活跃，硬件 $89 |
| **Bee** | 是 | 否（云） | 是 | 否 | 否 | Amazon 收购 |
| MacWhisper | 否 | 是 | 是 | Swift | 否 | 活跃，$40 |
| Superwhisper | 否 | 是 | 否 | Swift | 否 | 活跃，$85/年 |
| VoiceInk | 否 | 是 | 否 | Swift GPL | 是 | 活跃 |
| Buzz | 否 | 是 | 否 | PyQt | MIT | 活跃 |

### Rewind 死后的市场真空

Rewind.ai 是唯一同时满足 always-on + 全本地 + 可搜索 + macOS 原生 + 隐私优先的产品。2025年12月被 Meta 收购后关停。其用户（隐私敏感、愿意付费）现在没有替代品。

### 没有一个现有项目同时满足我们的五个核心需求

| 需求 | 最佳现有匹配 | 缺什么 |
|------|-------------|--------|
| Always-on 录音 | Screenpipe | 不是 macOS 原生 Swift |
| 全本地转录 | MacWhisper | 不是 always-on |
| 可搜索历史 | Screenpipe | 无 LLM 增强 |
| macOS Swift 原生 | VoiceInk | 不是 always-on，无搜索 |
| 隐私优先 + 轻量 | audio-monitor | 无 UI，无语义搜索 |

**结论：没有能直接用的。但不需要从零开始——核心框架（WhisperKit、FluidAudio）都是 MIT 开源的。**

---

## 3. 硬件环境与能力

### 目标设备

**MacBook Pro M5, 24GB RAM**

### Apple Silicon M5 AI 硬件

M5 是 Apple Silicon 史上最重要的 AI 架构升级，有**三套独立 AI 硬件**：

```
M5 MacBook Pro:
┌─────────────────────────────────────────────┐
│  CPU (18核)     GPU (10-40核)    ANE (16核)  │
│                 ┌──┐┌──┐┌──┐               │
│                 │NA││NA││NA│ ← GPU Neural   │
│                 └──┘└──┘└──┘   Accelerators │
│         ┌─────────────────────┐             │
│         │   统一内存 (24GB)     │             │
│         └─────────────────────┘             │
└─────────────────────────────────────────────┘
```

| 硬件 | 核心 | 用途 | 编程方式 | 功耗 |
|------|------|------|---------|------|
| **ANE** | 16核, ~20 TFLOPS | CoreML 推理 | CoreML 框架 | **极低 (<1W)** |
| **GPU Neural Accel.** | 每 GPU 核心一个 | 矩阵乘法加速 | Metal 4 Tensor API | 中等 |
| **GPU SIMD** | 通用计算 | 图形渲染 + 通用 | Metal | 较高 |

关键特性：
- **三者可同时运行，互不干扰**
- ANE 空闲功耗 **0W**（硬件断电门控）
- ANE 推理功耗 ~0.3W/pass（WhisperKit 实测）
- GPU Neural Accelerators 让 MLX prefill 加速 **3-4x**（需 macOS 26.2+）
- **MLX 自动使用 Neural Accelerators**，Python/Swift 代码零改动

### M1-M5 ANE 代际对比

| 芯片 | ANE 核心 | 实际 FP16 TFLOPS | 关键新功能 |
|------|---------|------------------|-----------|
| M1 | 16 | ~5.5 | 基准 |
| M2 | 16 | ~7.9 | +43%（最大跃进） |
| M3 | 16 | ~9 | +14% |
| M4 | 16 | ~19 | W8A8 INT8, Stateful KV-cache |
| **M5** | 16 + GPU NA | ~20 + GPU NA | **GPU Neural Accelerators, Metal 4** |

注意：Apple 的 TOPS 营销有水分。M4 宣称 38 TOPS 实际是把 FP16 TFLOPS 乘以 2 算 INT8。M3→M4 真实 ANE 提升只有 ~5%。M5 的 133 TOPS 是 ANE + GPU NA 合计。

---

## 4. ASR 模型调研

### 全面对比

| 模型 | 大小 | RAM | 中文 CER | 英文 WER | 流式 | 硬件 | 中英混合 |
|------|------|-----|----------|---------|------|------|----------|
| **WhisperKit large-v3-turbo 量化** | 632MB | ~1GB | ~10% | ~2% | 是 | **ANE** | 有限 |
| **Qwen3-ASR-0.6B 4-bit** | 90MB | ~500MB | **3.15%** | 2.11% | 是 | GPU (MLX) | **最佳** |
| Qwen3-ASR-1.7B | 3.4GB | ~4GB | **2.71%** | **1.63%** | 是 | GPU (MLX) | **最佳** |
| MLX Whisper large-v3-turbo | ~2GB | ~2GB | ~10% | ~2% | 否 | GPU (MLX) | 有限 |
| SenseVoice-Small (FunASR) | ~400MB | ~800MB | 5.14% | ~10% | 是 | CPU | 部分 |
| Paraformer-zh (FunASR) | ~450MB | ~900MB | **2.09%** | N/A | 是 | CPU | 否 |
| FireRedASR2-AED | 1.1B | ~3GB | **0.57%** | 1.93% | 否 | CPU only | 是 |
| Moonshine v2 Medium | 245MB | ~300MB | N/A | 6.65% | 是 | CPU (ONNX) | 否 |

### MVP 推荐：WhisperKit

| 理由 | 说明 |
|------|------|
| **零依赖** | 纯 Swift SPM，不需要 Python、不需要额外进程 |
| **ANE 运行** | 功耗极低（0.3W/pass），always-on 最合适 |
| **最轻量** | 和"极简 collector"定位一致 |
| **流式输出** | 支持 confirmed + hypothesis 双流 |
| **成熟** | 12K GitHub stars, ICML 2025 论文, 生产级 |

中文精度（~10% CER）是妥协，但对 voice memory 够用——关键词基本正确，能搜到能回忆。

### 精度增强路径（插件）

1. 检测到 LM Studio 运行时，可用 Qwen3-ASR API 重新转录（中文 3.15% CER）
2. 或者批量定时用 Qwen3-ASR 替换 WhisperKit 的初始结果
3. 核心 App 保持轻量，精度提升是可选插件

### WhisperKit 集成方式

```swift
import WhisperKit

// 初始化（App 启动时，模型自动下载缓存）
let whisperKit = try await WhisperKit(
    WhisperKitConfig(model: "large-v3-v20240930_turbo")
)

// 转录（VAD 切出的每段音频）
let result = try await whisperKit.transcribe(
    audioArray: floatSamples,  // [Float], 16kHz mono
    decodeOptions: DecodingOptions(
        language: "zh",
        wordTimestamps: true
    )
)

for segment in result {
    // segment.text, segment.start, segment.end
}
```

### Qwen3-ASR 集成方式（插件用）

```bash
# 启动本地 HTTP 服务
pip install mlx-qwen3-asr
python -m mlx_qwen3_asr.server --model Qwen/Qwen3-ASR-0.6B --port 8090
```

```swift
// Swift HTTP 调用
var request = URLRequest(url: URL(string: "http://localhost:8090/transcribe")!)
request.httpMethod = "POST"
request.httpBody = audioData
let (data, _) = try await URLSession.shared.data(for: request)
```

---

## 5. ANE 能力全图

### ANE 能做的所有事情（按成熟度）

| 领域 | 成熟度 | 最佳工具 | 与本项目的关系 |
|------|--------|----------|---------------|
| **ASR 语音识别** | 生产级 | WhisperKit | **核心功能** |
| **VAD 语音检测** | 生产级 | FluidAudio Silero VAD CoreML | **核心功能** |
| **说话人分离** | 生产级 | FluidAudio Pyannote CoreML | 插件：区分说话人 |
| **TTS 语音合成** | 生产级 | Kokoro-82M CoreML / TTSKit | 插件：语音摘要朗读 |
| **音频分类** | 生产级 | Apple SoundAnalysis | 插件：标记音频类型 |
| **LLM (Apple 3B)** | Beta SDK | Foundation Models (macOS 26) | 插件：本地润色 |
| **LLM (开源)** | Beta | ANEMLL | 参考 |
| **NER** | 生产级 | Apple NLTagger | 插件：实体提取 |
| **翻译** | 生产级 | Apple Translate | 插件：实时翻译 |
| **OCR** | 生产级 | Apple Vision | 未来：视觉记忆扩展 |
| **图文 Embedding** | 生产级 | MobileCLIP CoreML | 未来：多模态搜索 |
| **图像检测** | 生产级 | YOLO11 CoreML | 不相关 |
| **图像生成** | 生产级 | ml-stable-diffusion | 不相关 |

### ANE 硬性限制

| 限制 | 说明 |
|------|------|
| 只认 CoreML 格式 | 必须用 coremltools 转换 |
| FP16 精度 | 值超 ±65,504 变 NaN |
| 不支持动态形状 | 用 EnumeratedShapes（最多 128） |
| 上下文长度 ~4096 | GPU/MLX 能跑 32K+ |
| 自回归效率低 | Encoder 类最合适 |
| 首次编译慢 | 大模型首次加载几分钟（之后缓存） |

### ANE 最擅长 vs 最不擅长

| 最擅长（用于核心功能） | 最不擅长（避免） |
|----------------------|----------------|
| VAD（固定输入，always-on） | 长文本 LLM 生成 |
| WhisperKit encoder（音频特征） | 动态形状输入 |
| 音频分类 | 自定义算子 |
| 小型 NLP 模型 | RNN/LSTM |

---

## 6. M5 GPU Neural Accelerators

### 什么是 GPU Neural Accelerator

每个 M5 GPU 核心内嵌一个专用矩阵乘法单元（32 宽 × 4 路点积），类似 NVIDIA Tensor Core。

- **不是独立芯片**，是 GPU 核心内部的"器官"
- 每周期 512 次 FP16 乘加运算
- 最佳工作粒度 32×32 矩阵 tile
- 硬件矩阵转置零开销

### 各型号算力

| 芯片 | GPU 核心 | Neural Accelerators | 估算 FP16 |
|------|---------|--------------------|----|
| M5 | 8-10 | 8-10 | ~15 TFLOPS |
| M5 Pro | 16-20 | 16-20 | ~35 TFLOPS |
| M5 Max | 32-40 | 32-40 | ~70 TFLOPS |

### 实际加速效果

| 场景 | M4 → M5 提升 | 原因 |
|------|-------------|------|
| LLM Prefill | **3.3-4.4x** | Neural Accelerators |
| LLM Decode | ~20% | 仅带宽提升 |
| Whisper 编码 | **3-4x** | 等价 prefill |
| bge-m3 Embedding | **3-4x** | 纯 encode |

### MLX 自动利用

- MLX 在 macOS 26.2+ **自动使用** Neural Accelerators
- Python/Swift 代码**零改动**
- PyTorch MPS 和 Ollama/llama.cpp **不支持**

### 对本项目的影响

核心 App 用 WhisperKit (ANE)，不涉及 Neural Accelerators。但插件如果调 MLX（如 Qwen3-ASR、LM Studio），会自动获得 3-4x prefill 加速。三路硬件（ANE + Neural Accel. + SIMD）同时工作，互不干扰。

---

## 7. 架构设计

### 核心管线

```
┌─────────────────────────────────────────────┐
│  VoiceMemory macOS (Swift, menu bar App)    │
│                                             │
│  AVAudioEngine (16kHz mono)                 │
│       │                                     │
│       ▼                                     │
│  Silero VAD CoreML (ANE, <0.5W)             │
│       │ 检测到语音                            │
│       ▼                                     │
│  音频切段 + FLAC/CAF 编码                     │
│       │                                     │
│       ▼                                     │
│  WhisperKit (ANE, 0.3W/pass)                │
│       │                                     │
│       ▼                                     │
│  SQLite (GRDB) + 音频文件                     │
│       │                                     │
│       ▼                                     │
│  Menu Bar UI (状态指示)                       │
└─────────────────────────────────────────────┘
         │
         │ 开放接口 (SQLite 文件 + 可选 HTTP API)
         │
   ┌─────┼──────┬──────────┬───────────┐
   ▼     ▼      ▼          ▼           ▼
 搜索   润色    摘要      Embedding   第三方
(插件) (插件)  (插件)     (插件)      (插件)
```

### 借鉴 Dayflow 的设计

| Dayflow 做法 | 本项目对应 |
|-------------|-----------|
| 屏幕 1 FPS（数据量降 99.7%） | VAD 过滤静音（数据量降 70-80%） |
| 15 秒视频块 → 攒 15 分钟批量 AI | 音频段 → 可选攒 N 分钟批量 ASR |
| 原始视频 3 天自动删 | 音频文件可配保留期 |
| AI 文字结果永久保留 | 转录文本永久保留 |
| GRDB + SQLite | GRDB + SQLite |
| Sparkle 自动更新 | Sparkle 自动更新 |
| URL Scheme (`dayflow://start`) | URL Scheme (`voicememory://start`) |
| Markdown 导出 | Markdown 导出 |

### 数据流

```
录音 → VAD 检测 → 有语音？
                    │
              ┌─────┴─────┐
              │ 是         │ 否
              ▼            ▼
          切段编码       丢弃
              │
              ▼
          写入队列
              │
              ▼
      ┌───────┴────────┐
      │ 实时模式        │ 批量模式（可选）
      │ 每段立即转录    │ 攒 N 分钟批量转录
      ▼                ▼
    WhisperKit      WhisperKit (batch)
      │                │
      ▼                ▼
    写入 SQLite     写入 SQLite
    (text, timestamps, audio_path)
```

### 文件结构（参考 Dayflow）

```
VoiceMemory_macOS/
├── VoiceMemory/
│   ├── App/                    # 入口、生命周期
│   │   └── VoiceMemoryApp.swift
│   ├── Core/                   # 业务逻辑
│   │   ├── AudioCaptureManager.swift    # AVAudioEngine + 设备管理
│   │   ├── VADManager.swift             # Silero VAD CoreML
│   │   ├── TranscriptionManager.swift   # WhisperKit 封装
│   │   └── DatabaseManager.swift        # GRDB SQLite
│   ├── Models/                 # 数据模型
│   │   ├── Transcription.swift
│   │   └── AudioSegment.swift
│   ├── Views/                  # SwiftUI UI
│   │   ├── MenuBarView.swift
│   │   ├── TimelineView.swift  # 后续
│   │   └── SettingsView.swift
│   ├── System/                 # 系统集成
│   │   ├── LoginItem.swift     # 开机启动
│   │   ├── Permissions.swift   # 麦克风权限
│   │   └── SleepWake.swift     # 合盖/唤醒处理
│   └── Utilities/
│       ├── AudioEncoder.swift  # FLAC/CAF 编码
│       └── StorageCleanup.swift # 音频文件清理
├── VoiceMemoryTests/
├── Package.swift / .xcodeproj
└── README.md
```

---

## 8. MVP 定义

### MVP 做什么

| 功能 | 包含 | 说明 |
|------|------|------|
| Menu bar icon | 是 | 录音状态指示（录制中/暂停/错误） |
| Always-on 录音 | 是 | AVAudioEngine, 16kHz mono |
| VAD | 是 | Silero VAD CoreML (ANE) |
| ASR | 是 | WhisperKit (ANE) |
| 本地存储 | 是 | SQLite (GRDB) + 音频文件 |
| 设置界面 | 是 | 选麦克风、选模型、音频保留期、开关 |
| 开机自启 | 是 | Login Item |
| 合盖/唤醒处理 | 是 | NSWorkspace 通知 |
| 音频文件清理 | 是 | 可配保留期（7/30/永久天） |

### MVP 不做什么

| 功能 | 不包含 | 原因 |
|------|--------|------|
| 搜索 UI | 否 | 插件 |
| 时间轴 UI | 否 | 插件 |
| LLM 润色 | 否 | 插件 |
| Embedding | 否 | 插件 |
| NER | 否 | 插件 |
| RAG Chat | 否 | 插件 |
| 摘要 | 否 | 插件 |
| 说话人分离 | 否 | 插件 |
| 网络同步 | 否 | 插件 |

### MVP 的一句话

> 一个 menu bar App，打开就默默录音、转录、存到本地数据库。用户能看到它在工作，能暂停，能设置，其他什么都不做。

---

## 9. 技术选型

### 核心依赖

| 组件 | 选型 | 理由 |
|------|------|------|
| **ASR** | WhisperKit (SPM) | Swift 原生，ANE，零外部依赖，MIT |
| **VAD** | FluidAudio Silero VAD CoreML | ANE，亚毫秒级，4.3MB，MIT |
| **数据库** | GRDB.swift | Swift SQLite 封装，支持 SQL 窗口函数，比 Core Data 灵活 |
| **音频捕获** | AVAudioEngine | Apple 原生，支持设备切换通知 |
| **音频编码** | AVAudioFile / ExtAudioFile | 原生 FLAC/CAF 支持 |
| **UI** | SwiftUI | macOS 原生，menu bar popover |
| **自动更新** | Sparkle | 标准 macOS 更新框架 |
| **开机启动** | SMAppService / Login Item | macOS 13+ 推荐方式 |

### 不用什么

| 不用 | 原因 |
|------|------|
| Core Data | 无法做复杂 SQL（窗口函数、FTS5） |
| Realm | 过重，不需要 |
| Python / MLX | 核心 App 纯 Swift，不引入 Python 运行时 |
| Electron / Tauri | 不是 macOS 原生 |
| Firebase / 云服务 | 全本地 |

### SQLite Schema（初始）

```sql
CREATE TABLE transcriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    text TEXT NOT NULL,
    timestamp_start INTEGER NOT NULL,    -- Unix epoch ms
    timestamp_end INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL,
    language TEXT,
    audio_path TEXT,                      -- 相对路径
    model TEXT DEFAULT 'whisperkit',
    confidence REAL,
    created_at INTEGER NOT NULL
);

CREATE INDEX idx_timestamp ON transcriptions(timestamp_start);

-- FTS5 全文搜索（为搜索插件预留）
CREATE VIRTUAL TABLE transcriptions_fts USING fts5(
    text,
    content='transcriptions',
    content_rowid='id',
    tokenize='trigram'
);
```

---

## 10. 资源预算

### 内存

| 组件 | 内存 |
|------|------|
| Swift App 本身 | ~50 MB |
| Silero VAD CoreML | ~5 MB |
| WhisperKit 量化模型 | ~600 MB |
| SQLite | ~20 MB |
| **合计** | **~675 MB** |

24GB 机器占 ~3%，基本无感。

### 功耗

| 状态 | 功耗 |
|------|------|
| 无人说话（VAD 监听） | <0.5W |
| 有人说话（VAD + ASR） | ~1W |
| 日常平均 | **<1W** |

MacBook 屏幕 5-8W/h，本 App 的功耗可忽略。

### 存储（一年 always-on）

| 数据 | 每年 |
|------|------|
| 音频 FLAC（保留 7 天滚动） | **~100 MB**（峰值 ~280 MB） |
| 音频 FLAC（保留永久） | **~5.5 GB** |
| 转录文本 | ~100 MB |
| SQLite 索引 | ~50 MB |
| **合计（7天滚动）** | **~250 MB/年** |
| **合计（永久保留）** | **~5.7 GB/年** |

### 与竞品对比

| | Rewind | Screenpipe | **本 App** |
|---|---|---|---|
| 内存 | 2-4 GB | 1-2 GB | **~675 MB** |
| CPU | 5-10% 持续 | 5-10% 持续 | **<1%** |
| 存储/月 | 几十 GB | 几十 GB | **~25 MB (7天滚动)** |
| App 大小 | >500 MB | >200 MB | **~25 MB + 600MB 模型** |

轻一个数量级。

---

## 11. 插件扩展方向

### 插件接口

**SQLite 文件就是接口。** 插件直接读写 `~/Library/Application Support/VoiceMemory/voicememory.db`。

可选：核心 App 暴露 localhost HTTP API（如 `localhost:9090`），供需要实时数据的插件使用。

### 优先级排序

| 插件 | 优先级 | 依赖 | 说明 |
|------|--------|------|------|
| **搜索 UI** | P0 | 无 | SwiftUI 搜索面板，FTS5 查询 |
| **时间轴 UI** | P0 | 无 | 按天/小时浏览转录 |
| **精度增强** | P1 | LM Studio / Qwen3-ASR | 用高精度模型重新转录 |
| **LLM 润色** | P1 | LM Studio | 调 localhost:1234 润色文本 |
| **Embedding** | P1 | LM Studio (bge-m3) | 语义向量搜索 |
| **每日摘要** | P2 | LM Studio | 每天生成语音活动总结 |
| **说话人分离** | P2 | FluidAudio | 标注"谁在说话" |
| **NER** | P2 | Apple NLTagger | 提取人名/地点/组织 |
| **RAG Chat** | P3 | LM Studio + Embedding | "我昨天说了什么关于..." |
| **Markdown 导出** | P3 | 无 | 导出时间线 |
| **Dayflow 集成** | P4 | Dayflow App | 屏幕活动 + 语音关联 |
| **VoiceMemory 同步** | P4 | 网络 + Python 服务器 | 推送到 Mac Studio |
| **Apple Foundation Models 润色** | P4 | macOS 26 | 用 Apple 3B LLM 替代 LM Studio |

---

## 12. Dayflow 参考分析

### Dayflow 概况

- **GitHub**: [JerryZLiu/Dayflow](https://github.com/JerryZLiu/Dayflow) — MIT, ~5.8K stars
- **定位**: "A git log for your day" — always-on 屏幕活动记录器
- **技术栈**: Swift / SwiftUI / ScreenCaptureKit / GRDB / Ollama/LM Studio

### Dayflow 五阶段管线

```
屏幕 (1 FPS) → 15秒视频块 → 攒15分钟 → AI VLM 分析 → SQLite → 时间线 UI
```

1. **捕获**: ScreenCaptureKit, 1 FPS（降 99.7% 数据量）
2. **切块**: 15 秒 .mp4 存临时目录
3. **AI 分析**: 每 15 分钟批量，支持 Ollama / LM Studio / Gemini / ChatGPT
4. **存储**: SQLite (GRDB)，`LAG()` 窗口函数合并相似活动
5. **清理**: 3 天滚动删除原始视频，AI 文字永久保留

### Dayflow 资源占用

- 内存: ~100 MB
- CPU: <1%
- App: 25 MB
- 存储: 可配 1-20 GB 上限

### 核心设计理念（全部适用于本项目）

1. **极度克制的数据采集** — 1 FPS 而非 30 FPS
2. **原始数据临时，AI 结果永久** — 视频删，文字留
3. **本地 AI 是一等公民** — Ollama/LM Studio 默认推荐
4. **GRDB 而非 Core Data** — 需要 SQL 窗口函数
5. **Sparkle 自动更新 + URL Scheme 自动化**

### Dayflow + VoiceMemory = 完整记忆

Dayflow 录屏幕（你在看什么），VoiceMemory 录声音（你在说什么）。两者结合 = 最完整的个人上下文记忆。未来可做集成插件。

---

## 13. HCI 学术参考

| 论文 | 会议/来源 | 核心贡献 | 与本项目的关系 |
|------|----------|---------|---------------|
| **Memoro** (MIT Media Lab) | **CHI 2024** | Always-on 语音记忆 + LLM 检索 + "Queryless Mode" | 最直接的学术先驱；Queryless Mode 是未来方向 |
| Privacy-Preserving Wearable | arXiv 2511.11811 | 全本地 MLX + CoreML 穿戴设备 | 技术栈几乎一致 |
| AR Secretary Agent | arXiv 2505.11888 | AR 眼镜 + Whisper + GPT-4 记忆增强 | 用户研究显示记忆提升 20% |
| ACM LSC 2022-2025 | ACM Workshop | 年度生活日志检索比赛 | 学术界已做了多年，Voxento 系列是语音检索 |
| Apple SpeechAnalyzer | WWDC 2025 | Apple 新一代语音识别框架 | macOS 26 后可替代 WhisperKit |

### Memoro 的 "Queryless Mode"（未来方向）

MIT Media Lab 的 Memoro 系统有一个创新功能：不需要用户主动搜索，系统根据当前对话上下文**自动推断**你想回忆什么，并主动呈现相关的过去记忆。CHI 2024 用户研究显示回忆信心提升，任务负荷降低。

这是 VoiceMemory 远期可以探索的方向——从"被动搜索"到"主动推荐"。

---

## 14. 参考资料索引

### 核心框架
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — ASR, MIT, 12K stars
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — VAD/TTS/Diarization, MIT, 800 stars
- [GRDB.swift](https://github.com/groue/GRDB.swift) — Swift SQLite, MIT
- [Sparkle](https://github.com/sparkle-project/Sparkle) — macOS 自动更新

### 竞品与参考
- [Dayflow](https://github.com/JerryZLiu/Dayflow) — 屏幕活动记录, MIT, 5.8K stars
- [Screenpipe](https://github.com/screenpipe/screenpipe) — 屏幕+音频, MIT, 17K stars
- [VoiceInk](https://github.com/Beingpax/VoiceInk) — Swift 听写, GPL
- [audio-monitor](https://github.com/glebis/audio-monitor) — Python always-on, MIT
- [Omi](https://github.com/BasedHardware/omi) — 开源穿戴, MIT/Apache

### ASR 模型
- [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) — 中英双强, MLX 原生
- [mlx-qwen3-asr (PyPI)](https://pypi.org/project/mlx-qwen3-asr/) — Python 包
- [FireRedASR2S](https://github.com/FireRedTeam/FireRedASR2S) — 中文 SOTA
- [Moonshine](https://github.com/moonshine-ai/moonshine) — 超轻量英文 ASR
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) — ONNX ASR 部署

### ANE 与 Apple Silicon
- [WhisperKit ICML 2025 Paper](https://arxiv.org/html/2507.10860v1)
- [Orion: ANE Training](https://arxiv.org/abs/2603.06728)
- [Apple ML: MLX + M5 Neural Accelerators](https://machinelearning.apple.com/research/exploring-llms-mlx-m5)
- [ANEMLL](https://github.com/Anemll/Anemll) — 开源 LLM on ANE
- [hollance/neural-engine](https://github.com/hollance/neural-engine) — ANE 逆向文档
- [Apple ml-ane-transformers](https://github.com/apple/ml-ane-transformers)
- [Taras Zakharko: M5 Neural Accelerator Benchmark](https://tzakharko.github.io/apple-neural-accelerators-benchmark/)

### Apple 官方
- [Core ML](https://developer.apple.com/machine-learning/core-ml/)
- [Foundation Models](https://developer.apple.com/documentation/FoundationModels)
- [WWDC25: SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [WWDC25: Foundation Models](https://developer.apple.com/videos/play/wwdc2025/286/)
- [WWDC25: Discover Metal 4](https://developer.apple.com/videos/play/wwdc2025/205/)
- [WWDC25: Metal 4 ML + Graphics](https://developer.apple.com/videos/play/wwdc2025/262/)

### HCI 论文
- [Memoro (CHI 2024)](https://dl.acm.org/doi/10.1145/3613904.3642450)
- [Privacy-Preserving Wearable (arXiv 2511.11811)](https://arxiv.org/abs/2511.11811)
- [AR Secretary Agent (arXiv 2505.11888)](https://arxiv.org/html/2505.11888)
- [ACM Lifelog Search Challenge](https://arxiv.org/html/2506.06743v1)

### 详细调研报告
- [ANE-Research.md](/Users/bobbyjia/Desktop/Personal_project/VoiceMemory/ANE-Research.md) — ANE 能力全图 + 芯片对比 + Neural Accelerators
- [WhisperKit-Research.md](/Users/bobbyjia/Desktop/Personal_project/VoiceMemory/WhisperKit-Research.md) — WhisperKit 原始调研
