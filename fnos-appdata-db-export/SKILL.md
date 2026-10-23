---
name: fnos-appdata-db-export
description: 通过 SSH 访问飞牛(fnOS) 应用私有数据目录 /usr/local/apps/@appdata/<app>/（root + 专用用户 ACL，普通用户 Permission denied），用 sudo 拿一致性 SQLite 快照并下载到本地。当用户要求「访问/下载 fnos 上某个 app 的 db 目录」「导出 trim.music/相册/影视等应用的数据库」「Permission denied 打不开 @appdata」时使用。
agent_created: true
---

# 飞牛 fnOS 应用私有数据（@appdata）导出

## 环境事实（实测）

| 项 | 值 |
|---|---|
| SSH | `mcp__ssh-mcp-server`，connectionName `fnos`，`garson@192.168.88.129:22` |
| 配置 | `C:\Users\garso\.workbuddy\ssh-mcp\ssh-config.json`（含明文 password） |
| `@appdata/<app>` | `root:root` + POSIX ACL 只给 `<app>` 用户（如 `user:trim.music:rwx`）→ **garson 直接 ls 报 Permission denied** |
| sudo | **需要密码，且密码 == SSH 登录密码**（`sudo -n` 不可用） |

典型目录（`trim.music` = 飞牛音乐 App）：

```
/usr/local/apps/@appdata/trim.music/
├── db/     music.db  + music.db-wal + music.db-shm   ← 目标
├── log/
├── trim.music.log
└── trim.music.pid
```

## 关键坑

### 1. heredoc 会吃掉 sudo 密码的 stdin

```bash
# ✗ 错：heredoc 占了 stdin，sudo 读不到密码 → 连报 3 次 "incorrect password"
echo 'PW' | sudo -S -p '' python3 - <<'PY'
...
PY

# ✓ 对：两步走 —— 先写脚本文件，再喂密码执行
cat > /tmp/_x.py <<'PY'
...
PY
echo 'PW' | sudo -S -p '' python3 /tmp/_x.py 2>&1
```

### 2. 别用 `cp` 拷活在的 SQLite（WAL 模式下必然撕裂）

App 正在运行时 `music.db` + 46 MB 级 `music.db-wal` 并存，裸 `cp` 三件套拿到的
「主库 + WAL」不是同一时刻的，直接打开会缺最新数据或报错。
**必须用 SQLite backup API 出快照**（自动把已提交的 WAL 合并进单文件）：

```python
import sqlite3
src = sqlite3.connect('/usr/local/apps/@appdata/<app>/db/xxx.db')   # root 身份打开
dst = sqlite3.connect('/tmp/tm_dump/xxx.db')
src.backup(dst)      # 一致性快照，无 WAL 依赖
```

注意：快照**文件大小可能与源库相同**（WAL 页是原地覆盖，不改 page_count），
这不是失败；用 `pragma integrity_check` + 逐表行数比对 LIVE/SNAP 来确认。

### 3. 下载前必须放宽权限

`mcp__ssh-mcp-server__download` 是以 garson 身份读远端文件 → 快照要 `chmod 644`，
且落在 garson 可读的目录（`/tmp/tm_dump/`）。root 的 `~`（`/root`）不可用。

## 标准流程

```bash
# ① 探测（先确认目录存在与权限形态）
ls -ld /usr/local/apps/@appdata/<app> /usr/local/apps/@appdata/<app>/db
getfacl -p /usr/local/apps/@appdata/<app>

# ② 一致性快照（root 身份）
cat > /tmp/_snap.py <<'PY'
import sqlite3
src = sqlite3.connect('/usr/local/apps/@appdata/<app>/db/xxx.db')
dst = sqlite3.connect('/tmp/tm_dump/xxx.db')
src.backup(dst); dst.close(); src.close()
PY
echo 'PW' | sudo -S -p '' bash -c '
  mkdir -p /tmp/tm_dump
  python3 /tmp/_snap.py
  chmod 644 /tmp/tm_dump/*
  ls -la /tmp/tm_dump'

# ③ 校验：快照 vs 线上 逐表行数一致（同样走 sudo）
cat > /tmp/_cmp.py <<'PY'
import sqlite3
q = lambda p: sqlite3.connect('file:%s?mode=ro' % p, uri=True).execute(
    'select count(*) from <表>').fetchone()[0]
print('LIVE', q('/usr/local/apps/@appdata/<app>/db/xxx.db'))
print('SNAP', q('/tmp/tm_dump/xxx.db'))
PY
echo 'PW' | sudo -S -p '' python3 /tmp/_cmp.py

# ④ 下载（MCP 工具）+ 本地 md5 双向核对
md5sum /tmp/tm_dump/xxx.db          # 远端
# mcp__ssh-mcp-server__download → 本地
md5sum xxx.db                        # 本地，必须一致

# ⑤ 清掉远端临时快照
echo 'PW' | sudo -S -p '' rm -rf /tmp/tm_dump /tmp/_snap.py /tmp/_cmp.py
```

## 回滚 / 恢复（本流程只读，不改应用数据）

- 快照是**只读导出**，不 checkpoint 源库、不写任何文件到 `@appdata`，无副作用。
- 若要拿原始三件套（主库 + wal + shm）做取证，需**先停应用**（`sudo systemctl stop <app>`）
  再整组拷 —— 运行中拷出来的 wal 与主库不配对，比不拿更危险。

## trim.music 库结构（实测，25 表 / 约 5.9 万行）

`artist / album / track / audio_file / lyric / playlist / playlist_track / favorite_track /
play_history / genre / track_artist / track_genre / user / user_token / user_oauth /
shared_library(_member/_excluded_folder) / user_sorting_preference / app_state / app_hook / …`

- `user.password` 是 **bcrypt**（`$2a$12$…`）哈希，不是明文。
- 音乐实体：`track`（曲目，13089）↔ `audio_file`（文件路径，13089）↔ `album`（3413）↔ `artist`（2198）。
- 输出中文时 Windows 本地用 `PYTHONUTF8=1` 或直接设 `encoding`，避免 GBK 控制台乱码。
