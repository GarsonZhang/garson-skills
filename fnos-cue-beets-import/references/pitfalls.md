# 坑位总索引 + 坑 1~26 正文

> 全部实测踩过的坑，按危害排序。坑 1~26 的正文在本文件；
> 坑 27 及以后的正文写在各自 Phase 里，索引见下表。

## 坑位索引（全部实测踩过，按危害排序）

> 编号 1~23 在本节；**24 见 `02-restructure.md` 的 Phase 8**（`beet modify` 只改一半）、
> **25 见 `04-quality.md` 的 Phase 9**（专辑名里的碟号/幕次）、
> **26 见 `01-import.md` 的 Phase 10**（算「库内已有」必须用导入前备份库）、
> **27~36 见 `03-cleanup.md` 的 Phase 14/15**（封面水印图 / 标签层广告）、
> **37~42 见 `02-restructure.md` 的 Phase 17/18**（散曲专辑化 / 源区处置）、
> **43~49 见 `02-restructure.md` 的 Phase 19**（歌手合辑目录批量建专辑）、
> **50~56 见 `02-restructure.md` 的 Phase 20**（大套歌手目录并入/新建：GBK-latin1 乱码、专辑名匹配、多版本、多碟、标签器）、
> **57~68 见 `01-import.md` 的 Phase 21**（扁平无损/母带散曲：**WAV 写标签必须用 `mutagen.File`**、UTF-16 广告帧、
> 酷狗空返回不可缓存、文件名分词复核、命中三铁律、技术尾巴、错别字回正）、
> **69~73 见 `03-cleanup.md` 的 Phase 23**（收尾质量闸：酷狗 `songname` 截短版本词、`items.path` 是 BLOB、
> 判截短不能用「谁更长」、WAV 的 `LIST/INFO` 要用 GBK 重写、改 title 四处同步）、
> **74~81 见 `03-cleanup.md` 的 Phase 24**（流派清洗：无上游可回填、广告/GBK乱码/外语"世界音乐"三类脏值、
> `Other` 是占位值、判标错要看专辑而非流派名、**WAV 流派三处含 `LIST/INFO` 的 `IGNR`**、
> `ASFTags.pop` 不接受 default、用备份库差集定位改动）、
> **82~86 见 `03-cleanup.md` 的 Phase 25**（**用 iTunes API 批量补流派 9.0%→71.8%**：两段式架构、
> 曲名交集识别误配、`artistName` 纯度门槛不能硬卡、兜底不能用全体众数、
> `str(bytes)` 写坏 `LIST/INFO`、`chunks()` 白名单漏块）、
> **87 见 `03-cleanup.md` 的 Phase 25.10**（单曲级检索：艺术家级失效时的最后一公里）、
> **88~93 见 `03-cleanup.md` 的 Phase 25.11**（全库单曲重查 + 命中校验闸门：
> **只比曲名不校验艺术家 → 15~20% 同名误配**、曲名兜底召回升准确率崩、
> `country=cn` 返回 0 条、读 WMA 不能用 `easy=True`、
> 「写文件返回 ok」≠「文件真的改了」、「留空条数」的统计公式）、
> **rmtree 误删事故的恢复见 `05-recovery.md` 的 Phase 22**；
> **自动化任务误执行写操作（prompt 里不能写脚本名+动词）见 `05-recovery.md` 的 Phase 26**；
> **后台接力的 `pgrep -f` 自匹配死循环见 `05-recovery.md` 的 Phase 27**；
> **94~103 见 `02-restructure.md` 的 Phase 28**（`音乐/` 整体清空：iTunes 英文艺人名要手工映射、
> **投票法对翻唱歌手失效**、去重要按「曲名+映射后艺人」且忽略扩展名、
> 文件名 `-` 分段首段优先、GBK-latin1 乱码要 ≥2 汉字才认、
> **校验脚本非 ID3 容器的键名不能拿 `TIT2` 去比**、`ffcuesplitter` 静默不产出改用 `ffmpeg -ss/-t`、
> WAV 的 RIFF size 与实际不符会让 mutagen 静默拒写、散曲 `album` 要清空）。
> **104~107 见 `01-import.md` 的 Phase 14**（歌手单曲集入库：**`beet import -s` 是递归的，
> 单曲与子专辑必须分开暂存**、源缺 `tracknumber` → 文件名全以 `00` 开头、
> 伴奏轨与主曲 title 撞名 → `.1` 重名、**MB 里单曲是「1 轨 release」且轨数不等就永远匹配不上，
> 但曲名/发行日仍可当权威标签源**；另：`cp -a` 备份库会保留源 mtime，按 mtime 看不出备份新鲜度）。
> **108 见 `04-quality.md` 的 Phase 13.14**（更新归档 README：**拿「下一节标题」当锚点会把标题吞掉**，
> 替换串必须原样写回锚点，改完回读 `grep '^##'` 校验；顺带 `str.replace` 第三参是次数不是字符串）。

