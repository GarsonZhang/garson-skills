---
name: fnos-music-organize
description: 把飞牛(fnOS) NAS 上杂乱的音乐下载目录按艺人整理归档（如 ro-music-download 整理到 Music2）。当用户要求「整理某目录的音乐放到 XX」「按艺人分目录归档音乐」「ro-music-download 音乐归位」时使用。整理规则：tag、文件名、beets 三级取信息；按首位艺人分目录（多艺人经网易云 musicSize 裁决切分）；同曲保留最高音质；干跑先行、残缺件人工确认。
agent_created: true
---

# 飞牛音乐整理（按艺人归档）

把 NAS 上一个杂乱的音乐目录（典型：RO 音乐服务下载区 `ro-music-download`）按艺人分目录整理到目标目录。是 `fnos-cue-beets-import` 的姊妹技能——那个管「beets 库导入」，**本技能管「不经 beets、直接整理落盘」**。

## 前置

- SSH 连接名 `fnos`（garson@192.168.88.129:22），命令走 ssh-mcp 的 `execute-command`，脚本 `upload` 到 `/tmp/a3/`。
- NAS 上需 `ffprobe`（ffmpeg 自带）与 Python 3；判重需 `zhconv`（已装）。
- **目标目录必须先 `ls` 确认是否已存在、里面有什么**（坑 #101：用户提一个目录名不要按字面新建）。

## 整理规则（老张 2026-10-10 定，默认规则）

| # | 规则 | 实现位置 |
|---|---|---|
| 1 | 取数优先级：**文件 tag > 文件名「歌名 - 艺人」 > beets** | `music_organize.py` survey |
| 1b | **tag 含 U+FFFD（坏编码）或为空 → 强制回退文件名**。否则会生成乱码目录名，且不同文件的乱码 title 撞车导致误判重复 | survey |
| 2 | 目录结构：`<目标>/<首位艺人>/<原文件名>`；无艺人 → `未知艺术家/` | plan |
| 3 | 多艺人取首位：顿号「、」与 feat/ft./with/×// 直接切；`&`/`and`/`,` 走网易云 `musicSize>=100` 裁决（乐队名保留整串，如 Hillsong Young & Free） | `artist_split.py` + `nc_verdict.py` |
| 4 | 同曲重复：归一化 `(曲名, 首位艺人)` 判重，**保留音质最好**（无损>采样率>位深>码率>体积；绝不按体积排，坑 #81） | plan |
| 5 | 搬运用 `os.rename`（同盘 mv），保留属主/权限/时间戳 | apply |
| 6 | **执行前必查与目标的冲突**（os.rename 目标存在时 POSIX 静默覆盖）：同名同一文件→删源；同名不同内容→**按音质参数裁决，参数最高者留，参数相同留体积最大者**（无损>采样率>位深>码率>体积；赢的可能是库内旧文件，此时删源）；同曲不同名（flac-vs-mp3）→ 同一套音质参数对比，源好替换/库好删源 | `dest_conflict_check` |

## 工作流（必须按序，不得跳过干跑）

### 第 1 步：盘点（只读）

```
upload scripts/ 全部 4 个文件到 NAS /tmp/a3/
execute: ls -la <源目录>，摸清文件数、命名格式
execute: cd /tmp/a3 && python3 music_organize.py --src <源目录> --dst <目标目录>
```

干跑即盘点：输出疑似残缺件（<15s 且 ≤128k，**只警告不自动删**）、多艺人切分明细、重复项清单，并落 `/tmp/a3/plan.json`。

### 第 2 步：向用户确认两件事

1. **残缺件处置**：列出警告清单，问「删 / 留原位 / 归档标记」。无替补的删除是不可逆的，必须显式确认。
2. **多艺人切分异常**：`nc_verdict` 查不到的素人名字会整串保留；把切分清单给用户过目（老张对目录名是否像艺人很敏感）。

