# 库内「同一首歌存了多个格式」的去重

**场景**：`Music` 下同一个目录里，同一首歌同时存在 `xxx.flac` / `xxx.wav` / `xxx.wma` 等
多个封装格式，需要只保留一个最高质量的。典型来源是下载器落盘时格式不统一，
**不是重复导入产生的**（重复导入会走 beets 的 paths，不会同名并存）。

实测规模参考（2026-10-02）：全库 14067 个音频文件，命中 **97 组 / 195 个文件**；
其中 **65 组确认为同一录音**（可回收 2.03 GB），**32 组内容实质不同**（须保留）。

---

## 0. 先纠正一个直觉：**不能按体积挑大的**

| 格式 | 编码性质 | 16bit/44.1k 典型码率 | 标签 | 备注 |
|---|---|---|---|---|
| wav | 无损（未压缩） | ~1411 kbps | **基本没有** | 体积最大，但没有任何优势 |
| flac | 无损（压缩） | ~880 kbps | 完整 | 体积最小、标签全、跨端最好 |
| ape | 无损（压缩） | ~865 kbps | APEv2 | 兼容性差于 flac |
| wma | **有损** | ~107 kbps | 一般 | 体积最小、质量最差 |

按体积排会得出「wav 最大所以最好」的**错误**结论。正确顺序：
**无损 > 有损；同为无损时同规格下 flac > ape > wav（wav 无标签、体积大）。**

---

## 1. 扫描：同目录 + 同曲名 + 多扩展名

不需要 beets，纯文件系统扫描即可。用 `os.walk`，按
`(目录, 去掉扩展名后的曲名.strip().lower())` 分组，组内 ≥2 个文件即命中。

纳入比较的扩展名：`flac wav wma mp3 ape m4a aac ogg dsf dff wv opus aif aiff tak tta mpc`。
参考脚本：`s1_scan_dup.py`。

> 注意：本步只覆盖「同一目录、同名」。**跨目录的同曲不同格式**（同一首同时放在
> `歌手/` 和 `歌手/某专辑/`）不在范围内，需要另行扫描。

---

## 2. 读真实规格（ffprobe）

用 `ffprobe -show_entries stream=...` 拿 `codec_name / sample_fmt / sample_rate /
channels / bits_per_raw_sample / bits_per_sample / bit_rate / duration`。

要点：

- `codec_name` 决定无损与否：`flac/ape/alac/wavpack/tta/tak/dsd_*` 与 `pcm_*` 是无损。
- **wav 的位深常拿不到 `bits_per_raw_sample`**，要从 `codec_name`（`pcm_s24le` → 24）反解。
- **必须用 `subprocess.run([...])` 列表传参**，不要用 shell 循环喂路径（路径含空格/引号会被拆碎，
  直接产生假阳性 —— 见 pitfalls 47）。
- 参考脚本：`s2_probe.py`。

---

## 3. 判「是不是同一录音」——本任务的核心

### 3.1 主判据：RMS 能量包络互相关

```
ffmpeg -i FILE -f s16le -ac 1 -ar 8000 -        # 解码为 8kHz 单声道
→ 每 0.5 秒算一个 RMS → z-score 归一化 → 互相关（允许 ±100 秒偏移）
```

**为什么用包络而不是波形**：包络对**编码差异、声道相位、轻微变速**都不敏感，
只反映「能量起伏的节奏是不是同一段演奏」。实测有损 wma（107 kbps）与对应 flac
的包络相关也能到 **0.94–1.00**（例：杨钰莹《心雨》1.000、刘欢《亚洲雄风》0.975）。

### 3.2 辅助判据：时长比

同一录音在不同母版间通常差 **0–8 秒**（首尾静音长度、淡出长度不同）。
**时长比偏离 > 4% 就不再认为可去重**。实测分布：同源组 0–8 秒；
不同版本 40–152 秒（张镐哲《好男人》flac 2:46 vs ape 5:19 差 152 秒）。

### 3.3 判档阈值

| 档 | 条件 | 处置 |
|---|---|---|
| A 高置信同源 | env ≥ 0.95 且 时长比偏离 ≤ 4% | 归档多余副本 |
| B 同源 | env ≥ 0.85 且 偏离 ≤ 4% | 归档多余副本 |
| C 存疑 | env ≥ 0.75 或 偏离 4–6% | 人工确认 |
| D 疑似不同版本 | 其他 | **保留，不动** |

