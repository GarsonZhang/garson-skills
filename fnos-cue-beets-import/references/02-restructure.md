# 专辑归并重组 · 源素材处置

> 涵盖：同歌手多目录合并去重（Phase 8）、源素材「已入库即冗余」判定（Phase 16）、
> 散曲专辑化重组（Phase 17）、源素材区批量处置（Phase 18）、
> 歌手合辑建专辑（Phase 19）、大套歌手合集并入（Phase 20）、扁平无损散曲重组（Phase 21）。

## Phase 8 — 同歌手的「多目录」合并 + 冗余去重（2026-09-29 实测 160 目录 → 95 目标）

### 先认清对象

`Music/` 下的一级目录**全部是 `$albumartist`**（config 里 `default` 和 `singleton` 模板都以 `$albumartist` 开头）。
所以「同一歌手被拆成多个文件夹」= **tag 里 albumartist 有多个写法**。合并必须走 beets（改 tag → `beet move`），
**直接 `mv` 会让库 path 与实际文件脱节**。

判据：`select count(distinct albumartist) from items` vs `ls Music | wc -l`。
两者差得多（如 541 vs 553），差额就是「tag 与目录不一致」的错位目录。

### 坑 24【最坑，必踩】`beet modify` 只改一半，`beet move` 会原地不动

```
beet modify albumartist=X 'albumartist::旧名'      # 默认是 ITEM 模式 → 只改 items.albumartist
beet move 'albumartist::X'                        # 报 "Moving 0 items (706 already in place)"
```

**专辑曲目的目标路径由 `albums.albumartist` 决定**，而 item 模式不动 albums 表 →
beets 认为文件已在位，一根毛都不动。**必须再跑一遍 album 模式**：

```bash
beet modify    -y -m albumartist="$T" "albumartist::$K"   # singleton / 专辑外散曲
beet modify -a -y -m albumartist="$T" "albumartist::$K"   # 专辑曲目 + 同步 albums 表
```

`-m/--move` = 改完即移文件，一步到位。两遍都要跑，缺一不可。
自检看 `albums.albumartist` 的 distinct 数是否同步下降。

### beets 1.6 查询语法速查（实测）

| 写法 | 语义 |
|---|---|
| `field:value` | 大小写**不敏感**子串（`albumartist:王菲` 会命中 `王菲菲`、`刘欢王菲`） |
| `field::value` | **精确匹配**（`albumartist::BEYOND` 只出 BEYOND，不出 Beyond） |
| `path:value` | **对 blob 类型字段失效**（本项目 6093/7241 条 path 是 blob） |
| `path::value` | 可用（大小写敏感子串），`path::/Music/BEYOND/` 精确锁定目录 |
| `id:12` / `id:1..9` | 单条 / 范围；**不支持逗号列表** `id:1,2,3` |
| `+` `&` 等 | 值里的 `+` 会被解析器吃掉（`林忆莲+李宗盛` 查不到）→ 改用 `id:` 绕过 |
| 空格 | 值里含空格会被当**多条件 AND** 解析，注意加引号或用 `id:` |

`beet modify` 无 `-s`/`-p` 选项（1.6），`-a` 是 album 模式，`-m` 是移动，`-y` 跳过确认。
`beet move` 无 `-y`，有 `-p/--pretend` 可 dry-run。

### 映射表生成算法（可直接复用）

```
1. 归一化 norm(s): NFKC → 简繁统一(zhconv 'zh-cn') → 去空白(含全角) → 小写
                   → 去 [-_–—] → 去括号注释 → 去 ·.。，、'" 等标点
2. 精确簇: group by norm(s)；簇内代表 = item 数最多者（同数需人工指定，否则不稳定）
3. canon 优先查「别名表」：簇内任一名在 ALIAS 里 → 用它映射后的值
4. 合作拆分 first_artist(s): 按 [&、+/]|vs|feat 取第一段 → 若其 norm 命中主歌手表 P → 归它
   否则前缀匹配：norm(s) 以某个 P 的 key 开头且更长 → 归它（`张学友王菲` → `张学友`）
5. 显式兜底：ALIAS（艺名/英文名/错字）、EXCL（禁止前缀归并）、COMPIL（合辑→群星）、CANON_OVR
```

**EXCL 必须有**，否则会被前缀匹配误伤：
`陈明真`→`陈明`、`李健达`→`李健`、`王菲菲`→`王菲` 三对是**不同歌手**。

**同 item 数的簇必须用 CANON_OVR 显式定名**（如 `贝贝`/`贝  贝`、`4 IN LOVE`/`4 In Love`、
`张清芳`/`張清芳`），否则 `max()` 取谁取决于 dict 插入顺序，不可复现。

### 合辑类的收尾（用户要求「统一为群星」时）

光改 tag 不够 —— beets 对 compilation 专辑走**内置 `comp` 模板**，会固定输出到 `Compilations/`。
必须同时改 config：

```yaml
paths:
    comp: '$albumartist/%if{$year,$year }$album/$track $title'   # 覆盖内置 comp 模板
va_name: 群星                                                     # 以后新导入合辑的 albumartist
```

### 冗余去重（同类目「只留最佳格式」）

只处理 **singleton**（`album_id is null`），专辑内曲目不动（保护专辑完整性）：

```python
PRI = {'FLAC':0, 'APE':1, 'WAVE':2, 'MP3':3}
key = norm(title)                      # NFKC + 小写 + 去空白 + 去标点
group by (albumartist, key)
组内按 (格式优先级, -时长, id) 排序，依次遍历：
    若与已保留项的**时长差 ≤ 3 s** → 判为同一版本，丢弃
    否则 → 视为不同版本（Live/精选/不同录音），保留
```

**时长保护是必须的**：`Beyond 光辉岁月` 有 FLAC 302 s 与 APE 297 s 两个「同曲不同版本」，
无保护会被误删。（本轮 557 条候选，加保护后实际删 471 条。）

**执行方式**：先 `shutil.move` 到 `.flat_recycle/dup_YYYYMMDD/`（保持相对路径，可回滚），
再 `delete from items where id=?` 批量删记录。**不要逐条 `beet remove`**（471 次 ≈ 15 分钟）。

### 历史坏数据：`b'...'` + `_xXX` 二次转义

症状：`Music/b'Beyond'/b'24K_xe9_x87_x91_...CD1'/01 不再犹豫.wav` —— 早期脚本用 `str(bytes)` 写 db 造成的。
`os.path.exists()` 会返回 **True**（坏目录真的被建出来了），所以「path 失效 0」的自检**发现不了它**。

还原：

```python
def fix_component(x):
    x = x.strip()
    if len(x)>3 and x[0]=='b' and x[1] in ("'", '"') and x[-1]==x[1]:
        x = x[2:-1]                                    # 剥 b'...'
    if '_x' in x:
        b = codecs.escape_decode(x.replace('_x', '\\x').encode('latin-1'))[0]
        x = b.decode('utf-8')                          # _xe9_x87_x91 → 金
    return x
```

先 `shutil.move` 实际文件到还原后的路径，再 `update items set path=?`。

**新增自检维度**：除 `path 失效 / 重复 path` 外，还要比对 `(albumartist, path 第一级目录)` 是否成对，
并注意 `to_dir()` 要复现 beets 的 replace 规则（`/`→`_`、结尾 `.`→`_`），否则 `/` 分隔的合作名会全被误报。

---


---

## Phase 16 — 源素材目录「已入库即冗余」的判定与归档
（2026-09-30 实测：`音乐/《中华儿歌珍藏集6CD合集打包》[无损FLAC]/` → 归档 924 MB / 160 个 mp3）

### 16.1 先核「目录名 ↔ 实际内容」是否一致

