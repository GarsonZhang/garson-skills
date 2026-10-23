# 标签 · 封面 · 流派清洗

> 涵盖：内嵌封面水印图定位与重建（Phase 14）、标签层推广信息清洗（Phase 15）、
> 收尾两道质量闸——曲名被截短 + WAV `LIST/INFO` 乱码（Phase 23）、
> 流派清洗与中文规范化（Phase 24）、用 iTunes API 批量补流派（Phase 25）。
> **本文件是「改标签」类工作的必读**，尤其 Phase 23.4 的「一个 WAV 有三套元数据」。

## Phase 14 — 内嵌封面被「资源站水印图」污染：定位 + 平台重抓 + 批量重建
（2026-09-30 实测：1566 个文件 → 重建 1387 / 清空 179，最终水印图 0 残留）

### 14.1 先判「封面到底存在哪」，别一上来就改库

客户端里一批专辑显示同一张推广图（如「公众号：xxx　QQ群：xxxxxx」）时，
**先看 `albums.artpath` 和 Music 目录，再看内嵌标签** —— 三者是独立的：

```bash
# ① 库里的 artpath（本库 476 张专辑只有 2 张非空 → 排除）
python3 -c "import sqlite3;c=sqlite3.connect('/vol2/1000/电影音乐/beets.db');print(c.execute('select count(*) from albums where artpath is not null').fetchone()[0])"
# ② 磁盘图片文件（本库 Music 下只有 2 个 cover.jpg → 排除）
find /vol2/1000/电影音乐/Music -type f \( -iname '*.jpg' -o -iname '*.png' \) | wc -l
# ③ 内嵌图 → 就是它
```

> **三个数字不一致时，以「内嵌」为准。** 播放器/App 读内嵌标签，不读 beets 库。

### 14.2 全库内嵌图扫描 + MD5 聚类（定位水印图）

> ⚠️ **本节的 `one()` 只覆盖 FLAC + MP3/WAV 两种载体，是有盲区的版本。**
> APE(`Cover Art (Front)`)、WMA(`WM/Picture`)、M4A(`covr`) 全部漏扫 —— 实测 447 个 `.ape` + 1066 个 `.wma` 从来没被扫过，
> 导致「以为清干净了」但仍有残留。**做全库扫描必须用 Phase 15.1 的 5 载体完整版 `art_scan2.py`。**

脚本 `art_scan.py`：遍历库内 items 覆盖的音频，提取**第一张**图 → `path\t图数\t字节\tmd5` 落盘。
8 线程并行，9658 个文件约 3 分钟。

```python
def one(p):
    f = mutagen.File(p)
    pics = []
    if hasattr(f, 'pictures') and f.pictures:          # FLAC / Ogg
        pics = [x.data for x in f.pictures]
    elif getattr(f, 'tags', None):
        for k, v in f.tags.items():
            if str(k).startswith('APIC'):              # MP3 / WAV
                pics.append(v.data)
    ...                                                # ← 盲区：APE/WMA/M4A 见 15.1
```

然后按 md5 聚类，统计每个 md5 覆盖的 **文件数 / 专辑数 / albumartist 数**：

**判据（本次一定命中，且只有 5 张）**：

| 特征 | 说明 |
|---|---|
| 一张图跨 **多个 albumartist** | 真专辑封面绝不会跨歌手 |
| 覆盖专辑数远超正常（本次 210 / 148 / 53 / 48 / 16） | 正常专辑封面覆盖 1 个专辑 |
| **字节数高度聚集**（31686/31711/31731/31751/31796） | 同一张图的不同压缩版本 |

> 反向鉴别：同歌手散曲之间共用一张图是**正常**的（歌手宣传图），
> 别只按「覆盖多专辑」判（王菲 12 个散曲共用一张图，是正常收藏）。

扫描脚本必须**只扫库内 items 覆盖的文件**（用 `items.path` 过滤），否则会把归档区/`_split` 也扫进来。

### 14.3 重建来源：平台接口 + 归一化打分（**不要取第一条**）

这些专辑通常**没有 `mb_albumid`**（资源站导入、未走 MB 匹配），Cover Art Archive 走不通，
只能上平台。三个接口实测可用：

| 接口 | URL | 取图字段 |
|---|---|---|
| 酷狗专辑 | `https://mobilecdn.kugou.com/api/v3/search/album?format=json&keyword=<q>&page=1&pagesize=10` | `data.info[].imgurl`（含 `{size}` 占位） |
| 酷狗单曲 | `https://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=<q>&page=1&pagesize=10` | `imgurl` 或 `trans_param.union_cover` |
| 网易云专辑 | `http://music.163.com/api/search/get/web?s=<q>&type=10&offset=0&limit=10` | `result.albums[].picUrl` |
| 网易云单曲 | 同上 `type=1` | `result.songs[].album.picUrl` |

- 酷狗图片 URL 里的 `{size}` → 替换成 `480`（失败退回 `240`）
- 网易云图片 → 追加 `?param=500y500`
- 网易云需要 `Referer: http://music.163.com` + `Cookie: os=pc; appver=2.9.7`，请求间隔 ≥1.4s（限流凶）
- 两个 CDN 都有证书链问题 → `ssl.create_default_context()` 后 `check_hostname=False; verify_mode=CERT_NONE`

**打分（决定性，避免张冠李戴）**：

```python
def score(q_alb, q_arts, c_alb, c_art):
    na, nc = norm(q_alb), norm(c_alb)          # norm = 简体化 + 去轨号/括号/碟号/标点空白 + 小写
    if not na or not nc: return 0.0
    if na == nc:      s1 = 1.0
    elif na in nc or nc in na: s1 = 0.88
    else: return 0.0                            # 专辑/曲名对不上 → 直接淘汰
    qa = set(norm(x) for x in q_arts)           # 歌手别名集合（含 & 切段、去 feat./伴奏后缀）
    ncar = norm(c_art)
    if qa & {ncar}: s2 = 1.0
    elif any(x and (x in ncar or ncar in x) for x in qa): s2 = 0.9
    elif q_arts and norm(q_arts[0]) in COMP: s2 = 0.7   # COMP = 群星/华语群星/合辑…
    elif ncar in COMP: s2 = 0.7
    else: s2 = 0.3
    return s1 * 0.6 + s2 * 0.4
```

**阈值 0.85**，且必须 `img` 非空。实测：

- 单轮常规搜索（歌手+专辑/曲名）→ 426/477 单元命中（1235 文件）
- 加「简体化 + 去 `&` + 去 CD/Disc/第N期 后缀」→ +10
- **手写关键词**（平台命名差异，如 `伍佰 电影歌曲典藏`、`五月天 盛夏光年`、`林俊杰 I AM 世界巡回演唱会`）→ +7
- 网易云补充 → +0（这批没有）

**别指望「歌手名全串」当查询词**：`伍佰 & China Blue 愛上別人是快樂的事` 命中率差，
把 `&` 换成空格、或 `arts[0]` 只取第一段，命中率立刻上来。

### 14.4 写入：三种载体同时改，且**保留原有非水印图**

```python
keep = [x for x in get_pics(p) if md5(x) not in BAD]   # ← 关键：不要无脑 clear
newpics = keep + [('image/jpeg', new_data)]
put_pics(p, newpics)
```

一个单元（专辑/散曲）要同时做三件事：

1. 替换文件内嵌图（`put_pics`）
2. **专辑**额外写 `<专辑目录>/cover.jpg` —— 按目录读图的客户端优先用它
3. `update albums set artpath=? where id=?`（值用 `sqlite3.Binary(path.encode())`）

**各格式写入差异（一次写全，别漏）**：

