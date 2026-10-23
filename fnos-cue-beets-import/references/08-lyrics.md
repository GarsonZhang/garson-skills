# 08 · 本地歌词补全（`.lrc`）

飞牛音乐 App 的歌词 **88% 依赖云端刮削**，云端查不到就彻底没词，且界面不给原因。
补「与音频同目录、同名的 `.lrc`」是唯一可控路径 —— 不动音频、不改标签、失败也不影响现状。

**核心前提**：这是**文件系统层**的操作，**不经过 beets**（beets 不管 `.lrc`）。
`beet update` / `beet ls` 都不会看到它，也不会被 beets 移走。

---

## 0. 先诊断：App 的歌词从哪来

歌词存在 App 私有库 `/usr/local/apps/@appdata/trim.music/db/music.db` 的 `lyric` 表（**需 sudo**）。

`lyric.source` 语义：

| 值 | 来源 | 是否可控 |
|---|---|---|
| 1 | 音频文件**内嵌**标签 | 要改文件 |
| 2 | **同目录同名 `.lrc`** | ✅ **本方案走这条** |
| 3 | **云端刮削**（飞牛 musicsvc） | ❌ 不可控 |
| 4 | 用户手动 | — |

实测（14095 个 track）：

```
有歌词 7001（49.7%）
  source=3 云端   6178  ← 占 88%
  source=1 内嵌    432
  source=2 本地lrc 391   ← 与磁盘上 391 个 .lrc 完全对应
```

**结论**：云端一挂就全没了；**补 `source=2` 是唯一能自己掌握的**。

App 侧失败日志（`/usr/local/apps/@appdata/trim.music/log/{error,info}.log`）：

```
scrape cloud lyrics not found                → 云端查无此歌
scrape cloud lyrics by official ref not found → 曲目匹配成功但歌词库没有
```

**已验证的识别机制**：磁盘上 391 个 `.lrc` ↔ 库中 391 条 `source=2`，**一一对应，不漏一个**。

---

## 1. 导出口径：哪些曲目缺歌词

```sql
select t.id, af.path, t.title, t.duration_ms,
       (select group_concat(ar.name,' / ') from track_artist ta
          join artist ar on ar.id=ta.artist_id where ta.track_id=t.id) as artists,
       (select ar2.name from album_artist aa join artist ar2 on ar2.id=aa.artist_id
          where aa.album_id=t.album_id limit 1) as album_artist,
       (select name from album al where al.id=t.album_id) as album
from track t
left join audio_file af on af.id=t.audio_file_id
left join lyric l on l.track_id=t.id
where l.id is null
```

⚠️ `album` 表的专辑名列叫 **`name`**（不是 `album`，那是 beets 的叫法）。
导出成 JSON（含 `path` / `title` / `duration` / `artist` / `album_artist`），后续脚本都吃这个文件。

**建议先剔除非歌曲**：`唐诗 / 古诗词 / Violin / 伴奏 / 卡拉 / Instrumental / 纯音乐` 这类
本来就没有歌词，别浪费请求。

---

## 2. 三级数据源

| 级 | 源 | 命中率 | 网络要求 | 强项 |
|---|---|---|---|---|
| 1 | **LRCLIB** | 17.8% | **必须走代理**（按 IP 严格限流） | 版权歌、Live 版、海外 |
| 2 | **网易云 `cloudsearch/pc`** | ~49% | **必须直连** | 中文主流 |
| 3 | **笑匠音乐歌词库** `xiaojiangclub.com` | 补第 2 级的漏 | 直连 | 「网易云搜到但无词」的那批 |

**三源各占一块，实测独有率都不可忽略** —— LRCLIB 在「网易云可覆盖」之外的**独有率 45%**，
不要因为命中率低就砍掉。

### 2.1 LRCLIB（第一级）

```
GET https://lrclib.net/api/get?artist_name=&track_name=&album_name=&duration=
返回 syncedLyrics（带时间轴）/ plainLyrics
```