本次目录名写着 `[无损FLAC]`，**实际 160 个文件全是 mp3**，无损整轨并不在其中。

> 迅雷 / 资源站目录名**不可信**。先数扩展名再下结论：
> `find "$D" -type f -printf '%f\n' | sed 's/.*\.//' | tr 'A-Z' 'a-z' | sort | uniq -c | sort -rn`

### 16.2【关键】同一专辑的「无损版 vs 降级版」并存

| | 库内 a103–a108 | 本次源目录 |
|---|---|---|
| 格式 | **FLAC** | mp3 |
| 体积 | ~18 MB/首 | ~6 MB/首 |
| 位置 | `Music/群星/2010 中华儿歌珍藏集N/` | `音乐/…/分轨_…[mp3]/` |

**同专辑同曲目、只是码率不同** → 这不是「重复文件」，而是「同一专辑的降级副本」。

> **大小差 ~3 倍是强信号**：库里比你手上的副本大得多，多半库里才是无损版。
> **判定前务必查库内 `format`**：`select format, count(*) from items where album_id=? group by format` ——
> 别把「无损 vs mp3」误判成「内容不同」而不敢动。

### 16.3 删前必做：**逐曲核对**（不是抽样）

```python
# 源目录每首（去轨号 / 去备注词 / 繁简归一）→ 能否在「库内同专辑标题集合」里找到
norm(name_without_trackno) in set(norm(t) for t in lib_titles_of_that_album)
```

- 目标：**未覆盖 == 0**。少一首就不能删（库里没有的曲目，删了就丢了）。
- **同时查**：目录内**非音频文件 / 隐藏文件**是否为 0（cue / 封面 / readme / `.DS_Store` 等）。
- **抽验**库内目标文件 `ffprobe` 可解码（防「库里记着、磁盘是空壳」）。
- 曲数对照也要打印出来（每辑 库 vs 源），一眼看清是否成套。

```python
def norm(t):  # 去备注词 + 去标点 + 去空格 + 小写
    for w in ['电影','插曲','动画片','主题歌','电视专题片','主题曲','片头曲','片尾曲']:
        t = t.replace(w, '')
    return re.sub(r'[\s\-_—－\.]+', '', t.replace('《','').replace('》','')).lower()
```

### 16.4 处置：移入 `_media_archive`，不要直接 `rm`

即使用户说「删」，**默认先移入归档区**：
`mv "<源目录>" "_media_archive/<名称>_<日期>/"`，并在 `_media_archive/README.md` 追加一节，写清
**来源 / 判定依据 / 污染情况 / 何时可删除 / 可释放多少**。

> **`rm` 不可逆；`mv` 到归档区同样达成「从素材区移除」，且留退路。** 彻底删除等用户第二次确认。
> 归档区本身是「待清理区」，README 会累计每批的「可释放体积」，方便日后一次性回收。

---

## Phase 17 — 散曲按「网上权威元数据」专辑化重组
（2026-09-30 实测：394 首散曲 → 380 首重组进 182 个专辑，182 张封面全成，349 个 lrc 随迁；14 首保持散曲）

### 17.0 适用场景与前置

用户先要求「批量入库为散曲」，随后追加「**能匹配到专辑就优先放进专辑**」+「**tag 全部以网上为准，源 tag 只是参考**」。
此时**不要重新导入** —— 在**已入库的散曲上做重组**：改元数据 → 移动文件 → 建专辑记录 → 下封面。

前置：已完成平台探测，每首拿到 `album / albumartist / year / track / cover`。

### 17.1 平台通道：酷狗主、网易云辅（限流警示）

| 用途 | 接口 |
|---|---|
| 搜索候选 | `mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=K&page=1&pagesize=N` → `songname/singername/album_name/album_id/filename/trans_param` |
| 专辑详情 | `mobilecdn.kugou.com/api/v3/album/info?albumid=ID&format=json` → `albumname/publishtime/imgurl/singername` |
| 专辑曲目 | `mobilecdn.kugou.com/api/v3/album/song?albumid=ID&format=json&page=1&pagesize=N` → 每条 `filename`="歌手 - 曲名"、`trans_param.sort`=曲号、`duration` |
| 曲号兜底 | `music.163.com/api/song/detail?ids=[ID]` → `no`(曲号)、`al.publishTime`；**必须带 `Referer: https://music.163.com/`** |

> ⚠️ **网易云 `api/search/get/web` 极易限流** —— 连续快速请求会**整批返回空**（实测 374/394 失败）。
> 逐首搜索必须限速 ≥1s，或直接改用酷狗。酷狗实测 **184/184 专辑**都拿到了 year/cover/songs。

> 酷狗专辑曲目的曲名字段是 **`filename`**（"歌手 - 曲名"），**不是 `songname`**（那是搜索接口的字段）；
> 曲号在 `trans_param.sort`。用错字段会拿到一堆 None。
> 封面 URL 含 `{size}` 占位符，需替换为像素值（如 `500`）后再下载。

### 17.2【坑 37】beets `albums` 表**没有 `path` 列**

beets 1.6 的 `albums` 表（37 列）里**没有 path**，专辑目录由 `items.path` 的 dirname 派生。
验证脚本里若写 `SELECT path FROM albums` 会直接报 `no such column: path`。

```python
d = os.path.dirname(some_item_path)   # 想拿专辑目录：从该专辑任一 item 的 path 派生
# 走 API 时 alb.path 是运行时算出来的可用属性，但别去查表
```

### 17.3【坑 38】`Item.move()` 生成的路径**不符合库惯例**

`it.move(MoveOperation.MOVE, basedir=...)` 按 `paths.default` 模板生成 →
`郑智化/游戏人间/游戏人间.mp3`：**缺年份目录、文件名未补零**，
与库内既有 `2010 中华儿歌珍藏集1/01 xxx.flac` 风格不符。

**自己算路径**，别依赖模板：

```python
def san(t):
    return re.sub(r'[\\/:*?"<>|\r\n\t]', '_', (t or '').strip()) or '_'

adir = os.path.join(MUS, san(aa), ('%s %s' % (year, san(al))) if year else san(al))
ext  = os.path.splitext(src)[1] or '.mp3'
fn   = ('%02d %s%s' % (track, san(title), ext)) if track else (san(title) + ext)
os.makedirs(adir, exist_ok=True)
if os.path.isfile(os.path.join(adir, fn)):  # 防覆盖
    fn = ...
shutil.move(src, os.path.join(adir, fn))
it.path = os.path.join(adir, fn).encode('utf-8'); it.store()
```

> 曲号不连续是**正常的**：精选集往往只包含某专辑的几首，`01/04/05/06/07/09` 这种缺号不要"修"。

### 17.4 reuse 已有专辑时：目标目录必须取专辑**现有**位置

复用（库内已有同名专辑）时若仍按自算模板拼目录，**一旦两者不一致，文件就搬到 `alb.path` 并不指向的地方** →
库记录与磁盘长期错位（播放器能看到条目、路径却是错的）。

```python
if reuse:
    _p = existing[key].path
    adir = _p.decode('utf-8') if isinstance(_p, bytes) else _p   # 跟着专辑现有目录
else:
    adir = os.path.join(MUS, san(aa), ...)                       # 只有新建才自算
```

### 17.5【坑 39】音频搬家**必须同步搬同名 `.lrc`**

散曲目录里 `标题.lrc` 与 `标题.mp3` 是平级的。只搬 mp3 → 专辑目录里没歌词，
散曲目录留下**孤儿 lrc**（播放器不认、人工也难判断该删哪）。

