# 匹配预检 · 归档 · 全库自检

> 涵盖：批量导入前的零副作用匹配预检（Phase 9）、批次播放列表生成与四向校验（Phase 11）、
> 批次归档 + 库内元数据清洗 + 全库自检（Phase 13）。
> **每批任务收尾都应跑一遍 Phase 13 的自检清单。**

## Phase 9 — 批量导入前的「零副作用匹配预检」（2026-09-29 实测 120 个单元 / 56 分钟）

**什么时候用**：用户对着一个几十上百张的大目录说「这里面的专辑都处理一下」，
而你不知道哪些能自动匹配、哪些会卡住。**不要**直接 `beet import`（会写库、会 copy 几十 GB），
先用空库跑一遍匹配，拿到清单再定。

### 配置（临时库 + 不复制 + 不改源）

```yaml
# /tmp/probe.yaml
directory: /tmp/probelib
library: /tmp/probe.db
import:
    copy: no      # 不复制文件
    write: no     # 不回写源 tag
    quiet: yes    # 不交互，匹配不上就 skip
    detail: yes
    resume: no
```

```bash
mkdir -p /tmp/probelib
beet -c /tmp/probe.yaml -v import -q -l /tmp/manual.log "<目录>" > /tmp/probe.log 2>&1
```

**CLI 细节（都踩过）**：
- `-v/--verbose` 是**全局选项**，必须写在 `beet` 之后、子命令之前：`beet -c cfg -v import ...`。
  写成 `beet import -v` 会报 `no such option: -v`。
- `-p` 在 `import` 下是 `--resume`，**不是** pretend；没有 dry-run 模式。
- `-l LOG` = `file to log untaggable albums for later review` —— **这就是「需要人工处理」的官方清单**，
  `-q` 模式下每条 skip 都会写进去。
- 跑完后 `/tmp/probelib` 是空的（nocopy），`/tmp/probe.db` 是垃圾，随删。

### 从 verbose 日志里抽匹配质量

```python
# 关键行（每条专辑一个 block）
#   Tagging <artist> - <album>              ← 源 tag 里的专辑名
#   Searching for MusicBrainz releases with: {...}
#   Candidate: <artist> - <album> (<mbid>)  ← 每一个候选
#   Success. Distance: 0.03                 ← 该候选的距离（紧跟 Candidate）
#   Evaluating 5 candidates.                ← 候选总数
#   Skipping.  /  (Similarity: 100.0%) (Hybrid SACD, 2014, HK, ...)
```

用 `re.split(r'^=====\[(\d+)/(\d+)\] (.+)$', log, flags=re.M)` 切块（自己在循环里 echo 这个分隔符），
再用 `Candidate: (.+?) \(([0-9a-f-]{36})\)\n(?:.*\n)*?Success\. Distance: ([\d.]+)` 配对候选与距离。

**判据**：`-q` 模式下 `distance > strong_rec_thresh` 就 skip。
所以「skip + 有候选 + 最小距离 0.16~0.25」= 差一点点，放宽阈值就能救；
「skip + 最小距离 > 0.4」= 检索词已经坏了，**放宽阈值没用**。

### 坑 25【本次最大发现】专辑名里的「碟号 / 幕次」是隐藏的匹配杀手

38/98 个失败都是这个原因，症状非常有迷惑性：

| tag 里的 album | 后果 |
|---|---|
| `情缘十载'95友学友台湾演唱会 Disc1` | search term 带上 `Disc1`，MB 找不到，或匹配到别的 |
| `Black & White (Black)` | 括号里的碟标被当专辑名 |
| `雪狼湖(第二幕)` / `雪狼湖(第一幕)` | 把「幕」当专辑名，第一/第二幕被当成两张不同专辑 |
| `友情演绎DISC7` | 同上 |
| `1/2世纪演唱会CD1` | 同时含 `/` 和碟号，双重污染 |
| `Smile/爱慕(粤语版)` | **含 `/`**，检索词被当成分隔/路径 |

**这类专辑的「最佳候选」其实往往就是正确答案**（如 `Disc1` 那条 best candidate 就是
`張學友 - 情緣十載：'95友學友台灣演唱會`，distance 仅 0.03），但 beets 仍然 skip ——
因为多碟目录会被**按碟拆成多个导入单元**，每张碟只有一半曲目，跟 MB 的完整 2CD release 对不上。

**结论：先清洗 album 字段（去碟号/幕次/斜杠），比调阈值有效得多。**
本次实测：阈值 0.04→0.15 只把成功数从 9 提到 22；而 A+B 类 39 个只要改 tag 就能全部自动入库。

### 阈值到底能救多少（本次实测）

| 阈值 | skip | 说明 |
|---|---|---|
| 0.04（默认） | 111/120 | 简繁差异（0.08~0.12）就已超阈 |
| 0.15 | 98/120 | 只救回 13 个 |

**不要指望靠调阈值解决批量匹配问题。** 阈值只对「候选正确但距离略高」有效。

