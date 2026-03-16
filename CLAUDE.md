# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**VoiceMem** — 极简、轻量、always-on 的本地语音记忆收集器。macOS 原生 App，默默把你周围的声音变成可检索的文本，每 15 分钟聚合一次，形成 Dayflow 式纵向时间轴。

- **语言**: Swift / SwiftUI
- **目标平台**: macOS (Apple Silicon M5), macOS 14+ (Sonoma)
- **GitHub**: https://github.com/DearBobby9/voicemem
- **关联项目**: [VoiceMemory Python](../VoiceMemory/) — 完全独立，不共享代码; [Perch](../Perch/) — 未来集成目标（视觉+听觉记忆融合）
- **详细调研**: [PROJECT_PLAN.md](./PROJECT_PLAN.md) — 竞品分析、硬件调研、ASR 模型对比、HCI 学术参考

### 核心哲学

1. **只录声音** — 不录屏幕，VAD 过滤 70-80% 静音
2. **原始数据临时，AI 结果永久** — 音频可配保留期，转录文本 + 15 分钟聚合永久
3. **全本地** — 所有处理在本机完成，数据不出设备
4. **轻量后台** — <1% CPU, <675MB RAM, <1W 功耗
5. **插件化扩展** — 核心只做采集+转录+聚合+存储，AI 总结/润色/搜索都是插件

## Architecture

```
┌─ Core Pipeline (always-on) ──────────────────┐
│                                               │
│  AVAudioEngine (16kHz mono)                   │
│       │                                       │
│       ▼                                       │
│  Silero VAD CoreML (ANE, <0.5W)               │
│       │ 检测到语音                              │
│       ▼                                       │
│  音频切段 + FLAC/CAF 编码                       │
│       │                                       │
│       ▼                                       │
│  WhisperKit (ANE, 0.3W/pass)                  │
│       │                                       │
│       ▼                                       │
│  SQLite transcriptions (raw)                  │
│       │                                       │
│       ▼ 每 15 分钟                             │
│  SummaryAggregator → SQLite summaries         │
│                                               │
└───────────────────────────────────────────────┘
         │
    ┌────┼─────────────┐
    ▼    ▼             ▼
  主窗口  CLI 工具      插件层
  (时间轴) (AI Agent)  (LM Studio 总结/润色/Embedding)
```

### 三层接口

| 接口 | 用户 | 说明 |
|------|------|------|
| **主窗口** (Dayflow 式时间轴) | 人 | 纵向时间轴，每 15 分钟一个 block |
| **CLI 工具** (`voicemem`) | AI Agent | JSON 输出，可包装为 Claude Code Skill |
| **SQLite 文件** | 插件 | 直接读写 db，可选 localhost HTTP API |

### Tech Stack

| Component | Technology | Key Detail |
|-----------|-----------|------------|
| Audio capture | AVAudioEngine | 16kHz mono, callback mode, 设备切换通知 |
| VAD | Silero VAD CoreML (FluidAudio) | ANE, 4.3MB, 亚毫秒级 |
| ASR | WhisperKit (SPM) | ANE, large-v3-turbo 量化, ~632MB, 流式输出 |
| Database | GRDB.swift (SQLite WAL) | FTS5, Unix epoch ms timestamps |
| UI | SwiftUI | Menu bar + Main window (时间轴) |
| Auto-update | Sparkle | 标准 macOS 更新框架 |
| Login item | SMAppService | macOS 13+ 推荐 |
| Package manager | Swift Package Manager | 纯 SPM, 无 CocoaPods |

### Key Design Decisions

- **WhisperKit over Qwen3-ASR** — 纯 Swift SPM, ANE 运行, 零外部依赖; 中文精度 ~10% CER 是妥协但够用 (关键词基本正确)
- **GRDB over Core Data** — 需要 SQL 窗口函数、FTS5、精确控制 schema
- **15 分钟聚合 (Dayflow 模式)** — MVP 做纯文本拼接，Plugin 做 AI 总结; summaries 表预留 summary_text 字段
- **SQLite 文件就是插件接口** — 插件直接读写 db, 无需 IPC; 可选暴露 localhost HTTP API
- **CLI 工具是一等公民** — `voicemem` CLI 输出 JSON，可被 Claude Code Skill / Perch Chat / 其他 AI Agent 调用
- **FLAC/CAF 原生编码** — AVAudioFile / ExtAudioFile, 不引入第三方
- **ANE 优先** — VAD + ASR 全跑 ANE, 功耗 <1W, CPU 占用 <1%
- **不依赖网络/Python/LM Studio** — 核心 App 纯本地 Swift, AI 总结通过插件可选接入
- **Dayflow 设计借鉴** — 原始数据滚动删除 + AI 结果永久保留 + 15 分钟窗口 + GRDB + Sparkle
- **Core/ 不依赖 UI/App 生命周期** — 纯业务逻辑 + async API，为未来抽取 VoiceMemKit Swift Package 做准备（Perch 集成路径）
- **MVP 阶段独立于 Perch** — 先作为独立 App 开发验证 pipeline；Perch 可通过读 SQLite 桥接；长期目标是抽 VoiceMemKit Package 让 Perch import