| 扩展名 | 写法 |
|---|---|
| `.flac` | `FLAC(p).clear_pictures()` + `add_picture(Picture(type=3, mime='image/jpeg', data=…))` |
| `.mp3` | `ID3(p).delall('APIC')` + `add(APIC(encoding=3, mime='image/jpeg', type=3, data=…))` |
| `.wav` | `WAVE(p)`；`if f.tags is None: f.add_tags()` 后再 `delall/add` |
| `.m4a` | `MP4(p)['covr'] = [MP4Cover(data, imageformat=MP4Cover.FORMAT_JPEG)]` |
| `.ape/.wv/.tta/.tak` | `APEv2(p)['Cover Art (Front)'] = APEBinaryValue(b'cover.jpg\x00' + data)`，**只能存一张** |
| `.ogg` | `f['metadata_block_picture'] = [Picture(...).write()]` |
| `.wma` | ASF 的 `WM/Picture` 结构复杂 → **跳过**（本库 wma 多无内嵌图） |

#### 坑 33【踩过】WAV 的图要用 ID3 取，`mutagen.File()` 返回的 WAVE 没有 `pictures`

```python
f = mutagen.File(p)                 # WAVE 对象
f.pictures                          # ✗ AttributeError / 不存在
w = WAVE(p); w.tags.getall('APIC')  # ✓ 图在 ID3 chunk 里（本库 172196 B 的那张就是这么漏掉的）
```

同一份提图逻辑要同时覆盖 FLAC 与 WAV/MP3，否则会出现「明明有图却当成没有」→ 复用逻辑静默失效。

### 14.5 兜底顺序（找不到就**清空**，不要留着水印图）

1. **同单元内已有真图** → 回填（本次 0 例：资源站是整张统一塞水印图）
2. **同专辑/相关专辑的真图** → 复用（本次刀郎 10 首「N品」散曲复用《如是我闻》封面，10/10 成功）
3. **平台抓** → 见 14.3
4. **都没有** → **清除水印图**（保留非水印图），宁可没封面也不留推广信息
   （本次 24 单元 / 179 文件走这条；客户端会显示默认封面或按需在线匹配）

### 14.6 实测数据（本库）

| 指标 | 前 | 后 |
|---|---|---|
| 含水印图文件 | 1566 | **0** |
| 不同内嵌图 | 154 | 439 |
| 有内嵌封面文件 | 2031 | 1855 |
| 目录 cover.jpg | 2 | 81 |
| `albums.artpath` 非空 | 2 | 83 |
| items / albums | 9674 / 476 | 9674 / 476（未变） |
| path 失效 / 重复 path | 0 / 0 | 0 / 0 |

写入 967 FLAC + 288 MP3 + 55 WAV + 4 APE；抽样 12 张封面人工核对全部正确、
12 个被改文件 `ffprobe` 全部可解码。

**性能**：FLAC 换更大封面要整体重写文件（1566 个文件写了约 20 GB，约 10 分钟）。

### 14.7 必须做的三件事

1. **先干跑**（`--limit=N` 处理 N 个单元不落盘 + 单独 `--apply` 试 3 个单元），
   确认内嵌图与 `cover.jpg` 一致、`ffprobe` 能解码，再全量
2. **处理后重新扫一遍全库内嵌图**，断言「水印图文件数 == 0」（这是唯一硬指标）
3. **备份 `beets.db`**（本次改动了 `artpath` 与 `items.mtime`），并把
   「处理前每个文件的图片 MD5 快照」`embedded_before.tsv`、原始水印图 `arts/<md5>.jpg`
   一起留档 —— 这三样构成完整回滚依据

> 环境准备：`zhconv` 在 fnOS 上没有，需
> `pip3 install --user --break-system-packages zhconv`（Debian 12 的 PEP 668 限制）。

### 14.8 客户端不生效时

封面已内嵌 + 目录 `cover.jpg` 双写。若 App 仍显示旧图 → 是**封面缓存**，
在音乐应用里做一次「重新扫描媒体库 / 清除封面缓存」即可，不是数据没写进去。

---

## Phase 15 — 标签层污染清洗：`comments` / `description` 里的资源站推广
（2026-09-30 实测：4280 个文件、4280 条库记录 → 残留 0；顺带修 88 个重复图片块 + 3 个漏网 APE 水印）

### 15.1【先修正 Phase 14 的盲区】内嵌封面有 **5 个存放位置**

| 载体 | 键 | 读法 |
|---|---|---|
| FLAC / Ogg | Vorbis PICTURE block | `f.pictures` |
| MP3 / WAV / AIFF | ID3 `APIC` | `f.tags.getall('APIC')`（WAVE 用 `WAVE(p).tags`） |
| **APE / WV / TTA / TAK** | **APEv2 `Cover Art (Front)`** | `t['Cover Art (Front)'].value`（前面有 `cover.jpg\0` 前缀，要去掉） |
| **WMA / ASF** | **`WM/Picture`** | 二进制结构体，需手工解析（见下） |
| M4A | MP4 `covr` | `f.tags['covr']` |

> **Phase 14 的 `art_scan.py` 只覆盖前 2 行 → 447 个 `.ape` + 1066 个 `.wma` 从来没被扫过。**
> 补扫后确认仍有 **3 个 APE 带水印图**（`费玉清/不了情.ape`、`神秘女郎.ape`、`陋港之春.ape`）。
> **扫描覆盖率比命中率更重要 —— 漏扫的格式会一直骗你「已经清干净了」。**

`WM/Picture` 结构：`type(1B) + 图字节数(4B LE) + mime长度(4B LE) + mime + desc长度(4B LE) + desc + 图数据`

```python
import struct
def wmpic(b):
    n = struct.unpack('<I', b[1:5])[0]
    off = 5
    m = struct.unpack('<I', b[off:off+4])[0]; off += 4 + m
    d = struct.unpack('<I', b[off:off+4])[0]; off += 4 + d
    return b[off:off+n]
```

写 APE 封面：`APEv2(p)['Cover Art (Front)'] = APEBinaryValue(b'cover.jpg\x00' + data)`（**只能存一张**）

**`hasattr(tags,'getall')` 判 ID3 —— 实测可用**：

| 类型 | has getall |
|---|---|
| `_WaveID3`（WAV 的 ID3） | **True** |
| `VCFLACDict`（FLAC） | False |
| `APEv2` | False |
| `ASFTags`（WMA） | False |

> **但 ASF 落到 else 分支**，字段名首字母大写（`Description` / `Comment` / `Title` / `Author`），
> 匹配时要 `.lower()`，别写 `== 'comment'`。

### 15.2 「垃圾 tag」真身：`items.comments` 里的资源站推广

同一批资源站文件，除了封面被塞水印图，**`comment` 字段还会写推广**。本库 4279 条非空，全部是广告：

| 内容 | 条数 |
|---|---|
| `QQ群号：562125679 公众号：时光匆忙旅行者` | 978 + 66 |
| `点击资源平台www.djzypt.com` | 859 |
| `酷我音乐` | 801 + 141 |
| `与你杰媛收藏` | 484 |
| `更多无损单曲尽在 咣輝のま裔的空间 / http://hi.baidu.com/648785713 …` | 361 |
| `[60yp.com]60音盘更多音乐全集下载` | 146 |
| `磨坊高品质音乐论坛-MOOFEEL.COM` | 119 |
| `kuwo` / `乐天使资源网` / `至上音乐汽车音响` / `www.91ting.com` / `魔迷士音乐博客` | 约 350 |
| `ExactAudioCopy v…`（抓轨签名）、`163 key(Don't modify):…`（网易云加密串） | 169 / 23 |

### 15.3【坑 34】库里的 `comments` 与文件**脱钩**，必须两边都查

`items.comments` 是**导入那一刻的快照**。文件后来被别的工具（或自己上一轮的脚本）清过，beets 不会自动同步。
本次：**207 个文件库里还挂着 comment，文件里其实早已没有该字段**（Beyond《24K金限量珍藏版》的 WAV、一批 FLAC）。
反过来也可能有「文件里有、库里没有」。

> **清库 ≠ 清文件，清文件 ≠ 清库。两个都要做，且清理后要分别验证。**

### 15.4【坑 35】清理清单不能只存「命中项」

`--apply` 复用 dry-run 产出的清单时，如果清单里**只记了命中的字段**，执行阶段就无法反推「该保留哪些」；
过滤条件一旦写反，会静默 **0 处理**（本次踩过：打印 `ok=0 fail=0`、库里一条没动，加日志才发现）。