### 顺带：判「源是否已被处理过」

`_split/` 子目录的存在说明 cue 已被拆过；`已转换专辑/` 与 `_版本不同/` 是归档区
（后者的 `_DUP_VERSION.txt` 头部写明「匹配到 MB 条目，但库中已有该专辑的其它版本」，
内含完整 beet 日志和 `beet import -A --search-id <id>` 的手工指定命令）。
**归档区目录名与源目录名可能因版本标记不同而对不上，别指望按目录名 join。**

---


---

## Phase 11 — 每批转完后在 `Music/` 生成批次播放列表（m3u）

（2026-09-30 实测：为《经典老歌1688首》1066 首生成 `Music/《经典老歌1688首》.m3u`）

**用户约定：每批转化入库后，都要在 `Music/` 下留一个 `.m3u`**，用于整体播放/抽查。
命名与批次名对齐，直接放 `Music/` 根（`Music/<批次名>.m3u`），不放子目录。

### 写法（三条硬规矩）

1. **必须用相对路径**（相对 m3u 所在目录），否则整个 `Music/` 目录搬迁、换挂载点、或换机器读
   就全断链。`os.path.relpath(path, M).replace(os.sep, '/')` → `歌手/歌名.wma`
2. **UTF-8 无 BOM**，首行 `#EXTM3U`；每条配 `#EXTINF:时长,歌手 - 曲名`
3. 顺序按**源目录序号**（`_入库清单.tsv` 第一列），这样播放顺序和原合集一致

```python
M   = '/vol2/1000/电影音乐/Music'
D2  = '/vol2/1000/电影音乐/已转换专辑/<批次目录名>'
OUT = os.path.join(M, '<批次名>.m3u')

rows = []
with open(os.path.join(D2, '_入库清单.tsv'), encoding='utf-8') as fh:
    next(fh)                                   # 源文件/歌手/曲名/落盘路径
    for line in fh:
        p = line.rstrip('\n').split('\t')
        if len(p) >= 5:
            rows.append((int(p[0]), p[2], p[3], p[4]))   # (序, 歌手, 曲名, 落盘绝对路径)
rows.sort(key=lambda x: x[0])

lines, miss = ['#EXTM3U'], []
for num, artist, title, path in rows:
    if not os.path.isfile(path):
        miss.append((num, path)); continue         # 缺失要报出来，别静默吞
    try:    dur = int(round(ASF(path).info.length))    # wma→mutagen.asf.ASF；mp3/flac→mutagen.File
    except Exception: dur = -1                        # 读不到写 -1，播放器照放
    lines.append('#EXTINF:%d,%s - %s' % (dur, artist, title))
    lines.append(os.path.relpath(path, M).replace(os.sep, '/'))

with open(OUT, 'w', encoding='utf-8', newline='\n') as fh:
    fh.write('\n'.join(lines) + '\n')
```

直接读归档区 `_入库清单.tsv`，**不要回查 `beets.db`** —— 省一次全表归一化比对，而且天然
就是「本批」的范围，不会混进库里别的同名曲（这正是坑 26 的同类陷阱）。

时长读取走 mutagen 头解析，1066 个 wma 约半分钟，不必后台。

### 校验四项（缺一不可）

```bash
# 1) 条目数 == 库内该格式条目数（本次 1066 == 库内 .wma 总数）
# 2) 路径不存在 0    3) 重复条目 0    4) 绝对路径条目 0
```

```python
items = [l for l in txt.split('\n') if l.strip() and not l.startswith('#')]
assert len(items) == len(set(items))                       # 重复 0
assert not [i for i in items if i.startswith('/')]          # 全相对
assert not [i for i in items if not os.path.isfile(os.path.join(M, i))]   # 缺链 0
```

再顺手报一下总时长（累加 `#EXTINF` 的秒数）写进说明文件——本次 1066 首 = 72 小时 50 分，
这个数字对用户判断「这批值不值」很有用。

### 变体：批次尚未归档（没有 `_入库清单.tsv`）

2026-09-30《精选123部无损音乐专辑合集》实测：源目录里还有未处理整轨不能归档，因此拿不到
`_入库清单.tsv`。改用 **beets `added` 时间窗**圈定本批，反而更精确：

```python
DAY = '2026-09-30'
albs = [r[0] for r in c.execute(
    "select id from albums where date(CAST(added AS INTEGER),'unixepoch','localtime')=?", (DAY,))]
```

**先自证窗口干净**：跑 `select date(CAST(added AS INTEGER),'unixepoch','localtime') d, count(*) from albums group by d`，
**当天新增专辑数应等于本批成功导入的单元数**（本次 101 == 77+24）。
相等 → 放心用该日窗口；不等 → 当天混进了别的批次，需再按路径/名称二次过滤。

排序键改用 `(album_id, disc, track)`：`album_id` 递增 = beets 导入序 = 源目录遍历序，
比按专辑名排更贴近原合集播放顺序。

