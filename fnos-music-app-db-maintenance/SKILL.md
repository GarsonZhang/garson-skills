---
name: fnos-music-app-db-maintenance
description: 维护与修复飞牛(fnOS)自带「音乐」App 的私有 SQLite 库（music.db）——治理同名专辑分裂、云端刮削与本地元数据不一致、专辑/艺人归属错误、空专辑与孤儿记录。当用户提到飞牛音乐专辑重复、同名专辑被拆成两张、专辑艺人显示不对、扫描后专辑分裂、music.db 修复时使用。
agent_created: true
---

# 飞牛(fnOS)「音乐」App 数据库维护

飞牛自带音乐 App 的所有专辑/曲目/艺人关系都存在它自己的 SQLite 库里。
**它不是 beets**：文件标签正确不代表 App 里显示正确，反之亦然。两者必须分开诊断。

---

## 1. 环境事实

| 项 | 值 |
|---|---|
| 库文件 | `/usr/local/apps/@appdata/trim.music/db/music.db`（+ `-wal` / `-shm`） |
| 目录归属 | `root:root` + ACL 只给 `trim.music` 用户 → **必须 sudo**（sudo 密码 == SSH 登录密码） |
| App 进程 | `/usr/local/apps/@appcenter/trim.music/trim-music`（root 运行，PPID=1，由飞牛主服务 `trim` 托管，**不是独立 systemd 单元**） |
| 日志 | `/usr/local/apps/@appdata/trim.music/log/{error.log,info.log}` |
| schema 参考 | `/usr/local/apps/@appcenter/trim.music/sqlite.sql`（及 `sqlite_v2/v3/v4.sql`） |

核心表：

```
album / artist / track / audio_file / album_artist / track_artist
genre / track_genre / lyric / playlist / playlist_track / favorite_track
shared_library(_member/_excluded_folder) / user / user_token / app_state …
```

关系：`track.album_id → album.id`；`track_artist(track_id, artist_id, artist_order)` **UNIQUE(track_id, artist_id)**；
`album_artist(album_id, artist_id, artist_order)`。时间戳列是 **9 位纳秒 ISO**：`2026-10-01 21:17:25.376742358+08:00`。

---

## 2. 核心模型：`metadata_mode` 决定一切

| 值 | 含义 |
|---|---|
| `1` | 走**本地文件元数据**（用文件的 albumartist 等标签） |
| `2` | 走**云端刮削**（飞牛 musicsvc，`metadata_cloud_provider=1` + `metadata_cloud_ref_id`） |

**同名专辑分裂的典型成因**：同一张专辑里，大部分曲目按本地元数据入库（艺人 = 文件标签），
少数曲目被云端刮削匹配到了**具体演唱者**，于是专辑艺人变了、专辑被拆成两个条目。

实测案例（中华儿歌珍藏集，160 个文件的 `albumartist` 全部是「群星」）：

```
album 19321 中华儿歌珍藏集1  mode=1  27曲  artist=群星
album 19322 中华儿歌珍藏集1  mode=2   4曲  artist=段丽阳   ← 逐曲被刮削成 徐唱/曹蕾/段丽阳
album 19326 中华儿歌珍藏集4  mode=1  22曲  artist=群星
album 19327 中华儿歌珍藏集4  mode=2   1曲  artist=李颜龙
```

**关键**：文件标签没问题，要修的是 App 的库。

---

## 3. 诊断：**别只看"同名"就合并**（最容易犯的错）

全库同名专辑往往很多（实测 103 组 / 4775 张专辑），但**绝大多数是不同艺人的同名专辑，本来就该分开**：

```
Lover       → Peggy Lee  vs  Taylor Swift      ← 不同专辑，别动
传奇        → 王菲       vs  迪克牛仔             ← 不同专辑，别动
PLAY        → S.H.E      vs  Ticia,Ricii      ← 不同专辑，别动
```

**唯一可靠的判据：两张同名专辑的曲目所在目录是否有交集。**

同一专辑的曲目必然落在同一（或同一批 CD）目录；不同艺人的同名专辑目录必然不同。

```python
# 对每组同名专辑，取每张的「曲目父目录集合」，有交集才是真分裂
ds = {aid: {path.rsplit('/',1)[0] for path in 该专辑所有 audio_file.path}}
hit = any(ds[x] & ds[y] for i,x in enumerate(live) for y in live[i+1:])
```

实测：103 组同名 → 用该判据筛出 **24 组真分裂**，其余 79 组是不同专辑，未动。

---

## 4. 修复

### 4.1 先备份（用 SQLite backup API，不要 cp 活在的库）

