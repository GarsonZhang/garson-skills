---
name: fnos-video-library-organize
description: 通过 SSH 整理飞牛(fnOS)/Linux NAS 上杂乱的影视媒体目录——演唱会、音乐会、影片、MV 资源库。适用于「整理一下 XX 目录」「按艺人/类型归档」「清理重复和空目录」「重命名规范场次目录」等需求。核心是「盘点 → ffprobe 判同场 → 生成映射表 → 干跑 → 执行 → 回滚日志」六步法，全程只做目录层移动，不转码不删数据（删除类动作先隔离到 _待删 再确认）。
agent_created: true
---

# NAS 媒体目录整理（盘点 → 映射 → 干跑 → 执行 → 回滚）

飞牛 NAS 走 `mcp__ssh-mcp-server__execute-command`（`connectionName: "fnos"`，garson@192.168.88.129，locale en_US.UTF-8）。
典型目标：`/vol2/1000/电影音乐/演唱会`（15T 卷）。注意音乐库另有 beets（`Music/`），视频整理不要碰它。

## 铁律

1. **只移动，不删除**。删除类动作（重复副本、空目录）一律先移入 `_重复待删/`、`_空目录待删/`，等用户确认再真删。
2. **不转码、不重编码、不碰文件内部**。字幕（.srt/.idx/.sub）必须与主视频同目录、同步移动。
3. **先给方案再落地**。用户说「先分析、给方案、我确认后再做」时，只做只读盘点，不要动文件。
4. **同场次多版本判定用 ffprobe 时长，不要靠文件名猜**。时长一致（±5s）即同一场。
5. **重复文件必须 md5 逐对比**，不看文件名大小就下结论。

## 第 0 步：环境甄别

```bash
df -h /vol2 | tail -2                                   # 容量与剩余
ps -ef | grep -Ei 'emby|jellyfin|plex|nastool' | head   # 有没有媒体服务器（影响命名是否要适配刮削）
ls -la '/vol2/1000/电影音乐/'                            # 上级目录体系（MV/戏曲/Music 等容器是否已存在）
```

若存在 `MV/`、`电影/` 等既有容器，内容边界要跟用户确认是否移交过去。

## 第 1 步：只读盘点（全部原始数据）

```bash
D='/vol2/1000/电影音乐/演唱会'
cd "$D"
du -sh .                                              # 总量
ls -la                                                # 顶层条目，注意属主（garson 自建 vs xunlei-app 下载残留）
# 每个顶层目录的文件数/子目录数/占用
for d in */; do n=$(find "$d" -type f|wc -l); sd=$(find "$d" -mindepth 1 -type d|wc -l); sz=$(du -sm "$d"|cut -f1); echo -e "${sz}MB\t${n}f\t${sd}d\t$d"; done | sort -rn
find . -type d -empty | sort                          # 空目录（BT 任务骨架）
find . -type l | head                                 # 软链接（别当文件计数漏了）
```

## 第 2 步：ffprobe 全量扫时长+分辨率（判同场的关键依据）

```bash
cd "$D"
find . -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' -o -iname '*.rmvb' \
  -o -iname '*.rm' -o -iname '*.wmv' -o -iname '*.mpg' -o -iname '*.ts' -o -iname '*.vob' -o -iname '*.DAT' \) -print0 \
| while IFS= read -r -d '' f; do
    info=$(timeout 20 ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
      -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null | tr '\n' ' ')
    printf '%s\t%s\t%s\n' "$(stat -c %s "$f")" "$info" "$f"
  done > /tmp/probe_all.tsv
```

**判读方法**：同场次不同压制 → 时长几乎相同、分辨率不同（如 1280x720 的 8.5G vs 640x352 三碟 9190s）。
时长差异 >3% 的，是不同剪辑版本，**当独立条目保留**，不要合并也不要丢进低清副本。

### 时长不同时的最终裁定：抽帧对比法（比时长推断可靠得多）

时长不同不代表不同场——可能是同场不同剪辑。用画面证据定案：

```bash
# 等距抽 8 帧（按各自总时长的百分位）→ tile 4x2 拼成一张图
grab(){ f="$1"; tag="$2"; dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")
  mkdir -p /tmp/cmp/$tag; i=0
  for pct in 8 20 32 44 56 68 80 92; do i=$((i+1))
    t=$(python3 -c "print(int(float('$dur')*$pct//100))")
    ffmpeg -v error -ss $t -i "$f" -frames:v 1 -vf scale=320:-2 -q:v 4 /tmp/cmp/$tag/f_$(printf %02d $i).jpg -y
  done
  ffmpeg -v error -pattern_type glob -i "/tmp/cmp/$tag/f_*.jpg" -vf tile=4x2 -frames:v 1 /tmp/cmp/$tag.jpg -y
}
```