**另一个坑**：`items.added` 存的是 float 时间戳字符串，`items` 表上 `strftime/date` 会返回 NULL
（`albums.added` 才是可解析的时间）。要按天筛 items 时，**不要直接 `date(items.added)`**，
而是先由 `albums` 圈出 album_id 列表，再用 `album_id in (...)` 取 items。

### 坑 27【踩过】非 ASCII 路径别直接写进 heredoc 重定向

`cat > /vol2/.../已转换专辑/《经典老歌1688首wma 5.4G》/_说明.txt <<'EOF'` 会报
`No such file or directory`，路径在 `》` 处被拆断（多层 SSH 传参 + 中文路径所致）。
**一律先赋变量再引用**：`D2='...《...》'; cat > "$D2/_说明.txt" <<'EOF'`。
同目录的 `ls`、`mv`、`find` 全用 `"$D2"` 引用，别重复写中文字面量。

### 坑 28【踩过】`_split` 目录可能带后缀，判「已处理」要按前缀

多 CD 单元的分割产物目录是 `_split.CD1` / `_split.CD2` … 而非裸 `_split`
（《精选123部》里的「极致：小提琴全集」「小提琴大师精选集」都是这种）。
用 `basename == '_split'` 判断会把已切好的 5 张 CD 整套误判成「未处理」。
**一律用 `x.startswith('_split')`**，并在 `os.walk` 里 `dirs[:] = [d for d in dirs if not d.startswith('_split')]`
剪枝（否则遍历整棵分割产物树，白白慢十倍）。

### 生成「待人工处理整轨」清单的正确姿势

先按**目录树**判是否已处理，别只看一级目录（一级目录下某个 CD 切过，不代表整张都切过）：

```python
def split_below(d):                     # d 自身或任意子目录下有 _split* → 该单元已处理
    for root, dirs, files in os.walk(d):
        if any(x.startswith('_split') for x in dirs): return True
        dirs[:] = [x for x in dirs if not x.startswith('_split')]
    return False

# 候选 = 音频 > 80MB（排除分轨小文件）且 split_below(所在目录) 为假
```

过滤阈值取 **80 MB**：整轨 wav/ape/flac 普遍 130 MB 起，分轨单曲很少超过 80 MB，正好切开。
再对每个候选跑 `ffprobe -show_entries format=duration` 补时长，表格里带上时长便于用户判断。

**最后务必回查库内确认这些专辑确实没入库**（`albumartist like '%歌手%'`），
否则会把「已入库但源文件保留」的单元误报成待处理。

### 兼容性提示（写进说明文件）

- 播放器（VLC / foobar2000 / 飞牛自带）显示中文乱码时，**把扩展名改成 `.m3u8` 即可**，内容不用改
- 这批是 `.wma`，个别移动端/网页播放器不支持 wma 解码——放不出是解码问题，不是列表问题


---

## Phase 13 — 批次归档 + 库内「元数据清洗」与全库自检（2026-09-30 实测）

### 13.1 归档源目录到 `已转换专辑/`

目标目录**已存在**时不要 `mv 源 目标`（会嵌套成 `目标/源/…`）。

```bash
# 正确姿势：逐项搬，同名则合并
for x in "<源>"/*; do
  n="$(basename "$x")"
  if [ -e "<目标>/$n" ]; then cp -a "$x"/* "<目标>/$n"/; else mv "$x" "<目标>/"; fi
done
```
- **动手前先预演**：算出「直搬 N 项 / 合并 M 项 / 冲突 K 项」，K 必须为 0 才执行。
- 合并前必须确认两侧**内容零重叠**（比文件名 + 尺寸），否则是覆盖而不是合并。
- 收尾顺手删掉 0 字节的垃圾文件（本次清掉一个 `《经典老歌1688首wma` 空文件）。
- 搬完 `rmdir` 空的源目录。

### 13.2 库内元数据清洗的正确顺序（**顺序错了会白干**）

**物理文件是第一公民**。beets 库（`beets.db`）和 FLAC 内嵌标签是**两套独立数据**，
播放器只读内嵌标签，所以三者必须同时改，缺一不可：

```
① 备份 beets.db（cp -a beets.db beets.db.bak.<日期>-<标签>）
② 预演：算出 items 变更集 + 目录/文件改名映射，检查 目标重复=0、目标已存在=0
③ 改 DB（items + albums）
④ 移动/改物理文件与目录（mkdir -p 目标目录；shutil.move）
⑤ 重写内嵌标签（mutagen FLAC）
⑥ 删空目录；重建 m3u 播放列表
⑦ 全库自检 + 库↔标签逐条比对
```

### 13.3 只改「该改的字段」——更新条件写宽会静默毁数据

先按字段级 diff 决定要不要 UPDATE，**不要用「任一字段不等就整行 set」的懒写法**：