**实测：97 组里 32 组（33%）落进 C/D。也就是说「同名不同格式」有三分之一并不是重复。**
参考脚本：`s4_fingerprint.py`（包络）、`s11_plan.py`（分档 + 质量排序）。

---

## 4. 踩过的坑（都会静默给错结论）

| # | 坑 | 后果 | 正解 |
|---|---|---|---|
| 1 | **波形互相关不取绝对值** | 实测大量配对给出 **−0.98 / −0.97 / −0.92** 的强负相关（声道相位反转）。只看正值会把这些高置信同源判成「完全不同」 | 一律用 `abs()`，`|corr|` 才是同源度量 |
| 2 | **用 PCM 逐位比对（MD5）判同源** | 看似最严谨，实际全部失败：99 个无损对里逐位一致率 ~0.0001。不同母版之间有**电平/重采样差异**，PCM 必然不等 | 放弃逐位比对，改用归一化相关 |
| 3 | **用长窗（40 秒）做波形相关** | 对**速度差极敏感**：40 秒内漂移 0.2 秒（0.5% 速度差）相关即归零，把同源误判成不同源 | 要么用 5 秒短窗，要么直接用 RMS 包络 |
| 4 | 把「时长差」一律当作不同版本 | 同源母版差 3–8 秒很常见，直接判不同会漏掉大量重复 | 用**时长比**（4%）而不是绝对秒数 |
| 5 | 用 shell 循环 / `xargs` 喂路径给 ffprobe | 含空格、`$`、连续空格的路径被二次解析 → 假阳性 | `subprocess.run([...])` 列表传参 |
| 6 | `nohup python3 x.py &` 后台跑 | **经 ssh-mcp-server 起的后台进程在会话结束时被回收**，输出文件根本不会生成 | 前台跑（`cmdString` 加长 timeout），或 `setsid` 完全脱离 |
| 7 | 直接 `rm` 多余格式 | 判错就永久丢文件 | `mv` 到 `_media_archive/`，**归档不直删** |
| 8 | 归档完不清 beets 记录 | 实测**待归档文件 100% 已在库中登记**，不清会留孤儿记录，播放器仍显示已删曲目 | 归档后按 path 清理 items 记录 |

补充环境事实：NAS 上**没有 fpcalc / chromaprint**（音频指纹不可用）；
有 `numpy 1.24.2`（自算包络/FFT 够用）、`ffmpeg/ffprobe 8.1.1`、`python3 3.11.2`。

---

## 5. 质量排序（决定保留谁）

```python
def qkey(f):
    tier = 3 if f['lossless'] else 2          # 无损优先
    return (tier, f['bits'], f['sample_rate'],  # 位深 → 采样率
            FMT_RANK.get(f['codec'], 5),         # 格式偏好
            f['bit_rate'], f['size'])
```

`FMT_RANK`：`dsd_* 90 / flac 60 / alac 55 / wavpack 50 / ape 40 / tta,tak 30 /
pcm_* 25 / mp3 20 / aac,vorbis,opus 18 / wmapro 15 / wmav2 10`。

**顺序很重要**：`FMT_RANK` 必须排在 `bit_rate` 之前，否则 wav（1411 kbps）
会把同规格的 flac（880 kbps）挤掉。

效果：同规格 flac/wav → 留 flac；flac/ape → 留 flac；ape/wav → 留 ape；flac/wma → 留 flac。

---

## 6. 执行（归档，不是删除）

**实测一次完整执行：2026-10-02，65 组 / 65 个文件 / 2.03 GB**

```
1) 备份 beets.db → _db_backups_archive/beets.db.bak.dupdedup-<时间戳>
2) 生成 manifest：每个待归档文件的 path / size / md5 → 可据此恢复
3) mv 到 _media_archive/dup_format_<日期>/，保留原目录结构
4) 清理 beets 库中对应 items 记录（只动库不动盘）
5) 双向校验：items.path 都存在 · Music 下无孤儿 · 空目录 0 · 无曲专辑 0
```

### 6.1 beets 删记录的正确姿势

表结构：`items` / `item_attributes` / `albums` / `album_attributes`。

- 一次性 `select id, path, album_id from items` 建 `path → (id, album_id)` 映射，
  **按 id 删**。不要拿 str 直接 `where path=?` —— `path` 是 **BLOB**（坑 70），
  且 str→bytes 往返可能因编码归一化对不上。