再用 `mcp__ssh-mcp-server__download` 取回本地，用 Read 看图判读。**判据（按可靠度排序）**：

1. **台标 / LOGO 是否一致** —— 同一场官方录像会带同一个台标。实测：刘德华 1999 两版都有 `New Way` 台标、周杰伦 2007 两版都有 `Jay Chou` 台标 → 同场
2. **服装序列是否一致** —— 按百分位抽帧时服装出场顺序应能对上
3. **舞台布景 / 观众席形态** —— 体育场 vs 红馆四面台的机位完全不同
4. **片尾字幕** —— 出现在哪一版、什么位置（判断哪版更完整）

**陷阱**：抽帧同百分位不代表同曲目（总时长不同）。要看的是"服装/舞台/台标的对应关系"，不是逐帧重合。

**版本性质可能完全不同，不能一刀切当"高清 vs 低清"**。实测 MJ 1997 慕尼黑：
- mp4 1000x768 6350s —— 带 **ZDF 德国电视台标**，还插播了 Thriller/Ghosts 电影片段 → **电视播出版**
- avi 双碟 640x480 7343s —— 无台标、完整现场、多 16.5 分钟 → **完整现场版**
→ 两版互补，都留。这类"电视剪辑版 vs 完整现场版"的关系，删任何一个都会丢一种观看方式。

### 判断是否缺碟：查官方发行信息

用 WebSearch 查 MusicBrainz / 豆瓣 / 百度百科的专辑页，拿「碟数 + 总时长」与本地实况比对。
实测刘若英《单身日志》：官方 **2×DVD 总长 2:14:14**，本地 B+C 碟只有 1:44:51（差 29 分钟）→ 大概率缺前半场。
也可抽开场 0/4/8/15/25/40/60/90 秒的密集帧，看首帧是"开场"还是"换场"画面（官方 Disc1 第一轨是 INTRO 1:14，开场即是钢琴前奏）。

无元数据语义的文件名（如 `07年/07.mkv`）靠这个反查：时长 9194s + 720p，与 `陳奕迅.Eason's...rmvb`（9194s）一致 → 确认为同一场。

## 第 3 步：写映射表 spec.py（不要边想边 mv）

目录布局建议（先跟用户确认，别自作主张）：

```
<根>/
├── <艺人>/<艺人> - <年份> <场次名> [<版本/画质>]/     # 主体
├── 群星合辑/  古典与音乐会/                          # 正式分类容器
├── _卡拉OK与MV/  _非演唱会/                          # 内容边界容器
├── _重复待删/  _低清副本/  _残缺待补/  _空目录待删/   # 待决策容器
└── _整理日志_YYYYMMDD/                              # spec.py / organize.py / move_log / README
```

spec.py 结构（数据与逻辑分离，便于干跑）：

```python
ROOT = '/vol2/1000/电影音乐/演唱会'
DUP='_重复待删'; LOW='_低清副本'; INC='_残缺待补'
MOVES = []
def m(src, dst_dir, new=None):
    MOVES.append((src, dst_dir, new))
m('张国荣告别演唱会', LOW, '张国荣 - 1989 告别歌坛演唱会 [DVDRip 双碟]')
m('刘德华/刘德华.-.[2001夏日Fiesta演唱会.disk1].演唱会.(VCD).mp4', LOW,
  '刘德华 - 2001 夏日Fiesta演唱会 [VCD 双碟]/')     # 尾部 / = 进子目录保留原名（多碟合并）
EMPTY_DIRS = ['梅艳芳2003告别经典演唱会', ...]
```

**`new` 的语义必须显式**（这里翻过车）：
- 源是目录 → `dst_dir/new`（整体重命名）
- 源是文件 + `new` 以 `/` 结尾 → `dst_dir/new/原文件名`（多碟合并用）
- 源是文件 + `new` 不带 `/` → `dst_dir/new + 原扩展名`（单文件重命名）
- 同一个 `new` 被两个文件共用却没加 `/` → 批次内目标冲突，干跑会报出来

## 第 4 步：organize.py（--check / --run / --rollback）

```python
def target_of(src, dd, new):
    base = os.path.basename(src.rstrip('/'))
    sp = os.path.join(ROOT, src)
    if os.path.isdir(sp):
        return os.path.join(dd, new if new else base)
    if new and new.endswith('/'):
        return os.path.join(dd, new, base)
    if new:
        _, ext = os.path.splitext(base)
        return os.path.join(dd, new + ext)
    return os.path.join(dd, base)
```