### 1. 【最致命】`beet import -A` 是 `--noautotag`，等于关掉匹配

```
-a, --autotag        infer tags for imported files (default)
-A, --noautotag      don't infer tags for imported files (opposite of -a)
```

**`-A` 不是「自动选择」，是「不自动打标签」**——加上它 beets 就不会去查 MusicBrainz，
所有专辑都只会按现有标签将就导入（或跳过）。

正确命令：`beet import -q "$dir"`，**不要加 `-A`**。

> 这条曾让整批任务在错误参数下跑了 20 分钟，全部专辑都「匹配不上」。

### 1b. 【防误诊】整批「未匹配」不等于 `-A` bug

中文合集（车载 HIFI、抖音 BGM、《华语流行单曲珍藏系列》、《汽车发烧音乐精选》…）
在 MusicBrainz 里**覆盖率基本为 0**，全批 `Skipping.` 是正常结果，不是故障。
（实测：MB 查 `汽车发烧音乐精选CD10` → `count: 0`。）

判别顺序，别跳步：

1. `grep -n 'beet import' /tmp/cue_job.sh` → 确认没有 `-A`（正确形如 `"$BEET" import -q "$out"`）
2. 直查 MB 是否真有该专辑，不要用 beets 复现：

```bash
UA='beets/1.6.0 ( https://github.com/beetbox/beets )'
curl -s -m 20 -A "$UA" \
  "https://musicbrainz.org/ws/2/release/?query=release:%22<专辑名>%22&fmt=json&limit=3" \
  | python3 -c "import sys,json;print('count=',json.load(sys.stdin).get('count'))"
```

- `count=0` → 该专辑 MB 确实没有，skip 是正确行为，**别去改参数**
- `count>0` 而 beets 仍 skip → 才回头查参数 / 限速 / 匹配门槛

MB 强制要求 User-Agent 且限速 1 req/s（批量查询之间 `sleep 1.2`），无 UA 会被拒。

**同目录重跑会产生 `pending_match.txt` 重复行**：未匹配的 `_split` 不写进
`done.txt`，下次运行会重新 `beet import -q` 并再 append 一次。无害，汇报前 `sort -u` 去重。

**无望专辑的入库开销不小（实测）**：`beet import` 对「MB 里根本没有」的专辑
照样要花 **49~93 秒**（仍会走完整检索 + 打分流程）。一轮 25 分钟里
分割只占 7.2 分钟、入库占 18.1 分钟，而成功率可能是 0。
所以**别把「未分辨就先全量跑」当默认**——先跑 1b 的 MB `count` 抽样，
把注定无望的先挑出来，能省掉大头时间。

### 2. `beet import -p` 是 `--resume`，不是 pretend

```
-p, --resume     resume importing if interrupted
    --pretend     just print the files to import      ← 只有长选项
```

写 `-p` 会**真实导入**。曾因此在用户库里连写 8 条重复记录 + 8 个文件。
**任何声称「试跑不写入」的操作，先核对参数拼写。**

### 3. `-q` 下匹配失败的行为是「跳过」，且退出码恒为 0

- 匹配成功 → 导入
- 匹配不上 → 日志出现 `Skipping.`，**不入库**
- 无论成败，退出码都是 0，**不能用 `$?` 判断**

### 4. 用 `mb_albumid` 做二次确认

即使 `-q` 通常直接跳过未匹配的，仍建议核对库中新增专辑的 `mb_albumid`（防 fallback 入库）：