> 正确做法：执行阶段**重新读一遍该文件的全部字段**再逐个判定，或让清单存「全字段 + 命中标记」。

### 15.5 判定规则：正则 + **保留白名单**

```python
RE_AD = re.compile(
    r'(QQ\s*群|公众号|hi\.baidu|baidu|migu|djzypt|60yp|moofeel|letians|'
    r'520hjl|top100|91ting|momishi|pt80|verycd|kugou|kuwo|酷我|酷狗|咪咕|'
    r'音乐网|音乐论坛|资源网|资源平台|音盘|磨坊|海精灵|巨鲸|捌零|魔迷士|乐天使|'
    r'至上音乐|汽车音响|时光匆忙|杰媛|咣輝|炫网|扫码|扫一扫|加群|'
    r'欢迎常来|购买正版|支持正版|www\.|http)', re.I)
KEEP_PAT = re.compile(r'(JASRAC|Sony|Mastersound|Interprètes|大感謝|生命的現場)')  # 反向白名单
```

> **`\.com` 不能当判据**（太宽泛会误杀），但平台域名**要枚举**：`baidu|migu|kuwo|kugou|…`。
> 本次 `ting.baidu.com`(2)、`music.migu.cn`(16) 就是这么漏掉的。
>
> **必须保留的白名单**（有真实信息量）：
> `JASRAC / Cinepoly Records Co. Ltd.`（版权方）、
> `Epic/Sony Mastersound ~ 30-3P-431 (1983) … Vinyl Rip by …`（压制版本信息）、
> `Interprètes : …`（Apple Music 演职员表）、自己写进去的说明文字。

### 15.6 各格式的 comment 字段名

| 格式 | 字段 | 删除 |
|---|---|---|
| FLAC / Ogg | `comment`、`description`（可多值 list） | `del t[key]` |
| MP3 / WAV | ID3 `COMM` 帧；自定义塞在 `TXXX` / `WXXX` | `t.delall('COMM')` |
| APE | APEv2 `Comment`、`Description` | `del t[key]` |
| WMA | ASF `Description` | `del t[key]` |

改完 `f.save()`；同时 `update items set comments='', mtime=?` 回写库。

### 15.7 验证 = **用同一个扫描器再跑一遍 dry-run**

断言「命中 == 0」，这是唯一硬指标。本次：全库 9658 个文件重扫 → `ad`/`163`/`enc` 全 0；
随机 25 个被改文件 `ffprobe` 全部可解码；图片残留 0 / 重复块 0；库↔文件抽查一致。

> 附带发现：用「库↔文件比对」脚本时，**ASF 的键名是 `Title`/`Author`/`WM/AlbumTitle`**，
> 不是 `title`/`artist`/`album`。键名没覆盖全会误报 DIFF。

### 15.8 回滚依据

| 用途 | 位置 |
|---|---|
| 清理前 DB | `beets.db.bak.<date>-tag` |
| **被清理标签的完整原始值** | `.art_audit/tag_clean_plan.json`（本次 4279 条，含路径 + 原文） |
| 被改文件清单 | `.art_audit/tag_clean_done.json` |

> **注意：后续任何一次 dry-run 都会覆盖 `tag_clean_plan.json`** → 跑验证前先把 plan 备份到 `/tmp`。
> 恢复 `.db` 只回滚库记录，**不会**把标签写回文件；要完整还原得按 plan 逐条写回。

### 15.9【坑 36】重复图片块的成因与修复

写入脚本被跑了两遍 → 第二遍把第一遍写的图当成「非垃圾图」保留，又追加一张 → 每个文件两张**相同 MD5** 的图（白涨约 490 KB/文件）。

```python
seen, keep = set(), []
for pic in f.pictures:
    h = hashlib.md5(pic.data).hexdigest()
    if h in seen: continue
    seen.add(h); keep.append(pic)
f.clear_pictures()
for pic in keep: f.add_picture(pic)
f.save()
```

> 教训：**写入脚本要幂等**（写之前先判这张图在不在里面），或每轮跑完立刻重扫断言，
> 别让同一批文件重复进管线。

### 15.10 处理同类问题的**顺序**（本次验证有效）

1. **先摸清格式分布**（`collections.Counter(type(f).__name__)`）—— 决定要用几套读写逻辑
2. **全库扫描两遍维度**：图片（5 类存储）+ 标签（comment/description/COMM）
3. **库侧与文件侧分别统计**，找出「只在一边存在」的差集（坑 34）
4. dry-run → 小样本 3 个 apply → 验证 → 全量 apply
5. **全量后再次重扫**，断言两侧都为 0
6. 备份 DB、备份原始值清单、恢复根目录「只留 2 个回滚点」

### 15.11【补充】脏 tag 的极端形态：广告覆盖到 `TIT2` / `TPE1` / `TPE2`

Phase 15.2 讲的 `comments` 只是「一侧被污染」。**同一批资源站的 mp3 分轨更狠** ——
实测某源目录 160 个文件，除了 `COMM`，连**标题本身**都被广告占了：

| 字段 | 值 |
|---|---|
| `TIT2`（标题） | `QQ群号：562125679 公众号：时光匆忙旅行者` |
| `TPE1`（艺术家） | 同上 |
| `TPE2`（专辑艺术家） | 同上 |
| `COMM::eng` / `COMM:ID3v1 Comment:eng` | 同上（ID3v1 那份还是拉丁乱码） |
| `TALB` | 只有大辑名，**无分辑号** |
| `TRCK` | 统一错写同一个值（本次 `226`） |
| `APIC` | 160 个共用同一张水印图 |

> **此时「删字段」= 把标题也删了。** 唯一可信的信息是**文件名**
> （`01 小燕子 - 电影《护士日记》插曲.mp3`）。
> 正确做法是**从文件名重建**：轨号取 `^(\d{1,3})[\s._]+`、曲名取其余、`TALB` 补分辑号、`TRCK` 重置、`COMM` 全清。

**动手前先看「一个」文件的完整 tag**（别一上来就写清洗器）：

| 观察 | 走哪条路 |
|---|---|
| `TIT2` 是正常曲名，只有 `comment` 脏 | Phase 15 的**删字段**流程 |
| `TIT2`/`TPE1` 也是广告 | **文件名重建**流程（删字段救不了） |

---


---

## Phase 23 — 收尾两道质量闸：**曲名被截短** 与 **WAV `LIST/INFO` 乱码**（2026-09-30 实测 5 条 / 364 个）

入库完成后还有两个「肉眼才看得见」的坑：播放器显示的名字不是库里记的名字。
根因不在 beets，在**标签来源**与**容器里第二套元数据**。

### 23.1【坑 69】酷狗 `songname` 会把完整曲名**截到只剩版本词**

```
源文件：陈瑞-分手了别来打扰我(发烧版).wav
酷狗返回 songname：发烧版        ← 括号里的版本词被当成了整曲名
入库结果：/陈瑞/01 发烧版.wav      title='发烧版'
```
同类：`老地方的雨(发烧版)`、`错过了缘分错过你(发烧版)`、`为爱流泪的女人(dj何鹏版)`、
`女人花(英文版)`（→ `/姚璎格/2020 缘/01 英文版.wav`）。
**入库后必须用源文件名反查一遍 title**，不能信检索结果。

### 23.2【坑 70】beets 的 `items.path` 是 **BLOB** 列，`where path=?` 传 str 永远匹配不上

```sql
-- 错：查不到（返回 None，会被误判成"库内无此文件"）
select * from items where path = '/vol2/.../a.wav'
-- 对：
select * from items where cast(path as text) = '/vol2/.../a.wav'
```
写回时正相反：`update items set path=?` 要传 **bytes**（`new.encode('utf-8')`）。

### 23.3【坑 71】判「库内 title 是否被截短」不能用「文件名 `-` 左右谁更长」

`刘德华-悟.wav` 里左侧（艺术家）比右侧（曲名）长，按长度判会把**艺术家当成曲名**，
一次性误报 60+ 条。正确判据：