```python
# 反例：odt 取到 0（NULL 被 or 0 兜成 0），与 n_dt=None 不等 → 整行被无条件覆盖
if old[0]!=na or oy!=ny or odt!=n_dt or oat!=at:
    cur.execute('update albums set album=?,year=?,disctotal=?,albumtype=? ...')
```
本次代价：59 张张学友专辑的 `albumtype`（album/ep/live/compilation）被一并写成空串。
**兜底做法（本次采用）**：回滚到备份，再跑一个只 set 目标字段的精确定位脚本。
> 判断「要不要写」时把 `None` 与 `0` 统一：`norm = lambda v: v or 0`。

### 13.4 繁化简转繁：`zhconv` 的四类误伤必须回退

```python
from zhconv import convert
BACK = [('徵途','征途'), ('認牀','認床'), ('隻想','只想'), ('隻願','只願'),
        ('隻有','只有'), ('羣','群')]           # ← 实测必踩
def to_hant(s):
    t = convert(s, 'zh-hant')
    for a, b in BACK: t = t.replace(a, b)
    return t
```
| 误伤 | 原因 | 回退 |
|---|---|---|
| `征途`→`徵途` | 简体的 `征` 兼「征/徵」 | 回退（`征途/征戰/征服` 都用 `征`） |
| `認床`→`認牀` | `床/牀` 异体 | 回退 |
| `只想`→`隻想`、`只願`→`隻願` | 简体的 `只` 兼「只/隻」 | 回退 |
| `群`→`羣` | 异体 | 回退 |
- `用 convert(s,'zh-hans')!=s 判「含简体」是错的`：`妳→你` 会制造大量假阳性。
  **正确判据：`convert(s,'zh-hant') != s` 才说明含简体。**
- 判定前先想清楚**粒度**：本次用户要「繁化」的是 `album` 字段；
  但全库 `albumartist` 惯例是**简体**（陈奕迅/张学友/林俊杰…），
  `artist` 惯例是**繁体**（張學友 616 / 陳奕迅…）。**字段不同，惯例可能相反，别一把梭。**

### 13.5 权威源校对：机器转换 ≠ 结论

`zhconv` 只给字形，**给不了正确性**。本次靠检索修正了 3 处：
- `[超白金精选1]` → 实为 **《超白金精選》(2004 广东音像, 16 首)**（曲目逐条对上）
- `张学友16年金曲精选` → 实为 **《張學友16年金曲精選 VOL.1》(2001)**（「16 年」指 1985 起算 16 年）
- `Amour / 遙遠的她` → 实为 **《遙遠的她·Amour》(1986, 12 首)**，不是二合一
- 另修正错别字：`太阳升辰` → `太陽星辰`
> 判据优先级：平台曲目逐条比对 > 百科条目 > 字形转换。

### 13.6 「同名专辑」到底是不是重复？——三个证据

| 证据 | 结论 |
|---|---|
| 同名文件 MD5 **完全相同** | 真重复，合并 |
| MD5 不同，且**整张时长均匀偏移 ~2 s** | 同专辑**不同压片/复刻**（本次 1995/2013、1989/2007 两对） |
| MD5 不同，且**个别轨道差 20 s**（如 秋意濃 375.6 vs 395.7） | 不同版本，**不要合并** |
```bash
cd "<专辑目录>" && md5sum *.flac | sort      # 与另一张逐条比
```
结论：三对都保留，靠 `year` 与目录年份前缀区分（`1989 只願一生愛一人` / `2007 只願一生愛一人`）。

### 13.7 `x.N.ext` 重名文件（`.1`/`.2`…）的判别与处置

```python
pat = re.compile(r'^(.*)\.(\d+)(\.[A-Za-z0-9]+)$')
```
- **先排假阳性**：古典曲名自带 `No.2`/`Op.35` —— 规则：主干以 `No` 或 `Op` 结尾就跳过（本次排掉 12 条）。
- **有同名伙伴**（同目录存在 `x.ext`）→ 同题不同版本 → 消歧为 `x (另一版).ext`
- **无同名伙伴**（孤儿）→ 后缀无意义 → 直接去掉 `.N`
- 改名前必须检查目标路径不在库内、也不在磁盘上（防覆盖）。

### 13.8 改了路径，**所有 m3u 都要重建**

本次只动了 32 个文件，却让批次 m3u 出现 32 条失效路径。
生成脚本用「导入日期」圈批次（`date(CAST(added AS INTEGER),'unixepoch','localtime')=<批次日>`），
换路径后**直接重跑即可**，别手改 m3u。校验四项：条目数 / 路径失效 0 / 重复 0 / 绝对路径 0。

### 13.9 全库自检四项（每一轮收尾都跑）

```python
1) 库内 path 全部 os.path.exists   → 期望 0 失效
2) 库内 path 去重                 → 期望 0 重复
3) os.walk(Music) 反查孤儿文件    → 期望只剩 m3u8 与 cover.jpg
4) 空目录                         → 期望 0（find . -mindepth 1 -type d -empty -delete）
```
再加一项**库↔标签逐条比对**（title/album/artist/tracknumber/discnumber/date 按年比），
本次 676 条张学友全部对齐，发现并修掉两类残留：`date='1993'` 丢月日、`disctotal` 标签没跟着库改。