- **限流按出口 IP，很严**：直连约 **3 次/分钟**；5 秒间隔就 503。
- 处置：配**动态代理**；实测 **2.19 首/秒**（单代理 30 秒约 12 次请求）。
- ⚠️ **代理必须「一次一取」**，绝不复用 —— 复用会被记住同 IP，掉到 0.6 首/秒（慢 5 倍）。
- ⚠️ LRCLIB 返回**大量繁体**（`屋簷如懸崖`），必须 `zhconv` 转简体后再比对/落盘，
  否则与文件标签（简体）比对会**全部误判为"无命中"**。

### 2.2 网易云 cloudsearch（第二级）

```
搜索  GET https://music.163.com/api/cloudsearch/pc?s=<歌名 艺人>&type=1&offset=0&total=true&limit=10
      Header 必须带 Referer: https://music.163.com/ + 浏览器 UA
      返回 result.songs[]：id / name / ar[].name / al.name / dt(毫秒)

歌词  GET https://music.163.com/api/song/lyric?id=<id>&lv=1&kv=1&tv=-1
      lrc.lyric 是带时间轴的 LRC
```

- ⚠️ **别用老接口 `/api/search/get/web`** —— 它**只返回翻唱**（周杰伦《七里香》前 3 条全是翻唱）。
- ⚠️ **必须直连**：走代理 → 境外 IP 风控 → **0 候选**。
- **不需要账号**：免登录已能搜到原唱；实测直连 0.6 秒间隔 20 次**零失败**。
  个人账号批量万次调用反而有**封号风险**，不划算。

### 2.3 笑匠音乐歌词库（第三级）

**关键**：`/lyrics/{id}.html` 的 **id 就是网易云 song id**，所以**不需要任何搜索**，
直接拿第 2 级搜到的 id 拼 URL：

```
https://xiaojiangclub.com/lyrics/326988.html      → 「这么近那么远歌词 - 张靓颖」
https://xiaojiangclub.com/lyrics/2063487880.html  → 「罗刹海市歌词 - 刀郎」
```

| 项 | 情况 |
|---|---|
| 命中 | HTTP **200**，含标准带时间轴 LRC |
| 不存在 | HTTP **404** + 「页面未找到」（可安全区分） |
| 歌词位置 | `<section id="lrc-lyric-desktop">` → `<pre class="lyric-content">` |
| 另有 | 纯文本版在 `<section id="plain-lyric-desktop">` |
| `robots.txt` | `Disallow:` 空（允许抓取）+ `Crawl-delay: 10` → **串行化 + 1.5s 最小间隔** |

```python
re.search(r'id="lrc-lyric-desktop"[\s\S]*?<pre class="lyric-content">([\s\S]*?)</pre>', html)
```

⚠️ **局限**：该站**没有站内搜索**（`/search`、`/api/search`、`/so/`、`/s/` 全 404）；
`/list/{歌手}.html` → 301 → `/singer/{id}.html` 只列 **56 首精选**、不分页。
→ **只能按 song_id 取词**，对「网易云根本没搜到」的曲目**无能为力**（拿不到 id）。

⚠️ **Bing `site:` 路线已证伪**：该站**完全未被 Bing 收录**，Bing 会忽略 `site:`
静默回退成普通搜索（结果全是百度百科/QQ音乐/bilibili）。**不要走搜索引擎。**

---

## 3. 实现：三级瀑布（内建，不要串成三条流水线）

第三级依赖第二级的 `song_id`，**天然是它的子步骤** → 直接内建在同一个脚本里，
一次跑完，零重复搜索：

```python
lrc = ne_lyric(song_id)                       # 第二级
if not lrc.strip():
    lrc = xjc_lyric(song_id)                  # 第三级：同一 id 直达笑匠站
    if not lrc:
        return 'unresolved'                   # 三源都没有，放弃
```

**LRCLIB 并行跑**（走代理，与网易云的直连互不干扰），结果取并集。

**「优先级」建议用「每级跳过已存在的 `.lrc`」实现**，不要串行等——
两源网络路径相反，并行更快且结果等价。