```python
# 源主干按 - – — － 切段 → 若某段的 GBK/归一化串**包含** title 且更长 → title 是被截短的
segs = [s.strip() for s in re.split(r'[-–—－]', stem) if s.strip()]
cands = [s for s in segs if nt in norm(s) and len(norm(s)) > len(nt) + 1]
want = min(cands, key=len) if cands else None
```
再区分：
- `want` 的**括号内容 == 库内 title** 且是版本词（发烧版/英文版/dj何鹏版…）→ `AUTO` 自动修；
- 其余（`When You Believe (Duet With Mariah Carey)`、`加州旅馆(Hotel California)`、
  `你是我的眼（任雪晨）`）→ **不动**：库内 title 反而更干净，源文件名只是把歌手/标注塞进括号。

实测 430 个产物：误报收敛到 **32 条，其中 AUTO 5 条**。

### 23.4【坑 72】**同一个 WAV 里有三套元数据，播放器读哪套决定你看到什么**

| 层 | 位置 | 编码 | 谁在读 |
|---|---|---|---|
| RIFF `LIST/INFO` | `fmt→data→LIST`（常在尾部） | **ANSI 码页 = 中文 GBK** | 车载/老播放器**优先** |
| ID3v2 | `id3 ` chunk（mutagen 追加在文件尾部） | UTF-16 | PC/手机播放器 |
| APEv2 | 文件最末 `APETAGEX` | UTF-8 | foobar 等 |

- 源作者**用 UTF-8 写了中文进 `LIST/INFO`** → 按 GBK 读 = `浜戞湹`/`鏈煡鑹烘湳瀹?` 这种 mojibake；
  **注意窗口**：`mutagen.File(p, easy=True)` **读不到 `LIST/INFO`**，只有手写 RIFF 解析器才看得到（坑 57 的姊妹坑）。
- 只**删掉** LIST 不够：车载机只读 LIST/INFO，删了车上只剩文件名。
  **正确做法 = 用库内已核对的标签以 GBK 重写 `LIST/INFO`**（ID3 保留，两类设备都覆盖）。
- 判「要不要改」要**站在播放器视角**：用 `decode('gbk','replace')` 解开现有值再和库内比，
  对不上才改 —— 这样 UTF-8 中文天然落入「要改」，真 GBK 中文天然「不改」。缺 `INAM` 也判要改。
- 字段：`IART/INAM/IPRD/ICRD/IPRT/IGNR`；值必须能整体 GBK 编码，否则**跳过该字段**（不写 `?` 占位）。
  `ICRD/IPRT` 为 0 或空要跳过。size 字段含结尾 NUL（`len(vb)+1`），chunk 数据偶对齐。

### 23.5 重写 LIST 的结构处理（含「后随 id3 / APEv2」）

```
原：fmt → data → LIST → id3            （mutagen 写标签时把 id3 追加在 LIST 之后）
或：fmt → data → id3  → LIST           （先有 LIST 在尾、后写 id3）
重写：new_chunk = b'LIST' + size + payload (+pad)
      tail = 读 LIST 之后到 EOF 的全部字节            # 小，几 KB
      写 new_chunk + tail 到 LIST 原偏移 → truncate → RIFF size = 新文件长 - 8
```
- chunk 遍历用**白名单**（`fmt /data/LIST/id3 /fact/PEAK/JUNK/…`），遇到 `APET` 或缺省即 `break`
  —— 否则会把末尾 `APETAGEX` 当 chunk 头，解析出 `size=1480935233` 这种天文数字。
- APEv2 会被 `tail` 整体搬走，其 footer 里的 size 是 tag 内部长度，与绝对位置无关 → 安全。

### 23.6 改动 title 必须**四处同步**

```
1) 文件改名  os.rename(同目录, 保留 'NN ' 前缀)
2) 写标签    write_id3(..., title=want)     # 坑 57：必须 mutagen.File
3) 库内      update items set path=?, title=? where id=?   （path 传 bytes）
4) 清单      made.json 里的 path/title（m3u8 靠它重建）
```
漏第 4 步的症状：后续脚本报「文件不存在」，m3u8 少条目。

### 23.7 改完必须验证「音频数据没动」

```python
# 比对 data chunk 的 md5（对 60MB 文件也只要几秒）
def data_md5(p):
    f = open(p, 'rb'); f.seek(12)
    while True:
        cid = f.read(4); sz = struct.unpack('<I', f.read(4))[0]
        if cid == b'data':
            h = hashlib.md5(); left = sz
            while left > 0:
                c = f.read(min(1<<20, left)); h.update(c); left -= len(c)
            return h.hexdigest(), sz
        f.seek(sz + (sz & 1), 1)
```
试点两个代表文件（`LIST` 在末尾的 + `LIST` 后随 `id3 ` 的）→ md5 一致 + `RIFF size == filesize-8` + chunks 自洽 + `mutagen` 可读，再全量。

### 23.8 收尾自检清单（`a3_final.py`）

```
items / albums 计数 · 同路径重号 0 · 库内磁盘缺失 0 · Music 下「盘子有库无」0
空目录 0 · 无曲 albums 0 · m3u8 册数+条数 · 根目录回滚点收敛 · 本批 WAV 的 LIST/INFO vs 库内 title 不符 0
```
本轮结果：items **12451** / albums **1438**，全项 0，m3u8 **9 册**，LIST/INFO 不符 **0**。

### 23.9 本次脚本清单（`cue_tool_work/`）

| 脚本 | 作用 |
|---|---|
| `a3_scaninfo.py` | 扫描本批 WAV 的 `LIST/INFO` 垃圾（含 `?`/U+FFFD/与现 title 不符） |
| `a3_titlecheck.py` | 反查「库内 title 被截短」清单 → `/tmp/a3/title_fix.json`（带 AUTO 标记） |
| `a3_titlefix.py` | 修 title：改名 + 写 TIT2 + 更新库内 path/title |
| `a3_syncpath.py` | 把改名同步进各批 `made.json` |
| `a3_fixinfo.py` | **GBK 重写 `LIST/INFO`**（含后随 id3/APEv2 搬移） |
| `a3_stripinfo.py` | 旧版：只统计/删除 LIST（已被 `a3_fixinfo.py` 取代） |
| `a3_info_check.py` | 单文件 RIFF 结构 + INFO 值（GBK）+ mutagen 可读性校验 |
| `a3_final.py` | 全库自检一页纸 |

### 23.10 同专辑被导入两次：归一化 key 找组 + 按码率复核保留方（`a4_merge.py`）

```python
key = (norm(albumartist), re.sub(r'[.\s()（）\[\]【】]', '', norm(album)))
```
这条 key 能抓出「简繁 + 标点」差异造成的重复：`第一張創作專輯`/`第一张创作专辑`、
`Touch Of Love`/`Touch.Of.Love`、`情歌歲月精選(…)(Japan)`/`….Japan`、
`雪狼湖 (引進版)`/`雪狼湖(引進版)`。实测全库 **13 组**。

**决定能不能合，要看两组各自的「曲目集合重叠度」**，不能只看专辑名：
- 曲目 100% 相同，或归档方曲目**全被保留方覆盖** → 合并；
- 曲目几乎不重叠（李宗盛《爱情论》193 vs 920 只共有 1 首）→ **不是重复，别合**。

**保留方要按「体积 + 平均码率 + 格式」复核**（`a4_merge.py` 对「体积大 5% 以上」的归档方打标记）：
注意 **WAV 的 1411 kbps 只是 PCM 未压缩**，同为 CD 级时并不比 flac 好，反而占地方 ——
别被"体积更大"骗了；真正低质的是 mp3（128~320k）。

执行：
- 冗余目录 `shutil.move` 到 `_media_archive/dup_<date>/`（保留 Music 下相对结构），**绝不 rm**；
- 库内同步 `delete from items where album_id=?` + `delete from albums where id=?`；
- 收尾用 `a4_m3u8_clean.py` 剔除 m3u8 里**已不存在**的路径对 ——
  合并 / 升级 / 误删都会留下陈旧引用（本轮实测剔除：张学友 60、经典老歌1688首 25、
  精选123部 12、国语经典470首 5，其中含升级前的旧 `.wma` 与那 2 个不可恢复的文件）。

---