### 13.10 顺带：cover.jpg 挂进 albums.artpath

专辑目录里有封面但 `albums.artpath` 为空时：

```python
c.execute('update albums set artpath=? where id=?', (sqlite3.Binary(path.encode()), aid))
```

#### 坑 30【踩过】同一个 sqlite 游标做嵌套查询，外层结果会静默变空

```python
for aid, al, ap in cur.execute('select id,album,artpath from albums'):   # ← 外层
    cur.execute('select path from items where album_id=?', (aid,))       # ← 复用同一游标
```
第二次 execute 会让外层迭代器失效，表现为「待挂专辑永远 0」。
**用两个连接/游标**，或先 `fetchall()` 再循环。

#### 坑 31【踩过】改 DB 时必须同步改**物理路径**

beets 的 `path` 是权威定位，改了 `album`/`title`/`year` 就等于改了模板推导出的路径：
- `$albumartist/%if{$year,$year }$album/$track $title` → 改 album 要**重命名目录**，改 title 要**重命名文件**
- 轨号前缀**从旧文件名原样保留**（`^(?P<p>\d+\s+)`），别自己按 `%02i` 重算——各专辑补零规则不一致
- 文件名要按 beets 规则做 `sanitize`：POSIX 下 `\` 与 `/` → `_`
  （本次 `长流不息（张学友/黎瑞恩）` → `…（張學友_黎瑞恩）`）
- 时间戳有意义的标题要小心：`除了這些 還有......` 这类**标题自带尾点**的，去掉碟号后要与旧名对照确认

### 13.11 同名专辑消歧：后缀从**内嵌权威标签**取，别自己编

三对同名专辑已判定「不同压片」，光靠目录年份前缀不够——播放器里仍显示同名专辑。
**加后缀前先去读内嵌标签**，`musicbrainz_albumcomment` / `media` / `catalognumber` 常常直接写着版本性质：

```bash
python3 -c "
from mutagen.flac import FLAC
f=FLAC('<任一曲目>')
for k in ('musicbrainz_albumcomment','media','catalognumber','label','date','originaldate'):
    print(k, f.get(k))
"
```

本次实测拿到：

| 专辑 | 原版 | 再版（标签原文） | 后缀 |
|---|---|---|---|
| 吻別 | 1993 Polydor | 2012 Universal, `media=Digital Media` | `吻別 (數字版)` |
| 真愛：新曲＋真正精選 | 1995 Polydor `527 657-2` | 2013 Universal HK, `albumcomment=K2HD` | `真愛：新曲＋真正精選 (K2HD)` |
| 只願一生愛一人 | 1989 Polydor 磁带 | 2007 Universal HK, `albumcomment=復黑王` | `只願一生愛一人 (復黑王)` |

**原则：原版保持干净名，只给再版加后缀**（否则两张都变脏名，不划算）。
`K2HD`（高音质再制）、`復黑王`（环球黑胶复刻系列）都是行业通用标识，比笼统的「復刻版」精确得多。
改后缀 = 改 `albums.album` + `items.album` + **目录名** + 内嵌 `album` 标签 + `albums.artpath`（目录变了，封面绝对路径要跟着改）。

### 13.12 `zhconv` 的字形盲区：**繁体异体字它一律不动**

`zhconv` 只做「简→繁」映射。`祇`/`衹`/`傢` 这类**本身就是繁体、只是用字不规范**的字，
`convert(s,'zh-hant')` 前后完全一致 → 用 `convert(s,'zh-hant')!=s` 判定「含简体」会**整批漏掉**。

本次实测：上一轮宣称「曲名繁化完成」，实际还有 **11 条**含 `祇`/`衹` 的曲名没动：
`祇願一生愛一人` / `祇有你不知道` / `祇想一生跟你走`（跨 10 张专辑，含 1 条单曲）。

**收尾必扫清单**（每轮繁化后按字逐个 `LIKE` 扫一遍全库）：

```sql
select id,album_id,title,album from items
 where title like '%祇%' or title like '%衹%' or album like '%祇%' or album like '%衹%'
    or title like '%傢%' or title like '%麼%' or title like '%祗%';