---

## 4. 匹配逻辑（命中率的关键，不改会大面积假阴性）

三件事**缺一即产生大量误判**：

1. **艺人字段拆分** —— 库里 `artist` 可能是「张洪量莫文蔚」这种**无分隔符串**，
   整体比对**永远匹配不上**。按 `/、&,，;；`、`feat.` 拆成集合，**任一命中**即可。
2. **简繁归一** —— 文件标签可能是繁体（`張學友`、`張靚穎`），源站返回也可能是繁体。
   统一 `zhconv.convert(x, 'zh-cn')`。
3. **剥离括号与版本标记** —— `笑忘书 (Live)` → `笑忘书`；
   去掉 `（）()[]【】` 内容以及 `live/remix/cover/伴奏/纯音乐/instrumental` 标记。

匹配分级：① 歌名 + 艺人 → ② 歌名 + 时长 → ③ 歌名唯一候选。

**必须叠时长校验（±6 秒）** 防止放宽后误配（网易云候选时长字段是 `dt`，**毫秒**）。

```python
_BRK = re.compile(r'[（(\[【].*?[)）\]】]')
_MARK = re.compile(r'\b(live|remix|cover|伴奏|纯音乐|instrumental|demo|acoustic|版|片段)\b', re.I)
def key_of(s):
    s = s2s(_BRK.sub('', s))                 # s2s = zhconv 转简体
    s = _MARK.sub('', s)
    return re.sub(r'[\s\-–—_·,，.。!！?？\'"“”‘’&/:：]', '', s).lower()
```

**实测效果**：只做①~③ + 时长校验，命中率 **40% → 48.3%**。

---

## 5. 落地：从本地 `.lrc` 到 App 生效

### 5.1 文件命名（硬要求）

- 与音频**完全同名**，仅换扩展名：`这么近那么远(《80后》电影主题曲).wma` → 同名 `.lrc`
- 放**同一个目录**
- 生成规则：`os.path.splitext(audio_path)[0] + '.lrc'`
- 保持与 `Music/` 相同的相对路径树（散曲 3 段 `歌手/曲目.lrc`、专辑曲 4 段 `歌手/专辑/曲目.lrc`）

### 5.2 打包前必须做路径映射校验

**最容易翻车的一步**：清单里可能有「磁盘上已不存在」的残留（已删艺人的曲目、已归档的乱码目录），
上传后会变成**孤儿 `.lrc`**。

在 NAS 上比对（本地先导出 base 清单再上传）：

```python
# 本地
find lrc_out -name '*.lrc' | sed 's|^\./||; s|\.lrc$||' | sort > lrc_bases.txt

# NAS（python3）
import os
M = '/vol2/1000/电影音乐/Music'
EXTS = {'.mp3','.flac','.m4a','.wav','.ape','.wma','.dts','.ogg','.wv'}
bases = set()
for dp, _, fn in os.walk(M):
    for n in fn:
        b, e = os.path.splitext(n)
        if e.lower() in EXTS:
            bases.add(os.path.relpath(os.path.join(dp, b), M))
miss = [l.rstrip('\n') for l in open('/tmp/lrc_bases.txt', encoding='utf-8')
        if l.strip() and l.rstrip('\n') not in bases]
print('对不上(会失效):', len(miss))
```

实测：3537 条里 **3521 条对得上（99.5%）**，16 条对不上 —— 全是已删艺人的残留。
**打包时按 `bases` 过滤掉。**

### 5.3 打包 → 上传 → 铺开

```bash
# 本地：按有效清单打包（tar 保留中文路径）
# 上传：mcp__ssh-mcp-server__upload
# NAS：解包到 Music/
tar -xf /tmp/lrc_pack.tar -C /vol2/1000/电影音乐/Music
```

### 5.4 权限归位（必做，否则与全库不一致）