## Phase 24 — 流派（genre）清洗：84% 空、91% 待处理、广告当流派、GBK 乱码（2026-09-30 实测 1949 条 + 定向 500 条）

### 24.1【坑 74】流派**没有上游可回填** —— 别指望 autotag / MusicBrainz

```
空 genre 10357 / 12306 = 84.2%，"需重新定"（空 + Other + 垃圾）11200 = 91.0%
```
三条硬事实：
- 抽 **200** 个空值文件读**物理 tag**（vorbis `genre` / ID3 `TCON`）→ 命中 **0**。
  **源文件本身就没有流派**，从文件回填这条路是死的。
- MusicBrainz 覆盖：`mb_trackid` 非空仅 **1235 / 12306（10%）**，且都是早期 MB 入库的。
  全库重新 autotag 无收益，还会**连带改动标题/艺术家/专辑**，风险远大于收益。
- 音频指纹（acoustid）对中文老歌/发烧碟识别率同样低，且 12000 个文件算指纹 CPU 不划算。

→ **结论：流派只能靠「规则 + 人工审定」。** 两条口径先问清楚：
  ①**只清洗**（去广告/乱码/同义异写，空值原样保留）；②**清洗 + 规则推断**（判不出才留空）。
  老张 2026-09-30 选的是 ①，因为②的推断值不可控。

### 24.2【坑 75】脏值只有三类，但每类都反直觉

**① 广告 / 来源标记当流派（593 条）** —— 中文音乐库通病，作者把 genre 当"来源"字段用：
```
www.pt80.com(300)  letians.cn分享(124)  kuwo(104)
QQ群号：562125679 公众号：时光匆忙旅行者(45)  [gqsou.com分享](3)
海精灵音乐美图论坛(1)  捌零音乐论坛(1)  lina(1)  banb(1)  2740360_276441(1)
```

**② GBK→latin1 乱码（14 条）**：
```
Î´ÖªÁ÷ÅÉ            = "未知流派"
¾©¾ç                = "京剧"
脤媒赂猫脥酶脰路www.ting30.com = 广告（同款乱码）
```
判别办法：`v.encode('latin1','ignore').decode('gbk','ignore')` 能还原成人话就看一眼。

**③ 同义异写（458 条）**：`POP`/`Pop`/`POP流行` 是同一个值；`other`/`Other`；
`Weltmusik`/`World`/`Musique du monde`/`Asie`/`WORLD MUSIC世界音乐` 是同一族。

### 24.3【坑 76】法语 / 德语的「世界音乐」标签 ≠ 世界音乐

```
Asie(14)            出现在 G.E.M. 邓紫棋《啓示錄》      → 法语"亚洲"
Musique du monde(15) 出现在 陈奕迅《C'mon in~》/ 群星《女也 Herstory with Mayday》 → 法语"世界音乐"
Weltmusik(1)        出现在 刘德华(Andy Lau)           → 德语"世界音乐"
```
内容**全是华语流行**。欧洲标签软件（EAC 等）把"非欧美"一律归为世界音乐。
→ 照字面翻译成「世界音乐」是**语义错误**，必须看专辑内容定流派。

### 24.4【坑 77】`Other` / `other` 是 beets 的「未分类」占位值，与空等价（231 条）

它不是"其他流派"，是"没分类"。→ 清洗时**置空**；不要归一成中文「其他」，
否则车机流派列表里会多一个永远筛不出东西的假分类。

### 24.5 规范流派值集合（中文，刻意粗粒度 13 类）

```
流行  摇滚  民谣  民歌  古典  爵士  蓝调  原声  儿歌  世界音乐  舞曲  戏曲  有声读物
```

- 库内主体是华语流行老歌 / 发烧碟 / 古典，**细分流派（Goa、House）对车机筛选毫无价值**，反而难维护。
- `民歌`（传统民歌 / 合唱 / 地方民歌）与 `民谣`（唱作人 / 民歌风翻唱）**必须分开**：
  区瑞强《民歌味道》→ 民谣；上海乐团合唱团《中国民歌无伴奏合唱》→ 民歌。
- `有声读物` 单列 —— 唐诗朗诵 + 配乐不是音乐，混在「古典」里会让古典筛选失真（实测 311 首）。

### 24.6【坑 78】「只清洗不填充」会让空值**变多**，动手前先把这个账讲清楚

843 条置空后，空值 10357 → **11200**。用户选「只清洗」，字面理解是"不新填空值"，
但清掉广告必然产生新空值。**不提前说明，用户会以为"怎么空得更多了"。**

### 24.7【坑 79】判「标错」不能只看流派名，要看**专辑 / 艺术家**

实测 5 处原标签就标错的（不是脏值，是**识别错误**）：

| 专辑 | 首数 | 原值 | 改为 | 判断依据 |
|---|---|---|---|---|
| 李宗盛 7 张专辑 | 80 | 蓝调 | 民谣 | 李宗盛是民谣/流行唱作人；**但同批 伍佰《少年也安啦》标蓝调是对的，必须排除** |
| G.E.M. / 刀郎 / 陈奕迅 / 刘德华 | 43 | 世界音乐 | 流行 | 原值是外语标签，见 24.3 |
| 群星《唐诗三百首》CD1-5 +《长恨歌》 | 311 | 古典 | 有声读物 | 唐诗朗诵 |
| 上海乐团合唱团 + 群星《China Today 3 西北音乐》 | 54 | 民谣 | 民歌 | 传统民歌 |
| Michael Jackson《Thriller》 | 5 | 摇滚 | 流行 | 原值 `Rock, Funk` |

→ **做法**：写「规则表」，每条 = 一句话理由 + 一个 SQL `where`；
先 dry-run 打印**命中数**核对（本轮 80/7/43/54/5/311，与人工核对完全吻合）再 `--apply`。
**规则之间必须互斥** —— 李宗盛规则里必须写 `albumartist='李宗盛'`，否则会把伍佰那首也带走。

### 24.8【坑 80】WAV 的流派有**三处**，只改 ID3 车机还是显示旧值

Phase 23.4 讲过 WAV 有三套元数据，**流派也是三份**：
- RIFF `LIST/INFO` 的 **`IGNR`** ← **车载 / 老播放器优先读这个**
- ID3 的 `TCON`
- APEv2 的 `Genre`

`mutagen.File(p)['TCON'] = '流行'` 只动中间那个。实测 160 个 WAV 改完 ID3 后，
`LIST/INFO` 里仍是 `POP` / `www.pt80.com`，且 `IART` 是源文件自带的 `'??'`。
→ 必须用 **GBK** 重写 `IGNR`（**不是删掉** —— 删了车上就没流派了）。
反过来，若新值是**空**，`build_info` 会跳过该字段，IGNR 自然被删掉，这是正确行为。

### 24.9【坑 81】`ASFTags.pop()` 不接受 default 参数（mutagen 1.46）

```python
t.pop('WM/Genre', None)          # TypeError: pop expected at most 1 argument, got 2
t['WM/Genre'] = [value]          # TypeError（必须包 ASFUnicodeAttribute）
```
正确写法：
```python
from mutagen.asf import ASFUnicodeAttribute
if 'WM/Genre' in t: del t['WM/Genre']
if value: t['WM/Genre'] = [ASFUnicodeAttribute(value)]
```
**只有「置空」这条路会踩到 `pop`** —— 所以 1947/1949 成功、恰好 2 个 wma 失败。
→ **"清空值"与"写新值"必须走不同代码路径，不要共用一行。** MP4Tags（m4a）同理，用 `in` + `del`。

### 24.10 用「备份库 ↔ 当前库」做**差集**定位本轮改动

比"重新算增量"可靠：
```python
om = {id: genre for ... in sqlite3.connect(BAK)}          # 改前备份
changed = [r for r in new_items if om.get(r.id, '') != r.genre.strip()]
```
用途：① 导出需要同步 `LIST/INFO` 的 WAV 清单；② 作为全量回读校验的靶子；
③ 报告里给出准确的"改了多少条"（实测 1949，其中 160 个是 WAV）。