```python
old_title = it.title          # ⚠️ 必须在赋新 title 之前存下来
...
nlrc = os.path.splitext(dst)[0] + '.lrc'          # 目标是"与音频同名"
if not os.path.isfile(nlrc):
    for cand in (old_title, it.title, os.path.splitext(os.path.basename(src))[0]):
        c = os.path.join(os.path.dirname(src), cand + '.lrc')
        if os.path.isfile(c) and os.path.abspath(c) != os.path.abspath(nlrc):
            shutil.move(c, nlrc); break
```

本次 380 首搬出 **349 个 lrc**；搬完全库扫一遍 **孤儿歌词 = 0**。

### 17.6 试跑后要改逻辑？**先回滚，再统一重跑**（别留两套代码）

本次先跑 9 首验证 → 发现「目录缺年份」「lrc 没跟走」两个问题。
**错误做法**：给这 9 首单独打补丁 + 新脚本处理剩余 371 首（两套代码、两种中间状态）。
**正确做法**：写回滚脚本把这 9 首**移回散曲位置 + `album_id=NULL` + 删专辑记录 + 清空遗留目录**，
修好脚本后**全量重跑一次**。

```python
# 回滚三件套（缺一不可）
shutil.move(it.path, 原散曲路径)
cur.execute('UPDATE items SET path=?, album_id=NULL WHERE id=?', (dst, i))
cur.execute('DELETE FROM albums WHERE id=?', (aid,))
```

> 专辑化脚本**大致幂等**（第二次跑时专辑已存在 → 走 reuse；`src==dst` 跳过移动），
> 但**半成品状态最难排查** —— 宁可回滚重跑。

### 17.7 skip 机制：与库内老专辑"不合"的单曲主动跳过

自动匹配会把 1 首单曲塞进一张库内已有的老专辑，可能造成：
- 与库内同曲的既有版本**重复**（本次《黑白灰》库里已有 7 个 FLAC，含同名「兄妹」）
- 混入该专辑的**历史脏标签**（老 FLAC 标题是 `陳奕迅 - 兄妹` 这种未清洗格式）

```python
SKIP = set(json.load(open(skip_file)))    # 例如 ['黑白灰']
...
for (aa, al), rows in groups.items():
    if al in SKIP: continue
```

> 判据：**命中该专辑的曲数很少（1–2 首）且库内已有该专辑** → 先跳过、写进报告让用户定夺。
> 别为了"整齐"去污染一张本来就有问题的老专辑。

### 17.8 验证脚本的三个要点

1. **定位本批次** —— `added` 时间戳断点法（新批次的 `added` 与上一批有明显间隔）：
   ```python
   rows = list(cur.execute('SELECT id,added FROM items ORDER BY added DESC LIMIT N+30'))
   TH = None
   for k in range(len(rows) - 1):
       if rows[k][1] - rows[k+1][1] > 3600:
           TH = rows[k+1][1]; break
   ```
2. **反查索引要含"网上名"** —— `title` 已被网上元数据改写，必须用 `(norm(网上艺术家), norm(网上曲名))` 反查，
   源名只作兜底；否则会误报一堆「找不到」。
3. **全量体检** —— 专辑目录存在 / `cover.jpg` 存在 / 每个 `items.path` 都 `isfile` / 同专辑无多目录 / 孤儿 lrc 为 0。

### 17.9 播放列表（m3u8）搬家后**必须重建**

`Music/xxx.m3u8` 用**相对路径**，文件一进专辑目录，旧条目全部失效。重建时同样要兼容两套名字：

```python
cands = [(norm(p['artist']), norm(p['title']))]                     # 源名
pr = probe.get(p['no'])
if pr: cands.append((norm(pr.get('sg') or ''), norm(pr.get('sn') or '')))   # 网上名
m = meta.get(p['no'])
if m:  cands.append((norm(m['src_artist']), norm(m['src_title'])))          # 原始名兜底
```

本次重建后 **470 条、路径失效 0**。顺带一说：播放列表**该不该保留已进专辑的曲目**由用户定 ——
本次按"合集"语义全量保留，只是路径指向新位置。

### 17.10 beets Python API 速查

```python
import sys; sys.path.insert(0, '/usr/share/beets')
from beets import config; config.set_file('/home/garson/.config/beets/config.yaml')
from beets.library import Library
lib = Library(DB)

lib.items()             # 全量 item
lib.albums()            # 全量专辑（alb.path 为运行时计算属性）
lib.add_album(items)    # 把一批 item 合成一张专辑（自动分配 album_id）
it.store()              # 只写库
it.write()              # 写文件内嵌标签
it.get_album()          # 取所属 Album 对象
alb.artpath = p.encode('utf-8'); alb.store()   # artpath 是 BLOB，必须 encode
```

> `lib.items(album_id=None)` **不支持这个参数**（会 `TypeError`）；
> 取散曲用 `[it for it in lib.items() if it.album_id is None]`。
> 另外 `Library` 直接打开同库时，注意**别与正在运行的 `beet` 命令并发写**。

### 17.11 库 ↔ 文件标签比对

```python
f = mutagen.File(path, easy=True)    # 各格式统一出 title/artist/album/date/track
```

> `easy=True` 对 mp3 / flac / mp4 / asf 通用（**ASF/WMA 的键名归一后也是 `title/author/...`**，见 15.7）。
> **只比对本批次**（其余是历史脏数据，会把噪声淹没真问题）。
> 本次 395 条 → **0 不一致、0 读取失败**。

### 17.12 备份与回滚点

```bash
cp -p beets.db beets.db.bak.$(date +%Y%m%d)-albumize
```

按项目约定把根目录收敛回 **2 个有效回滚点**（更旧的移入 `_db_backups_archive/`）：

| 保留 | 含义 |
|---|---|
| `-albumize` | 本次专辑化**完成**后 |
| `-guoyu` | 本系列操作**开始前**（可整体回退） |

> 归档区 README 要**同步补表格行**（本次补了 `-art` / `-tag` 两条）；
> `_media_archive/README.md` 也要追加本批**来源 / 判定 / 处置 / 何时可删**。

---

## Phase 18 — 源素材区的批量处置（归档 / 入库 / 待定）
（2026-09-30 实测：`音乐/` 46 个目录 / 899 GB / 34310 文件）

### 18.1 第一步：目录级摸底（**不要**一上来就逐个处理）

```python
for name in sorted(os.listdir(SRC)):
    # 体积 / 文件数 / 子目录数 / 扩展名分布（Counter.most_common(8)）
```

一眼能看出三类：**大杂烩合集**（几千 mp3）／**专辑型资源**（flac+cue+jpg）／**空壳残留**（0 文件）。

> **先把 0 文件的空壳 `rmdir` 掉**（本次 2 个），别混进后续统计。

### 18.2 第二步：两级比对，**tag 才是准的**

只按文件名解析会**严重高估"未入库"**（大量文件不带歌手，或带 `(Live)`／`-《某电影》主题曲` 这类长尾巴）。
正确做法是**两级**：

| 级别 | 手段 | 用途 |
|---|---|---|
| 粗筛 | 文件名解析（去编号 / 去营销后缀 / ` - ` 分词 / 繁简归一） | 快速出覆盖率画像 |
| 精筛 | `mutagen.File(fp, easy=True)` 读内嵌 tag → `(norm(artist), norm(title))` 查库 | **定处置** |

> 文件名解析时要**同时试"去开头编号"和"不去"**两种（`^\d{1,4}` 可能是轨号，也可能是歌名开头如《1987…》），任一命中即算命中。
> 营销后缀（`10倍音质`／`3D环绕`／`HIFI`／`车载`）建议在归一化时剔除。

### 18.3 三条路线