```bash
find /vol2/1000/电影音乐/Music -name '*.lrc' -newer <参照时间> -exec chown garson:Users {} + 
find /vol2/1000/电影音乐/Music -name '*.lrc' -exec chmod 700 {} +
```

全库正常权限是 **`garson:Users` + `700`**（不是 666/644）。

### 5.5 让 App 生效（**核心难点，已找到唯一可行路径**）

⚠️ **App 只在曲目「首次入库」时关联同目录 `.lrc`**。之后下面这些**全部实测无效**：

| 尝试 | 结果 |
|---|---|
| 新增 `.lrc` 后等 FSEvents | 日志只记 `skip non-audio file`，不处理 |
| `touch` 音频文件 | 只产生 `OnFileCloseWrite` |
| 音频「删除 → 重建」（制造 `OnFileCreated`） | 只记 FSEvents，**无任何 scanner 动作** |
| **在 App 界面点「扫描」** | **依然无效** —— 扫描是增量的，不重新处理已在库的曲目 |
| 手动插 `lyric(source=2)` 记录 | Web 端仍「暂无歌词」；`stored_guid` 对应的内容不在本地（可能在云端） |

✅ **唯一生效的办法：让曲目「从库里消失」，App 才会当新曲目重建并关联 `.lrc`。**

**执行步骤**（务必按序）：

```python
# 1) 先整库备份 music.db（必做）
# 2) 导出映射：audio_file.path → 旧 track_id（重建后要用来迁移引用）
# 3) 删除目标曲目的库记录
#    注意：playlist_track / favorite_track / play_history 先别删，稍后迁移
DELETE FROM track_artist WHERE track_id IN (...);
DELETE FROM track_genre  WHERE track_id IN (...);
DELETE FROM lyric        WHERE track_id IN (...);
DELETE FROM track        WHERE id IN (...);
DELETE FROM audio_file   WHERE id IN (...);
# 4) touch 音频文件（批量逐个 os.utime），App 会异步重建
os.utime(audio_path, None)
```

实测：App 会**自动重建**，日志出现 `scanner[persistAudioFileTrack]: finished`
+ `after enqueueing lyric download`，且 **`lyric.source=2` 计数随 track 数同步增长**
（实测一次 4393 个曲目：`source=2` 从 391 一路涨到与重建数持平）—— 说明每个重建曲目都成功挂上了本地歌词。

- ⏱ **重建速率约 6 个/秒**（4393 个约需 12 分钟），期间 `track` 数从 9722 缓慢回升到 14115
- ⚠️ **`sqlite3` 事务**：Python sqlite3 默认在 DML 前隐式开事务，
  直接再 `BEGIN IMMEDIATE` 会报 `cannot start a transaction within a transaction`。
  需 `sqlite3.connect(..., isolation_level=None)` 再手动 `BEGIN/COMMIT`

⚠️ **代价：`track_id` 会全部改变**（实测 69427 → 79602）→ **必须迁移引用**：

| 表 | 影响 |
|---|---|
| `playlist_track` | 歌单；**不迁移则歌单失效**（实测 4393 个曲目涉及 2089 条引用） |
| `favorite_track` / `play_history` | 收藏 / 播放历史（实测 0 / 6 条） |

**迁移方法**：重建**后**再取一次 `audio_file.path → 新 track_id`，与重建前的映射按 path 对齐，
批量 `UPDATE playlist_track SET track_id=新 WHERE track_id=旧`。

⚠️ **重建会让专辑聚合回退** —— 实测（4393 个曲目重建后）：

| 项 | 重建前 | 重建后 | 修复后 |
|---|---|---|---|
| 有歌词曲目 | 7018 (49.7%) | **11399 (80.8%)** | — |
| 同名专辑组 | 79 | **102** | **80** |
| 空专辑 | 0 | 12 | 0 |

App 重建 album 时**按文件标签分组**，因此：
- 多版本聚合专辑（如「雪狼湖」）会**重新分裂**
- 库里手工合并过的专辑会**回退**（实测「中华儿歌珍藏集1/4」各多出 1 张单曲专辑）