- 非空 → 真匹配到 MusicBrainz
- 为空 → 只是 fallback → `beet remove -a -f "id:N"`（**不带 `-d`**）撤出库，文件保留
- 无新增 → 被跳过了

已验证 `beet remove -a -f` 不带 `-d` 不删文件。读库直连 sqlite 最快（0.02s，比起 beets 快约 20 倍）。

**试过但无效、别浪费时间**：`beet import -l <log>` 只写一行 `import started`；
临时配置 `beet -c` 覆盖 `import.quiet_fallback: skip` 实测也不生效。

### 5. 【高频】cue 与音频文件名不一致 → 用符号链接修正

从网盘/挤压包拿到的资源，cue 里 `FILE "五月天 - 为爱而生.ape"`，
磁盘上却是 `五月天.-.[为爱而生].专辑.(ape).ape` —— **名字对不上，分割直接报
`ERROR: No audio track found`**。

不必改 cue、也不必改原文件，**在 cue 同目录建个同名符号链接**即可：

```bash
ln -sf "五月天.-.[为爱而生].专辑.(ape).ape" "五月天 - 为爱而生.ape"
~/ffcuesplitter_env/bin/ffcuesplitter -ce gb18030 -i "....cue" -f flac -o _split
rm -f "五月天 - 为爱而生.ape"          # 用完立刻删
```

实测有效（13 轨全出、中文无乱码）。**触发条件要保守**：仅当 cue 只引用 1 个文件、
且目录里也仅有 1 个音频（排除符号链接）时才用，避免错配。

### 6. 绝不要转码 cue，要用 `-ce` 指定编码

ffcuesplitter 定位音频的机制（读 1.0.31 源码确认）：

```python
# cuesplitter.py:241
tracksrc = os.path.join(dirname, track.file.path)   # file.path 是解码后的 str
if not os.path.exists(tracksrc): ...                # str 按文件系统编码(UTF-8)转字节 → stat
```

成立条件两条：① cue 能被某编码**无损解码**；② 解出的名字转 UTF-8 字节后 **== 磁盘文件名字节**。

- 磁盘名是 UTF-8 字节（SMB 拷贝的正常情况）→ `-ce <正确编码>` 解码 cue 即可，**一个文件都不用动**
- 磁盘名是 GBK 字节（U 盘/rsync 直拷遗留）→ 改 cue 编码**无解**，必须先改磁盘文件名
- **把 cue 转成 UTF-8 会破坏 FILE 行字节匹配 → 分割失败**，且是不可逆改动

实测分布：551 个 cue → **465 个 gb18030、20 个 utf-8-sig**。中文专辑绝大多数是 GBK。

### 7. 同目录多个 cue 的含义

- `xxx.cue` = 整轨清单（FILE 指向 `xxx.wav` / `CDImage.ape`）
- `xxx.flactracks.cue` = **分轨清单**（FILE 指向 `01-xxx.flac`）
- `修复.cue` = 他人修过的版本

同一整轨被两个 cue 引用时，第一个处理并归档后第二个必然「源缺失」——正常，别重复导入。

### 8. `-o` 输出目录会混入 `*.ffcuesplitter.log`

分割后要 `rm -f "$out"/*.ffcuesplitter.log`。

### 9. 【静默丢内容】同目录多张整轨 → 共用 `_split` 会吞掉后一张

脚本里 `out="$d/_split"` 是**按目录**取名的，所以同一目录下的多张 cue 会指向同一个
`_split`。实测该源目录里 **50 个目录有多个 cue，其中 44 个是「真多整轨」**：

| 类型 | 例子 | 后果 |
|---|---|---|
| 多 CD | `许巍…(CD1).ape.cue` + `(CD2)`；`王菲…Disc1` + `Disc2`；雨果唐诗 `①~⑤` | **CD2 及之后整张丢失** |
| 同专辑不同来源 | `xxx.wav.cue` + `xxx.(APE).cue` | 第二份被跳过（可接受，同一专辑） |
| 修复版 | `修复.cue` + 原版 cue | 先排序者胜（`修` 在 `齐` 前，正好取到修复版） |