| 覆盖率 | 内容特征 | 处置 |
|---|---|---|
| 高（≳90%） | 正常专辑/合集 | **归档**（移动，可逆） |
| 低 | tag 干净、专辑形态完整 | **入库** |
| — | 目录里有**整轨**（时长 >900s） | **待定**：先剔整轨，见 18.5 |

**判据补充**：广告 tag 覆盖（`小高网分享`／`公众号：XX资源库`／`www.xx8g.com`）、
**GBK 乱码 tag**（`´³ºìµÆµÄ¶ÅÀÙË¹` 这种 `latin1` 误解码）、`- 10倍音质` 后缀 —— 
同时出现这几样，基本可判为**倒卖的劣质车载合集**，不入库，直接归档。

> 本次 6 个车载目录（592 GB）就属此类，且**三个目录互为近重复**（未命中数 2510/2510/2508）——
> 「近重复」本身也是"倒卖合集"的强特征。

### 18.4【坑 40】`beet import -p`（pretend）**不阻止 `-m` 移动文件**

实测：`beet import -A -m -q -p "<目录>"` **真的把文件移动并入库了**（本次误移 11 个文件）。
不要指望 `-p` 做安全预演。

> **安全预演要自己写**：先只收集 + 打印计划，`--apply` 才动手（见 17.6 的自控脚本模式）。
> 或者干脆**全程用 beets Python API 自控**，不碰 `beet import` 的 CLI。

### 18.5【坑 41】「整轨 + 分轨并存」的目录 → `beet import` 会**双导入**

整轨 flac/ape 的 `track` 为空 → beets 给它 `track=0`，**单独建成一张只有 1 首的专辑**
（本次 `Music/赵雷/2016 无法长大/00 无法长大.flac`，363 MB），而分轨另建一张 —— **同一专辑两份**。

```python
# 判整轨：时长 > 900s 一律剔除
if tg['length'] and tg['length'] > 900: continue
```

> 这类目录的典型形态：根目录 `专辑名.flac` + `专辑名.cue` + `Cover.jpg`，另有一个 `_split/` 子目录放分轨
> （**很多下载站把分轨藏在 `_split` 里**，`os.walk` 能进去，但人工 `ls` 容易忽略）。
> **只导入分轨，整轨退回源目录**（无损整轨本身有价值，别删）。

### 18.6【坑 42】源 tag 的 `albumartist` **完全不可信**，beets 会照着它归位

本次分轨的 tag 里 `albumartist='『溪口』民谣典藏系列'`（资源站加的系列名），
`beet import` 就**照单全收**，建出了 `Music/『溪口』民谣典藏系列/2016 赵雷《无法长大》/` ——
专辑艺术家、目录层级全错。

> 这正是"**tag 必须从网上权威源获取**"的实证：源 tag 只配当匹配线索，不配当元数据。
> 自控脚本里，`albumartist` 要**用酷狗/网易云的结果覆盖**，源值只作搜索关键词。

### 18.7 误导入的修正三件套

```python
# 1) 分轨归位：改 album/albumartist/year + 移动到正确专辑目录
it.album='无法长大'; it.albumartist='赵雷'; it.year=2016; it.store()
shutil.move(p, dst); it.path=dst.encode('utf-8'); it.store()
# 2) 整轨退回源目录 + 删库记录（不删文件）
shutil.move(track_path, src_backup); it.remove()
# 3) 删掉被创建的错误空目录
os.rmdir(错误专辑目录); os.rmdir(错误 albumartist 目录)
```

### 18.8 顺带发现的「孤儿文件」

`Music/『溪口』民谣典藏系列/2016 赵雷《无法长大》/` 里那 10 个 flac **磁盘上有、库里没记录**
（被 beets 当"已有目标"合并进去后，源目录仍留下文件；或历次导入残留）。

> 全库自检（17.8 的"文件存在性"检查）只查「库→磁盘」方向，
> **反方向（磁盘有、库无）要单独扫**：
> 遍历 `Music/` 的音频 → 路径不在 `items.path` 集合里 → 即孤儿。
> 这类文件容易被"归档/清理"误伤，处置前先扫一遍。


---

## Phase 19 — 源素材区「歌手合辑目录」批量建专辑（2026-09-30 实测 14 目录 / 1479 音频 → 1040 首 / 451 专辑）

源素材区里大量目录形如「周深 无损音乐集」「李宗盛[1986-2018]所有专辑合集」——
**一个目录里混装同一歌手的几十张专辑**。既不能当"整目录 = 一张专辑"导入
（`import_src_album.py` 的老思路），也不能全走逐曲检索（会把一张整碟拆成十几张微专辑）。
核心是**先把目录切成"专辑单元"，再决定每个单元用哪种映射**。

### 19.1 第一步：把目录切成「专辑单元」

**专辑单元 = 音频文件所在的叶子目录**（不是 `SRC` 的顶层子目录！顶层常常只是分类容器）：

| 目录形态 | 例子 | 单元取法 |
|---|---|---|
| 分类容器 + 专辑目录 | `周杰伦无损专辑+单曲/无损FLAC/七里香/` | 取**叶子目录** `七里香` |
| 双层容器（同名嵌套） | `陈一发儿无损音乐合集/陈一发儿mp3/陈一发儿mp3/` | 叶子名是容器 → 退回逐曲 |
| 整轨 + 分轨并存 | `曹格专辑/2012-11-荷里活的动物园[台湾][WAV]/_split/` | `_split`/`split`/`分轨` **上溯一级** |
| 多碟目录 | `陈奕迅无损音乐专题/2010-DUO…3CD/CD1/` | `CD1`/`Disc2`/`碟3` **上溯一级** |
| 扁平（无子目录） | `程响 无损歌曲/曲名-歌手-id.flac` | 无单元 → 见 19.3 |

```python
d = os.path.dirname(os.path.relpath(fp, SRC))
if d:
    b = os.path.basename(d)
    if b.lower() in {'_split','split','分轨','_split_','splits'}: d = os.path.dirname(d)
    if DISC.match(os.path.basename(d)): d = os.path.dirname(d)      # ^(cd|disc|碟|d|vol)\s*\d+$
    unit = os.path.basename(d) or None
```

**容器目录黑名单**（叶子名不是专辑名，而是分类层）→ 归入"扁平"走逐曲：
```python
CONT = re.compile(r'(?i)^(无损(音乐|flac)?|flac格式|mp3格式|wav格式|.{0,20}格式|'
                  r'.{0,20}打包.{0,20}|.{0,20}下载.{0,20}|.{0,20}合集|'
                  r'[^\[\]（）()]{0,24}?(mp3|flac|wav|ape|m4a|wma))$')
```
> 注意用 `$` 锚定：`1992-Karen[mp3]` **不能**被判成容器（`[mp3]` 结尾是 `]`），
> 而 `陈一发儿mp3` 要判成容器。

### 19.2 专辑名的三种来源，优先级是「可信 tag > 目录名解析 > 网上检索」

1. **可信 tag 专辑**（`_saneB(tag_album)`）——如《甜歌精选 CD1–CD5》、周杰伦各专辑。
   直接按它分组，最省事也最准（配 19.3 的编码修复后）。
2. **目录名解析**——`parse_unit()` 从 `2017-阿拉德-宿命之门 DNF动画原声带（周深部分）` 里剥出年份与专辑名。
3. **逐曲酷狗检索**——只用于上面两者都拿不到的散曲。