**修复方式**（重建后必做，顺序无所谓）：
1. 删空专辑：`DELETE FROM album WHERE id NOT IN (SELECT DISTINCT album_id FROM track WHERE album_id IS NOT NULL)`
   （`album_artist` 同步删）
2. 重新合并同名专辑：用与 `SKILL.md` 第 3 节相同的**「曲目所在目录是否有交集」判据**，
   保留曲目最多的那张。实测一次修好 22 组、迁移 47 条曲目。

⚠️ App 的 API **不可编程调用**：走 unix socket（`/run/trim_srv.sock`），
`/api/v1/*` 经 nginx 一律 302，只能靠文件系统事件驱动。

---

### 5.6 完整实战配方（4393 个曲目，一次跑通）

```
① 抓取歌词 → 本地 lrc_out/（见第 2~4 节）
② 路径映射校验 → 剔除孤儿，得到有效清单（第 5.2 节）
③ tar 打包（Python tarfile）→ 上传 → 解包到 Music/
④ chown garson:Users + chmod 700
⑤ 整库备份 music.db
⑥ 导出映射：audio_file.path → 旧 track_id
⑦ 删除目标曲目的 track / audio_file 记录（保留 playlist_track 等）
⑧ os.utime() 逐个 touch 音频 → App 异步重建（约 6 个/秒）
⑨ 重建完成：track 数回升、lyric.source=2 同步增长
⑩ 迁移引用：按 path 对齐新旧 track_id，UPDATE playlist_track / favorite_track / play_history
⑪ 清理空专辑 + 按「目录交集」重新合并同名专辑
⑫ 让用户在 App Center 重启「音乐」应用
```

**实测总览（2026-10-02）**：4411 个 `.lrc` → 有效 4395 → 铺开 4787 个文件；
重建 4393 个曲目；歌词覆盖 **49.7% → 80.8%**；歌单 26 个、7294 条引用零丢失。

**② 直接往 App 库补 `lyric` 记录**（零文件副作用，但需确认 App 是否认账）

```sql
CREATE TABLE lyric (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  guid        TEXT NOT NULL UNIQUE,   -- 32 位 hex
  track_id    INTEGER NOT NULL,       -- → track.id
  source      INTEGER NOT NULL,       -- 1内嵌 / 2伴随文件 / 3刮削 / 4手动
  stored_guid TEXT,                   -- 歌词提取后在本地的存储 guid
  created_at  DATETIME NOT NULL,
  updated_at  DATETIME NOT NULL
)
```

- 时间戳格式同其它表：`2026-10-02 00:49:44.123000+08:00`
- ❌ **实测无效**：手动插入 `source=2` 记录后，Web 端仍显示「暂无歌词」。
  说明 App 不是「有记录就去读文件」，**`stored_guid` 对应的内容才是关键**
  （App 数据目录只有 `db/` 和 `log/`，全盘搜不到 lyric 目录 → 内容很可能在**云端**）。
- ❌ **其它实测无效的方式**：
  - `touch` 音频 → 只产生 `OnFileCloseWrite`，不处理
  - 音频「删除 → 重建」产生 `OnFileCreated` → App **只记录 FSEvents，不重新扫描已在库的曲目**
    （实测：`OnFileDeleted` + `OnFileCreated` 后无任何 scanner 日志，`lyric` 无变化，也没产生重复条目）
- ✅ **唯一有效路径**：让 App 界面触发一次扫描。前端代码里存在
  `sharedLibrary.scan` / `sharedLibrary.scanAll` 两个入口；
  扫描流程 `scanner[persistAudioFileTrack]` 会执行 `after persisting lyrics`（带 `lyricCount`）。
  ⚠️ App 走 unix socket（`/run/trim_srv.socket`），**没有可直接调用的 TCP API**
  （`/api/v1/*` 经 nginx 一律 302），所以只能从界面点。

### 5.6 影响面

- `playlist` / `playlist_track` 是**用户数据**，扫描不会动
- 歌词只在 `lyric` 表 + 文件系统，**不涉及 beets 库**（`beets.db` 完全不受影响）