## Commands

```bash
# Build from terminal
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme VoiceMem -configuration Debug build

# Run the built app
open ~/Library/Developer/Xcode/DerivedData/VoiceMem-*/Build/Products/Debug/VoiceMem.app

# Or use Xcode directly
open VoiceMem.xcodeproj
# Cmd+R to build & run

# Kill all VoiceMem processes before rebuild
pkill -f "VoiceMem" 2>/dev/null || true
pgrep -fl "VoiceMem" || echo "No VoiceMem processes"

# CLI tool (after build)
voicemem today                              # 今天所有 summary blocks
voicemem search "API 设计"                   # FTS5 搜索
voicemem range 14:00 16:00                   # 时间范围查询
voicemem summary 2026-03-16 14:00            # 某个 15 分钟窗口详情
voicemem stats                               # 统计信息
```

No tests or linting configured yet.

## Project Structure

```
voicemem/
├── PROJECT_PLAN.md              # 详细调研与计划 (竞品/硬件/ASR/架构)
├── CLAUDE.md
├── .gitignore
├── VoiceMem/
│   ├── App/                     # 入口、生命周期
│   │   └── VoiceMemApp.swift
│   ├── Core/                    # 业务逻辑 (不依赖 UI, 未来可抽 Package)
│   │   ├── AudioCaptureManager.swift    # AVAudioEngine + 设备管理
│   │   ├── VADManager.swift             # Silero VAD CoreML
│   │   ├── TranscriptionManager.swift   # WhisperKit 封装
│   │   ├── SummaryAggregator.swift      # 15 分钟聚合逻辑
│   │   └── DatabaseManager.swift        # GRDB SQLite
│   ├── Models/                  # 数据模型 (纯 Codable, 不依赖 UI)
│   │   ├── Transcription.swift
│   │   ├── Summary.swift
│   │   └── AudioSegment.swift
│   ├── Views/                   # SwiftUI UI
│   │   ├── MenuBarView.swift            # Menu bar icon + popover
│   │   ├── TimelineView.swift           # Dayflow 式纵向时间轴
│   │   ├── MainWindowController.swift   # 主窗口管理
│   │   └── SettingsView.swift
│   ├── System/                  # 系统集成
│   │   ├── LoginItem.swift      # 开机启动
│   │   ├── Permissions.swift    # 麦克风权限
│   │   └── SleepWake.swift      # 合盖/唤醒处理
│   └── Utilities/
│       ├── AudioEncoder.swift   # FLAC/CAF 编码
│       └── StorageCleanup.swift # 音频文件清理
├── VoiceMemCLI/                 # CLI 工具 (AI Agent 接口)
│   └── main.swift
├── VoiceMemTests/
└── Package.swift / VoiceMem.xcodeproj
```

## SQLite Schema

```sql
-- 原始转录 (每个 VAD 语音段一条)
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

CREATE INDEX idx_transcriptions_timestamp ON transcriptions(timestamp_start);

-- 15 分钟聚合 (Dayflow 模式)
CREATE TABLE summaries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    window_start INTEGER NOT NULL,       -- 15 分钟窗口起始, Unix epoch ms
    window_end INTEGER NOT NULL,
    raw_text TEXT NOT NULL,              -- 拼接的原始转录 (MVP)
    summary_text TEXT,                   -- AI 总结 (Plugin 填充, 可空)
    transcription_count INTEGER NOT NULL,
    model TEXT,                          -- 总结用的模型 (null = 纯聚合)
    created_at INTEGER NOT NULL
);

CREATE INDEX idx_summaries_window ON summaries(window_start);

-- FTS5 全文搜索
CREATE VIRTUAL TABLE transcriptions_fts USING fts5(
    text,
    content='transcriptions',
    content_rowid='id',
    tokenize='trigram'
);
```

SQLite PRAGMAs (apply at connection time):
```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA cache_size = -64000;
PRAGMA temp_store = MEMORY;
PRAGMA mmap_size = 268435456;
PRAGMA foreign_keys = ON;
```

## Resource Budget (M5 MacBook Pro 24GB)

| Component | Memory |
|-----------|--------|
| Swift App | ~50 MB |
| Silero VAD CoreML | ~5 MB |
| WhisperKit 量化模型 | ~600 MB |
| SQLite | ~20 MB |
| **Total** | **~675 MB (~3%)** |

| State | Power |
|-------|-------|
| No speech (VAD listening) | <0.5W |
| Speech (VAD + ASR) | ~1W |
| Daily average | **<1W** |

## Development Phases

- **MVP**: Pipeline + Menu bar + Main Window (Dayflow 时间轴) + 15 分钟聚合 + Settings + 系统集成
- **Phase 1**: CLI 工具 (`voicemem`) + Claude Code Skill + FTS5 搜索
- **Phase 2**: LM Studio 总结 plugin + 润色 + Embedding
- **Phase 3**: Daily summaries, speaker diarization, NER
- **Phase 4**: RAG Chat, Perch 集成 (VoiceMemKit Package), Dayflow 集成, VoiceMemory Python sync

## CLI Tool Design