**写 `_saneB()` 时必须与艺术家校验分开**：
```python
BADEND = re.compile(r'(经典|流行|音乐|歌曲|榜|合集|精选|推荐|试音|车载|发烧|休闲|串烧|单曲|专辑|无损|打包|下载|未知|unknown|various|群星|va)', re.I)
BADALB = re.compile(r'(未知|unknown|various|^\s*(群星|va|no album|合辑)\s*$)', re.I)
def _sane(x):    # 艺术家：黑名单全开
def _saneB(x):   # 专辑：只挡「未知/various/空泛」
```
> **踩过**：一开始用同一套黑名单，`精选/合集` 把《甜歌精选 CD1》这类真专辑名全毙了，
> 结果 5 张 CD 被打散成 100+ 个微专辑。**专辑名的合理性标准本就比人名宽松**。

### 19.3【坑 43】老中文文件的 tag 是 **GBK 字节按 latin1 读出**的乱码

实测：`音乐/pt80《龚玥_走天涯_CD2》/01 母亲.mp3` 的 tag 读出来是
`artist='¹¨«h'`、`title='Ä¸Ç×'`、`album='Î´Öª³ªÆ¬¼¯'` —— 即 `龚玥` / `母亲` / `未知唱片集`。
这类文件在素材区**成片存在**，不修就会：搜索用脏关键词 → 拿到垃圾专辑；写回也是乱码。

```python
def fix_enc(s):
    if not s: return s
    try: b = s.encode('latin-1')
    except Exception: return s
    if all(c < 128 for c in b): return s
    for enc in ('gbk', 'gb18030', 'big5'):
        try: d = b.decode(enc)
        except Exception: continue
        if re.search(r'[\u4e00-\u9fff]', d) and not re.search(r'[\u00c0-\u00ff]', d):
            return d
    return s
# 读 tag 后立刻: artist,title,album,aa = map(fix_enc, (...))
```
> 判据：解码结果里**有汉字且没有残留的 Latin-1 重音字符**。`big5` 放最后兜底。

### 19.4【坑 44】`artist` 也别信 tag，从**源目录名**推更稳

同一批文件里 `artist` 可能是 `2015`、`因为你 所以我`、`『溪口』民谣典藏系列` 这种垃圾
（资源站把专辑名/年份塞进了 artist 字段）。而**源目录名反而干净**：`周深 无损音乐集` → `周深`。

```python
SKW = ['无损音乐合集','无损音乐集','无损音乐专题','无损音乐','无损专辑','无损歌曲','无损单曲',
       '黑胶全集','所有专辑','专辑歌曲','专辑','单曲','合集','精选','系列','音乐','歌曲','全集','打包','下载','无损']
SITE = re.compile(r'(?i)^(pt\d*|www|bbs|com|cn|net|org|hires|dsd|hifi|flac|mp3|wav|ape|cd|disc|vol|no)$')
# 去 []/【】/《》→ 去关键词 → 去数字符号 → 取第一个「像名字」且不在 SITE 里的 token
```
再用**全目录 tag 的多数派**做补全（`Michael` → `Michael Jackson`），
但要求该多数派**占比 ≥ 50%**，否则会把混合合集的某个高频歌手误当成整目录的艺术家。

### 19.5【坑 45】beets 1.6 `Library.add()` **只吃 Item，不吃路径**

```python
lib.add('/path/x.flac')          # ❌ AttributeError: 'str' object has no attribute 'add'
```
`Library.add(obj)` 内部是 `obj.add(self)`，传 str 就直接炸。正确写法：
```python
from beets.library import Library, Item
it = Item.from_path(dst)          # 读文件 → Item（失败会抛异常，正好当校验）
if it is None: raise Exception('无法读取音频')
lib.add(it)
it.title = ...; it.store(); it.write()
```

### 19.6【坑 46】`lib.add(Album(...))` 返回的是 **rowid**，不是对象

```python
alb = lib.add(Album(album=al, albumartist=aa, year=y))   # ❌ alb 是 int，alb.id 报错
```
建专辑一律走**已验证**的 `lib.add_album(items)`：
```python
for 目录 in 分组:                     # ← 必须按目录/专辑分组建，不能把 4 张专辑的 items 一起传
    alb = lib.add_album(该组 items)   # 会自动写 album_id
    alb.artpath = cover_path.encode('utf-8'); alb.store()
```
> **踩过**：补录脚本把 4 张专辑的 41 个 items 一次性 `add_album`，
> 结果 41 首全挂到**同一条 album 记录**上（专辑名取了第一条）。按目录分组即可。
> 修正时的可靠判据是 `len(list(a.items()))`（`lib.items(album_id=…)` 在 1.6 不存在，见坑 37）。

### 19.7【坑 47】同专辑 FLAC/MP3 双份 → 必须组内去重

`李宗盛[...]/FLAC格式/1993-希望/` 与 `MP3格式/1993-09-01 希望/` 是**同一专辑的两种格式**，
按专辑名分组后会合进同一组 → 双导入。组内按 `(disc, 归一化曲名, 曲号)` 去重，**音质优先**：

```python
RANK = {'.flac':5, '.ape':5, '.wav':4, '.m4a':3, '.wma':2, '.mp3':1}
key = f"{disc}|{norm(title)}|{track}"
if key in seen:  保留 RANK 更高者
```
本次 14 目录共去掉 **116 首**重复（李宗盛、周杰伦、莫文蔚最集中）。

### 19.8【坑 48】`-CDA/-CDB` 是同一专辑的双碟，`CD1/CD2` 是不同卷

- `今生爱的就是你-CDA` / `-CDB` → 归一为专辑 `今生爱的就是你`，**写 `disc=1/2`**；
- `甜歌精选 CD1…CD5` → **保持 5 张分立专辑**。

```python
mm = re.search(r'(?i)[\s\-_]*(?:cd|disc|碟)\s*([a-e])\s*$', alb)   # 只认字母碟号
if mm:
    disc = ord(mm.group(1).upper()) - 64
    alb  = alb[:mm.start()].strip(' -_')
```
`it.disc = r.get('disc',1)`，排序键 `(disc, track, filename)`。

### 19.9 扁平目录的三种去向（按优先级）

```
① 可信 tag 专辑  → 按 tag_album 分组（《甜歌精选 CD1-5》、周杰伦各专辑）
② 曲号恰好 1..N 且不重复（≥4 首）→ 视为「一整盘」：用代表曲目取 年份/封面，整组同一专辑
③ 其余 → 逐曲酷狗检索，按专辑分组；检索无结果 → 作**散曲**存 `Music/<artist>/曲名`
```
> **踩过**：先用"曲号重启"切整盘，结果《甜歌精选》5 张 CD 各自从 01 开始 →
> 被切成几十个碎片。**判据要严格**：`len(tracks)==len(flat)==len(set(tracks))` 且等于 `range(1,N+1)`。
> 双碟编号重叠的目录就自然落到逐曲，反而正确。

### 19.10【坑 49】扩展名会撒谎：按**魔数**判定真实格式

| 现象 | 魔数 | 处置 |
|---|---|---|
| `.flac` 实际是 WAV | `RIFF....WAVE` | 改名 `.wav` 再入库（本次 1 例，73 MB 救回） |
| `.mp3` 实际是 M4A | `....ftypmp42` | 改名 `.m4a` |
| `.mp3` 只有 ID3 头、后面无有效帧 | `ID3\x03` 之后扫不到同步字 | **损坏残件**（多为迅雷未下完）→ 隔离 |

```python
b = open(p,'rb').read(16)
if b[:4]==b'RIFF': newext='.wav'
elif b[4:8]==b'ftyp': newext='.m4a'
# 改名后再 Item.from_path()，成功则正常补录
```
> `mutagen` 的报错信息很有用：`can't sync to MPEG frame` = 无有效帧；`is not a valid FLAC file` = 容器不对。

### 19.11 收尾必做：四向校验 + 目录清理