run() 要点：
- `full = os.path.join(ROOT, dp)` → **`os.makedirs(os.path.dirname(full), exist_ok=True)`**
  （只 `makedirs(dd)` 会在目标含子目录时 `FileNotFoundError`，`shutil.move` 随后 fallback 到 copy 分支——同分区至少只是报错，跨设备就真拷贝了）
- 每项 `try/except` 记失败继续，不要裸跑中断在半路
- 写 TSV 日志 `[src_rel, dst_rel]`，`--rollback` 按逆序移回
- 空目录单独一步、放在 MOVES 之后（父目录移空后才能收走）

先 `--check`：验证源存在、目标不冲突、批次内无重复目标。**必须 100% 通过再 `--run`**。

## 第 5 步：重复文件 md5 逐对比

读取量 = 涉及文件总大小 × 2，机械盘约 130MB/s。**分批跑**（每组 5~8 对），单次别超 10 分钟。
按排序后的文件列表 zip 配对（多碟目录文件名可能不同但顺序对应：`DVD 1/2/3` ↔ `cd1/2/3`）。
文件数不同直接判「人工复核」，不要硬凑。

## 第 6 步：汇报与收尾

- 写 `_整理日志_<日期>/README.md`：目录规范、容器用途表、回滚命令、待人工确认清单、可回收空间
- 汇报里必须有「待你确认的 N 件事」：删重复（XG）、删空目录（N 个）、低清副本取舍、疑似同场但时长不同的条目
- 用户确认删除后，按三步走：
  1. **先留档**：`find <容器...> -type f -printf '%s\t%p\n' | sort -k2 > "$L/deleted_files_manifest.tsv"`，另导目录清单
  2. **再精确点名删**：`shutil.rmtree(os.path.join(ROOT, d))` 逐个容器路径，**绝不对媒体根目录用通配符**
  3. **改 README**：容器表更新 + 追加「已执行的清理（回收 XG）」段落
- 执行「留高清」类指令前，必须逐项确认每个降质副本都存在高清主版本（列表形式给用户过目），否则会把唯一副本删掉
- 对「时长不同」的疑似同场条目，即使画质低也**不要**归入降质副本——剪辑版本不同，是独立资产

## 变体：单曲 MV / 卡拉OK 库（与整场录像逻辑相反）

MV 库是**单个 3~6 分钟文件**的堆叠，组织方式跟「整场演唱会录像」不一样：

- **不要按艺人建目录**。实测 884 个 MV 横跨 264 位歌手，约 15% 是多人合唱无单一归属，建目录只会更碎。按「来源/年代」分容器（`经典老歌MV/` `流行单曲MV/` `韩语MV/` `MV合集/`），或按用户要求全部打平。
- **盘点换成本地分析更快**：`find . -type f -printf '%s\t%P\n' > /tmp/inv.tsv` → `download` 回本地 → 本地 Python 做正则拆分/异常检测/长度校验。比在 NAS 上写分析脚本省事得多。
- **命名规范**：`<歌名> - <歌手>[ & <歌手2>][ (备注)].<ext>`。实际脏数据与处理：

| 脏数据 | 实测例子 | 处理 |
|---|---|---|
| 下载站前缀 | `[PT80]` `[www.pt80.com]` | 删除 |
| en dash 冒充连字符 | `476 流着泪的你的脸 – 任贤齐.mkv` | `–`/`—` → ` - ` |
| 缺分隔符 | `644 流浪到淡水 金门王 李炳辉.mkv` | 按歌手表切分 |
| **歌名/歌手颠倒** | `483 容祖儿 - 挥着翅膀的女孩.mkv` | 对调（靠「歌手字段含虚词」嗅探） |
| 歌手大小写/错字 | `beyond`/`BEYOND`、陈淑华→陈淑桦、付笛生→付笛声 | 别名表 |
| 多人分隔符不一 | `张学友 汤宝如` vs `A&B` | 统一 ` & ` |
| 下载残留标记 | `[MV]` `[KO_CN]` | 转 `(韩语中字)` 之类备注 |

- **跨来源同名判定**：ffprobe 时长 + 抽帧，别靠文件名。实测两个韩剧 OST MV（`那时那人` / `你一人`）时长只差 0.001s、md5 却不同，抽帧 8 帧有 7 帧画面完全重合 → 同一支 MV 的两个压制版。
- **用在线曲目表独立佐证**：查 OST/专辑页拿「曲目 + 歌手 + 时长」与本地比对，一次同时确认「是不是同一首」和「歌手是谁」。上述两版经查证都是 `그대 한 사람`（金秀贤），只是中译名不同（唯你一人/那时那人/你一人）——与抽帧结论互相印证。
- **无歌手信息的单曲**（`日不落.vob`、`鲁冰花.mkv`）不要臆造，查证后在汇报里单列「需你核对」，标注推断依据与存疑点。