---

## 6. 实测数据（2026-10-01，缺词 6556 首）

| 结果 | 数量 |
|---|---|
| 本地已有 `.lrc`（补前） | 391 |
| LRCLIB 命中 | 1147（17.8%，带时间轴 775） |
| 网易云 + 笑匠站命中 | ~1600（笑匠站贡献其中约 1/5～1/4） |
| **路径映射通过率** | **3521/3537 = 99.5%** |

**各源独有率**（抽 LRCLIB 已命中的 40 首回测）：

```
网易云也能拿到  52%      笑匠站能补到  2%      LRCLIB 独有 45%
```

---

## 7. 拿不到的那部分（约占一半）—— 不是脚本问题

抽样中「网易云根本搜不到」占 **67.5%**，其中约一半是**本来就没有歌词**：

- **古诗词朗诵** —— 王维 / 杜甫 / 孟浩然 / 贺知章 / 温庭筠（专辑里成体系出现）
- **纯器乐 / 试音碟 / DTS / 卡拉OK** —— 1812 序曲、舒伯特小夜曲、小提琴经典
- **版权下架** —— 周杰伦等（网易云搜不到，LRCLIB 才有）
- **冷门翻唱、网络歌手、外文**

**换任何源、给任何账号都拿不到。** 诊断时先把这类筛出来，别浪费请求，也别向用户承诺全覆盖。

---

## 8. 踩过的坑

| # | 坑 | 后果 | 正解 |
|---|---|---|---|
| 1 | 拿**相对路径**比 NAS 的**绝对路径** | 0 匹配，误判全都没对 | 统一成相对 `Music/` 的 relpath |
| 2 | 比对不处理简繁 | LRCLIB 返回繁体 → **全部误判"无命中"** | `zhconv.convert(x,'zh-cn')` |
| 3 | 艺人字段整体比对 | 「张洪量莫文蔚」永不匹配 | 拆成集合 |
| 4 | 用网易云**老接口** `/api/search/get/web` | 只拿到翻唱 | 用 `cloudsearch/pc` |
| 5 | 网易云**走代理** | 境外 IP 风控 → 0 候选 | 网易云**必须直连** |
| 6 | 代理**复用同一 IP** | 被站点记住 → 503 增多、速率降 5 倍 | **一次一取**，绝不复用 |
| 7 | 用 `nohup ... &` 启后台任务 | 随调用结束被清理，任务静默中断 | 用工具的 `run_in_background` |
| 8 | 日志重定向但不加缓冲 | 进度全看不见（块缓冲） | `PYTHONUNBUFFERED=1` |
| 9 | 单线程抓取 | 11 首/分钟，7000 首要 9 小时 | 多线程；实测 6 并发 → **125 首/分钟** |
| 10 | 每轮遍历已完成文件做判断 | 速率掉到 0.13 首/秒 | 启动时先过滤，再进主循环 |
| 11 | 打包前不做路径映射校验 | 已删曲目的 `.lrc` 变**孤儿文件** | 上传前用 NAS 端比对过滤 |
| 12 | 下完不修权限 | 与全库 `garson:Users 700` 不一致 | `chown` + `chmod 700` |
| 13 | 以为要「重新扫描」 | 触发重扫有覆盖风险 | App 有 FSEvents，**不用扫**；必要时只重启 App |

---

## 9. 依赖与脚本清单

| 项 | 说明 |
|---|---|
| `zhconv` | **NAS 系统 python3 已装**；本地需自建 isolated venv 安装 |
| 本地脚本 | `netease_fetch_mt.py`（网易云+笑匠，多线程+三级瀑布）、`lrc_fetch_multi.py`（LRCLIB，多线程+动态代理） |
| 输出目录 | 本地 `lrc_out/`，结构与 `Music/` 一致 |
| 备份点 | 不需要动库 —— 本方案**只加文件，不改库**，回滚 = 删掉新增的 `.lrc` |
