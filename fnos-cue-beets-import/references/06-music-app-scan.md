# 飞牛「音乐」App 扫描失败排查（失败 N 项 / 无具体原因）

飞牛自带「音乐」App（`trim.music`）扫描共享库时提示「失败 N 项」但**不给任何原因**。
原因只写在 App 自己的日志里，必须上机翻。

> 本节与 beets 无关：这是**飞牛 App 侧**的扫描失败，不是 beet import 的失败。
> 两者日志位置、判定逻辑完全不同，别混。

---

## 1. 判定逻辑（先建立模型）

扫描每个新音频文件时，App 会调**媒体服务器**做 `AudioInfo` 解析：

```
get audioInfo from media srv failed. sharedLibraryID=3, audioPath=<文件>,
  audioInfoResp=&{{<id> fail <code> broken media file} []}
task err: calling media server AudioInfo failed
```

- **解析成功** → 入库（后续扫描 skip，日志只留 `audio file is already scraped`）
- **解析失败** → 计入失败项，且**不登记** → 下一轮扫描会**再次**尝试、**再次**失败

所以「失败 N 项」≈「本轮扫描中 AudioInfo 解析失败的文件数」。
一个坏文件会在**每一轮**扫描里重复报同一条错 —— 用这个特征可以快速锁定它。

`audioInfoResp` 里的 `fail <code>` 常见值：

| 消息 | 含义 |
|---|---|
| `broken media file` | **文件本身坏了**（截断 / 容器头缺失 / 非音频数据） |
| `body not in json format` | 媒体服务器瞬时异常，通常重试即好 |
| `context deadline exceeded` | 媒体服务器超时，瞬时，非文件问题 |

---

## 2. 翻日志

```bash
# 日志目录（root 私有，需 sudo；sudo 密码 == SSH 登录密码）
/usr/local/apps/@appdata/trim.music/log/
├── error.log        # 追加；失败与降级警告都在这里
├── info.log         # 当前滚动中的主日志（100MB 滚动一次）
└── info-<ISO时间>.log  # 历史滚动段
```

⚠️ **heredoc 会吃掉 sudo 密码的 stdin** —— 必须两步走（先写脚本文件，再喂密码执行）：

```bash
# ✓ 对
echo 'PW' | sudo -S -p '' tail -n 60 /usr/local/apps/@appdata/trim.music/log/error.log

# 有复杂脚本时：本地/heredoc 写文件 → sudo 执行
cat > /tmp/x.sh <<'EOF'
...
EOF
echo 'PW' | sudo -S -p '' bash /tmp/x.sh
```

快速定位坏文件（这类错误在整个日志里通常只有个位数）：

```bash
echo 'PW' | sudo -S -p '' bash -c '
  grep "broken media file" /usr/local/apps/@appdata/trim.music/log/error.log \
    | grep -o "audioPath=[^,]*" | sort -u'
```

看某文件被报了**几轮**（多轮 = 反复失败，就是失败计数来源）：

```bash
grep -F "<文件名>" .../error.log | grep -o '^time="[^"]*"' | uniq -c
```

---

## 3. 全库体检（确认到底有几个坏文件）

**必须用 Python**，不要用 shell 循环 / `xargs` 喂路径给 ffprobe。

> ⚠️ **实测坑**：`xargs -I{} bash -c 'ffprobe "{}"'` 在路径含 **双引号**、**`$`**、**连续空格**时会被
> shell 二次解析 → 路径错乱 → **假阳性**。
> 实测：`TRA$H.mp3` 被变量展开成 `TRA.mp3`；`(From the Nickelodeon Show "Spongebob")` 丢了引号；
> 一次体检因此虚报 6 个「坏文件」，实际全是好的。
> 正确做法：`subprocess.run([...])` 列表传参，shell 无关。

```python
# /tmp/chk_audio.py —— 8 线程，13040 个文件约 8 分钟
import os, subprocess, json
from concurrent.futures import ThreadPoolExecutor

ROOT = '/vol2/1000/电影音乐/Music'
EXTS = {'.mp3', '.flac', '.m4a', '.wav', '.ape', '.ogg', '.wv'}

files = [os.path.join(dp, n)
         for dp, dn, fn in os.walk(ROOT)
         for n in fn if os.path.splitext(n)[1].lower() in EXTS]

def probe(p):
    try:
        r = subprocess.run(['ffprobe', '-v', 'error',
                            '-show_entries', 'format=duration,format_name',
                            '-of', 'default=nw=1', p],
                           capture_output=True, timeout=60)
        if r.returncode != 0:
            return (p, r.stderr.decode('utf-8', 'replace').strip()[:300])
    except Exception as e:
        return (p, 'EXC: %s' % e)
    return None

bad = []
with ThreadPoolExecutor(max_workers=8) as ex:
    for res in ex.map(probe, files):
        if res:
            bad.append(res)

json.dump({'total': len(files),
           'bad': [{'path': p, 'err': e} for p, e in bad]},
          open('/tmp/bad_audio2.json', 'w', encoding='utf-8'),
          ensure_ascii=False, indent=2)
print('TOTAL', len(files), 'BAD', len(bad))
for p, e in bad:
    print(p); print('      ', e.replace('\n', ' | ')[:150])
```