- 删 `items` 必须**级联删 `item_attributes`**（`entity_id = item.id`），否则留垃圾属性行。
- **孤儿专辑只清「本批次涉及的 album_id 里、删空了的」**，绝不做全库孤儿扫描删除 ——
  库里可能本来就有历史孤儿，全局删会误伤。
- 事务：`con.isolation_level = None`，手动 `BEGIN` / `COMMIT`。
- 实测：65 条 items 移除后，`14091 → 14026`，孤儿专辑 **0**（本批涉及的两个专辑都还有剩余曲目）。

### 6.2 两个操作细节

- 归档目录**用 Python `os.makedirs` 建**，不要 `sudo mkdir`（后者属主变 root，事后还要 `chown -R garson:Users`）。
- `os.rename` 同分区（`Music` 与 `_media_archive` 都在 `/vol2`）秒完成；
  **每移一个立刻复核**（原位置没了 + 目标存在 + 大小一致），错了就 `sys.exit` 停，
  别等一批移完再统一查。

### 6.3 先出方案报告、拿到确认再动手

涉及移动文件 + 改数据库，属危险动作。报告含：分档结论、逐组保留/归档、
完整待归档清单、执行步骤、回滚依据。

### 6.4 App 侧确认方法（不用重启、不用重扫）

```bash
grep OnFileMovedOut /usr/local/apps/@appdata/trim.music/log/info.log | tail -70
# 条数应与归档数完全一致；再确认 error.log 的最后错误时间早于本次操作
ls --time-style=full-iso -l /usr/local/apps/@appdata/trim.music/log/error.log
```

实测 65 个文件 → **65 条 `OnFileMovedOut`**（01:59:39–01:59:44），
该时间窗内只有心跳、无其他事件；`error.log` 最后错误早于操作 14 分钟（转码心跳参数校验噪声，历史遗留）。

### 6.5 收尾留意：历史失效记录

库内常存在**历史遗留的、指向不存在文件的 items 记录**（实测 9 条）。它们不在本批次范围内，
**不要顺手删** —— 先列出来让用户确认。

用户确认后可一并清理，做法：

- **删盘范围只在归档区**（`_media_archive` / `已转换专辑`）按**同名匹配**找残留，
  并且**把本次归档目录设成保护路径**（`dp.startswith(PROTECT)` 就跳过），避免误删刚要保留的副本。
- 实测 9 条记录里只有 **1 条**在归档区有实体文件（乱码目录里的 `01 冰雨.wav`），
  其余 8 条文件确已不存在 —— 所以「清磁盘」往往只删掉一个文件。
- 空目录逐级 `os.rmdir`（空才删成功），**绝不用 `rmtree`**（见 05-recovery 的 33 文件事故）。
- 删完校验：库内指向不存在文件的记录 **0**、孤儿专辑 **0**。
- 实测效果：items `14026 → 14017`，albums `3004 → 2997`（顺带清理掉 7 个删空的专辑）。

顺带记录一个环境事实：`_media_archive` 归档区的体积可能很大（实测 **596 GB**，
其中 553 GB 是车载U盘源素材、21 GB 伍佰源副本、18 GB 已在库专辑）。
**清理范围一定要跟用户确认到具体目录，不要按「归档区」整片删。**

---

## 7. 脚本清单（/tmp/a3/，本地同名副本在会话工作区 `fnos_dedup/`）

| 脚本 | 作用 |
|---|---|
| `s1_scan_dup.py` | 扫同目录同名多格式组 |
| `s2_probe.py` | ffprobe 读真实规格 + 初次质量打分 |
| `s3_duration.py` | 时长/码率聚合，看差异规律 |
| `s4_fingerprint.py` | RMS 包络互相关（结果缓存 `/tmp/a3/envs/*.npy`） |
| `s5_verdict2.py` | 双指标判定（含线性重采样对齐） |
| `s7/s8/s9_*.py` | 波形级交叉验证（长窗 / 短窗 / 变速对齐）——**注意上面第 1、3 条坑** |
| `s10_dump.py` | 导出全部指标 + 阈值扫描 |
| `s11_plan.py` | 分档 + 质量排序 + 核对 beets 登记 |
| `s12_report.py` | 生成 Markdown 方案报告 |