流程是：CD1 切完 `_split` 生成并入库 → `done.txt` 记下 `_split` → CD2 循环时
`_split` 已存在且 `is_done` 命中 → **`continue` 跳过，CD2 从未被切也从未入库**。
不报错、不告警。**跑之前必须查**：

```bash
export PYTHONUTF8=1
cd "$ROOT" && python3 - <<'PY'
import os, collections
d = collections.defaultdict(list)
for dp, dns, fns in os.walk('.'):
    if any(p in ('_split','_cue_archive','.cue_tool') or p.endswith('_split.tmp') for p in dp.split(os.sep)): continue
    for fn in fns:
        if fn.lower().endswith('.cue'): d[dp].append(fn)
real = {k: v for k, v in d.items()
        if sum(1 for f in v if 'flactracks' not in f.lower()) > 1}
# 落盘清单，供 Phase 5 清理时排除（这些目录的 _split 必须保留）
with open('.cue_tool/rework_multi_cue.txt', 'w', encoding='utf-8') as fh:
    for k in sorted(real): fh.write(os.path.normpath(k) + '\n')
print('需要独立输出目录的目录数:', len(real), '-> .cue_tool/rework_multi_cue.txt')
for k, v in list(real.items())[:20]: print('  ', k, '->', sorted(v))
PY
```

修法：① 跳过 `*flactracks*.cue`（它引用的是已切好的单轨，不该再切）；
② 该目录有多张整轨时，`out` 加上 cue 名后缀：

```bash
base="$(basename "$cue" .cue)"
case "${base,,}" in *flactracks*) log "skip-flactracks $cue"; continue ;; esac
n=$(find "$d" -maxdepth 1 -iname '*.cue' ! -iname '*flactracks*' | wc -l)
if [ "$n" -gt 1 ]; then out="$d/_split.$base"; else out="$d/_split"; fi
```

### 10. 【幂等】`is_done` 判定必须在循环最前面，且键不能用 `_split`

原脚本把 `is_done "$out"` 放在 `if [ -d "$out" ]` **分支内部**，于是：

- **删掉 `_split` 后重跑 → 会重新分割 + 重新 import → 库里变双份**（判定条件不成立，
  直接走 `else` 重新切）。这正是「Phase 5 清理 `_split`」的隐藏地雷。
- 幂等键用 `_split` 路径本身也是错的：这个路径会被清理掉。

修法：把判定提到最前，键改用 **cue 全路径**（永不被删）：

```bash
key="$cue"
is_done "$key" && { log "skip-done $cue"; continue; }
...
case ... esac
  OK) log "import-ok $out"; echo "$key" >> "$DONE" ;;
```

（注意 `done.txt` 语义随之从「已入库的 `_split` 路径」变为「已处理的 cue 路径」，
按老格式解析 `done.txt` 的脚本要一起改。）

### 11. 【误诊】`import-none(未匹配)` 是二义标签：「匹配到但已在库中」也被记成它

`checkmb()` 的判据是「库内有没有新增专辑记录」，而 `beet import -q` 在**两种**情况下
都不新增，脚本都会写进 `pending_match.txt`：

| 实际情况 | beet 输出特征 | 该不该管 |
|---|---|---|
| A. 真无候选（MB 没这张专辑） | 只有 `Skipping.`，**没有** `Similarity:` | 需人工匹配 |
| B. **匹配到候选，但该 release 已在库中** | 先打印候选详情（`Correcting tags from…`、`URL:`、`(Similarity: xx%)`），再 `Skipping.` | **不用管，库里已有** |

实测 B：`张学友/专辑/1985-Amour遥远的她[Korea]` 输出
`(Similarity: 100.0%) (Hybrid SACD, 2014, HK, …)` + `URL: …/release/d6b9f2e2-…`，
而 `d6b9f2e2` 正是库里已有的《Amour / 遙遠的她》→ 判为 `import-none`，其实完全正常。

**判别一行搞定**：`grep -c 'Similarity:' run.log`。有候选却没入库，就是 B 类。

```bash
# 重分类 pending：duplicate（不用管）/ nomatch（真需人工）/ unknown
python3 "$ROOT/.cue_tool/classify_pending.py"
```