启动（后台，避免 MCP 超时）：

```bash
chmod 644 /tmp/chk_audio.py
echo 'PW' | sudo -S -p '' nohup python3 /tmp/chk_audio.py > /tmp/chk_audio.out 2>&1 &
# 之后 cat /tmp/chk_audio.out
```

---

## 4. 坏文件的典型形态（迅雷未下完）

```
$ ls -la "<文件>"
-rw-rw-rw- 1 xunlei-app xunlei-app 1741255 Sep 30 21:37 01 恋之风景.mp3   # 属主 xunlei-app、666、体积偏小

$ ffprobe -v error -show_format "<文件>"
[mov,mp4,m4a,3gp,3g2,mj2] moov atom not found
<文件>: Invalid data found when processing input

$ od -A d -t x1z -N 32 "<文件>"
0000000 49 44 33 04 00 00 00 00 10 27 54 49 54 32 00 00  >ID3......'TIT2..<   # ID3v2.4 头
```

特征组合：

- 扩展名是 `.mp3`，但 `file` 判定为 `Audio file with ID3 version 2.4.0, contains: - ISO Media, MP4 v2`
  → 实际是 **m4a 容器**，被 ID3 头 + 改后缀套了层皮
- **moov atom not found** → 索引丢失，无法解码
- 尾部大片 `0x00` 零填充 → 写入中断
- 属主 `xunlei-app:*`、权限 666 → **迅雷直接下载落进库目录**，绕过了 beets 导入流程
  （beets 导入的库内文件属主是 `garson:Users`、权限 700）

---

## 5. 处置

```bash
# ① 不要直接删：先 mv 出库（母版/取证都留着）
mkdir -p /vol2/1000/电影音乐/_media_archive/broken_audio/林嘉欣/
echo 'PW' | sudo -S -p '' mv "<坏文件>" /vol2/1000/电影音乐/_media_archive/broken_audio/林嘉欣/

# ② App 里对该共享库点「重新扫描」→ 失败计数归 0
# ③ 该曲目另行从完好来源重新获取（重新下载 / 走 beets 导入）
```

若用户明确要求**直接删除**（不归档），执行 `echo 'PW' | sudo -S -p '' rm -f "<文件>"`，
删完用 `test -e "<文件>"` + `ls -la "<目录>"` 双向确认。**删除、覆盖、移库前一律先确认**（红线）。

> 提示：该文件若从未成功入库，App 侧不会有残留条目，删完等 App 下一轮扫描「失败项」即归 0；
> 若曾被登记过，则需在 App 里对该共享库手动触发重新扫描。

---

## 6. 相关但不同的错误（别当失败项处理）

| 日志 | 性质 | 处理 |
|---|---|---|
| `extract embedded picture from metadata failed ... invalid picture type: 4294967295` | 内嵌封面格式不规范，**已自动降级**到外部提取器 | 无害，数量多也不必管 |
| `extract embedded picture via metaflac failed ... executable file not found in $PATH` | 系统没装 `metaflac`，走 fallback | 无害 |
| `resize saved cover failed, keep original` | 封面图损坏，保留原图 | 无害 |
| `enqueue metadata correction failed ... append metadata correction task item failed` | **元数据修正任务入队失败**，与扫描失败计数无关 | 单独排查（疑似同路径任务重复入队 / 特殊字符路径） |
| `audio file is already scraped` | 已入库，正常 skip（error 级但非故障） | 忽略 |

---

## 7. 顺带体检项

```bash
# 有多少文件是迅雷直下进库的（绕过 beets，权限/标签都不规范）
echo 'PW' | sudo -S -p '' bash -c \
  'find /vol2/1000/电影音乐/Music -type f -user xunlei-app 2>/dev/null | wc -l'
```

量级较大时（实测 609 个）值得单独做一轮「权限归一 + 标签复核」，但**不要顺手改**，先出报告再确认。