```python
import sqlite3, os
src = sqlite3.connect('/usr/local/apps/@appdata/trim.music/db/music.db')   # root 身份
dst = sqlite3.connect('/vol2/1000/电影音乐/_db_backups_archive/music.db.snapshot-<日期>')
src.backup(dst); dst.close(); src.close()
os.chmod(备份路径, 0o644)     # 否则下载/比对读不了
```

### 4.2 合并（保留曲目最多的那张）

```python
con = sqlite3.connect(SRC, timeout=30)
con.execute('PRAGMA busy_timeout=30000')
cur.execute('BEGIN IMMEDIATE')
for keep, drop in 计划:
    cur.execute('UPDATE track SET album_id=?, updated_at=? WHERE album_id=?', (keep, now, drop))
    cur.execute('DELETE FROM album_artist WHERE album_id=?', (drop,))
    cur.execute('DELETE FROM album WHERE id=?', (drop,))
con.commit()          # 出错务必 rollback
```

- `now` 用 `datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S.%f000+08:00')` 保持 9 位纳秒格式
- **保留原则**：曲目数最多的那张（内容更全）；也有按 `metadata_mode=1` 优先的场景，看诉求
- 若还要求"曲目艺人统一"（如用户说"都改为某艺人"）：
  `DELETE FROM track_artist WHERE track_id IN (...)` 再批量 `INSERT`，
  因 `UNIQUE(track_id, artist_id)` 直接 UPDATE 可能冲突

### 4.3 收尾必做校验（与备份逐表比对）

```python
for t in ['track','album','audio_file','artist','track_artist','album_artist','genre',
          'track_genre','lyric','playlist','playlist_track','favorite_track']:
    比对 before/after 行数
```

**预期**：`album` 与 `album_artist` 各减「被删专辑数」；`track` / `audio_file` / `artist` /
`track_artist` **必须完全不变**。再查：

- 孤儿 `track`（`album_id` 悬空）= 0
- 孤儿 `album_artist` = 0
- 空专辑（无 track）= 0

### 4.4 App 重载

App 是常驻进程。改库后若界面未刷新，需让 App 重载；
最稳妥是让用户在**飞牛 App Center** 里重启「音乐」应用（不要贸然 kill 进程，其托管方式不确定能否自拉起）。
只要**不触发重新扫描**，App 通常不会覆盖你的改动。

---

## 5. 注意

- **多版本同名专辑要单独判断**，不要塞进批量规则。实测「雪狼湖」一张专辑聚合了 5 个目录
  （`1997 雪狼湖` / `雪狼湖 (引進版)` / `1997 雪狼湖(限量珍藏紀念版)` / `雪狼湖` / 艺人根目录），
  共 108 曲，且与另一张 15 曲的同名专辑共享 `1997 雪狼湖` 目录 —— 此类需要用户决策。
- 只改 `album_id` 不要顺手改 `metadata_mode`，除非用户明确要求回落本地元数据。
- 云端刮削出的艺人记录（如「段丽阳」）在合并后可能变孤立，可留可删，不影响一致性。
- **校验时别在遍历游标的同时用同一游标查询**：`for r in cur.execute(...)` 内部再 `cur.execute(...)`
  会把外层游标重置，循环只迭代首行（实测把 26 个歌单只打印出 1 个，差点误判数据丢失）。
  用独立游标或先 `fetchall()`。
- **歌单批量操作**：歌单表是 `playlist(guid UNIQUE, name, cover_guid, user_id, …)` +
  `playlist_track(user_id, playlist_id, track_id, added_at, …)`，`UNIQUE(playlist_id, track_id)` 自动去重；
  **播放顺序由 `added_at` 决定**，批量导入要让它按源顺序递增；同一首歌可跨多个歌单。
  由 m3u/m3u8 建歌单时，条目里的相对路径基准是 **m3u 文件所在目录**。

---

## 6. 歌词补全（本地 `.lrc`）

App 歌词 88% 靠**云端刮削**，云端查不到就彻底没词。补「同目录同名 `.lrc`」是唯一可控路径
（App 识别为 `lyric.source=2`，不用联网、不动音频）。

**源选型实测**：网易云 `/api/cloudsearch/pc`（**直连、免登录**）命中 **48.3%**；
LRCLIB（**必须走动态代理**）11–18%；两源网络路径相反，**可并行互补**。
网易云的老接口 `/api/search/get/web` 只返回翻唱，不要用。**不需要网易云账号**（免登录已够，账号批量有封号风险）。

**三个假阴性来源**（缺一命中率就腰斩）：① 艺人字段未拆分（「张洪量莫文蔚」无分隔符）
② 简繁未归一（`張學友` vs 张学友）③ 括号/Live/伴奏标记未剥离。再叠**时长校验(±6s)** 防误配。

完整方案、接口、SQL、踩坑表 → `references/lyrics-fill.md`