```

> 注意 `祇`(qí, 地神/只) 与 `祗`(zhī, 敬) 是**两个字**，别混。
> 判定「该不该改」仍要回到权威源：本次「只願一生愛一人」是官方用字，粤语唱片惯用「只」。
> **改 title 会连带改文件名**——同一批一起做，别分两次跑。

### 13.13 改文件前先算「m3u 命中」，别盲目重跑

改动集算出来后，**先核对这批文件被哪些 m3u 引用**：

```python
abs_ent={os.path.normpath(os.path.join(M,e)) for e in m3u_entries}
hit = abs_ent & (oldset | newset)
```

本次 45 个改动文件**命中 0**（属 9-28/9-29 批次，不在两个 m3u 的批次窗口内），
说明播放列表本不受影响；但仍重跑一次生成脚本作为兜底。
判据是「m3u 按 `added` 日期圈批次」，**只有改动文件落在该批次窗口内才会影响列表**。

### 13.14 备份文件堆积的归档法（每轮收尾都该看一眼库根目录）

连续做几轮清洗后，库根目录会堆满 `beets.db.bak.<日期>-<标签>`。
归档原则：**根目录只留 2 个有效回滚点，其余移到归档目录（移动，不删除、不压缩）**。

```bash
BASE=/vol2/1000/电影音乐
ARC=$BASE/_db_backups_archive
mkdir -p "$ARC"
cd "$BASE"
# 明确列文件名逐个 mv，不用通配符（防误伤 beets.db 本身）
for f in beets.db.bad.* beets.db.bak.旧批.* wubai_tag_*.json; do
  [ -e "$f" ] && mv "$f" "$ARC/"
done
```

要点：
- **保留哪些**：不看 mtime 看语义。`bad`/`中间态` 即使 mtime 最新也不是有效回滚点。
  优先保留「**最近一次有实际改动的前置状态**」（如张学友清洗前、归档批改动前）。
- **先验唯一性**：`md5sum beets.db.bak.* | sort` —— 本例 14 个 MD5 全不同，确实无冗余副本可删。
  若发现两个 MD5 相同，说明中间有一次是白做的，可只留新的。
- **必写 `README.md`**：逐个标注「文件 → 对应阶段 / 时间」+ 回滚命令 + 何时可整目录删除。
  否则一周后就不知道 `bak.20260929-flat` 是什么了。
- **回滚不会回滚音频文件**：恢复 `.db` 只恢复库记录，磁盘上的路径/文件名/内嵌标签不受影响，
  需另行按变更记录反向执行。README 里必须写明这一点。
- 归档后**立刻验证当前库仍可打开**：`select count(*) from items / albums`。

> 同类遗留：处理目录扁平化/大批量导入时若用过「回收站」式目录（如 `.flat_recycle`），
> 收尾时应检查其体量并提请用户确认——本次发现一个 **21 GB / 902 文件**的回收站，
> 属 GB 级决策，**不在自动化授权范围内，必须交用户定夺**。
> （2026-10-02 复查：`_media_archive` 已到 **594 GB / 26713 文件**，其中
> `_车载U盘合集_20260930` 单个目录就 553 GB、`_已在库专辑_20260930` 18 GB、
> `dup_20260930` 3.2 GB —— 磁盘尚余 12 TB，无空间压力，仍一律不动、只报告。）

#### 坑 108【踩过】更新归档 README 时，拿「下一节标题」当锚点会把标题本身吃掉

想在某节前插入新内容，很容易写成「以 `\n## 如何回滚` 为锚点做替换」，
而替换串**没把锚点标题原样带回** → `## 如何回滚` 直接从 README 里消失
（正文还在但没了标题，属结构性损坏，`cat` 全文很难一眼看出）。

```python
# 错：锚点被吞
md = md.replace('\n## 如何回滚', '\n<新章节>\n\n')
# 对：锚点原样写回
md = md.replace('\n## 如何回滚', '\n<新章节>\n\n## 如何回滚')
```

**改完必须回读校验**：`grep -n '^##' README.md` 把改前改后的标题清单比一遍，少一个就是中招了。

> 顺带一个 Python 陷阱：`str.replace(old, new, count)` 第三个参数是**次数**（int），不是字符串。
> 把整段新文本误传成第三个参数会报 `'str' object cannot be interpreted as an integer`。
> 同理 `re.Pattern.sub(repl, s, count)` —— 别把 `s` 写两遍。

### 13.15 判断「回收站 / 源素材目录」里的东西是否已入库 —— 三层核对法

场景：清理工作留下的 `_recycle` / `_extras` / `源副本` 目录，需先回答「这些内容库里有了吗」，
**不能靠文件名直接比对**（导入时 beets 会按模板重命名，源文件名与库内路径毫无关系）。

```
第一层 曲名匹配（主力）  文件名 → 归一化 → 比对全库归一化曲名集合
第二层 尺寸匹配（辅助）  与 Music/ 全盘文件的字节尺寸比 → 只能识别「字节级重复」
第三层 标签复核（兜底）  残余项读 ID3/Vorbis 的 title 再查一次
```

⚠️ **第二层只能证明"是"，不能证明"否"**：同一首歌的 `wav` 与 `flac`/`mp3` 尺寸必然不同，
所以「尺寸查不到」≠「没导入」。本例 `dup_*` 块 471 文件尺寸命中仅 3 个，但曲名命中 100%。

#### 曲名归一化函数（踩了三个坑才写对）