```python
# 库→磁盘：items.path 是否都存在
# 磁盘→库：Music 下音频是否都在 items.path 集合里（孤儿）
# 空目录：os.listdir == []
# 空专辑：len(list(a.items())) == 0
```
清理「只剩封面」的目录时要**限定文件类型与数量**，否则会误删
`Music/群星/洗脑电音·魔幻绕耳/`（15 个 `.dts` 文件，扩展名不在标准音频表里）：

```python
IMGTXT = ('.jpg','.jpeg','.png','.bmp','.gif','.txt','.log','.cue','.url','.db','.ini')
if 无音频 and 无子目录 and len(ents) <= 6 and all(扩展名 in IMGTXT): 才删
```
> 本次清掉 12 个目录（8 个空艺术家目录 + 3 个失败导入留下的"仅封面"目录 + 1 个空父目录）。

### 19.12 本次脚本清单（`cue_tool_work/`）

| 脚本 | 作用 |
|---|---|
| `coll_import3.py` | 主程序：单元切分 → 分组 → 去重 → 搬移 → 入库 → 封面（`--apply` / `--limit=` / `--units`） |
| `recover_add.py` | 补录：扫描 Music 下已就位但不在库的文件 |
| `fix_bad_b.py` | 按魔数纠正扩展名后补录；损坏件隔离 |
| `clean_dirs.py` | 空目录 / 仅封面目录清理 |
| `verify_b.py` | 四向校验（缺失 / 孤儿 / 空目录 / 空专辑） |
| `gen_report_b.py` | 从执行日志生成专辑明细报告 |

> 网上通道仍以**酷狗**为主（稳定），只用来补 `年份 / 封面 / 规范专辑名`；
> 规范名**必须与原名互相包含**才采纳，否则会像坑 42 那样被带偏。



---

## Phase 20 — 大套「歌手合集目录」批量并入 / 新建（2026-09-30 实测：张学友 108 G → 684 曲入库）

适用：源区里是「某歌手全部专辑/单曲」的巨型目录树（整轨 ape/flac + cue + `_split`、
"伪单曲"目录、`歌手.-.[专辑].专辑.(APE)` 命名）。目标是把它们并进库里已有的同名专辑，
缺的才新建。

### 20.1【坑 50】老中文文件 tag 是 **GBK 字节被按 latin1 读出** 的乱码

`ÎÇ±ð` = 吻别、`ÇéÍø` = 情网。**不修编码，任何"库内是否已有"的比对都会大面积漏判**
（初版把 96 个已入库单元误判成未入库，等于要重复导入 96 张专辑）。

```python
def fix_enc(s):
    if re.search(r'[\u4e00-\u9fff]', s):     # 已是正常中文就别动
        return s
    try:
        d = s.encode('latin1').decode('gb18030')
    except Exception:
        return s
    return d if re.search(r'[\u4e00-\u9fff]', d) else s
```
> **只在原串无 CJK 时才尝试** —— 否则会把正常中文二次破坏。
> 还要处理**双重编码**（`ç²¾é\x80\x89`）与 `CJK + 单个 PUA 字符`（`鏈\ue046煡鑹烘湳瀹?`）。

### 20.2【坑 51】比对专辑名必须限定在**目标艺术家的专辑集合**内

跨全库做子串包含会把张学友的单元误配到莫文蔚专辑 `[i]`、`如果爱忘了`、
`Eason&Friends 903 id club拉阔音乐会`。→ 先 `select album from albums where albumartist=?`
拿候选集合，再在其中匹配。

### 20.3【坑 52】短名子串包含过松

`Jacky Cheung 15` 含 `Jacky` → 被并进 `Jacky` 专辑（真发生过，已回滚）。
→ 要求 `min(len)/max(len) >= 0.6` 才算候选。

### 20.4【坑 53】多版本会撞同一专辑

雪狼湖 5 个版本、Touch Of Love 3 个、拉阔 3 个。
> 规则：源目录名带**版本标记**（国语版 / 引进版 / 限量珍藏纪念版 / 复黑 / 24K Gold /
> DSD / Japan / TaiWan / HongKong / Korea / K2HD / XRCD）或 **Live / 演唱会 / 音乐会**
> 字样 → **一律新建带后缀专辑，绝不并入**；其余才允许并入库内同名专辑
> （并入时按曲名去重，正好补全库内的残缺专辑）。

### 20.5【坑 54】`歌手.-.[专辑].专辑.(APE)` 型目录名不能用「删括号」清洗

删括号会把专辑名一起删掉。必须**提取中括号内容**；`张学友-1994-12.-.[X]` 同理。

### 20.6【坑 55】多碟必须**按父目录合并**

`Disc1/`、`Disc2/` 在多处（切分、去重、专辑归属）都要先按父目录合并，
否则"同名去重"会直接把 Disc1 丢掉。

### 20.7【坑 56】标签器必须按**真实扩展名**分支

目标文件是 mp3 时用 `mutagen.flac.FLAC()` 会全部报 `is not a valid FLAC file`
→ 整批 684 个文件 **0 个标签写入成功**（静默失败，只有看日志才发现）。
```python
mf = mutagen.File(dst)      # 或 mutagen.File(dst, easy=True)
```
统一走 `mutagen.File`，别自己 new 具体格式类。

### 20.8 「MusicBrainz 自动匹配」在本库覆盖极差

54 个暂存专辑跑 `beet -l /tmp/x.db import -q -C`，**只命中 3 个**，其余全 Skipping。
→ 别把 MB 匹配当主力；改走「清洗目录名 → 繁体化 → 并入/新建」路线。

---

## Phase 21 — 扁平「无损/母带散曲」目录：清广告 → 取数 → 专辑化重组（2026-09-30）

适用：一坨扁平目录，文件名就是 `艺术家-曲名.wav`（或完全没有文件名规律），
tag 可能全无、可能全是广告、可能 artist/title 互换。实测三目录：

| 代号 | 源目录 | 音频 | 结果 |
|---|---|---|---|
| `MB` | `高清原声母带音乐资源` | 71 WAV（192kHz/64bit，400MB~1.2GB/首，共 55 G） | 23 新 + 48 库内重复 |
| `CW` | `300多首车载女声HIFI试音碟，20倍极致音质` | 283 WAV + 28 MP3 | 282 新 + 29 重复，命中 279 |
| `JX` | `🔥精选无损音乐合集346首【WAV格式转存即听🔥】` | 342 WAV | 104 新 + 238 重复，命中 168 |
| `DL` | `刀郎…16张专辑`（余 35 WAV） | 35 WAV + `list.txt`(gb18030) | CD1 18 + CD2 17，多碟拆两条记录 |

### 21.1【坑 57 · 最严重】给 **WAV 写标签 = 必须用 `mutagen.File(path)`**

用 `mutagen.id3.ID3(path).save(path)` 会把 ID3 块写到 **RIFF 头前面**，
文件变成 `invalid start code ID3[4] in RIFF header`，beets 直接
`ReadError: can't sync to MPEG frame`。**35 个刀郎 WAV 全部写坏**，只能回滚重做。

```python
mf = mutagen.File(path)          # WAVE / MP3 对象都拿得到
if mf.tags is None:
    mf.add_tags()
t = mf.tags
is_id3 = hasattr(t, 'delall')    # WAVE/MP3 走 ID3 帧；FLAC/APE 走 dict
...
mf.save()
```
> WAV 的元数据位置：`fmt ` → `data`（巨大）→ `id3 ` → `LIST`。
> `LIST/INFO` 子块是 **GBK**：`IART/INAM/IPRD/ICRD(可能是 `2004-12-24`)/IPRT/ICMT/ISFT`。
> **`mutagen.File(p, easy=True)` 读不到 `LIST/INFO`**，会误判「无 tag」——必须自己解析 RIFF。