## DVDISO（VIDEO_TS）无损转 mkv

```bash
# 1. 字节拼接（关键：不能用 -f concat demuxer）
cat VTS_01_1.VOB VTS_01_2.VOB VTS_01_3.VOB VTS_01_4.VOB > /tmp/all.vob
# 2. remux：丢弃 dvd_nav_packet，只留视频+音频，不重编码
ffmpeg -i /tmp/all.vob -map 0:v:0 -map 0:a:0 -c copy -map_metadata -1 out.mkv
```

**致命坑：`-f concat -i list.txt` 对 VOB 会静默丢数据。**

实测谭咏麟 94 纯金曲 DISC.1：原盘 4.19GB / 9.5Mbps，用 concat demuxer 输出只有 **1.19GB / 2.7Mbps**——而**时长仍然是正确的 3529s**，只有体积出卖了它。日志里带 `Invalid frame dimensions 0x0`、`Header missing` 警告（容易被当成无害噪声刷过去）。
原因：每个 VOB 头部带 DVD 导航包和 sector 对齐，concat demuxer 按"独立文件"处理会解析错乱。
改成 `cat` 字节拼接后：4.12GB / 9.34Mbps ✓ 与原盘一致。

**验收标准**：输出体积 ≈ 原盘体积（差 <5%，差值来自丢弃的 nav packet），位率与原盘相当。
**只看时长会被骗，必须核对体积/位率。**

其他要点：
- 必须 `-map 0:v:0 -map 0:a:0`，避免把 `dvd_nav_packet` 数据流带进容器
- DVD 音轨常是 `mp2`（MPEG Audio Layer 2）而非 AC3——mkv 支持，主流播放器都能播
- 多碟分别转（DISC.1 / DISC.2），**不要跨碟拼接**
- 临时文件放同分区（快且不跨设备），转完立即删
- 耗时参考：4GB / 机械盘 ≈ 50s 拼接 + 60s remux
- 章节在 IFO 里，ffmpeg 拿不到；要保留章节需装 mkvtoolnix 用 `mkvmerge -o out.mkv a.vob + b.vob`
- **转完先抽帧确认画面正常，再决定删不删原盘**

## 存量文件命名规范化（检测 + 改写）

拆平之后通常还要「统一命名」。做法：

**检测**：遍历每个艺人目录下的视频文件，判断文件名是否以 `{艺人名} - ` 开头。
容器目录要单独映射（`群星合辑` → `群星`、`古典与音乐会` → 乐手名），否则整目录会被误判为不达标。

```
符合命名规范: 157 个
不符合: 62 个
```

**改写**：统一为 `艺人 - 年份 场次名 [版本/画质][ CD{n}].ext`
- **年份从旧文件名提取**：`(?:19|20)\d{2}`。注意 `903拉阔演唱会` 里的 903 是电台名不是年份、`4.5M` 是码率、`2004-2005` 是跨年巡演——宁可留空也不要编。
- **场次名忠于原文件**：保留 `BAD`/`HIStory`/`DUO`/`Star Light`/`Music Odyssey` 等原文标识，不要自作主张翻译。
- **版本标记照搬原压制标识**：`HALFCD`/`DVDRip`/`VCDRip`/`蓝光原盘`/`DAT`/`BluRay 1080p`，再按画质补 `[4K]`/`[蓝光]`。
- **附属文件跟视频同名**：`.chs.srt`/`.chn1.srt`/`.jpg`/`.png` 都要改。用「基名映射」批量处理最省事：
  ```python
  for ob in sorted(bmap, key=len, reverse=True):   # 长基名优先，避免短基名抢匹配
      if f.startswith(ob): new = bmap[ob] + f[len(ob):]
  ```
  注意个别笔误文件（如 `哥本哈根站r.png` 多打了个 r）必须显式列出。
- **DVDISO 的 `VIDEO_TS/VTS_01_*.VOB` 绝对不能改名**（DVD 规范硬要求），只能改外层目录名。做完的检测会剩这几个"不达标"，属正常。

## 把场次目录拆平（内容提到上一级）

用户常说「子目录里只有一个视频就提到平级」「多 CD 的也提到上一级」。规则与坑：

