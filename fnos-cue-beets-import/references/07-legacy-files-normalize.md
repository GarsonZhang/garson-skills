# 库内「属主/权限不符」遗留文件的归位

**场景**：库目录 `/vol2/1000/电影音乐/Music` 下有一批文件属主是 `xunlei-app:xunlei-app`、权限 `666`，
而库里正常文件是 `garson:Users` + `700`。文件能正常播放，但"状态不统一"。
（诱因：迅雷/下载器直接落盘，或下载态文件被后续流程带入库。）

---

## 0. 先别急着"重新导入"——先判清文件到底在不在 beets 库里

**这是本类任务最容易搞错的一步。** 实测踩过的坑：拿**相对路径**去比 beets 库的路径，
得出"608 个全是黑户"的**完全错误**结论，进而选错了整条处理路线。

beets 的 `items.path` 存的是**绝对路径**（`/vol2/1000/电影音乐/Music/...`）。
比对必须两边都是绝对路径：

```python
import sqlite3
B = '/vol2/1000/电影音乐/beets.db'
xl = {l.strip() for l in open('/tmp/xl609.txt', encoding='utf-8') if l.strip()}
con = sqlite3.connect('file:%s?mode=ro' % B, uri=True)
dec = lambda x: x.decode('utf-8', 'replace') if isinstance(x, bytes) else x
dbp = {dec(p) for (p,) in con.execute('select path from items')}   # 绝对路径
print('已在库:', len(xl & dbp), ' 不在库:', len(xl - dbp))
```

实测某次结果：608 个里 **577 个音频早就已在 beets 库中**，不在库的 31 个**全是 .lrc**
（beets 不管 lrc）。也就是说「音频部分早被导入过，只是属主/权限没归位」——
**这种情况根本不需要重新 MB 匹配导入，只需要权限归一。**

还要顺带查两类记录：

```python
# ① beets 库中指向已不存在文件的孤儿记录
import os
print([p for p in dbp if not os.path.exists(p)])
# ② 孤儿专辑（albums 无 items 引用）—— 正常应为 0
con.execute('''select a.id,a.album,a.albumartist from albums a
               left join items i on i.album_id=a.id where i.id is null''').fetchall()
```

---

## 1. 核对「文件实际标签」与「库中记录」是否一致

文件若被下载器覆盖过，标签可能变。核对时**必须用 `easy=True`**：

```python
from mutagen import File as MFile
f = MFile(p, easy=True)      # ← MP3 的 ID3 键是 TIT2/TPE1/TALB，
t = f.tags or {}             #   直接读 t.items() 拿不到 'title' 会全部误判为空
g = lambda k: (str(t[k][0]) if isinstance(t.get(k), list) and t.get(k) else str(t.get(k, '')))
```

> ⚠️ **实测踩过的坑**：不用 `easy=True` 时，233 个 MP3 被误判为"标签为空、与库不一致"，
> 改 easy 后真实不一致只有 3 个，且全是 `.wav`（easy 模式读不了 WAV 的 ID3，仍是假阳性）。
> **WAV 的标签要用 `mutagen.wave.WAVE` / ffprobe 单独核**。

---

## 2. 关于 MB 完整匹配：对这类库通常**不划算**，先量化再决定

如果用户选择"MB 完整匹配重新导入"，**先跑非交互预览量化收益**，别直接上：

```bash
# 注意：-p 是 prompt 不是 pretend；-P 才是 pretend；非交互必须再加 -q
beet import -C -P -q "$dir" < /dev/null
```

实测结论（327 张专辑样本内）：

| 现象 | 数据 | 说明 |
|---|---|---|
| 命中率极低 | 30 张专辑只有 2 张匹配成功（~7%） | 多数目录**曲目残缺**（如《范特西》目录仅 7/10 首）→ 分数达不到 `strong_rec_thresh` → 自动 skip |
| **简繁倒退** | 命中的那条把「因为」→「因為」 | MB 上华语专辑多为台版繁体；库里若已做过**简体归一**，MB 匹配会把它**改回繁体**，与既有规范相悖 |
| 速度 | 约 20 s/专辑 | 327 张需近 2 小时 |
| **`-P` 并非只读** | 预览后 `beets.db` 的 md5 变了 | 实测 2 条 item 记录被**重建**（id 变化，album_id 变化）。**路径级 0 变化、孤儿专辑 0、无数据损失**，但"预览绝对安全"这个假设不成立 |

**结论**：文件若已在库中且标签与库一致，MB 匹配只带来风险，没有收益 —— 直接跳过。

---

## 3. 权限归一（真正要做的那一步）

目录通常已是 `garson:Users 700`，**只需改文件**：