```python
def clean(s):
    s = s.strip()
    s = re.sub(r'^(\d{1,3})[\s._]+', '', s)      # 轨号前缀 —— 后面必须有分隔符！
    s = re.sub(r'\.\d{1,2}$', '', s)              # 重名后缀 .1/.2
    s = re.sub(r'[\(\uff08][^\)\uff09]*[\)\uff09]', '', s)   # 括号备注
    s = re.sub(r'[._\-\u2013\u2014\uff0d]+', ' ', s)          # 点/下划线/各种横杠
    return re.sub(r'\s+', ' ', s).strip()

def norm(s):
    t = clean(s).replace(' ', '').replace('&', '').replace('&', '')
    t = re.sub(r'[?:：？!！,，]', '', t)            # 标点全角半角统一去掉
    return convert(t, 'zh-hans').lower()           # 繁简归一
```

| 坑 | 现象 | 修正 |
|---|---|---|
| 分隔符只写 `' - '` | `伍佰 And China Blue-放浪舞者` 整串当曲名 → 漏 | 补 `-`（无空格）与 `_` |
| 轨号正则 `^\d+` | `199玫瑰` 被吞成 `玫瑰` → 漏 | 改成 `^(\d{1,3})[\s._]+` |
| 标点未归一 | `你們在哪裡?` / `配樂:下雨` / `對白:護士服` 查不到 | 去掉 `?:：？` 等 |

**并给多个候选名**（完整串 / 按 `-` 切后半 / 按 `_` 切后半），任一命中即算命中：

```python
def cands(base):
    out = [base]
    for sep in (' - ', '-'):
        if sep in base: out.append(base.split(sep, 1)[1])
    if '_' in base: out.append(base.split('_', 1)[1])
    return out
```

#### 结论怎么写才可信

- **必抽样人工复核**：随机取 10~15 个"命中"项，打印「源文件名 → 库内 artist/album」对照，
  确认不是同名不同曲的假阳性。本例 15/15 正确（含 `原来你什么都不要`→库内`原來你什麼都不要`）。
- **残余项逐个读标签**：`mutagen.File` 取 `title`/`TIT2`，往往能解释为什么文件名匹配不上。
- **单文件大素材要单独判定**：整场演唱会/整轨 DTS 这类**无内嵌标签的单文件**，
  按曲名无从匹配。此时应说明「其**内容**（同场演唱会）是否已在库」+「该**载体**（多声道原盘）是否入库」，
  这是两个问题，别混为一谈。

> 核心心态：**算出的命中率偏低时，先怀疑自己的归一化，别急着下"未导入"的结论。**
> 本例经历 93.5% → 99.6% → 895/896 三跳，前两跳全是自己的 bug。

#### 归档落位

音频素材与数据库备份**分目录存放**，语义不混：

```
_db_backups_archive/          # beets.db 各阶段备份
_media_archive/               # 音乐素材（回收站、源副本、原盘）
  └─ README.md                # 核查方法 + 各块命中结论 + 何时可删
```

### 13.16 影像/非音乐素材的入库判定（微电影、花絮、访谈、整场实录）

从 Blu-ray / DVD 影音全纪录里拆出来的**非音乐内容**（微电影、筹备纪录、照片集锦、访谈），
入库前先回答两个问题：

**问题一：它是什么？** —— 多数情况能在官方发行文案里直接找到答案。
本次靠检索确认：`微電影「我在哪裏」` = 伍佰为「大感謝」20 週年巡演**自掏 500 万拍的串场微电影**，
官方文案写明它属《生命的现场 Live - 20周年大感谢台北演唱会影音全纪录》的
「**特别收录**」（与 54 首正式曲目并列但性质不同）。

**问题二：挂专辑还是做单曲？**

| 内容性质 | 归属方式 |
|---|---|
| 音乐曲目（Live 版、加歌） | 挂进对应专辑，注意 `disc`/`disctotal` 与既有曲目一致 |
| **影像素材 / 特别收录 / 非音乐** | **做独立单曲**（`album_id=NULL`），别混进音乐专辑 |

本次选单曲，理由：
- a404《生命的現場》库内 54 首，与官方「54 首完整收录」**完全吻合** —— 它是纯净的音乐专辑，
  塞一条 7 分钟微电影进去会破坏这个语义
- 库里已有 8 个伍佰单曲（`誰是老大.mp3` / `赴湯蹈火.mp3` / `重生.flac` …），单曲是既有常态形态

**单曲字段范式**（照抄现有单曲，避免自创）：

```python
row.update(dict(album_id=None, album='', track=0, tracktotal=0, disc=0, disctotal=0, comp=0,
                year=<作品年>, month=0, day=0,
                artist=AA, albumartist=AA,           # 单曲 also 填 albumartist
                length=info.length, bitrate=info.bitrate, format='FLAC',
                samplerate=info.sample_rate, bitdepth=info.bits_per_sample, channels=info.channels,
                mtime=os.path.getmtime(dst), added=time.time(),
                encoder=(f.get('encoder') or [''])[0]))
# 其余列按类型给默认：数值列 0、文本列 ''、rg_*/initial_key 给 None
```

