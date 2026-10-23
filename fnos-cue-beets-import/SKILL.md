---
name: fnos-cue-beets-import
description: 飞牛(fnOS) NAS 上 beets 音乐库批量运维的总入口——通过 SSH 执行 CUE 整轨分割、分轨/散曲/整轨入库、专辑归并重组、标签与封面清洗、流派修正、本地歌词补全、全库自检与事故恢复。当用户提到飞牛/fnOS 音乐库整理、CUE 分割、整轨转单曲、ffcuesplitter、beets 批量导入、ape/flac 整轨拆分、GBK 中文乱码、cue 与音频文件名不一致、音乐批量入库、音乐标签清洗、封面水印、流派乱码或流派为空、专辑去重合并、m3u 播放列表、音乐库全库自检、飞牛音乐没歌词/歌词缺失、批量补 .lrc、歌词抓取、同一首歌存在多个格式/同名不同格式去重/只保留最高音质时使用。
agent_created: true
---

# 飞牛(fnOS) beets 音乐库批量运维

用 `ssh-mcp-server` 连飞牛终端，对音乐库做「扫描 → 分割 → 导入 → 清洗 → 自检 → 归档」全链路处理。

**本文件是总入口**：先看环境事实与红线，再按「按任务读对应文件」的导航跳到 reference。
详细步骤、脚本、108 条实测坑都在 `references/` 下 —— **不要凭记忆猜，先读再动手**。

---

## 前置

```
mcp__ssh-mcp-server__list-servers     # 确认连接名
```

本环境为 `fnos`（garson@192.168.88.129:22）。命令走 `mcp__ssh-mcp-server__execute-command`，
参数是 **`cmdString`** + `timeout`（毫秒）；上传脚本用 `mcp__ssh-mcp-server__upload`
（`localPath` / `remotePath`）。支持多行与 heredoc。