**顺带一个坑**：补跑失败项时，目标值**必须从 plan 取，不能从库里读** ——
因为主脚本在写文件失败时会 `continue`，**不会**更新库，库里还是旧值，
从库读会让补跑"写了个寂寞"（第一版 `a5_genre_retry.py` 就这么错的）。

### 24.11 校验三件套（全绿才算完）

```
1) 值域   : select distinct genre → 必须全部落在规范集合内，非规范值 0 种
2) 全量回读: 本轮改动的**每个**文件读回 genre 与库内比对（不是抽样）→ 不符 0
3) 结构   : WAV 的 RIFF size == 文件大小-8、chunk 链连续、尾部只允许 APEv2/ID3；
            flac 不得有 ID3 头（播放器可能优先读它）
```
本轮结果：改动 **1949**（置空 843 / 归一 1106）+ 定向 **500** → 非规范值 **0 种**、
全量回读不符 **0**、WAV 结构异常 **0**、flac 带 ID3 头 **0**。

最终分布：
```
空 11200 | 流行 444 | 有声读物 311 | 民谣 114 | 民歌 99 | 古典 88
摇滚 42 | 原声 4 | 舞曲 2 | 蓝调 1 | 戏曲 1
```

### 24.12 本次脚本清单（`cue_tool_work/`）

| 脚本 | 作用 |
|---|---|
| `a5_genre_scan.py` | 盘点：分布 / 空值结构 / **抽 200 个文件读物理 tag**（判"能否回填"） |
| `a5_genre_scan2.py` | 专辑级分布 / MB 覆盖度 / 已有流派风向标 |
| `a5_genre_scan3.py` | 按专辑艺术家聚合、估算规则表覆盖率、列各流派下的专辑 |
| `a5_genre_fix.py` | **清洗主脚本**：`CLEAR`/`MAP` 映射表 + 库↔文件双写（`set_genre_file`） |
| `a5_genre_fix2.py` | 定向修正：6 条「专辑/艺术家」规则，互斥且带理由 |
| `a5_genre_retry.py` | 补跑写文件失败项（**目标值从 plan 取**，见 24.10） |
| `a5_genre_verify.py` | 值域校验 + 库↔文件抽样 |
| `a5_genre_audit.py` | 纯空白值清理 + 各流派下的专辑明细（供人工核对） |
| `a5_verify2.py` | 全量回读 + WAV 结构自洽 + flac 残留 ID3 |
| `a5_wav_info.py` | 把流派同步进 WAV 的 `LIST/INFO`（`IGNR`，GBK） |

**通用函数** `set_genre_file(path, value)`（在 `a5_genre_fix.py` 里）按标签对象类型分支，
可直接复用于任何"只改流派"的场景 —— 已覆盖 ID3(mp3/wav)、VorbisComment(flac)、
APEv2(ape)、MP4Tags(m4a)、ASFTags(wma)。

### 24.13 外部流派数据源探测结论（2026-09-30 实测，**可直接复用**）

用户会问「有没有接口能按歌名查流派」。答案是**有，但只有一个可用**：

| 源 | 结论 |
|---|---|
| **iTunes Search API** | ✅ **唯一可用**。免 key、免认证、国内直连 0.17s |
| Deezer | ❌ 国内连接超时（12s timeout） |
| MusicBrainz | ⚠️ 能连但 503 频发，且中文老歌覆盖差（`mb_trackid` 仅 10%） |
| Last.fm | 需申请 API key，tags 是用户标注，噪声大 |

**iTunes 用法要点**：
```
https://itunes.apple.com/search?term=<艺人 曲名>&entity=song&limit=200&country=us
```
- `country=cn` **返回 0 条**（中国区音乐服务已关闭）→ 用 `us` / `hk` / `tw`
- `limit` 上限 200
- 返回 `primaryGenreName`（苹果自己的分类，非用户 tag）
- **官方限制：约 20 次/分钟**。Apple Performance Partners 文档原话 ——
  *"The Search API is limited to approximately 20 calls per minute (subject to change)."*
  - `approximately` + `subject to change` 说明这**不是配额合同**，只是典型行为；
    社区实测有被更严限流（IP 信誉差）也有更宽松的
  - **按 IP 计，不是按 key**（接口无认证）→ 同一出口 IP 上的其它程序**共享**这 20 次/分钟
  - 官方其它建议：加缓存；需要更高用量走 **Enterprise Partner Feed**（EPF，需申请审批）
- 本项目实测：**3.3s 间隔**（≈18/min）连跑 12306 次，**0 次被限流**
- 被限流返回 **403（blocked）/ 429（rate limited）**；
  **不要立刻重试** —— 分钟级窗口不会在几秒内恢复，退避要按分钟算

**两种查法的实测差异**：

| 查法 | 命中率 | 问题 |
|---|---|---|
| 曲目级 `term=艺人 曲名` | **约 60%** 有效 | 发烧碟翻唱歌手（钰迪/天唱组合/王秀芬）整片查不到；约 20% **错配**（"金池 勇气"→返回"座位"） |
| 艺术家级 `term=艺人&limit=200` | **25/25 = 100%** | **会误配**：`Beyond` → 返回 `Electronic`/`New Age`（同名电子艺人）→ 判成「舞曲」 |

**误配的自动识别 —— 曲名交集校验（实测 10 个判对 9 个）**：
```python
# 库内该艺人的曲名集合 ∩ 接口返回的 trackName 集合
# 归一：去括号/标点/空格 + zhconv 转简体；逐对 Jaccard>=0.75 算命中
# 交集 >= 3 → 可信；= 0 → 判为误配
Beyond → 交集 0   ✓ 拦下     五月天 → 237  ✓
钰迪   → 交集 0   ✓ 拦下     刀郎   → 251  ✓
群星   → 交集 31  ✗ 漏判（容器名，必须硬排除 Various Artists / 群星）
```
**「群星」这类合集容器必须硬排除** —— 它不是人名，模糊搜会匹配到 `Various Artists`
合辑，genre 取到 `Soundtrack` 就全错了。

**其他坑**：
- `zhconv` 在 NAS 上**已装**（`from zhconv import convert`，调用要带 locale：`convert(t, 'zh-cn')`）。
- genre 是**苹果的英文分类且粒度粗**：实测 60 首里 **Mandopop 占 31**。
  映射成中文时 `Mandopop`/`Cantopop/HK-Pop`/`Tai-Pop`/`Pop` 全归「流行」，
  会**丢掉摇滚/民谣的细分**（五月天 `Mandopop×172 / Chinese Rock×17`、伍佰 `Mandopop×137 / Chinese Rock×22`
  —— 按众数都会判成「流行」）。
- 效率换算：**按艺术家查 1022 位 × 3.3s ≈ 56 分钟**；按曲目查 11200 首 ≈ 10 小时。
  → **要批量做就按艺术家查**。

**结论**：外部接口能拿到「客观依据」，比 24.1 说的库内推断可靠；
但只有约 60~75% 的可覆盖量，且会丢失流派细分。**剩下的仍需关键词规则兜底。**

---

## Phase 25 — 用 iTunes API 批量补流派：**9.0% → 71.8%**（2026-09-30 实测，新增 7728 首）

### 25.1 整体架构：**两段式**（查询与写入必须分开）

```
a9_itunes_fetch.py   查询 + 落盘 plan（带断点续跑缓存）   ← 1015 位艺术家 ≈ 70 分钟
a9_itunes_apply.py   按 plan 写库 + 写文件 tag            ← 7728 首 ≈ 10 分钟
```
**为什么必须分开**：查询要 1 小时且受网络限速；写入要处理 7000+ 文件（flac 改标签会**重写整个文件**）。
分开后查询中断可续跑（`itunes_cache.json` 每 5 位落盘一次），写入失败可单独重试。

### 25.2 查询阶段的三个关键规则

**① 按「艺术家」查，不按「曲目」查**
```
term=<艺术家>&entity=song&limit=200&country=us      ← 1022 位 ≈ 56 分钟
term=<艺术家 曲名>&entity=song                       ← 11200 首 ≈ 10 小时（放弃）
```
按曲目查还有一个硬伤：**发烧碟翻唱歌手整片查不到**（钰迪/天唱组合/王秀芬），有效命中仅约 60%。