**规则**
- 单视频场次 → `{场次目录名}.{ext}`
- 多视频场次 → `{场次目录名去掉碟数词} CD{n}.{ext}`，n 从原文件名的碟号提取
- 保留有语义的碟号：`出发站/终点站`、`上/下`、`B/C`
- 字幕/附随文件跟随对应视频同名（`.chs.srt`、`.chn1.srt` 这类后缀必须保留，播放器才认）
- **含 `VIDEO_TS` 结构的 DVDISO 必须整目录跳过**（拆了就没法播）

**坑（全部实测）**
1. **先剔除 sample 再判定单/多碟**。`...-sample.avi` 排序时排在正片之前（`-`=45 < `.`=46），若一起参与判定，正片会被误标成 `CD2`。范晓萱/孙燕姿/Mariah Carey 三组都踩过。
2. **删掉「双碟/三碟/上下」等词后要清理括号内残留空格**：`[DVDRip 双碟]` 去词后得到 `[DVDRip ]`（括号内尾空格），需再 `re.sub(r'\s+\]', ']', s)`。
3. **碟号提取正则**：`(?:cd|disk|disc|part)[\s._-]*(\d+)`；兜底 `[-_ ](\d{1,2})(?=\.[A-Za-z0-9]+$)`；都失败按文件名排序给序号。
4. 拆完要用 `os.walk(topdown=False)` **自下而上**清空目录，否则残留空壳。
5. 先跑 `--check` 打印全部映射，**逐组扫一遍再执行**——这类规则驱动的批量改名，异常往往就藏在个别文件名里（如上面的 sample）。

## 踩坑清单（实测）

0. **批量重命名已有目录后，必须同步更新历史 move_log 的路径前缀**，否则 `--rollback` 全部失效（源/目标都找不到，静默跳过）。做法：按 `/` 切分每个单元格，首段命中 old→new 映射就替换：
   ```python
   parts = cell.split('/', 1)
   if parts[0] in mapping:
       cell = mapping[parts[0]] + ('/' + parts[1] if len(parts) > 1 else '')
   ```
   改完 `head -3` 抽查一眼。

1. **ssh-mcp 每次调用是独立会话**，`nohup cmd &` / `start &` 的后台进程会被回收（日志为空、ps 查不到）。长任务必须前台跑或分批。
2. **手打中文文件名极易错字**（陶喆→陶鹆、草蜢→草蟒），干跑一定会报「源不存在」。用 `python3 -c "import os; print([repr(f) for f in os.listdir('.') if '关键词' in f])"` 回读核对，不要靠记忆。
3. **heredoc 传中文/特殊字符**：用 quoted 形式 `<< 'EOF'`，里面的 `\'` 原样落盘，Python 单引号字符串能正确解析含 `'` 的中文名（如 `Eason\'s`）。不要用不带引号的 heredoc。
4. **顶层条目名含 `&#39;`（HTML 转义）**、前后空格、`.MKV/.DAT` 大小写混乱是常见下载残留，映射表里要精确复制，改名时才清掉。
5. **`du` 报 1MB 的目录往往内部全空**（BT 骨架），`find -type f | wc -l` 才是真相。
6. **只含字幕（.srt）没有视频的目录** → `_残缺待补/`，不要当正常场次。
7. 空目录里可能嵌套一层空目录（`五月天世界巡演/五月天「…」全记录`），整体移走即可。
8. 已按艺人分好的目录（用户手工建的）**内部条目不要改名**，只处理重复/低清/残缺，减少破坏面。
9. **Linux 单文件名上限 255 字节**（ext4），中文 3 字节/字。多人合唱串（21 人 × ` & `）直接越界，`shutil.move` 抛 ENAMETOOLONG。生成映射表时必须逐条 `len(name.encode('utf-8'))` 校验，超限收成「前2位 等N人」。
10. **Windows 生成的 TSV 上传到 Linux 带 CRLF**。读映射表用 `line.rstrip('\r\n')`，用 `rstrip('\n')` 会在路径尾部留 `\r`，干跑全报「源不存在」——而且是静默的全量失败，很容易误判成文件真丢了。
11. **打平类改造**（把子目录内容全提到根目录）之后，被搬空的源目录要**另走一步**收进 `_空目录待删/`，不能混在同一批 MOVES 里——父目录还有文件时移不走。
12. 用户说「先分析、给方案」时，方案要给**可选项让用户挑**（是否保留序号、是否分容器、重复项留哪版），不要替用户定；确认后再生成映射表、再干跑。顺序颠倒的话 884 条改名全白做。
13. 给用户看的对照表要**分类**（根目录 / 实质改名 / 仅格式微调），别丢 884 行原始表过去；「仅去序号」那类占比 85% 的用样例 + 计数带过。