**工作方式**：本地写脚本 → upload 到 NAS `/tmp/a3/` → 远端执行 → 拉输出。
本地脚本目录：`C:\Users\garso\WorkBuddy\2026-09-28-22-19-05\cue_tool_work\`

---

## 环境事实（实测，别凭猜）

| 项 | 值 |
|---|---|
| 系统 | Debian 12 bookworm / x86_64 |
| locale | `en_US.UTF-8` |
| ffcuesplitter | `~/ffcuesplitter_env/bin/ffcuesplitter` v1.0.31，有 `-ce` |
| beet | `/usr/bin/beet` v1.6.0（Python 3.11.2） |
| beets 配置 | `directory=/vol2/1000/电影音乐/Music`；`library=/vol2/1000/电影音乐/beets.db`；`paths.default=$albumartist/$year $album/$track $title` |
| import 行为 | **`copy`（默认）** → 导入即复制到 Music 下套用 paths，源文件保留 |
| `flac` 命令 | 未装，**不需要**（ffmpeg 自带 flac 编码器） |
| 源目录 | `/vol2/1000/电影音乐/音乐` |
| 归档区 | 源 → `已转换专辑/`；库内冗余件 → `_media_archive/`；旧备份 → `_db_backups_archive/` |
| 库规模 | items ≈ 12306 / albums ≈ 1426（2026-10-01） |
| Python 依赖 | `zhconv` 已装（简繁归一，**调用要带 locale**：`convert(t, 'zh-cn')`） |
| iTunes API | **流派数据源**：免 key、国内直连；`country=us`（`cn` 返回 0 条）；**官方限速约 20 次/分钟且按 IP 计**，实测 3.3s 间隔安全。⚠️ **单曲匹配必须再校验返回的 `artistName`**，只比曲名会产生 15~20% 同名误配。完整用法见 `references/03-cleanup.md` 的 **24.13**（数据源选型 + 限速细节）、**Phase 25**（批量补齐）与 **25.11**（命中校验闸门） |

---

## 绝对不要做（红线）

- 不要给 `beet import` 加 `-A`（那是 `--noautotag`，等于关掉匹配）
- 不要把 `beet import -p` 当干跑
- 不要用 `$?` 判断 beet 导入成败
- 不要转码/覆盖原 cue
- 不要用 `pkill -f cue_job.sh` 停任务（命令行含同串会自杀）—— 用 `kill $(cat /tmp/cue_job.pid)`
- 不要未经确认删除源文件、`_split`，或执行 `beet remove -d`
- **不要在缺少「库内轨数 == `_split` 轨数」校验时删源**（库可能只写了一半，删了就没了）
- **不要直接 `rm` 整轨母版** —— 归档走 `mv`；母版是换版本 / 重新匹配的唯一退路
- **回滚脚本里不要用 `shutil.rmtree`** —— 只删「库里登记过」的文件，目录只在删空后 `os.rmdir`
- **给 WAV 写标签不要用 `mutagen.id3.ID3(path)`** —— 会把 ID3 写到 RIFF 头之前，文件直接读不了
- **自动化任务的 prompt 里不要出现「脚本名 + 执行动词」** —— 会被理解成"去执行它"。
  本项目实测：一个只读的进度汇报 automation 因 prompt 里写了
  「下一步跑 `a11_apply.py`」，把写库脚本真跑了一遍（Phase 26）。

---

## 按任务读对应文件

| 我要做什么 | 读哪个 |
|---|---|
| 把一批源目录导入库（cue 整轨 / 分轨 / 散曲 / 无曲目表整轨） | `references/01-import.md` |
| **把「歌手单曲集」批量入库**（顶层真单曲 singleton + 子目录附赠 EP，含替换库内旧 mp3） | `references/01-import.md` 的 **Phase 14** |
| 合并重复专辑、整理专辑结构、处置源素材区 | `references/02-restructure.md` |
| **把一整批「歌单式合集」逐曲归入原专辑批量入库**（含艺人名映射 / 去重口径） | `references/02-restructure.md` 的 **Phase 28** |
| 清理或修正标签、封面、流派（含 WAV 的 `LIST/INFO`、**用 iTunes API 查流派 / 批量补齐**） | `references/03-cleanup.md` |
| 跑匹配预检、生成 m3u、批次归档、全库自检 | `references/04-quality.md` |
| **飞牛自带「音乐」App 扫描显示「失败 N 项」、且不给原因**（App 侧故障，非 beets） | `references/06-music-app-scan.md` |
| **库内文件属主/权限不符（如 `xunlei-app` + `666`）**、判断文件是否已在 beets 库、评估 MB 重匹配是否值得 | `references/07-legacy-files-normalize.md` |
| **批量补本地歌词（`.lrc`）、飞牛 App 里大量歌没歌词** | `references/08-lyrics.md` |
| **同一首歌存了多个格式（flac/wav/ape/wma 并存），只留最高质量的那个** | `references/09-dup-format-dedup.md` |
| **车载U盘倒卖合集这类「一个源目录几万个音频」想清洗后另存**（识别劣质特征 / 命中率预检 / 文件名重建标签 / 网易云批量查） | `references/10-car-collection-cleanup.md` |
| **按艺人分目录、artist 字段是多艺人串（`A、B` / `A & B` / `A feat. B`）要取首位** | `references/11-artist-splitting.md` |
| 回滚、恢复误删，或**写任何删除类脚本之前** | `references/05-recovery.md` |
| 查某条具体的坑 / 看完整 103 条索引 | `references/pitfalls.md` |

---

## 最致命的几条坑（完整见 pitfalls.md）

| # | 坑 | 后果 |
|---|---|---|
| 1 | `beet import -A` 其实是 `--noautotag` | 整批任务在错误参数下白跑 20 分钟 |
| 15 | 散装合集的 MB 误配 | 上千首歌被写成同一个**假艺人** |
| 21 | `albumartist` 为空 | 音乐「消失」在 `Music/_/` 和 `Music/__/` |
| 22 | `beet update` **会移动文件** | 不只是回写字段，路径会被改 |
| 47 | 用 shell 循环 / `xargs` 把路径喂给 `ffprobe` 做全库体检 | 路径含 `"`、`$`、连续空格时被 shell 二次解析 → **假阳性**（实测虚报 6 个坏文件）。必须用 Python `subprocess.run([...])` 列表传参 |
| 48 | 拿**相对路径**比 beets 库的**绝对路径** | 0 匹配 → 误判"文件全是黑户"，选错整条处理路线（实测把 577 个已在库的文件当成未入库） |
| 49 | 以为 `beet import -P`（pretend）是只读 | 预览**也会写库**（实测 2 条 item id 被重建）。预览前必须先备份 `beets.db` 并做 id 级 diff |
| 50 | `beet import` 非交互环境不接 stdin | 卡在 `Enter one of 1-5...`，**并吃掉 while 循环的 stdin** 导致只处理 1 张专辑。须加 `-q` 且 `< /dev/null` |
| 51 | 命令里出现要 `pgrep/pkill` 的真实字符串 | 匹配到自身 → 自杀（SIGTERM）。连 `echo "beet 残留"` 都会中招；须把匹配串放进脚本文件执行 |
| 52 | 读 MP3 标签不用 `mutagen` 的 `easy=True` | ID3 键是 `TIT2/TPE1/TALB`，直接读 `tags.items()` 会全部误判为空（实测虚报 233 个"标签不一致"） |
| 54 | 回滚脚本用 `rmtree` | 误删 37 个库内老文件，其中 2 个永久丢失 |
| 57 | 给 WAV 写标签用 `ID3(path)` | 文件变 `invalid start code ID3[4] in RIFF header`，35 个被写坏 |
| 70 | `items.path` 是 **BLOB** 列 | `where path=?` 传 str 永远匹配不上 |
| 72 | 一个 WAV 里有**三套元数据** | 播放器读哪套决定你看到什么，只改一套不够 |
| 73 | 比对歌词/标题时不处理**简繁** | 源站返回繁体（`張靚穎`）→ 全部误判"无命中"，命中率归零 |
| 74 | 艺人字段**整体**比对（如「张洪量莫文蔚」） | 无分隔符串永不匹配，大面积假阴性 |
| 75 | 用网易云**老接口** `/api/search/get/web` | 只返回翻唱；须用 `cloudsearch/pc` |
| 76 | 网易云**走代理** | 境外 IP 风控 → 0 候选（与 LRCLIB 正好相反，必须**直连**） |
| 77 | 抓取代理**复用同一 IP** | 被目标站记住 → 503 增多、速率降 5 倍；须**一次一取** |
| 78 | 补完 `.lrc` 不做**路径映射校验** | 已删曲目的歌词变成**孤儿文件** |
| 79 | 判「同曲多格式是否同一次录音」**用波形相关却不取绝对值** | 相位反转的配对给出 **−0.98** 的强负相关，被误判成「完全不同」（实测 9 组中招） |
| 80 | 用**长窗（40s）波形相关**判同源 | 0.5% 速度差即让相关归零，同源被误判成不同源；改用 RMS 包络（见 09） |
| 81 | **按体积**挑「最高质量」 | wav 未压缩体积最大却无标签，会把 flac 挤掉；另「同名不同格式」有 1/3 并非重复（见 09） |
| 82 | 用 `nohup ... &` 起后台长任务（经 ssh-mcp-server） | **会话结束进程被回收**，日志与输出文件根本不生成。须 `setsid nohup ... < /dev/null &`，并确认 `ps` 的 TTY 列是 `?` |
| 83 | 数 beets `-q` 日志的成功条数用 `grep Success` | 恒为 **0**（日志里没有该字样）→ 误判「全军覆没」。要数 `item_imported` / `import_task_apply` |
| 84 | 以为网易云或笑匠能拿**流派** | 实测：网易云曲目无 genre、专辑 `tags` 返回空、笑匠是纯歌词库 → **流派只能用 iTunes**（见 10 与 24.13） |
| 85 | 写流派时只处理「**空值**」(`if cur: continue`) | 源文件自带的脏 genre 会被原样留下：实测 1086 个是目录名/广告/GBK 乱码/无映射英文。**必须三分支：白名单保留 / 英文译中文 / 其余清空**（见 10.1） |
| 86 | 只按扩展名认定音频格式 | 实测混着 **7 个假 flac**（头部 32 字节全 `00`，真损坏）、**1 个假 mp3**（实为 RIFF WAVE）。要用 `file` + `od -A n -t x1 -N 32` 验魔数（正常 flac 头 `66 4c 61 43`）（见 10.2） |
| 87 | 用 SQL `like '%中文目录%'` 查 beets 库归属 | `items.path` 是 **BLOB**，中文 LIKE 永远返回 0 → 误判「未入库」。必须取出来 `.decode('utf-8')` 再比（见 10.3） |
| 88 | 只统计音频体积就报「回收了多少」 | 同目录还有 `.mp4` 1337 个 / 100.6 GB、`.exe` 自解压包 7 个 / 14.2 GB、`.part` 残留。**`du` 与音频求和的差额要单独交代**；`.exe` 内的 wav 从未解压过（见 10.4） |
| 89 | 用「**艺人不在库**」单判据删网络歌手 | 单条判据必误伤：实测 9602 → 2687（四轮收紧）。必须**多重 or**：艺人匹配 / 曲名匹配 / **颠倒交叉匹配** / **网易云白名单**（见 11.1） |
| 90 | 忽略**繁简差异** | 库内大量是繁体发行版（`終結孤單` vs `终结孤单`、`Mayday` vs `五月天`），不做繁简归一「曲名在库」这层几乎全废。NAS 已装 `zhconv`，库侧与文件侧要走同一个 `norm()`（见 11.2） |
| 91 | 把「**无 artist**」当成「确认不在库」 | 无 artist 的文件在集合求交里恒为空集，会被静默归入待删（实测 3594 个）。**「无法判断」必须与「确认不在库」分流**，前者默认不动（见 11.3） |
| 92 | 删之前不出**艺人名单**给人过目 | 名单一眼就能看出 `王一博 21`/`杨紫 16`/`不改音响提升六倍音质 17`（营销词被当艺人）这类整类误伤。长尾极散，**只看 Top 25 就够**（见 11.4） |
| 93 | 用 `7z x` 解 **RAR5 自解压 `.exe`** | p7zip 16.02 对 `m3:25` 报 `Unsupported Method`，**exit=0 但产出全是 0 字节**。用 `apt install unrar` 后 `unrar x -o+ -idq file.exe dest/`（见 12.1–12.2） |
| 94 | 解压后不查 **0 字节文件** | 「退出码 0 + 目录结构完整 + 文件数正确」的失败形态只能靠 `find -size 0` 发现（见 12.1） |
| 95 | 把**精选集重收的曲目**当「同曲重复」删掉 | 实测 450 首里唯一曲目仅 281 个，但那是 5 张正规精选集重收母专辑曲目。**专辑收藏完整性 ≠ 同曲多副本**，误去重会掏空精选集（见 12.4） |
| 96 | 转码后只信 ffmpeg 退出码 | 静默截断不会报错。要逐首比 `ffprobe` 时长（`|d1-d2|<=1.5s`），并抽验标签/封面覆盖率（见 12.3） |
| 97 | 直接 `beet import -s` 灌一个大目录 | singleton 模板 `$albumartist/$title` 会撞车：实测 10408 首只有 6233 个唯一键，**7021 个文件互相覆盖**。导入前必须算 `dup_internal` / `collide_lib` / `no_artist` 三项（见 13.1） |
| 98 | `beet import -s` 吃 `.mp4` | beets 把 mp4 当 MPEG-4 音频，实测 **1326 个 MV 视频**入库、title 变成 `www.xgw5.com`。导入前按扩展名白名单过滤；已导错的要剥离但**别连带删库里原有的 `.tdl`**（见 13.3） |
| 99 | 用「网易云收录过」当正规歌手白名单就完事 | 会把营销词一起保护：`9月热门无损DJ串烧` 45 首、`不改音响提升六倍音质` 14 首漏网。收尾必须复查 artist。规则要精确——**`DJ` 只精确匹配、`Music` 不能当关键词**，否则误伤 DJ OKAWARI / Ramin Djawadi（见 13.4） |
| 100 | 给无 artist 的文件直接套路径模板 | 会产出 `Music/<曲名>` 畸形路径（实测 3585 个）。必须兜底成「未知艺术家」；注意 **WAV 不支持 albumartist 帧**，要用 `mutagen.wave.WAVE`+ID3 单独写（见 13.2） |
| 101 | 用户提到某个目录名就**按字面新建** | 用户说「移到 music/mv 目录」，我新建了 `Music/MV/`，而 **MV 仓库其实是平级的 `电影音乐/MV/`**（已存在 888 个文件的老收藏，带 `歌名 - 歌手` 命名规范）。**先 `ls` 确认目录是否已存在、里面有什么**（见 13.7） |
| 102 | 多艺人串**只用正则切**（尤其 `&`/`,`） | `Simon & Garfunkel`（乐队，应保留）与 `Jay-Z & Kanye West`（合作，应切）**词形同构**，纯正则必错。须「正则召回 + 网易云 `musicSize≥100` 裁决」（见 11） |
| 103 | 切分时把 `feat.` **连空格一起留给艺人名** | 若正则写成 `feat.` 而不吃前置 `\s*`，`周杰伦 feat. 袁咏琳` 会切出尾巴带空格的 `周杰伦 `。前导 `\s*` 必须加（见 11.2） |

---

## 每批任务的收尾清单

```
1) 库↔磁盘双向自检：items.path 都存在 · Music 下无孤儿 · 空目录 0 · 无曲专辑 0
2) 同路径重号 0
3) 若改过标签：抽样回读比对，确认「库 = 文件」
4) 若改过 WAV：宽容扫描确认 LIST/INFO 的 IGNR 与库一致
5) 按源目录生成 / 更新 m3u
6) 备份收敛：根目录只留 1 个有效回滚点，其余移入 _db_backups_archive/
7) 源目录归档走 mv，并把批量数据落盘成 JSON 备查
```

具体命令见 `references/04-quality.md` 的 Phase 13。