### 第 3 步：执行

```
execute: cd /tmp/a3 && python3 music_organize.py --src <源目录> --dst <目标目录> --apply
```

如需删除残缺件，用 `rm` 前先在对话里给出完整清单并获得确认。

### 第 4 步：收尾校验 + 报告

```
ls -A <源目录> | wc -l        # 应为 0（全部搬走）
find <目标> -type f | wc -l     # 文件数守恒：源 N = 搬运 + 删重复 + 删残缺
find <目标> -type d -empty      # 空目录应为 0
```

抽查 2-3 个文件的 tag（`ffprobe -show_entries format_tags`）确认搬运无损。产出一份中文执行报告（用户偏好：结论表先行、处置明细、校验数据）。

## 下载源质量坑（实测，干跑阶段要重点看）

| 现象 | 识别 | 处置 |
|---|---|---|
| **FLAC 被标签写入写坏** | 服务端任务 `completed_with_warnings`；警告 `标签嵌入失败: Attempt to access memory outside buffer bounds`；`ffprobe: Invalid data found`，但文件头 `fLaC` 正确、全文件无零尾 | `scripts/fix_broken_flac.py` 重建（音频帧完好，可救）；先干跑再 `--apply` |
| **标签是乱码（U+FFFD）** | 典型是老的 Windows 抓轨（album 里带 `(2010/11/25 上午 …)`）。同一批多个文件的乱码 title 相同 → 误判重复 | 规则 1b 自动回退文件名 |
| **扩展名骗人** | `.mp3` 实际是 ogg/vorbis（看 `ffprobe format_name`） | 按"同曲保留最高音质"处理；与用户确认 |
| **文件名畸形** | `歌名 - 艺人 - 艺人 、 乐队`（多段 `-`）、专辑名混进 artist | 人工确认后再动，别硬切 |
| **截断音频** | 时长明显偏短（如 54 秒）、`<15s 且 ≤128k` | 残缺件只警告不自动删，须人工确认 |
| **音源把「A & B」写成「A 、 B」** | 顿号是"绝对切分"，会把一只乐队拆成两个目录 | 人工裁决；需要时用艺人覆盖表（见下）|

处理手段：所有删除动作**不 `rm`**，改为移入隔离区（如 `/vol2/1000/电影音乐/.deleted-YYYYMMDD/`），可回滚。

## 网易云裁决的硬约束

- **直连，禁走代理**（境外 IP 风控 → 0 候选）
- **限速 3.3s/次**；结果落盘 `nc_art_cache.json`，同批任务不重复请求
- **只认精确命中**（norm 归一后比 `name` 或 `alias`），**绝不取搜索 top1 兜底**（会大面积误判）
- 阈值 `musicSize >= 100` 为实测值：经典乐队/组合都 ≥246，合作串无整串条目

## 与相关技能的边界

| 场景 | 用哪个 |
|---|---|
| 杂乱目录直接按艺人整理到新目录（不进 beets 库） | **本技能** |
| 导入 beets 库（cue 整轨 / 分轨 / singleton，写 beets.db） | `fnos-cue-beets-import`（references/01） |
| 库内多艺人切分设计细节与 17 条回归用例 | `fnos-cue-beets-import`（references/11-artist-splitting.md），切分器逻辑相同 |

## resources

- `scripts/music_organize.py` — 主流水线（survey → plan → dry-run/apply）
- `scripts/artist_split.py` — 艺人切分器（顿号/feat 直接切 + 可疑分隔符召回）；`python3 artist_split.py` 跑 17 条回归用例，改完必跑
- `scripts/nc_verdict.py` — 网易云语义裁决（musicSize≥100 闸门 + 缓存 + 限速）
- `scripts/fix_broken_flac.py` — 修复被标签写入写坏的 FLAC（元数据块坏了、音频帧完好）；干跑默认，`--apply` 落盘，原件进隔离区