**② 误配识别 —— 曲名交集**
```python
# 归一：去括号内容 + 去标点空格 + zhconv 转简体
# 库内曲名 ∩ 接口 trackName，逐对 Jaccard >= 0.75 算同一首
# 交集 >= 2 → 可信；= 0 → 误配（Beyond 会匹配到同名电子艺人 → 被判"舞曲"）
```

**③ 硬排除合集容器**：`群星` / `Various Artists` —— 不是人名，模糊搜会匹配到合辑，genre 取到
`Soundtrack` 就全错了（实测「群星」交集 31，是碰巧撞上 Various Artists 合辑里的同名民歌）。

### 25.3【坑 82】`artistName` 纯度门槛**不能硬卡**，会让曲名交集说话

第一版加了「主 artistName 占比 >= 50%，否则跳过」，结果 **378 位 / 1860 首被误杀**：

```
齐秦       主艺人 Chyi Chin        占比 0.28  ← 是对的！只是搜索结果里合作曲目多
上海交响乐团  Shanghai Symphony Orch 占比 0.12  ← 对的
Henryk Szeryng  Wilhelm Kempff, ... 占比 0.20  ← 对的（合作专辑）
周杰伦      主艺人 "Cool Music"     占比 0.05  ← 这个才是真误配
```
**正确做法**：取消纯度门槛，改用曲名交集判可信；并且**兜底流派只取「交集曲目」的众数**
（而不是全体 results 的众数）—— 这样混进来的杂项自然被排除，不需要靠占比卡。

改用此法后，同一份 cache **再救回 1621 首**（含古典演奏家 50 首）。

### 25.4【坑 83】兜底流派不能用「艺术家全体 genre 众数」—— 双语歌手会整片错

陈奕迅 522 首未匹配的，按艺术家众数（粤语 112 / 华语 72）全填「粤语流行」——
但他的《十年》《爱情转移》是国语歌。张学友（粤语 106 / 华语 53）、王菲（华语 95 / 粤语 77）同理。

**三层兜底优先级**（实测有效）：
```python
1) 逐曲匹配   同一首歌自己的 genre（最准）
2) 专辑内传播  同专辑已匹配曲目的 genre 众数 —— 一张专辑语言/风格通常一致
3) 艺术家兜底  仅当 genre 纯度 >= 0.75 才敢用；否则留空
```
前 6 位艺术家的实测分布：逐曲 937 / 专辑内 1003 / 艺术家兜底 323 / **留空 1059**。
宁可留空也不猜错 —— 留空是"不知道"，填错是"错误的确定"。

### 25.5【坑 84】WAV 的 `IGNR` 必须同步（与 Phase 24.8 同源）

本轮 495 个 WAV 改动中 **419 个含 `LIST/INFO`**，全部要用 GBK 重写 `IGNR`；
**76 个本来就没有 LIST**（源文件如此，流派只写在 ID3 的 `TCON` 里）—— 不动它。

**验证要用宽容扫描**，不能用 `a3_fixinfo.chunks()`（它有白名单限制）：
```python
# 宽容版：遇到任何 chunk 都继续遍历，不因未知块 break
while pos + 8 <= sz:
    cid, s = 读头部
    if cid == b'LIST': 解析 parse_info
    pos += 8 + s + (s & 1)
```
最终：含 LIST 的 419 个 **IGNR 与库内不符 0**。

### 25.6【坑 85】Phase 23 遗留缺陷：`str(bytes)` 把 BLOB 的 repr 写进了 `LIST/INFO`

重写 `LIST/INFO` 时若 `meta` 的某列是 **BLOB**（老数据），`str(val)` 会写出
**`b'[\xe7\x82\xab\xe9\x9f\xb3...'`** 这样的垃圾字面量，而非中文。
实测 48 个刀郎 WAV 的 `IPRD` 被写成了这个形态。

**解决**：取值一律过一层类型兜底
```python
def _s(x):
    if isinstance(x, (bytes, bytearray)):
        return x.decode('utf-8', 'replace')
    return '' if x is None else str(x)
```
注意 `sqlite3` 的 TEXT 列若存了 BLOB，**返回的是 bytes**；用
`select count(*) where album like 'b''%'` **查不出来**（类型不匹配），必须靠 `typeof()` 或运行时类型判断。

### 25.7【坑 86】`a3_fixinfo.KNOWN` 的白名单会**漏块**，导致漏处理

录音软件（Pro Tools 等）会在 WAV 里塞自定义块：实测 `DGDA`（chunk 链
`JUNK→bext→fmt →minf→elm1→data→regn→umid→DGDA→id3 `）。
`chunks()` 遇到不在 `KNOWN` 的块会 **break**，若 `LIST` 排在其后就会被漏掉。
→ 已把 `DGDA` 等加入 `KNOWN`；但**判断「是否已同步」时应独立用宽容扫描**，不要复用白名单版。

### 25.8 成果（`fnos-cue-beets-import` 实测）

| 项 | 数值 |
|---|---|
| 起点（Phase 24 清洗后） | 非空 1106 / 12306 = **9.0%** |
| 查询 | 1021 位艺术家，成功 1021，失败 0 |
| 可信 | 232 位（+ 改进后补 120 位） |
| **写入** | **6107 + 1621 = 7728 首** |
| 终点 | 非空 **8834 / 12306 = 71.8%** |
| 校验 | 全量回读 7728 个 **0 不符**；WAV 结构 0 异常；flac 带 ID3 头 0；非规范值 0 种 |

最终分布：`华语流行 5833 / 粤语流行 1007 / 流行 738 / 有声读物 311 / 摇滚 217 / 民谣 166 /
古典 139 / 台湾流行 135 / 民歌 125 / 原声 98 / 世界音乐 28 / 舞曲 11 / 日本流行 10 /
轻音乐 7 / 蓝调 6 / 爵士 2 / 戏曲 1 / 空 3472`

### 25.9 脚本清单

| 脚本 | 作用 |
|---|---|
| `a9_itunes_fetch.py` | 查询 + 生成 plan（缓存断点续跑、曲名交集校验、三层兜底） |
| `a9_itunes_fetch2.py` | 改进版（复用 cache，**免网络**）：取消纯度门槛、兜底只取交集众数 |
| `a9_itunes_apply.py` | 按 plan 写库 + 写文件；**只填空值**防覆盖；失败不改库 |
| `a5_wav_info.py` | 同步 WAV 的 `LIST/INFO`（`IGNR`，GBK）；基准库改为「本轮改动前」的备份 |
| `a9_info_final.py` | 宽容扫描确认所有 WAV 的 `IGNR` 与库一致 |
| `a9_wav_verify.py` | 宽容版 RIFF 结构校验（对比 `a5_verify2.py` 的白名单版） |
| `a10_itunes_track.py` | **单曲级检索**评测（两种模式 + 曲名严格校验） |
| `a11_itunes_alltrack.py` | 全库 12306 首逐首单曲重查（断点续跑，只查不改） |
| `a11_apply.py` | 按单曲结果重写流派（**无校验，已废弃**，改用 a13） |
| `a12_verify.py` | **命中校验闸门**（只读）：用 iTunes 返回的 artistName 判定是否同名误配 |
| `a13_apply_gate.py` | **带闸门**的流派写库（默认 dry-run，`--apply` 才写） |
| `a14_check_tags.py` | 库 ↔ 文件 流派一致性自检（只读），`--all` 查全库 |

### 25.10【坑 87】单曲级检索（iTunes `entity=song`）—— 艺术家级失效时的最后一公里

**老张口径（2026-10-01 明确）：单曲级查到的优先级最高；单曲搜不到的留空，不做推断兜底。**

**何时必须用单曲级**（艺术家级失效的三类场景）：
```
① 艺术家名乱码或不是人名：`鍒樺痉鍗?`、`9月热门无损DJ串烧`、`陈瑞 & 赵鑫`
② 搜索结果被杂项淹没：`群星`、`Twins`(→ Cocteau Twins)、`Beyond`(→ 同名电子艺人)
③ 发烧碟翻唱歌手，整片查不到：钰迪 / 天唱组合 / 王秀芬
```
→ 逐首用 iTunes Search API 的 `term=<艺术家> <曲名>&entity=song&country=us` 查；
  **合集容器（群星）没有可用人名，只能仅用 `<曲名>` 查**。