```bash
# 先用清单文件驱动，避免路径含空格/引号被 shell 拆解
echo 'PW' | sudo -S -p '' bash -c '
  while IFS= read -r f; do
    chown garson:Users "$f" && chmod 700 "$f"
  done < /tmp/xl609.txt
  echo done'
```

- 库里正常文件的基准是 **`700` + `garson:Users`**（实测 1969/2000 抽样）
- 改完抽样 `stat -c '%U:%G %a %n'` 复核
- **改属主/权限不影响飞牛 App 播放**（库里其他 700 文件 App 读得正常）

---

## 4. 收尾

| 项 | 做法 |
|---|---|
| beets 孤儿记录 | `beet remove -d` 删记录（文件已不存在，**只动库不动盘**），或按 id 精确清理 |
| `.lrc` 歌词 | beets 不管 lrc，需手工归位：文件名与同目录音频同名、放在同一目录 |
| 散曲（无专辑目录） | 直接用 `paths.singleton`（本项目为 `$albumartist/$title`）决定目标位置 |
| 飞牛 App | **只要不移动音频文件、不改标签，就完全不用重扫**（这是"只做权限归一"方案的最大好处） |

---

## 5. 乱码目录 / 文件名处置

GBK↔UTF-8 混淆产生的乱码名（例：`Music/鍒樺痉鍗_/`）。反推原文：

```python
s = '鍒樺痉鍗_'
s.encode('gbk').decode('utf-8', 'replace')    # → 刘德?    ← 正确方向（末尾被截断）
s.encode('utf-8').decode('gbk', 'replace')    # → 閸掓ê鐥夐崡_  ← 方向反了，是二次乱码
```

要点：

- 目录名末尾常带 `_` 之类的**截断痕迹**，反推可能只恢复出前几个字，别指望完整还原
- **定归属要靠旁证**，不要猜：库里是否已有同名正常目录（本例有 `刘德华/`）、是否有同曲文件（本例有 `刘德华/冰雨.flac`）
- **处置走 `mv` 归档，不要直删**：`mv "Music/<乱码目录>" "_media_archive/garbled_dir/"`
- 归档后同步属主：`sudo mkdir` 建出来的目录属主是 `root`，要 `chown -R garson:Users` 补回
- 本例归档内容 `01 冰雨.wav`(48 M) 与已有 `刘德华/冰雨.flac`(29 M) 是**同曲的两种无损格式**，属冗余 —— 这类"WAV 整轨 + FLAC 单曲"是常见重复形态

---

## 6. 全库权限归一的收尾校验

```bash
# 目标：全库只剩一种组合
find /vol2/1000/电影音乐/Music -type f -printf '%u:%g %m\n' | sort | uniq -c | sort -rn
# 期望输出仅一行：  NNNN garson:Users 700
```

实测某库：15370 个文件 **100% `garson:Users 700`**。
若仍有零星 `666`/`644`，按第 3 节再来一轮即可（`-perm 666 -o -perm 644` 先导出清单，再清单驱动 chown/chmod）。

---

## 7. 脚本层踩过的坑（全都会静默产生错误结论）

| # | 坑 | 后果 | 正解 |
|---|---|---|---|
| A | `for f in $(cmd)` / 命令替换后**不带引号**传路径 | 含空格路径被 word splitting 拆碎，`ffprobe`/`stat` 报"文件不存在" | `while IFS= read -r f; do ... done < list` |
| B | 命令里出现要 `pgrep/pkill` 的**真实字符串** | 匹配到自身进程 → **把自己 kill 掉**（SIGTERM） | 把匹配串写进**脚本文件**执行；或 `[b]eet` 这类技巧，且确保命令行别处不出现真串（`echo "beet 残留"` 也会中招） |
| C | 用**相对路径**比 beets 库的**绝对路径** | 0 匹配 → 得出"全是黑户"的错误结论 | 两边统一为绝对路径 |
| D | 读 MP3 标签不用 `easy=True` | 标签被误判为空 | `MFile(p, easy=True)`；WAV 另用 `mutagen.wave` / ffprobe |
| E | 以为 `beet import -P` 只读 | 预览也在写库（id 重建） | 预览前先 `cp beets.db` 备份；预览后 `md5sum` 对比并做 id 级 diff |
| F | `beet import -P`（交互）在无 tty 环境跑 | 卡在 `Enter one of 1-5...`，**并把 while 循环的 stdin 吃光**导致只跑 1 张专辑 | 加 `-q`，并把 stdin 显式 `< /dev/null` |

**回滚依据**：动手前导出 `{path, size, mtime, uid, gid, mode, tags}` 的 JSON manifest，
存到 `_db_backups_archive/`；beets.db 同时带时间戳备份。