### 21.2【坑 58】广告藏在 **UTF-16 的 `COMM`/`USLT` 帧**里，字面量扫描扫不到

`www.carjlb.com` 在 `COMM` 帧、以 UTF-16 存；`b'www.carjlb.com'` 的字节 `find` **找不到**。
→ 必须用 mutagen 按帧取 `text`/`url` 再判：
```python
def _frame_text(fr):
    v = getattr(fr, 'text', None) or getattr(fr, 'url', None)
    return ' '.join(v) if isinstance(v, (list, tuple)) else str(v or '')
```
> **USLT 是真歌词时要保留**：文本含 `[\d\d:/d/d` 即判为歌词，跳过清理。
> CW 清了 283 个 USLT 广告（`【熊猫无损音乐www.xmwav.com】`），JX 清了 39 个 `COMM` 广告。
> 清完**必须再跑一遍同一个扫描器**确认归零，并用 `ffprobe` 复核 `comment=` 空、时长不变。

### 21.3【坑 59】酷狗 API **间歇性空返回**，空结果绝不可落缓存

`GET https://<host>/api/v3/search/song?format=json&keyword=..&page=1&pagesize=N`
同一 query 有时有结果、有时返回空数组。v1 把空返回当「无结果」写进缓存 →
758/965 条被污染 → 命中率从 25/25 崩到 87/342。

```python
HOSTS = ['mobiles.kugou.com', 'msearchcdn.kugou.com', 'mobilecdn.kugou.com']
for attempt in range(3):
    for h in HOSTS:
        lst = _query(kw, h)
        if lst:                       # 非空才算成功
            got = lst; break
    if got: break
    time.sleep(0.7)
if not got:
    KC[key] = None                   # 只在【彻底失败】后才落缓存
    return None
```
> `msearchcdn` / `mobiles` 比 `mobilecdn` 稳；`searchcdn.kugou.com` 解析不了（已剔除）。
> 另加 `--retry-null` 开关：清掉缓存里的空值重跑。
> 再加「先做库内去重」省请求（省掉 ~40%）。

### 21.4【坑 60】源文件无 tag 时，用「**文件名分词**」做二轮复核

归档区大量源文件（如 `已转换专辑/华语流行乐坛歌手精选1264首经典歌曲（无损音乐）/F-Q/刘若英 - 光.flac`）
**完全没有 tag**。只按「候选自身 tag」复核会把它们全部降级成"需人工"。

```python
def strip_num(stem):                 # 去前导编号 '01 ' / '1184..' / '062.'
    ...
def toks(stem):                      # 去编号 → 按 - – — _ 多空格 单空格 切词 → 归一化
    ...
# trust 判定：标题词命中（等值 / 是某个分词 / 长标题子串包含）
#             且 艺术家每个子词（& 、 / 拆开）都命中
```
> 实测把可自动恢复数从 **25/37 提到 34/37**。

### 21.5【坑 61】候选打分要用**分词集合**，别只做子串

只用 `want in fn` 打分时，短标题（如《光》）会有一堆 5.6 分的噪声候选
把真源挤出 top-N 窗口。加入 `want in cand_toks → +6`、`artist in cand_toks → +2` 后区分度才够。

### 21.6【坑 62】复核时 **title 和 artist 两个 tag 都要并进候选词集合**

只并 title，`原来你也在这里.ape`、`堆积情感.ape` 这类"文件名不带艺术家、只有 tag 带"的
源会判失败。

### 21.7【坑 63】不要 `attach database` 一个**已经 connect 过的**库

`sqlite3.OperationalError: database bak is locked`，即使先 `bak.close()` 仍报。
→ 改直连 INSERT：
```python
icols = [r[1] for r in cur.execute('PRAGMA table_info(items)')]
ph = ','.join('?' * len(icols))
row = bak2.execute('select * from items where id=?', (i,)).fetchone()
cur.execute('insert into items values (%s)' % ph, row)
```

### 21.8【坑 64】写库前先查**同路径重号**，别信"防重查询"

恢复脚本首跑在 `lib.add()` 之后崩（`Results` 对象没有 `.count()`），重跑时
`lib.items('path:^…$')` 的防重查询**没匹配到**（beets 路径以 bytes 存，查询语法不通用），
结果同一路径入库 2 条、建出 2 条同名 album。→ 事后必须：
```sql
select path, count(*) c from items group by path having c > 1;
```

### 21.9【坑 65】文件名里的**技术尾巴**必须剥掉，否则搜索被带偏

`张宇-单恋一枝花 WAV-192KHZ-64Pit(Precise).wav` 里的尾巴进了候选曲名，
酷狗搜出同歌手的另一首 → `单恋一枝花` 被改写成 `月亮惹的祸`；
`成龙&金喜善-无尽的爱 WAV-192KHZ-64bit(Precise)` 清不干净时留下 `无尽的爱 KHZ`。

```python
t = re.sub(r'[\s\-_]*(?:wav|flac|ape|wv|dsd)?[\s\-_]*\d{2,3}\s*(?:khz|KHz|kHz)'
           r'[\s\-_]*\d{0,3}\s*(?:bit|Bit|Pit|pit|bt|BT)?[\s\-_]*', ' ', t, flags=re.I)
t = re.sub(r'[\s\-_]*(?:wav|flac|ape)[\s\-_]*\d{0,3}\s*', ' ', t, flags=re.I)
t = re.sub(r'[\s\-_]*[（(]\s*(?:precise|hi-?res|24\s*bit|dsd|无损|母带|高清|原声)\s*[)）]',
           ' ', t, flags=re.I)
```
> 注意顺序：**KHZ 那条要先吃掉后面的 `-64bit`**，否则会剩个孤零零的 `bit`/`KHZ`。

### 21.10【坑 66】酷狗命中的三条铁律（否则会**改错歌名/塞错专辑**）

```
ok_ti = 酷狗 songname ≈ 候选曲名      # ① 曲名必须匹配
ok_ar = 酷狗 singername ≈ 候选歌手    # ② 歌手确认
规则：ok = ok_ti and (ok_ar or 候选无歌手 or 非交换序候选)
```
- **① 是硬门槛**。只匹配歌手就采纳，会把《单恋一枝花》改成《月亮惹的祸》。
- **② 交换序候选必须双匹配**。`艺术家-曲名` 型文件名要同时试 `(a,t)` 和 `(t,a)`，
  但 `(t,a)` 这一序必须要求歌手也匹配 —— 否则《你的每次呼吸》(Sting) 会被配成
  Tammy Wynette 的单曲《Sting》（歌名恰好等于 `Sting`，`same()` 命中）。
- **歌手没匹配上时，绝不能用酷狗的专辑/年份**，只能用它的曲名。
  否则《无尽的爱》(成龙&金喜善) 会被塞进关淑怡《传奇 - 真假情话》。
  例外的两种情况：候选本来就没有歌手（纯曲名搜索）→ 可以退回酷狗的 `singername`。
- **括号内容不能当歌手**：`(藏文)`、`(Remixed By Photek)`、`(Duet With Mariah Carey)`
  是补充说明，必须标记 `usable_a=False`，否则会出现 `歌手=藏文` 这种目录。

### 21.11【坑 67】源文件歌手**错别字**：用「库内同曲名 + 差一字歌手」回正

源文件里有 `伍伯-挪威的森林.wav`（应为 伍佰）、`陈淑华-梦醒时分.wav`（应为 陈淑桦）。
若库里已有同名曲、且存在**仅差 1 个字符**的歌手写法，就采用库里的写法：
```python
def edit1(a, b):     # 归一化后是否只差 1 字符（等长比对 / 短的删 1 个）
```
→ 回正后这两首直接变成"库内重复"，**不再产生 `Music/伍伯/` 这种错字目录**。