```bash
voicemem today                              # 今天所有 summary blocks (JSON)
voicemem search "关键词"                     # FTS5 全文搜索
voicemem range 14:00 16:00                   # 时间范围
voicemem range 2026-03-16 14:00 16:00        # 指定日期+时间范围
voicemem summary 2026-03-16 14:00            # 某个 15 分钟窗口详情
voicemem stats                               # 统计 (今日条数, 总条数, 存储)
voicemem status                              # 录制状态
```

输出格式 (JSON):
```json
{
  "window": "2026-03-16T14:00/14:15",
  "raw_text": "我觉得REST比较好...",
  "summary_text": null,
  "transcription_count": 5,
  "transcriptions": [
    {"time": "14:02:30", "text": "我觉得 REST 比较好...", "duration_ms": 3200},
    {"time": "14:05:10", "text": "GraphQL 太复杂了...", "duration_ms": 2800}
  ]
}
```

Phase 1 完成后包装为 Claude Code Skill:
```
voicemem-recall: 查询用户的语音记忆。用于回答"我之前说过什么"、"今天讨论了什么"。
```

## Mandatory Workflows

### After Writing or Modifying Code (Post-Implementation，强制)

每次写完或改完代码，必须按顺序执行以下步骤，不可跳过：

1. **Code Review**: 启动 `superpowers:code-reviewer` agent 自动 review 所有改动
2. **修复**: 按 Critical / Important / Suggestion 分级输出，**必须修复所有 Critical 和 Important**，Suggestion 视情况处理
3. **中文汇报**: review + 修复完成后，用中文向用户汇报：
   - 改了哪些文件、改了什么
   - Code review 摘要（发现了什么问题、怎么修的）
   - 测试指南（用户怎么验证这些改动）
   - APP 可见变化（用户能感知到的行为变化，没有就写"无"）

### After Every Git Push

**You MUST update both:**
1. **CLAUDE.md** — if architecture, tech stack, or project structure changed
2. **Memory files** (`~/.claude/projects/.../memory/`) — save stable patterns, decisions, and debugging insights learned during the session

### Plan Mode: Persist After Planning — 死规矩

**列完计划后，必须先更新所有文档，然后才能 ExitPlanMode 让用户接管。** 用户会在 approve 后清空上下文，下一个 Claude 实例没有对话历史。

必须按顺序更新：
1. **CLAUDE.md** — 如果计划涉及架构、技术栈、端点、项目结构变化
2. **Memory files** (`~/.claude/projects/.../memory/`) — 写入计划摘要、当前阶段、决策要点、下一步实现步骤
3. **Plan file** — 确保自包含（新实例无需对话上下文就能理解并执行）

**只有以上全部完成后，才可以调用 ExitPlanMode。**

### Logging Convention

```swift
import os
private let logger = Logger(subsystem: "com.voicemem.app", category: "AudioCapture")
logger.info("[AudioCapture] VAD detected speech segment: \(durationMs)ms at \(timestamp)")
logger.error("[AudioCapture] Device disconnected: \(deviceName)")
```

## Swift Conventions

- Use `@Observable` (macOS 14+) over `ObservableObject`
- Prefer `async/await` over completion handlers
- Use `Codable` for all persistence models
- Apple-native look: SF Symbols, system fonts, vibrancy materials
- One type per file (unless closely related helper types)
- Group by layer: App/, Core/, Models/, Views/, System/, Utilities/
- All scripts use `[ClassName]` prefix in logs
- **Core/ and Models/ must NOT import SwiftUI** — keep UI-independent for future Package extraction

## Local Data

All stored under `~/Library/Application Support/VoiceMem/`:
- `voicemem.db` — SQLite database (transcriptions + summaries + FTS5)
- `audio/` — FLAC/CAF audio segments (configurable retention: 7/30/永久 days)

## Plugin Extension Directions

| Plugin | Priority | Dependency | Interface |
|--------|----------|-----------|-----------|
| CLI Tool (`voicemem`) | P0 (Phase 1) | None | SQLite query → JSON |
| Claude Code Skill | P0 (Phase 1) | CLI | Skill wraps CLI |
| LM Studio 总结 | P1 (Phase 2) | LM Studio | localhost HTTP → 填充 summaries.summary_text |
| Precision (Qwen3-ASR) | P1 | LM Studio | localhost HTTP |
| LLM Polish | P1 | LM Studio | localhost HTTP |
| Embedding (bge-m3) | P1 | LM Studio | localhost HTTP |
| Daily Summary | P2 | LM Studio | localhost HTTP |
| Speaker Diarization | P2 | FluidAudio | CoreML ANE |
| NER | P2 | Apple NLTagger | System framework |
| RAG Chat | P3 | LM Studio + Embedding | localhost HTTP |
| **Perch Integration** | P4 | Perch App | SQLite cross-read → 未来 VoiceMemKit SPM |
| Dayflow Integration | P4 | Dayflow App | SQLite cross-read |
| VoiceMemory Sync | P4 | Network + Python server | HTTP POST |
| Apple Foundation Models | P4 | macOS 26 | ANE, 替代 LM Studio 总结 |