> 分类脚本的正则**必须包含 `import-dup(已在库中)` 这个分支** —— 漏了会把它判成
> `unknown`。实测全量跑完 pending 374 条：漏分支时 `duplicate=0 / unknown=133`，
> 补上后正确分为 `duplicate=128 / nomatch=242 / unknown=4`。
> `duplicate` 那批的源目录已被 `cue_one.sh` 自动归档（目录不存在），
> 只剥下的 `pending_match.txt` 残留记录可直接清掉 —— **删前先验证目录确实不存在**。

**对「同专辑多版本」目录的连锁影响（张学友系最典型）**：
源目录里大量成对存在 —— `1985-Amour遥远的她[Korea]` 与 `[PolyGram]`、
`1985-Smile[Korea]` 与 `[PolyGram]`、`1989-只愿一生爱一人[Korea]/[PolyGram]/[引进版]`…
每个专辑的**第一个版本**正常入库，后续版本匹配到**同一个 `mb_albumid`** → 全部 B 类跳过。
所以这类源目录 `done.txt` 的增速约为**源目录数的一半**，不是异常。

> ⚠️ **B 类的 `_split` 不能删**。库里的副本是 MB 首选 release（如 2014 SACD 版），
> 源目录是另一个版本（如 1985 原版），**内容不同**。要留 1985 版就只能人工指定候选：
> `beet import -A --search-id <release id> "<dir>/_split"`。

### 12. 【静默漏数据】解析 `run.log` 不能用 `\S+` 匹配路径

日志格式是 `<时间> <事件> <路径>`，而**路径常含空格**
（例如 `London Cast (Crawford, Brightman, Barton) - Andrew Lloyd Webber - …`）。
`re.compile(r'^\S+ \S+ import-ok (\S+)$')` 会**静默漏掉**这些条目 ——
`cue_archive_dup.py` 与 `classify_pending.py` 都踩过，表现是「明明有 N 条 dup 却只识别出 1 条」。

正确写法是按「时间 + 事件」前两列切分，剩下整段归路径：

```python
re.compile(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} import-ok (.+)$')
```

### 13. 【假故障】扩展名与真实格式不符：资源站把 RAR 改名成 `.ape`

**现象**：`ffprobe: Invalid data found when processing input` → `cue_split.py` 返回
`FFPROBE-FAIL` → 回退 ffcuesplitter → 同样报错 → 最终落 `SPLIT-EMPTY` / `split_failed.txt`。
看起来像「源文件损坏」，实际是**打包时多套了一层压缩**。

**判据：读文件头 16 字节**，别只看扩展名。

| 头字节 | 真实格式 |
|---|---|
| `4d 41 43 20`（`MAC `） | APE |
| `66 4c 61 43`（`fLaC`） | FLAC |
| `52 49 46 46`（`RIFF`） | WAV |
| **`52 61 72 21 1a 07 00`（`Rar!`）** | **RAR 压缩包（伪装）** |
| `50 4b 03 04`（`PK`） | ZIP（伪装） |

```bash
head -c 16 "$F" | od -A x -t x1z      # xxd 不一定有，od 一定有
file "$F"                              # 也能直接认出 Rar archive data
```

**全盘筛查**（读前 24 字节统计 magic）——实测 832 个源音频里只 1 个是伪装的，
所以**别因为它就怀疑整批损坏**，先扫一遍再下结论。

**修复**（`7z` 在 fnOS 上有，`unrar` 没有）：

```bash
7z l "$F"                              # 先看内容：通常是一个 <原名>.ape.ape
7z x -y -o/tmp/_rarfix "$F"            # 解压
head -c 8 /tmp/_rarfix/*.ape* | od -A n -t x1z   # 确认是 MAC
ffprobe -v error -show_entries format=format_name,duration -of default=nw=1 /tmp/_rarfix/*.ape*
mv "$F" "$W/quarantine_rar/<name>.rar"           # 原包 mv 到隔离目录，**不删**
mv /tmp/_rarfix/*.ape.ape "$F"                    # 真文件放回 cue 声明的那个名字
bash "$W/cue_one.sh" "$D"                         # 重跑
```

> 解压出的文件名常是 `xxx.ape.ape`（双扩展名），必须**改成 cue 里 `FILE` 声明的名字**，
> 否则 `resolve_audio` 找不到。


---