**校验只能靠曲名**（歌手名多半对不上：库里中文 vs 接口英文音译）：
```python
# 归一：去括号内容 + 去标点空格 + zhconv 转简体
# 相等 或 Jaccard >= 0.75 才算命中；否则丢弃
# limit 取 10（不是 200），扫到第一个曲名匹配的即停
```
不匹配一律丢弃 —— 「金池 勇气」会返回「座位」，必须挡掉。

> ⚠️ **上面这个「只比曲名」的做法在 2026-10-01 全库重查时被证伪**：
> 它会产生 **15~20% 的同名误配**（那英《不管有多苦》→ 许茹芸 Valen Hsu、
> 张学友《星晴》→ 池昌旭 Ji Chang Wook）。**曲名匹配必须再叠一道艺术家校验**，
> 做法与实测数据见 **25.11**。别看漏这一节。

**实测（对剩余 3472 首空值抽样 60 首）**：

| 模式 | 写法 | 命中 |
|---|---|---|
| A 非群星 | `term=<艺术家> <曲名>` | 19/40 = **48%** |
| B 群星合集 | `term=<曲名>` | 11/20 = **55%** |
| 合计 | | 30/60 = **50%** |

→ 外推 3472 首可再补约 **1736 首**；耗时 3472 × 3.3s ≈ **3.2 小时**。

**两个必须注意的噪音**：
- 模式 B 阈值 0.75 会在合集里擦边通过：「**山村老师**」命中了「**山村老尸**」（Jaccard 恰好 0.75）。
  合集内曲名重复度高，**模式 B 应把阈值提到 0.85 或要求完全相等**。
- 「`Track13`」「`Track04.家乡`」这类**没有真实曲名**的条目永远查不到，直接跳过。

**与艺术家级的分工**：

| | 艺术家级 | 单曲级 |
|---|---|---|
| 覆盖 | 主流歌手（命中 25/25） | 长尾、合集、发烧碟 |
| 成本 | 1022 次 ≈ 56 分钟 | 6109 首 ≈ 5.6 小时 |
| 精度 | 高（有曲名交集校验） | 高（曲名严格匹配）但噪音略多 |
| 顺序 | 先跑（一次拿 200 首，效率高） | 后跑，只补前者的漏 |


### 25.11 全库单曲重查 + **命中校验闸门**（2026-10-01 实战，12306 首）

老张口径不变：**单曲级优先，搜不到留空**。这次把全库 12306 首全跑了一遍，暴露出
25.10 那个「只比曲名」的做法**不能直接写库**。

**执行数据**：查询 12h50m（实测 3.75 秒/首，不是 3.3）→ 命中 7078（57.5%）；
过闸门后写库 **5898 条变更**（填入 1114 / 覆盖 952 / 清空 3832），
最终库内 **有流派 6116 首（49.7%）、留空 6190 首**。

#### 【坑 88】只比曲名不校验艺术家 → **15~20% 同名误配**

`if xt == ct or jac(ct, xt) >= thr` 只要曲名对上就认，**完全不看返回的 `artistName`**。
全库实测的误配样例：

| 库内 | iTunes 返回 | 真相 |
|---|---|---|
| 那英《不管有多苦》 | Valen Hsu | 许茹芸 |
| 张学友《星晴》 | Ji Chang Wook | 池昌旭（韩） |
| 齐秦《原来的我》 | Dave Wang | 王杰 |
| 汪峰《像个孩子》 | Bruce Liang | 梁咏琪？ |
| 张学友《心如刀割》 | Nicky Lee | 李玖哲 |

**判定闸门（`a12_verify.py`，按顺序）**：
```
1. direct  库内名整体出现在返回串里（中文合唱 / 拉丁同名）        → PASS
2. cjk     返回名含汉字却对不上库内名                        → FAIL
           ★中文之间不存在罗马化歧义，这条最便宜也最有效。
             它挡住了「整张专辑被误配到中文翻唱歌手」：
             龙飘飘《真情比酒浓》→ 高莲娜 & 夏菊子、郑钧《赤裸裸》→ 陈楚生
3. token   按 & 、, ; / feat ft and with 拆 token，逐个比：
           a) token 与库内名互为子串（伍佰 & China Blue ↔ Wu Bai & China Blue）→ PASS
           b) 反查：该 token 在库内只指向本艺术家（rev 占比 ≥ 0.6）
              且本艺术家有相当比例用它（fwd 占比 ≥ 0.3）        → PASS
              ★ a、b 缺一不可，否则「齐秦 → Dave Wang」这种孤例会被错放
4. other   都不成立                                          → FAIL（陌生名）
5. mode B  群星/合辑，无艺术家可比                            → 放行（保持原判）
```

三条实战教训：
- **v1 漏了多艺术家拆分**，把合唱曲目全判成误配（张学友《甲乙丙丁》→「Jacky Cheung, Andy Hui」）。
- **众数映射会被「自洽污染」洗白**：某个 artist 的命中整片都错到同一个人时，
  rev/fwd 占比反而自洽达标。中文硬规则（第 2 条）能挡住其中的中文部分。
- **错杀是代价、不是 bug**：区瑞强 → Albert Au（那确实是他的英文名）会被判 FAIL，
  本来正确的流派被清空。属「宁可留空不填假依据」的代价，接受。

#### 【坑 89】「曲名兜底」召回升、**准确率崩**，禁止用于回填

对 40 条未命中加「仅曲名查」兜底：捞回 21 条（52.5%），但艺术家对得上的**只有 1~3 条**：

| 库内 | 返回 |
|---|---|
| 谭咏麟《情缘巴士站》 | ManLi ❌ |
| 张学友《星晴(原唱：周杰伦)》 | Ji Chang Wook ❌ |
| 叶倩文《零时十分》 | George Lam ❌ |
| 五月天《赌神》 | Mayday ✓ |

→ 同一曲名在 iTunes 上常有多人翻唱，去掉艺术家等于放弃唯一可靠的辨别依据。

#### 【坑 90】`country=cn` 返回 **0 条**，换地区救不了命中率

| 查询 | us | cn |
|---|---|---|
| 张学友 夢中的妳 | 10 条（无该曲） | 0 |
| 张学友 遙遠的她 | 10 条（命中） | 0 |
| 齐秦 狂想 | 1 条 | 0 |

老华语资源**只在美国区**，`country=us` 是对的，不用折腾代理。

#### 【坑 91】读 WMA 绝不能用 `mutagen.File(path, easy=True)`

本机 mutagen 对 ASF 的 easy 映射取不到 genre，会把**写成功**的 WMA 误报成「文件里没流派」
（实测 `WM/Genre` 明明已写入）。校验必须按容器类名分支读原始标签：

```python
if hasattr(t, 'getall') and hasattr(t, 'delall'): fr = t.getall('TCON')   # ID3
elif cls == 'MP4Tags':  v = t.get('\xa9gen')                              # m4a
elif cls == 'ASFTags':  v = t.get('WM/Genre')                             # wma
else:                   找 key.lower() == 'genre'                          # flac/ape
```

#### 【坑 92】「写文件返回 ok」≠「文件真的改了」——必须读回来比对

`set_genre_file()` 对每个容器走不同分支，任一分支写偏**都不会抛异常**、返回仍是 `ok`。
所以 apply 之后**必须**跑一次 `a14_check_tags.py`（库 ↔ 文件逐条比对）。
本次 5898 条自检 100% 一致才收工。

#### 【坑 93】统计「写完后留空多少」的公式

```
✗ 留空 = 清空条数        ← 漏掉「本来就是空、这轮也没变」的条目
✗ 有流派 = 12306 - 清空   ← 把「不变」里的空条目算成了有流派（本次多算 2358 首）
✓ 留空 = 清空 + 「不变」里 old 为空的条数
```
区别很大：错误公式给 8474，真实是 6116。**dry-run 的数字报给用户前先核对口径**。

---