**出处必须可溯**，否则半年后不知道这 7 分钟是什么：
- `comment` 写「<活动>串场微电影；<专辑>特别收录」
- `genre` 给 `Soundtrack`（别留空）
- `date` 与同批内容保持一致（本次用演唱会年 2012，而非发行年 2014，与 a404 对齐）

**用字先查库内惯例再定**：本次 `裡`(8 条) vs `裏`(0 条) → 文件名从源来的「我在哪裏」统一成「我在哪裡」。

#### 坑 32【踩过】源目录结构本身可能是错的，导入会把错误忠实继承下来

导入后若发现**曲目数与该专辑官方曲目数不符**，回查**源目录**，别默认是自己处理错了：

```bash
ls -1 "<归档的源副本目录>" | wc -l        # 源到底有几个文件
```

本次实例：
- `2000-电影歌曲典藏1992-2000` 源目录只有 **13** 个文件（官方 16 首，源就缺 `愛你一萬年`/`樓仔厝`）
- `2001-梦的河流` 源目录多放了 `伍佰 - 配乐：下雨.mp3` → 导入后成了《夢的河流》第 13 首
- 结果：a389 = 13 首（少 3）、a390 = 13 首（多 1）

**用官方曲目数当基线反查**是发现这类问题最有效的手段：
逐张比对「库内曲目数 vs 官方曲目数」，不等就去查源。
若源就缺文件，**不要用其他专辑的同名版本硬凑**（Live 版≠录音室版），如实标注缺口。

### 13.17 曲目错专辑的「归位」——先查官方曲序，往往要整张重排

发现某张专辑里混进了本不属于它的曲目时，别急着「插一首进去」——**先查官方曲序**。

本次实例：a390《夢的河流》里多出 `配樂:下雨`，按官方它属 a389《電影歌曲典藏1992-2000》**第 9 首**。
归位前用 4 个来源（HMV / tagtuner / 滚石购物网 / music-social）交叉核对官方 16 首曲序，结果发现：

**库内 a389 的轨号与官方本来就是错位的** —— `稀微的風中`(库内 9 / 官方 14)、
`何時再見夢中人`(库内 5 / 官方 15)、`衝衝衝`(库内 8 / 官方 16)。

所以正确做法不是「插到第 9 位再顺移」，而是**整张按官方曲序重排**。

```python
# 归位一份曲目要同时改四处：物理文件名 / 内嵌标签 / items 行 / （换专辑时）year
PLAN = [
 dict(iid=7615, trk=14, src='…/09 稀微的風中.mp3', dst='…/14 稀微的風中.mp3', trk_s='14'),
 dict(iid=7631, trk=9,
      src='…/2001 夢的河流/13 配樂_下雨.mp3',
      dst='…/2000 電影歌曲典藏1992-2000/09 配樂_下雨.mp3',
      trk_s='9', newalb='電影歌曲典藏1992-2000', newyear=2000),
]
for p in PLAN:
    if p['src'] != p['dst']:
        shutil.move(p['src'], p['dst'])
    a = ID3(p['dst'])                                     # MP3；FLAC 则用 FLAC()
    a.setall('TRCK', [TRCK(encoding=3, text=p['trk_s'])])  # 必须用 Frame 对象
    if p.get('newalb'):  a.setall('TALB', [TALB(encoding=3, text=p['newalb'])])
    if p.get('newyear'): a.setall('TDRC', [TDRC(encoding=3, text=str(p['newyear']))])
    a.save()
    cur.execute('update items set track=?,album_id=?,album=?,year=?,path=?,mtime=? where id=?', …)
```

要点：

- **MP3 用 `mutagen.id3`**（`TIT2`/`TALB`/`TPE1`/`TPE2`/`TRCK`/`TDRC`），键名与 FLAC 的 Vorbis 完全不同；
  **写轨号/年份必须包成 Frame**（`setall('TRCK',[TRCK(...)])`），直接赋字符串会报 `'x' not a Frame instance`。
- **换专辑要连 `year` 一起改**（本次 2001 → 2000，与目标专辑一致），否则标签与库自相矛盾。
- **移动顺序**：若新文件名要占用旧文件名的轨号前缀（新的 `09` 抢旧 `09` 的位置），
  **先移走旧的、再放新的**——按 PLAN 列表顺序执行即可，别用无序集合。
- **补零惯例跟专辑走**：本例文件名补零（`09 xxx.mp3`）而 ID3 `TRCK` 不补零（`9`）——
  改完要与同专辑其他曲目一致；**校验时把 `'09'` 与 `'9'` 归一比较**，否则会报一堆假不一致。
- **缺口不硬凑**：源里没有的曲目就如实留空（本例 a389 保留 `t5`/`t8` 空位），
  不用其他专辑的同名 Live 版填——Live 版 ≠ 录音室版。
- 归位后 a389 = t1–t16 连续编号（缺 5、8）= **14/16**；a390 从 13 → **12/12**。


---