### 21.12【坑 68】`--apply` 的产物清单必须**增量合并**，否则 m3u8 丢文件

`a3_flat.py` 每跑一次会覆盖 `<DIR>_made.json`。多次/分批 apply 时必须
先 load 已有文件再 append，最后 m3u8 才能覆盖全部产物。

### 21.13 回滚脚本的**致命教训**（见 Phase 22.1）

`a3_rollback.py` 早期版对"本批目标目录"直接 `shutil.rmtree(t)` —— 而本批产物
可能被写进了**本来就有老文件的目录**（JX 往 `刘若英/`、`林志炫/`、`莫文蔚/1997 做自己/`
追加过文件），整目录删除 → **丢掉 37 个库内旧文件**。

---


---

## Phase 28 — `音乐/` 剩余项整体清空：2745 个音频 → 1791 首入库（2026-10-01 实测）

> 场景：`音乐/` 剩 23 项 / 19 GB（5 个「歌单式」合集 + 8 个歌手专题 + 6 个整轨 + 零散）。
> 目标：全部按规范落到 `Music/`，源目录归档，`音乐/` 清空。

### 28.1 链路（三段式，网络与写库错峰）
```
① a14_itunes_lib.py   2745 个文件逐首查 iTunes（term="<艺人> <曲名>"，曲名校验）
   → /tmp/a6/lib_track_cache.json        命中 2110（76.7%），耗时 2.6 h
② a16_plan.py         生成入库计划（艺人映射 + 去重 + 专辑归并 + 目标路径）
   → /tmp/a6/import_plan2.json
③ a16_apply.py        写标签 → move 落位 → beets API 写库 → 封面
   a16_verify.py       全量回读校验（库行 ↔ 文件标签）
```
结果：**入库 1786 首 / 0 失败 / 354 秒**；`音乐/` 归档 19.39 GB → 清空。

### 28.2 三条必须拍板的规则（坑 95~97）

**① 艺人名：中文名一律原样，只映射高置信英文名**
iTunes 返回 `Jonathan Lee / JJ Lin / Eason Chan`，库里是 `李宗盛 / 林俊杰 / 陈奕迅`。
不映射会造出第二套目录（把刚合并好的又拆开）。
但**投票法（按同曲在库里的 albumartist 投票）不能用于推映射**：
```
Kousuke Atari(中孝介) → 全票投给「周杰伦」   ← 他翻唱过《花海》
Peng Fang(彭芳)      → 4/6 投给「周杰伦」   ← 发烧翻唱碟
白兰滴 / 林诗曼 / 肖启伦 → 全票给「周杰伦」  ← 假艺人名
```
**规则**：中文艺人名**原样保留**（天然躲开假名）；只对**英文艺人名**查手工审定表；
表里没有的**保留 iTunes 原名** —— **映射错的危害 > 不映射**（映射错会把翻唱塞进原唱目录）。

**② 去重按「曲名 + 映射后艺人」，且必须忽略扩展名**
```
✗ 只按曲名   → 翻唱与原唱同名，会误判为重复而跳过
✗ 只按路径   → `01 城府.mp3` 与 `01 城府.flac` 是同一首的两个副本，判不出来
✓ 按「归一化曲名 + 映射后艺人」判重；按「目标路径去扩展名」在同批内消重，无损优先
```
本轮实测：跳过库内已有 773 首、同批冗余剔除 212 条。

**③ 建专辑规则与 A-3 对齐：只要取到专辑名就建专辑，不设数量下限**
（`a3_flat.py` 就是 `if r['hit'] and r['album']`）。
别自作聪明设「≥8 首才建专辑」的门槛 —— 那会把「逐曲归入原专辑」变成「全落散曲」。
本轮 1619 个专辑组（1547 个只有 1 首）+ 37 散曲。
散曲要**清空 `album` 字段**（库内既有 3434 条散曲都是 `album=''`），否则库↔文件不一致。

### 28.3 踩过的坑（坑 94~103）

| # | 坑 | 现象 | 解法 |
|---|---|---|---|
| 94 | 后台接力 `pgrep -f` **自匹配** | 接力永不触发（匹配到自己的命令行） | 用 PID 文件 + `kill -0`（见 `05-recovery.md` Phase 27） |
| 95 | iTunes 英文艺人名 | 目录分裂 | 手工映射表 + 中文名原样 |
| 96 | 投票法推映射 | 翻唱歌手全票给原唱 | 只映射高置信、宁缺毋滥 |
| 97 | 去重口径 | 漏判 mp3/flac 同曲副本 | 忽略扩展名 |
| 98 | 文件名 `-` 分段解析 | `许嵩-如果当时-网友别名：xxx` 把备注当艺人 | **首段命中库内艺人就用首段**；末段是备注或含 `：` 则回退 |
| 99 | GBK 字节被 latin1 读 | `¹¨«h`(龚玥)、`Ê®ËÍºì¾ü`(十送红军) | `s.encode('latin1').decode('gbk')`，**要求解出 ≥2 个汉字**（否则会误伤 `Señorita`） |
| 100 | 校验脚本的键名 | 校验报 352 条不符，其实文件是对的 | 非 ID3 容器**不能拿 `TIT2` 去比**：MP4 是 `©nam`、ASF 是 `Title`、APEv2 是 `Title`、Vorbis 是小写 |
| 101 | `ffcuesplitter` 静默不产出 | cue 解析正常、打印 `Finished!` 但**零输出** | 改用 `ffmpeg -ss/-t` 按 cue 的 `INDEX 01` 抽；**只抽库里缺的那几首**，别整张重切 |
| 102 | WAV 的 RIFF size ≠ 实际长度 | `mutagen` 判 `info is None`、写标签**静默失败** | 把 offset 4 改成 `filesize-8`；若 chunk 链本身乱了（`data` 后多 1 字节）就**截到 data 末尾**再补 ID3（音频 `data` 块 md5 必须不变） |
| 103 | 散曲 `album` 字段 | 与库内惯例不符 | 单曲统一 `album=''`（`album_id` 为 NULL 即为 singleton） |

### 28.4 脚本清单（`cue_tool_work/`）
| 脚本 | 作用 |
|---|---|
| `a14_itunes_lib.py` | 逐首查 iTunes（断点续跑，落 `lib_track_cache.json`） |
| `a15b_check.py` / `a15c_artist.py` / `a15d_map.py` / `a15e_list.py` | 计划体检：库内冲突、艺人名中英对照、ASCII 艺人清单 |
| `a16_map.py` | **人工审定映射表** + `fix_enc()` + `guess_from_filename()` + `is_bad_tail()` |
| `a16_plan.py` | 生成入库计划（映射 / 去重 / 专辑归并 / 目标路径 / 冲突消解） |
| `a16_apply.py` | 写标签（按容器分支 `set_tags`）→ move → beets 写库 → 封面 |
| `a16_verify.py` | 全量回读校验（**按容器映射键名**） |
| `a16_wav_fix.py` | 修 RIFF size 不符的 WAV + 补标签 |
| `a18_cue.py` | 整轨补全：cue 时间点 + ffmpeg 抽缺曲 |
| `a16_m3u8.py` | 按源文件夹生成 m3u8（并入整轨补全产物） |
| `a19_archive.py` | 源目录归档（同名目录递归合并，重名文件加 `_dup<N>`，**绝不 rm**） |

### 28.5 结果
```
items 12306 → 14097   albums 1426 → 3022   音乐/ 23 项 → 0 项
m3u8 9 → 25 册（新增 16 册）
自检：同路径重号 0 / 库内磁盘缺失 0 / 盘子有库无 0 / 空目录 0 / 无曲专辑 0
全量回读 1786 条 0 不符
```
