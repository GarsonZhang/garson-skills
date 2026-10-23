# 歌词：App 侧诊断

> **完整抓取与落地流程**（多源选型、三级瀑布、匹配逻辑、路径校验、打包上传、权限）
> 在 `fnos-cue-beets-import` 技能的 **`references/08-lyrics.md`**。
> 本文只讲**从 App 库这一侧怎么看、怎么判**。

---

## 1. 歌词存在哪

`/usr/local/apps/@appdata/trim.music/db/music.db` 的 **`lyric`** 表（目录 root:root + ACL，**需 sudo**）。

## 2. `lyric.source` 语义

| 值 | 来源 | 可控性 |
|---|---|---|
| 1 | 音频文件**内嵌**标签 | 要改音频 |
| 2 | **同目录同名 `.lrc`** | ✅ 补这个最划算 |
| 3 | **云端刮削**（飞牛 musicsvc） | ❌ 不可控 |
| 4 | 用户手动 | — |

## 3. 一键统计覆盖率

```sql
select source, count(*) from lyric group by source order by 1;       -- 各来源分布
select count(*) from track;                                          -- 曲目总数
select count(distinct t.id) from track t join lyric l on l.track_id=t.id;  -- 有词的曲目数
```

实测（14095 个 track）：

```
有歌词 7001（49.7%）
  source=3 云端    6178  ← 占 88%
  source=1 内嵌     432
  source=2 本地lrc  391  ← 与磁盘上 391 个 .lrc 一一对应
```

**结论：歌词 88% 靠云端，云端查不到就彻底没词**；补 `source=2` 是唯一自己能掌握的路径。

## 4. 为什么不给原因

日志在 `/usr/local/apps/@appdata/trim.music/log/{error,info}.log`：

```
scrape cloud lyrics not found                 → 云端查无此歌
scrape cloud lyrics by official ref not found → 曲目匹配成功，但歌词库没有这首歌
scrapeCloudLyrics                             → 总调用次数，用来算失败比例
```

**注意**：同一个文件会**每轮扫描反复失败**（因为没入库，下轮又当新文件重试），
所以日志里会看到重复记录。

## 5. 相关配置（别乱动）

`shared_library.auto_download_lyric` —— 自动下载歌词开关（实测 = 1，已开启）。
**"歌词缺失"不是配置问题**，不要往这个方向调。

## 6. 导出待补清单

SQL 见 `08-lyrics.md` 第 1 节。⚠️ **`album` 表的专辑名列叫 `name`**（不是 `album`，那是 beets 的字段名）。

## 7. 注意

- 补歌词**只往文件系统加 `.lrc`**，**不写 App 库** —— 不需要备份 `music.db`，回滚 = 删掉新增的 `.lrc`。
- App 有 **FSEvents 监听**，新增文件会自己感知，**不需要手动重新扫描**。
- 一旦触发重新扫描，App 可能重新刮削；只要不触发，改动不会被覆盖。
