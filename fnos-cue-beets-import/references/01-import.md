# 导入全流程（CUE 分割 · 分轨入库 · 散曲 · 整轨补全）

> 涵盖：环境自检 → 扫描分类 → 试跑 → 批处理 → 汇报 → 清理（Phase 0~5）；
> 分轨专辑入库（Phase 6）、现场整轨声学拆轨（Phase 7）、
> 扁平散曲批次（Phase 10）、无曲目表整轨五路补全（Phase 12）。
> 动手前先看 SKILL.md 里的「绝对不要做」红线清单。

## 标准流程

### Phase 0 — 环境自检

```bash
command -v beet; ~/ffcuesplitter_env/bin/ffcuesplitter --version
~/ffcuesplitter_env/bin/ffcuesplitter -h 2>&1 | grep -c -- '-ce'
locale | head -1
python3 -c "import sqlite3;print('albums:',sqlite3.connect('/vol2/1000/电影音乐/beets.db').execute('select count(*) from albums').fetchone()[0])"
```

### Phase 1 — 扫描分类

```bash
cat > /tmp/_scan.py <<'PYEOF'
import os, re, sys
ROOT = sys.argv[1]
FILE_RE = re.compile(r'''^\s*FILE\s+(?:"([^"]*)"|(\S+))''', re.M)
CANDS = ["utf-8-sig", "utf-8", "gb18030", "gbk", "big5", "utf-16"]
AUDIO = ('.flac','.ape','.wav','.wv','.tak','.tta','.mp3','.m4a','.dsf','.dff')
ok = fix = missing = 0
for dp, dns, fns in os.walk(ROOT):
    if any(p in ('_split','_cue_archive','.cue_tool') or p.endswith('_split.tmp')
           for p in dp.split(os.sep)):
        continue
    for fn in fns:
        if not fn.lower().endswith('.cue'): continue
        c = os.path.join(dp, fn); raw = open(c, 'rb').read(); direct = False
        for enc in CANDS:
            try: t = raw.decode(enc)
            except (UnicodeDecodeError, LookupError): continue
            refs = [m.group(1) or m.group(2) for m in FILE_RE.finditer(t)]
            if refs and all(os.path.exists(os.path.join(dp, r)) for r in refs):
                direct = True; break
        if direct: ok += 1; continue
        aud = [e for e in (os.listdir(dp) if os.path.isdir(dp) else [])
               if e.lower().endswith(AUDIO) and not os.path.islink(os.path.join(dp, e))]
        if len(aud) == 1: fix += 1
        else: missing += 1
print(f"直接可处理 {ok} | 需链接修正 {fix} | 源确实缺失 {missing}")
PYEOF
python3 /tmp/_scan.py "/vol2/1000/电影音乐/音乐"
```

**汇报时必须说明「源确实缺失」那批是资料不全（合集缺文件 / 只有残缺分轨），不是编码问题。**

### Phase 2 — 试跑 1 张（产物放 /tmp，零副作用）

```bash
TMP=/tmp/_cue_try; rm -rf "$TMP"; mkdir -p "$TMP"
time ~/ffcuesplitter_env/bin/ffcuesplitter -ce gb18030 -i "/path/to/xxx.cue" -f flac -o "$TMP"
ls -la "$TMP"      # 确认产物名形如 01 - 曲名.flac 且中文无乱码
rm -rf "$TMP"
```

### Phase 3 — 后台批处理

**必须后台**：实测 24MB→1.4s、362MB→20s；165.9GB 规模预计数小时，远超 SSH 命令超时。

**执行粒度是「逐张交替」，不是「全部切完再统一入库」**：脚本对每个 cue
`分割 → 立刻 beet import → 下一个 cue`。实测单张循环：

| 阶段 | 实测耗时 |
|---|---|
| 分割（ffcuesplitter） | 31~38 秒 |
| 入库（beet import） | 49~93 秒 ← MusicBrainz 限速是瓶颈，占约 2/3 |
| **合计** | **约 90 秒/张** → 551 张约 15 小时 |

好处是库渐进增长、中途崩溃也有部分成果；代价是最后一张的分割要等全部入库完成。
若确实需要「分割产物先全齐」，得改成两阶段（先全切、再统一 import），
但**必须停下正在跑的任务换脚本**——不能直接编辑 `/tmp/cue_job.sh`（bash 按字节偏移续读，会跑飞）。

下发脚本 → 启动 → 轮询（启动与轮询各 1 次调用）：

```bash
cat > /tmp/cue_job.sh <<'JOBSH'
#!/bin/bash
# 用法: bash /tmp/cue_job.sh <目标目录绝对路径>
set -uo pipefail
export PYTHONUTF8=1        # locale 非 UTF-8 时防 os.path.exists(中文名) 抛错

ROOT="${1:?需要目标目录}"; ROOT="${ROOT%/}"
WORK="$ROOT/.cue_tool"; mkdir -p "$WORK"
CLI="$HOME/ffcuesplitter_env/bin/ffcuesplitter"
BEET=/usr/bin/beet
DB=/vol2/1000/电影音乐/beets.db

LOG="$WORK/run.log"
DONE="$WORK/done.txt"; PEND="$WORK/pending_match.txt"
MISS="$WORK/missing_source.txt"; FAIL="$WORK/split_failed.txt"
PROG="$WORK/progress.lst"; EXCL="$WORK/exclude.txt"; SKIPL="$WORK/skipped_excluded.txt"

touch "$LOG" "$DONE" "$PEND" "$MISS" "$FAIL" "$PROG" "$SKIPL"
[ -f "$EXCL" ] || : > "$EXCL"
echo $$ > /tmp/cue_job.pid          # 存 PID，以后停止用 kill $(cat ...)，别用 pkill -f（会自杀）

log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }
maxid(){ python3 -c "import sqlite3;print(sqlite3.connect('$DB').execute('select coalesce(max(id),0) from albums').fetchone()[0])"; }
is_done(){ grep -Fxq "$1" "$DONE" 2>/dev/null; }
is_excluded(){ grep -Fxq "$1" "$EXCL" 2>/dev/null; }

# 输出 "编码<TAB>需要建链接的名字"（后者空则无需链接）
probe(){ python3 - "$1" <<'PY'
import os, re, sys
cue = sys.argv[1]; d = os.path.dirname(cue)
raw = open(cue, 'rb').read()
R = re.compile(r'''^\s*FILE\s+(?:"([^"]*)"|(\S+))''', re.M)
CANDS = ["utf-8-sig","utf-8","gb18030","gbk","big5","utf-16"]
AUDIO = ('.flac','.ape','.wav','.wv','.tak','.tta','.mp3','.m4a','.dsf','.dff')

avail = {}
for enc in CANDS:
    try: t = raw.decode(enc)
    except (UnicodeDecodeError, LookupError): continue
    refs = [m.group(1) or m.group(2) for m in R.finditer(t)]
    if refs: avail[enc] = refs

for enc, refs in avail.items():                      # 优先：直接全部命中
    if all(os.path.exists(os.path.join(d, r)) for r in refs):
        print(enc + "\t"); sys.exit(0)

try: entries = os.listdir(d)
except OSError: sys.exit(0)
aud = [e for e in entries
       if e.lower().endswith(AUDIO)
       and os.path.isfile(os.path.join(d, e))
       and not os.path.islink(os.path.join(d, e))]
for enc, refs in avail.items():                      # 次选：单引用+单音频 → 链接修正
    if len(refs) == 1 and len(aud) == 1 and refs[0] != aud[0] and '/' not in refs[0]:
        print(enc + "\t" + refs[0]); sys.exit(0)
PY
}

checkmb(){ python3 - "$1" <<'PY'
import sqlite3, sys
c = sqlite3.connect('/vol2/1000/电影音乐/beets.db')
rows = c.execute("select id, coalesce(mb_albumid,'') from albums where id > ?", (int(sys.argv[1]),)).fetchall()
if not rows: print('NONE')
elif all(m for _, m in rows): print('OK')
else: print('NOMB ' + ' '.join(str(i) for i, m in rows if not m))
PY
}

log "===== JOB START: $ROOT ====="
find "$ROOT" -type f -iname '*.cue' -print0 | sort -z | while IFS= read -r -d '' cue; do
  case "$cue" in */_split/*|*/_split.tmp/*|*/_shnsplit/*|*/_cue_archive/*|*/.cue_tool/*) continue ;; esac
  d="$(dirname "$cue")"; out="$d/_split"; tmp="$d/_split.tmp"; linkname=""
  echo "$cue" >> "$PROG"

  if is_excluded "$d"; then log "excluded $d"; echo "$cue" >> "$SKIPL"; continue; fi

  if [ -d "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
    is_done "$out" && { log "skip-done $out"; continue; }
  else
    pout="$(probe "$cue")"
    enc="${pout%%$'\t'*}"
    linkname="${pout#*$'\t'}"
    [ "$linkname" = "$pout" ] && linkname=""
    if [ -z "$enc" ]; then log "SRC-MISSING $cue"; echo "$cue" >> "$MISS"; continue; fi

    if [ -n "$linkname" ]; then
      actual=""
      for f in "$d"/*; do
        [ -f "$f" ] || continue
        [ -L "$f" ] && continue
        b="$(basename "$f")"
        case "${b,,}" in
          *.flac|*.ape|*.wav|*.wv|*.tak|*.tta|*.mp3|*.m4a|*.dsf|*.dff) actual="$b" ;;
        esac
      done
      if [ -n "$actual" ] && [ ! -e "$d/$linkname" ]; then
        ln -sf "$actual" "$d/$linkname" 2>/dev/null && log "link-fix [$linkname] -> [$actual]"
      else
        linkname=""
      fi
    fi

    rm -rf "$tmp"; mkdir -p "$tmp"
    if ! "$CLI" -ce "$enc" -i "$cue" -f flac -o "$tmp" >>"$LOG" 2>&1; then
      [ -n "$linkname" ] && rm -f "$d/$linkname"
      rm -rf "$tmp"; log "SPLIT-FAIL $cue"; echo "$cue" >> "$FAIL"; continue
    fi
    [ -n "$linkname" ] && rm -f "$d/$linkname"      # 用完立刻删链接
    rm -f "$tmp"/*.ffcuesplitter.log
    if ! find "$tmp" -maxdepth 1 -iname '*.flac' | grep -q .; then
      rm -rf "$tmp"; log "SPLIT-EMPTY $cue"; echo "$cue" >> "$FAIL"; continue
    fi
    rmdir "$out" 2>/dev/null                         # 防 mv 变嵌套
    mv "$tmp" "$out"
    log "split-ok[$enc] $out"
  fi

  b="$(maxid)"
  "$BEET" import -q "$out" >>"$LOG" 2>&1             # 注意：不加 -A！
  v="$(checkmb "$b")"
  case "$v" in
    OK) log "import-ok $out"; echo "$out" >> "$DONE" ;;
    NONE) log "import-none(未匹配) $out"; echo "$out" >> "$PEND" ;;
    NOMB*)
      for i in ${v#NOMB }; do "$BEET" remove -a -f "id:$i" >>"$LOG" 2>&1; done
      log "import-pending(已撤销) $out"; echo "$out" >> "$PEND" ;;
  esac
done
log "===== JOB END: $ROOT ====="
JOBSH
chmod +x /tmp/cue_job.sh
bash -n /tmp/cue_job.sh && echo "语法 OK"
setsid nohup bash /tmp/cue_job.sh "/vol2/1000/电影音乐/音乐" > /tmp/cue_job.out 2>&1 < /dev/null &
sleep 5; echo "PID: $(cat /tmp/cue_job.pid)"
```

轮询：

```bash
W="/vol2/1000/电影音乐/音乐/.cue_tool"
printf "已扫描 %s | 成功 %s | 待匹配 %s | 源缺失 %s | 分割失败 %s\n" \
  "$(wc -l < $W/progress.lst)" "$(wc -l < $W/done.txt)" "$(wc -l < $W/pending_match.txt)" \
  "$(wc -l < $W/missing_source.txt)" "$(wc -l < $W/split_failed.txt)"
PID=$(cat /tmp/cue_job.pid 2>/dev/null); kill -0 "$PID" 2>/dev/null && echo "运行中" || echo "已结束"
grep -aE 'split-ok|import-ok|import-pending|import-none|SRC-MISSING|link-fix|excluded' "$W/run.log" | tail -15
```

**停止任务（正确姿势，实测踩过）**：

```bash
PID=$(cat /tmp/cue_job.pid)
CH=$(pgrep -P "$PID")                 # 只能拿到直接子进程！
kill "$PID" 2>/dev/null; for c in $CH; do kill "$c" 2>/dev/null; done
```

三个坑：

1. **`pgrep -P` 拿不到孙进程**。循环体跑在 `find | while` 的 subshell 里，
   ffcuesplitter / ffmpeg 是**孙进程**，`kill` 主进程后它们会变孤儿继续跑完。
   停完必须复查：`ps -eo pid,ppid,comm --no-headers | awk '$3=="ffmpeg"'`，
   拿到 PID 再 `kill -9`。
2. **绝不要 `pkill -f 'ffcuesplitter'`** —— `-f` 匹配整条命令行，会把**执行这条命令的
   SSH shell 自己**匹配上并杀掉（表现为 `SIGTERM` 直接中断返回）。
   同理 `pkill -f cue_job.sh` 会自杀。只能按 PID 精确 kill。
3. 停完清掉半成品：`find "$ROOT" -type d -name '*_split.tmp' -exec rm -rf {} +`。
   库不会被写脏（beets 基于 sqlite，中断的 import 不留残record），复查
   `beet ls -a | wc -l` 与停前一致即可确认。

### Phase 3b — 逐张模式（用户要求「一个一个处理」时）

把主循环抽成单张脚本，落盘在 `.cue_tool/cue_one.sh`，用法：

```bash
bash "$ROOT/.cue_tool/cue_one.sh" "$ROOT/张学友/专辑/1985-Smile[Korea]"
```

与批处理共用同一套状态文件（`done.txt` / `pending_match.txt` / …），
所以逐张跑完再跑批处理仍然幂等。输出精简（每张 5~7 行）：

```
▶ 张学友/专辑/1985-Smile[Korea]
▶ cue: CDImage.cue
· 编码=gb18030
· 分割完成: 11 首
✓ 入库成功
▶ 库内专辑数: 5
```

判定分支比批处理细：`NONE` 再拆成 `import-dup(已在库中)` 与 `import-none(未匹配)` ——
判据是「本次 import 新增的日志里有没有 `Similarity:`」（用 import 前后的 `wc -l` 行号差
裁出本次输出，别去 tail 整个日志，会串到上一张）。

**实测节奏（张学友/专辑，22:51~22:58）**：单张 **93~175 秒**，
波动来自 MB 限速。逐张与批处理**都是串行**，差别只在可见性 —— 若用户以为
批处理是「多线程」，直接说明：脚本本身就是一个 `while` 循环，从头到尾一张一张来。

**源处置（转换成功后归档，不可逆，改动前必须确认）**

`cue_one.sh` 内置处置逻辑，输出样例：

```
▶ 张学友/专辑/1987-JACKY[Korea]
▶ cue: CDImage.cue
· 编码=gb18030
· 分割完成: 10 首
✓ 入库成功
· 源已归档: 已转换专辑/张学友/专辑/1987-JACKY[Korea]
▶ 库内专辑数: 8
```

**先问清三件事**（2026-09-28 老张确认的口径，不同用户差异极大）：

| 项 | 口径 |
|---|---|
| 删除范围 | **整个专辑目录**（cue / 整轨 / 图 / `_split`） |
| 方式 | `_split` **真删**；其余原文件 **`mv`** 到 `/vol2/1000/电影音乐/已转换专辑/<相对路径>` |
| 跳过条件 | 多整轨目录（读 `rework_multi_cue.txt`）**整批跳过** |

> 回收目录放在 `音乐/` **外面**（同级），否则会被 `find` 重新扫到。

**「版本不同」的归档标记**（用户追加要求：在转换文件夹里一眼看出哪些是版本冲突的）：

- 归到 `已转换专辑/_版本不同/<原相对路径>/`，与正常归档分开
- 目录内落 `_DUP_VERSION.txt`：归档原因、源目录、时间、**beet 匹配详情原文**
  （beets 自己会写 `This album is already in the library!` —— 最有力的凭据，别删）
- `已转换专辑/_版本不同/_清单.txt` 逐行汇总：`<相对路径> | (Similarity: xx%) (版本描述)`
- 存量补处理：`python3 .cue_tool/cue_archive_dup.py [--apply]`
  —— 解析 `run.log` 判定 B 类，**默认干跑**；执行后自动把这些条目从 `pending_match.txt` 移除

判定 B 类的可靠依据是 **beet 输出含 `Similarity:`**（坑 #11），不要靠手写规则：
`import-none(未匹配)` 与 `import-dup(已在库中)` 两个标签都可能对应 B 类。

**三道闸门（缺一不可）**：

1. 只有 `import-ok` 触发；`import-dup` / `import-none` / `SRC-MISSING` / `SPLIT-FAIL` 源一律不动
2. 多整轨目录 → 整批跳过（CD2+ 未处理，母版丢了补不回来）
3. **库内轨数 == `_split` 轨数** → 否则不删源并报警
   （`select count(*) from items where album_id > <import 前 maxid>` 比对 flac 文件数，
   防「库只写了一半」就把源删了）

**干跑开关**：`KEEP_SOURCE=1 bash cue_one.sh "<目录>"` 走完全流程但不删不移。
**第一次改处置策略后必先干跑，再真跑。**

### Phase 3c — 串行批驱动（剩余量大时的推进方式）

用户要求「一个一个处理」但剩余 **400+ 张**时，靠人肉逐次下发 SSH 不现实。
做法：**保留逐张脚本，外加一个串行驱动**，本质仍是 `while` 循环一次一张，
只是把「谁来喊下一张」交给脚本，日志可随时查。

**先落队列**（`.cue_tool/todo_queue.txt`）：所有含「非 flactracks 的 `.cue`」的目录，
减去 `done.txt` / `pending_match.txt` / `missing_source.txt` / `split_failed.txt`
已覆盖的目录，按路径排序。

```bash
export PYTHONUTF8=1
python3 - <<'PY'
import os, collections
ROOT='/vol2/1000/电影音乐/音乐'; W=os.path.join(ROOT,'.cue_tool')
handled=set()
for fn in ['done.txt','pending_match.txt','missing_source.txt','split_failed.txt']:
    p=os.path.join(W,fn)
    if not os.path.isfile(p): continue
    for l in open(p,encoding='utf-8',errors='replace'):
        l=l.strip()
        if l: handled.add(os.path.normpath(os.path.dirname(l)))
cands=[]
for dp,dns,fns in os.walk(ROOT):
    parts=dp.split(os.sep)
    if any(p in ('_split','_cue_archive','.cue_tool') or p.endswith('_split.tmp') for p in parts): continue
    if [f for f in fns if f.lower().endswith('.cue') and 'flactracks' not in f.lower()]:
        cands.append(os.path.normpath(dp))
todo=[d for d in sorted(cands) if d not in handled]
open(os.path.join(W,'todo_queue.txt'),'w',encoding='utf-8').write('\n'.join(todo)+'\n')
print('待处理:', len(todo), '| 已处理:', len(cands)-len(todo))
PY
```

> `done.txt` / `pending_match.txt` 存的是 `_split` 路径，`missing_source.txt` /
> `split_failed.txt` 存的是 `.cue` 路径 —— 一律 `dirname` 取专辑目录，别按字符串前缀比。

**驱动脚本** `.cue_tool/cue_runall.sh` 要点：

- 逐行读队列，每张前查 `done.txt` / `pending_match.txt`（幂等），并查
  `batch_skip.txt`（`missing` / `fail` 对应目录，省得白重跑）
- 只调用 `bash cue_one.sh "$d"`，**不内联任何处理逻辑**
- `echo $$ > /tmp/cue_runall.pid`，日志 `batch.log`，每张记 `START` / `END rc=$?`
- `cue_one.sh` 的退出码语义：`0` 已处理（含「版本不同」归档）、
  `2` 源缺失、`3` 分割失败 —— 驱动据 `$?` 分类计数，**不中断**继续下一张

**启动方式（必须脱离 SSH 会话）**：

```bash
setsid nohup bash "$W/cue_runall.sh" </dev/null >/dev/null 2>&1 &
```

**暂停方式**：`kill $(cat /tmp/cue_runall.pid)` —— 当前张跑完才停（不会切到一半断），
恢复直接重跑驱动脚本，已完成的自动跳过。

**进度查看**（别 tail 整个 batch.log，会长）：

```bash
W='/vol2/1000/电影音乐/音乐/.cue_tool'
printf 'done=%s pending=%s missing=%s fail=%s | 库内=%s\n' \
  "$(wc -l < $W/done.txt)" "$(wc -l < $W/pending_match.txt)" \
  "$(wc -l < $W/missing_source.txt)" "$(wc -l < $W/split_failed.txt)" \
  "$(/usr/bin/beet ls -a | wc -l)"
grep -aE 'START|END rc=[23]|BATCH' "$W/batch.log" | tail -12
```

**实测节奏**：单张 **60~175 秒**（MB 限速波动）。448 张约 **10~15 小时**。

> 报进度时区分「已跑张数」与「入库成功数」：`done.txt` 增量才是入库，
> `END rc=0` 里有相当比例是「版本不同」归档（未真正新增专辑）。

### Phase 3d — 切割性能：`cue_split.py`（**单张提速 3 倍的关键**）

**根因**：`ffcuesplitter` 把 `-ss` 放在 `-i` **之后**（输出侧 seek），
切每首曲子都要从整轨开头解码到该曲起点 —— n 轨的总解码量 ≈ **n²/2 倍全片时长**。
一眼可辨的征兆：切 10 轨的耗时远大于「ffmpeg 全片解码一次」的耗时。

实测（同一素材 `1987-JACKY[Korea]`，217MB ape，10 轨）：

| 方案 | 耗时 |
|---|---|
| `ffcuesplitter -ce gb18030 -i cue -f flac` | **79.9 s** |
| `cue_split.py`（输入侧 `-ss` + 4 路并行） | **7.3 s** |

**10.9 倍**。切完单张总耗时从 ~105 s 降到 **~22~32 s**，
新瓶颈变成 `beet import` 的 ~25 s（MB 查询 + 复制入库）。

脚本落在 `.cue_tool/cue_split.py`：

```bash
python3 "$WORK/cue_split.py" "<cue>" "<输出目录>" [并行度=4]
# 退出码 0 成功 / 2 源缺失 / 3 失败（调用方回退 ffcuesplitter）
```

要点：

- **输入侧 seek**：`ffmpeg -ss $start -i "$audio" -t $dur -c:a flac`，flac/ape 都能精确 seek
- **并行**：`ThreadPoolExecutor(max_workers=核数)`；4 核实测 7.3 s
- **切点取 `INDEX 01`**，`INDEX 00`（pregap）归上一轨尾 —— 与 ffcuesplitter **逐轨等长**
  （用含 `INDEX 00` 的 cue 核验：209.63 / 214.60 / 211.16 / 202.68 … 完全一致）
- **主动放弃**（返回 3，交回 ffcuesplitter）：多 `FILE` 段的 cue、
  cue 起点溢界（`INDEX 01 > 音频时长`，说明 cue 与音频不匹配）、解析不出轨
- **文件名与旧产物同格式** `%02d - %s.flac`（`\/:*?"<>|` 及控制字符换 `_`）
- **标签对齐**（决定 beets 匹配行为，不能少）：`ALBUM`=cue 的 TITLE、
  `ARTIST`=轨 PERFORMER（缺则 album PERFORMER）、`TITLE`=轨 TITLE、
  `track=n/N`、`date`=cue 的 `REM DATE`（有才写）；**不写 `albumartist`**，与旧产物一致

**替换后必做的两步等价验证**（缺一不可）：

1. 逐轨 `ffprobe` 时长与 ffcuesplitter 旧产物**逐条比对**（必须秒级一致）
2. 临时库跑 `beet import -q`，确认匹配到**同一个 `mb_albumid`**
   （实测 JACKY 两条路径都落在 `4b48d322-d10f-4c42-a76f-67b7cf81a496`，Similarity 100%）

**cue 格式事实（482 个待处理 cue 实测）**：编码 `gb18030` 占 **96%**（另 22 个 `utf-8-sig`）；
含 `INDEX 00` 的占 **59%**；多 `FILE` 的仅 3 个 —— 所以 `INDEX 01` 是主线，多 FILE 交给回退。

**接入方式**（`cue_one.sh` 里）：快路径失败即回退，保证能力不缩水。

```bash
split_ok=0
if python3 "$WORK/cue_split.py" "$cue" "$tmp" "$SPLIT_PAR" >>"$LOG" 2>&1; then
  split_ok=1; log "split-fast[$enc] $out"
else
  log "split-fast-fallback $cue"
  rm -rf "$tmp"; mkdir -p "$tmp"
  if "$CLI" -ce "$enc" -i "$cue" -f flac -o "$tmp" >>"$LOG" 2>&1; then split_ok=1; fi
fi
```

---

### Phase 4 — 汇报

给：直接可处理 / 需链接修正 / 源确实缺失 三个数量；成功导入数、待人工数；清单路径；空间占用。

**「有没有产出」只有两个硬指标，别看错：**

| 指标 | 命令 | 含义 |
|---|---|---|
| 库内专辑数 | `beet ls -a \| wc -l` | **唯一**能说明「真的入库了」的指标 |
| 磁盘实物 | `find . -type d -name '_split'` + 数 flac | 只说明「分割在跑」 |

`_split` 有文件 ≠ 入库成功。未匹配的专辑会一直堆在磁盘上而不进库，
所以早期 `done.txt` 为 0 是完全正常的，但同时「库内专辑数没涨」也是真的没产出。

**排序陷阱（极易被误判成故障）**：`sort -z` 按全路径排序，数字 / Latin 开头的
中文合集（`24K金碟…`、`Michael Jackson…`）会排在专辑目录（`张学友/`）前面。
源目录构成偏合集时，前几十个 cue 可能全部零产出。**跑之前先看顺序**：

```bash
ROOT=/vol2/1000/电影音乐/音乐
find "$ROOT" -type f -iname '*.cue' -print0 | sort -z | tr '\0' '\n' \
  | sed "s|^$ROOT/||" | awk -F/ '{print $1}' | uniq -c
```

拿到顺序后，对前几批各做 1 次 MB `count` 查询，就能**提前**告诉用户
「第几个 cue 开始才有产出」——比事后解释为什么没产出有效得多。

**成功路径要先验证**（尤其第一次跑某个源目录）：拿一张确定的真实专辑，
在**临时库**上跑完整链路，绝不在正式库上试：

```bash
export PYTHONUTF8=1
rm -rf /tmp/_proof; mkdir -p /tmp/_proof/split
ffcuesplitter -ce gb18030 -i "<album>/xxx.cue" -f flac -o /tmp/_proof/split
rm -f /tmp/_proof/split/*.ffcuesplitter.log
cat > /tmp/_proof/config.yaml <<'YAML'
directory: /tmp/_proof/Music
library: /tmp/_proof/beets.db
import:
    copy: yes
paths:
    default: $albumartist/$year $album/$track $title
YAML
beet -c /tmp/_proof/config.yaml import -q /tmp/_proof/split
beet -c /tmp/_proof/config.yaml ls -a -f '$id | $albumartist | $album | $year | [$mb_albumid]'
rm -rf /tmp/_proof          # 记得清，/tmp 可能是内存盘
```

见到 `Similarity: 9x%` + `mb_albumid` 非空，才叫「流水线可用」。
实测此法在《意亂情迷》上得 99.1%，10 首正确切分并按 paths 落盘。

**⚠️ 年份/版本会被 MB 首选 release 改写（务必向用户说明）**：beets 落盘用
**MB 首选 release** 的年份与版本名，不是源目录标注的。实测连续三张：

| 源目录 | 入库结果 |
|---|---|
| `1985-Smile[Korea]` | `張學友 / Smile / 2014` |
| `1986-情无四归[PolyGram]` | `張學友 / 情無四歸 / 1996` |
| `1986-相爱[Korea]` | `張學友 / 相愛 / 2023` |

年份全被改成 MB 再版年份。若用户在意原始年份（发烧碟常见诉求），
落盘目录名会「看起来不对」，但这**不是 bug**，是匹配到哪个 release 就用哪个的元数据。
要保留原年份只能人工指定 release（`--search-id`）或事后 `beet modify`。

手工补救：

```bash
beet import -A "<dir>/_split"                       # 交互式选候选
beet import -A --search-id <MusicBrainz_ID> "..."    # 指定 ID 强制匹配
beet import -A -u "..."                              # 放弃匹配，按现有标签入库
beet import -A "CD1/_split" "CD2/_split"             # 多 CD 合并
```

（注意：手工补救时 `-A` 才用得上，含义仍是「不再自动推断」，此时靠交互选择。）

### Phase 5 — 清理 `_split`（可选，**仅在任务全部跑完后**）

> 若用的是 `cue_one.sh`（逐张 + 内建处置），清理已随入库自动完成，
> 本 Phase 只需处理**批处理模式遗留的存量**（老数据 `_split` 仍在原地）。

**只清理 `done.txt` 里的**（真匹配到 MusicBrainz 且 `Music/` 下有副本）。

- ✅ `done.txt` → 可清理
- ❌ `pending_match.txt` → **绝不能碰**！那批还没入库，`_split` 是唯一的分轨产物，
  正等人工匹配（其中 B 类虽已入库别的版本，但内容不同，见坑 #11 的警告）
- ❌ `missing_source.txt` / `split_failed.txt` → 没东西可清
- ❌ `rework_multi_cue.txt` 里的目录 → 多整轨，CD2+ 还没处理

**现成脚本**（已落盘在 `.cue_tool/`，默认 dry-run）：

```bash
python3 "$ROOT/.cue_tool/classify_pending.py"              # 先重分类 pending
bash "$ROOT/.cue_tool/cleanup_split.sh" "$ROOT"            # dry-run，出完整清单
bash "$ROOT/.cue_tool/cleanup_split.sh" "$ROOT" --apply    # 确认后才真移
```

`cleanup_split.sh` 的内建安全约束：只处理 `done.txt` 里的、排除 pending/missing/fail、
排除多整轨目录、路径必须匹配 `$ROOT/*/_split`、**只 `mv` 到 `.cue_recycle/` 绝不 `rm`**、
cue 与整轨母版原地不动。`done.txt` 为空时直接拒绝执行。

**四条硬约束**：

1. **先确认能重新分割**。删 `_split` 的前提是 cue + 整轨母版还在 ——
   所以**只删 `_split`，别删整轨**（整轨是母版，匹配错了就永久没了）。
2. **飞牛没有回收站**（`gio` / `trash-put` 都没有，`rm` 即永久删除）。
   必须**先 `mv` 到回收目录**（同文件系统，瞬时重命名，不占额外空间），
   观察确认无误后再真删：
   ```bash
   mkdir -p "$ROOT/.cue_recycle"
   mv "$d/_split" "$ROOT/.cue_recycle/$(echo "$d" | md5sum | cut -c1-8).$(basename "$d")"
   ```
3. **必须先 dry-run 并打印完整清单**，逐条核对后再 `--apply`。
4. **配套修掉坑 #10**：`_split` 删了以后，幂等键必须是 cue 路径，
   否则下一次运行会把整批重新 `beet import`，库里再长一份。

清理前核对命令（确认 `Music/` 副本数与 `_split` 轨数一致）：

```bash
W="$ROOT/.cue_tool"
sort -u "$W/done.txt" | while read -r s; do
  [ -d "$s" ] || continue
  n=$(find "$s" -maxdepth 1 -iname '*.flac' | wc -l)
  echo "$n 轨  $s"
done
# 再抽样比对：beet ls -a -f '$albumartist / $album' 里是否都有对应专辑
```


---

## 防重复（跑之前必查）

**两层去重机制不一样，别混为一谈**：

| 层级 | 行为 | 说明 |
|---|---|---|
| 候选匹配级（`mb_albumid`） | **会拦** | 匹配到的 release 已在库中 → 跳过（就是坑 #11 的 B 类） |
| 文件级（同一目录重复 import） | **不拦** | 同一张导入两次 → 两条记录 + 两份文件（重名自动存为 `01 曲名.flac`、`01 曲名.1.flac`…） |

所以「库里不会因为重跑而变双份」只在**匹配成功**时成立；一旦匹配到不同的 release，
或幂等键失效（坑 #10），照样会重复入库。

```bash
beet ls -a -f '$albumartist // $album // $year'          # 跑前看库里有什么
beet ls -a -f '$albumartist // $album' | sort | uniq -d  # 跑后查重复
```

有重复必须**先让用户确认**再清：

```bash
beet remove -a -d -f "album:'专辑名'"     # -d 连文件一起删
```

**增量运行安全**：同一目录跑第二次，`_split` 已存在且记入 `done.txt` → 跳过。

## 关于源文件与空间

`copy` 模式下导入后源目录的 `_split` 变冗余（Music 下已有副本）。**默认不删任何源文件。**
要回收空间必须显式确认，且只针对已记入 `done.txt` 的目录。


---

## Phase 6 — 分轨专辑批量入库（目录自带 tag、无 cue）

源库里有一批**有音频、无 cue 的分轨专辑**（实测 285 个目录 / 5878 首）。
`todo_queue` 的入选条件是「目录含非 flactracks 的 `.cue`」，所以这批被整条 cue 流水线
**静默跳过**，得另走一条链。2026-09-29 全量跑完，记录实际参数与踩到的 6 个坑。

### 流水线（脚本都落 `<ROOT>/.cue_tool/`）

| 步骤 | 脚本 | 作用 |
|---|---|---|
| 1 | `flat_probe.py` | 拿「目录名 / 文件 tag」的多组候选查 MB，用「谁命中」反推哪组解析对（285 命中 158 = 55%） |
| 2 | `flat_finalize.py` | 收敛成 `flat_final.tsv`（目录/artist/album/year/来源），无年份的回查 MB release `date` |
| 3 | `flat_retag.py` | 按 `MB 权威值 > 原 tag > 目录名 > 文件名` 重建 tag，原值备份进 `flat_tag_backup.json` |
| 4 | `flat_trackfill.py` | 用 MB 曲目表补 TRCK（三轮匹配：归一化精确 → 前缀包含 → 子串） |
| 5 | `flat_fix_singles.py` | 修散装合集的 MB 误配污染（坑 15）+ APEv2 双键（坑 16） |
| 6 | `flat_import_one.sh` | 逐张导入 + 归档（两道模式闸门） |
| 7 | `flat_runall.sh` | 串行驱动，幂等查 `flat_done.txt` |
| 8 | `flat_fix_tenyears.py` | 事后补救：文件名重建 tag + 打散成单曲（坑 20） |

**实测 57 分钟 / 285 张**（远快于预估 —— 走 `-A` 不查 MB，瓶颈只剩文件复制）。

### 坑 15【最坑】散装合集的 MB 误配会把上千首歌写成同一个假艺人

`华语流行乐坛歌手精选1264首/A-D`、`王菲 无损单曲`、`华语流行单曲（珍藏系列）第N辑`
这类目录，**目录名是分区名/合集名而不是专辑名**。probe 拿它（和目录内文件 tag）去查 MB，
命中的是与内容毫无关系的 release —— 实测 `A-D` → artist=`Molly` / album=`"A D"`，
`R-X` → `David Reilly` / `How Humans R(x)`。
`flat_retag` 的「MB 权威值优先」于是把噪声写进文件：**A-D/F-Q/R-X/Y-Z 四个目录
1258 首的 artist 全变成 Molly/Telana/David Reilly/oDDling**。

**判据（别用「路径含 单曲/精选/合集」—— 那会把 5853/5878 全圈进来）**：
只取「`flat_plan.tsv` 里的目录 **且** 音频数 ≥45」（实测 22 个）。
`《中华儿歌珍藏集6CD合集打包》/分轨_xxx[flac]/` 这类**真专辑**路径同样含「珍藏/合集」，
但「在 plan 里」+「≥45 首」两条一起卡就分开了。

**修法**：`flat_fix_singles.py` 不碰网络，只用两个可信源 ——
`flat_tag_backup.json`（flat_retag 动手**之前**的原始值）+ 文件名。

- 原值 artist 若确实出现在文件名分段里 → 认它（`BEYOND - 两颗心`）
- 否则用「目录歌手名」在分段里匹配，命中的那段是 artist、另一段是 title
  （`一代天骄 - 凤凰传奇.ape` 原值为空，靠目录名「凤凰传奇 无损单曲」定出歌手在后段）
- 多歌手合集（含 华语/流行/乐坛/歌手/歌曲/合集/热歌/榜/车载 等词）推不出唯一歌手 → 保留各曲原值
- 清空 `album`/`tracknumber`（散装单曲没这两个语义，留着会在库里造出几百条 1~10 首的假专辑）
- `TRACK_RE` **只剥纯数字前缀**：曾用 `[A-Za-z]{0,2}\d{1,3}` 把歌手名 `BY2` 整段吃掉，
  title 变成 `我知道`、artist 落到目录名上
- 目录歌手名提取要**跳过分区名**（`A-D`/`F-Q`/`A02`）与容器名（`请打开后选择单文件下载`），
  否则会拿「A-D」当歌手

### 坑 16【beets 读不到的标签】APEv2 的 `Album Artist` 与 `albumartist` 是两个键

`mutagen` 的 easy 接口写 `albumartist`：

- FLAC/Ogg 用 Vorbis comment，**键大小写不敏感** → 覆盖成功
- **APEv2（.ape/.wv/.tak/.tta）大小写敏感** → 落到小写 `albumartist` 上，
  文件里已有的 `Album Artist`（资源站自带，或上一轮 flat_retag 写的）原样留着

beets 走 mediafile，**只认 `Album Artist`**。于是同一个文件里两个键打架：

```
'Album Artist' = '音乐'        ← beets 读这个
'albumartist'  = '凤凰传奇'     ← mutagen easy 读这个
```

实测 86 个凤凰传奇 ape 因此被判成 `albumartist='音乐'`，整批落到 `Music/音乐/` 下。

- **判别**：`mutagen.File(p)` 后遍历 `for k, v in f.items()`（**不要**用 `easy=True`），看是否双键
- **修**：`tags['Album Artist'] = <真值>` 并 `del tags['albumartist']`
- **`APEv2.save()` 必须显式传路径** —— `tags.save(p)`；漏传报
  `Missing filename or fileobj argument`
- 让 beets 跟上：`beet update '<query>'`（重读 tag）→ `beet move '<query>'`（按新值归位）
- 只修「`Album Artist` 是噪声值（音乐/QQ群/论坛/网址）」的冲突；
  纯空格差异（`刘德华 柯受良 吴宗宪` vs `刘德华柯受良吴宗宪`）**别动**，
  否则会引起一批无辜的目录重命名

### 坑 17【plan 父子重叠】父目录导入会递归吃掉子目录，且把它们的 album 名抹平

`flat_plan.tsv` 里若**父目录自身有音频**、同时又列了它的子目录，就会出事：
`beet import <父目录>` 是**递归**的，一把把子专辑也导了，然后 `mv` 整个父目录归档，
后续轮到子目录时 `[ ! -d "$d" ]` → 全部 skip。

实测 `林俊杰无损单曲合集`（自身 23 首散曲 + 22 个子专辑）：22 张专辑的文件其实都入库了，
但 `--set album=<父目录的 album>` 把它们**全塞进同一个 album**（只靠各自 tag 的 year
裂成 23 条记录），真专辑名（《第二天堂》《编号89757》…）全丢。
**数据没丢，元数据退化了** —— 别误判成丢数据。

- **跑之前先查** `flat_plan.tsv` 里有没有 `d.startswith(p + '/')` 的父子对
- **修**：把父目录从 plan 摘掉，或让父目录单独走单曲模式（`-s` 且**只传文件、不传目录**）
- **补救**：源在归档区完整 → 删掉错记录后逐个重导（用各自 `flat_final` 值）

### 坑 18【singleton 不建 album 记录】归档闸门不能用 `albums.max(id)`

临时库实测：`beet import -A -s` 之后 **`albums` 表为空，`items.album_id` 恒为 NULL**。
若归档闸门写成「`select count(*) from items where album_id > <import 前 maxid>`」，
单曲模式会**恒判「新增 0 首」** → 永不归档 + 下次重跑再导一遍。

**水位线改用 items 总行数差**（对专辑/单曲两种模式都成立）：

```bash
item_count(){ python3 -c "import sqlite3;print(sqlite3.connect('$DB').execute('select count(*) from items').fetchone()[0])"; }
before=$(item_count); beet import ... ; new=$(( $(item_count) - before ))
```

实测：专辑模式 17/17、单曲模式 60/60，新增 77 = 17+60 精确对上。

### 坑 19【源本身残缺】分轨文件头被清零（下载未完成）

`超8000首高品质歌曲（84.1G）/五月天专辑/…` 里 12 首 flac 有 5 首前 32K~64K 字节全为 `00`，
`file` 报 `data`，`mutagen` 抛 `FLACNoHeaderError` → beets 跳过 → 归档闸门判 `PARTIAL`。

- **判据**：读前 8 字节，`66 4c 61 43`(`fLaC`) 才是真的；全 `00` 就是没下完
- **看严重程度**：算全文件零字节占比 —— `0.4%` 且头偏移 32K 尚可救（只是元数据头丢），
  `60%` 那种没救
- **处置**：`PARTIAL` 分支保留源不归档（脚本已内建），清单交人工，**不要归档不要删**

### 坑 20【水印串不总在同一字段】三个字段整段相同 → 原值判定会放行

`《十年好歌·男人篇+女人篇》黄金国语珍藏6CD[无损WAV.MP3高品质320K]` 这批 101 首，
资源站把 **`TALB` / `TPE2` / `TIT2` 三个字段整段写成了同一个水印串**
「QQ群号：562125679 公众号：时光匆忙旅行者」；mp3 那套的 `TRCK` 还是**恒定错值 226**。

`flat_retag` 的 NOISE 表里有 `QQ群|公众号`，看起来能拦住 —— 但它的取值优先级是
「MB 权威值 > 原 tag > 目录名 > 文件名」，这批 MB 没命中，回落时 `album` 走了
「目录名」分支（`十年好歌·女人篇`，看着干净），`albumartist` 就把水印留下来了。
结果整批落进 `Music/QQ群号：562125679 公众号：时光匆忙旅行者/`。

**所以：水印串不一定出现在同一个字段，判「这批 tag 不可信」要三个字段一起看。**
快速探针 —— 同一目录下若 `TALB == TPE2 == TIT2`，基本可判为水印批次。

**修法：`flat_fix_tenyears.py`（本轮新增）**
- 唯一可信源 = **文件名**（这里两种形态，先剥曲序再分流）：
  - `01 宁夏（梁静茹）.wav` → `歌名（歌手）`（正则 `^(.+?)\s*[（(]([^（）()]+)[)）]\s*$`）
  - `01 披着羊皮的狼  谭咏麟.wav` → `歌名<2+空格>歌手`（正则 `^(.+?)\s{2,}(\S.*)$`）
  - 先用括号规则、再退双空格规则 —— 顺序反了会把 `Love Love Love（蔡依林）` 的括号当曲名一部分
- 落盘策略经用户确认走 **按歌手打散（singleton）**：`Music/<歌手>/<歌名>.<ext>`，
  清掉 `album`/`tracknumber`/`COMM`（水印还在注释帧里，`del` 掉所有 `COMM*`）
- **`clean()` 不能删空格**：照搬 `flat_fix_singles.clean()` 的「中文之间的空白一律并掉」
  会把合唱曲 `千里之外  周杰伦 费玉清` 粘成 `周杰伦费玉清`。本批只做「连续空白压成一个」

**「已入库的那套」怎么改**（改动前 `beet remove` 摘记录，注意别删文件）：

```bash
cp "$DB" "$DB.bak.<日期>-<主题>"                       # 先备份库
beet remove -a -f 'albumartist:<水印特征>'              # 不加 -d → 只删记录，文件保留
mv "$M/<水印目录>" /vol2/1000/电影音乐/.flat_recycle/   # 移出库（beets 拒绝导入库内文件）
python3 flat_fix_tenyears.py <回收目录> --apply         # 改 tag
beet import -q -I -A -s -m <回收目录>                   # -m 移动式，省一次全量拷贝
```

配对的 320K mp3 那套若源还在、从未入库：同样改 tag → `beet import -q -I -A -s`（**不带 `-m`**，
保留源）→ 源目录 `mv` 进 `已转换专辑/`。若归档区已有同名目录，**逐子目录并入**
（`for d in "$SRC"/*/; do mv "${d%/}" "$A/"; done; rmdir "$SRC"`），别整目录 `mv` 造成覆盖。

**收尾核对**：本批零 `.1` 重名（`find "$M" -name '*.1.*' -newermt '<开跑时间>'` 应为 0）；
`Music/` 下不再有以水印串命名的一级目录；`items.album_id is null` 数 = 本批首数。

### 坑 21【静默隐身】`albumartist` 为空 → beets 把空路径组件写成 `_`，音乐「消失」在 `Music/_/` 与 `Music/__/`

**症状**：`Music/` 一级下冒出 `_` 和 `__` 两个目录，`beet ls -a` 看不见像样的专辑名，
按歌手也搜不到这批歌 —— 但文件确实在、也能播。

**成因**：`paths.default` 是 `$albumartist/%if{$year,$year }$album/$track $title`。
当字段为空时 beets 不跳过该组件，而是**用 `_` 占位**：

| 空字段 | 落盘 |
|---|---|
| `albumartist` 空、`album` 有值 | `Music/_/<专辑>/<曲>` |
| `albumartist` **和** `album` 都空 | `Music/__/<曲>`（单层，不是 `_/_`） |

临时库零风险复现（几秒）：

```bash
rm -rf /tmp/_b; mkdir -p /tmp/_b/Music /tmp/_b/src
cat > /tmp/_b/config.yaml <<'YAML'
directory: /tmp/_b/Music
library: /tmp/_b/beets.db
paths:
    default: $albumartist/%if{$year,$year }$album/$track $title
YAML
python3 - <<'PY'
import shutil, mutagen
shutil.copy('<任一音频>', '/tmp/_b/src/a.flac')
f = mutagen.File('/tmp/_b/src/a.flac', easy=True)
f['artist'] = []; f['albumartist'] = []; f['album'] = []; f['title'] = ['测试曲']
f.save()
PY
beet -c /tmp/_b/config.yaml import -q -I -A /tmp/_b/src
find /tmp/_b/Music          # -> /__/01 测试曲.flac
```

**什么时候会踩**：`flat_final.tsv` 里该目录的 `artist` 列本来就是空的 ——
`flat_probe.py` 的 `artist_from_dir()` 对这几类目录名提取不出艺人：
`【翱视群龍收藏】[红色经典]刀郎—红星照我去战斗WAV分轨`（前缀噪声 + 长串）、
`发烧天碟.-.[雨果发烧碟九].专辑`（本就是合辑）、`盖世英雄演唱会/CD1`（目录名里没歌手）。
`flat_retag` 忠实地把空值写进 tag → 落 `_`。

**排查（`_` 在 SQL `LIKE` 里是通配符，别用它查）**：

```python
hit = []
for r in cur.execute('select id,path,albumartist,album from items'):
    p = r[1].decode('utf-8','replace') if isinstance(r[1],(bytes,bytearray)) else r[1]
    if p.startswith('/vol2/1000/电影音乐/Music/__/') or '/Music/_/' in p:
        hit.append((r, p))
print(len(hit))                     # 205
# 落点分布 / 空 albumartist 的专辑
cur.execute("select id,album from albums where albumartist is null or albumartist=''")
```

**修法**（归属基本都能从目录名/源路径推出来）：手工建映射表 → 写 `artist`+`albumartist`
（+`album`）→ **同步库用 `beet modify` / SQL，绝不能用 `beet update`**（见坑 22）
→ `beet move` 归位。APEv2 文件务必走 `flat_fix_singles.write()` 那类**双键同步**的写函数（见坑 16）。

wav 要注意：`mutagen.File(path, easy=True)` 对 WAVE **直接返回 WAVE 对象**（不支持 easy），
赋值 list 会报 `['某某'] not a Frame instance`。必须非 easy 取 `f.tags` 后显式 setall：

```python
from mutagen.id3 import TIT2, TPE1, TPE2, TALB, TDRC
f = mutagen.File(path)
if f.tags is None:
    f.add_tags()
t = f.tags
t.setall('TIT2', [TIT2(encoding=3, text=title)])
t.setall('TPE2', [TPE2(encoding=3, text=albumartist)])
t.setall('TALB', [TALB(encoding=3, text=album)])
f.save()
```

**连带坑：`.1` 重名 = 同内容双源**。`__` 里出现 `01 xxx.1.wav` 这种，
说明**同一个演唱会/专辑在 `flat_plan.tsv` 里以两个不同源目录各出现一次**
（如 `盖世英雄演唱会/盖世英雄演唱会/CD1` 与
`王力宏 无损全集 22CD/香港豪华精装版《盖世英雄演唱会》/盖世英雄演唱会/CD1`），
`-A` 不查 MB 也就不去重 → 第二次复制时加 `.1`。
**处理：确认两源内容一致后，`.1` 那份直接隔离，不要重复入库。**
开局就该查 `flat_plan.tsv` 有无「同内容多源」，与坑 17 的父子重叠一起查。

### 坑 22【最贵的教训】`beet update` 会**移动文件**，不只是回写字段

2026-09-29 为了把新写的 tag 同步进库，跑了 `beet update 'albumartist:'`，后果：

1. **移动了 1138 个文件**（按读到的 tag 重新计算路径并搬运）——完全没预期；
2. **覆盖了 1259 条库记录**：`985 条 year 被清成 0`、22 个专辑记录被改。
   根因是 flat / tenyears 流程后期批量改过 tag，**文件 mtime 比库记录新**，
   update 一跑就用（不含 year 的）文件 tag 把库覆盖了。

**铁律：改完 tag 要同步库，用 `beet modify` 或直接 SQL，永远不要用 `beet update`。**

```bash
# ✅ 正确：直接写库，不读文件、不搬文件
beet modify -a 'id:115' 'albumartist=群星' 'album=雨果发烧碟九'
beet modify    'album_id:115' 'albumartist=群星' 'album=雨果发烧碟九'
# 或 SQL（本库字段就是 items/albums 的列）：
#   update items  set albumartist=?, album=?, artist=? where album_id=?
#   update albums set albumartist=?, album=?               where id=?
```

**事故后的补救套路**（已验证有效）：
1. 立刻 `cp beets.db.bak.<日期>-<主题> beets.db` 回滚库（前提是动手前备了份）；
2. 以**文件实际位置为准**重建 path —— 文件一个没丢（`find Music -type f | wc -l`
   与 `select count(*) from items` 数量相等就是没丢），按 basename / 归一化 basename
   把它们找回来，再用 album、albumartist 消歧；
3. 消歧要点：
   - **album 名必须按「目录层」匹配**（`os.sep+album+os.sep in path`），否则
     `人生海海` 这种曲名出现在别的专辑文件名里会误判；
   - **album 名要先做 sanitize**：beets 会把 `\ / : * ? " < > |` 换成 `_`，
     于是 album `李宗盛的音樂旅程 | 不捨` 实际目录是 `李宗盛的音樂旅程 _ 不捨`；
   - **排除已被有效记录占用的目标**，否则两条记录抢同一个文件；
   - 同内容的重复专辑（两条 aid、同一批文件）会表现为「目标被 x2 抢占」，
     这类要单独比对曲目再定，别自动分配。

**另外**：`beet update` 之后 `beet move` / `beet ls` 都可能连带异常，处理完务必做一次
一致性自检：

```bash
python3 - <<'PY'
import sqlite3, os, collections
c = sqlite3.connect('/vol2/1000/电影音乐/beets.db')
M = '/vol2/1000/电影音乐/Music'
rows = [(r[0], (r[1].decode('utf-8','replace') if isinstance(r[1],(bytes,bytearray)) else r[1]))
        for r in c.execute('select id, path from items')]
print('item 总数:', len(rows))
print('path 失效:', sum(1 for _, p in rows if not os.path.isfile(p)))
print('重复 path:', sum(1 for k, v in collections.Counter(p for _, p in rows).items() if v > 1))
print('Music 下文件数:', sum(len(f) for _, _, f in os.walk(M)))
PY
```


### 坑 23【同内容双源 → 同名专辑两条记录】`-A` 不查 MB，两次都入库

**症状**：`albums` 里同名同 albumartist 出现 2~4 条；两条记录的若干 `path` 字面重复；
磁盘上出现**一对只差年份前缀的目录**（如 `刀郎/2011 2011身披彩衣的姑娘/` 与 `刀郎/2011身披彩衣的姑娘/`）。

**成因**：同一张专辑在源库里有**两个源目录**（合集包 + 单专辑包），
`flat_plan.tsv` 都会列上；分轨流水线用 `-A`（刻意的，见「参数口径」）**不查 MB**，
于是两次都真入库。实测（2026-09-29）全库 23 组同名专辑，其中：
- **真重复（曲目 100% 重合）** 8 组
- 高度重叠 71~92%（同专辑不同曲目数）4 组
- **其实是 CD 分卷**（各 aid 的文件都在**同一目录**，如 `24K金限量珍藏版3CD` 3 条 × 17 首 = 51 文件）
  → 该合并成一个多碟专辑，**不是删重复**

**判据：比 `title` 不是比文件名**（两源命名格式不同，`05.最美的还是我们新疆.wav` vs
`刀郎-最美的还是我们新疆（live）.wav`）：

```python
def nz(t):                                  # 归一化：去空白 + 去括号内容 + 小写
    t = re.sub(r'[\s\u3000]+', '', t or '')
    return re.sub(r'[（(][^）)]*[）)]', '', t).lower()
rate = len(setA & setB) / min(len(setA), len(setB))    # ≥0.95 真重复；0.7~0.95 待甄别
```
先看两边 `os.path.dirname(path)` 分布 —— **同目录 + 文件数成倍数 = CD 分卷**，别删。

**「保留哪一套」的硬证据**（别凭感觉）：

1. `mb_albumid` 非空的那条（真匹配过 MB）
2. 源目录里有 **`list.txt`（官方曲目表）+ `log.log`（EAC 抓轨日志）+ 图册** 的那套
   —— 实测靠 `list.txt` 定案争议：源2 写明 `05. 最美的还是我们新疆（演唱会版）`，
   证明带 `（live）` 的命名是对的、另一套是无标注的简版
3. 路径符合库约定（带 `$year` 前缀）、tag 字段齐全（TRCK/TDRC 有值）

**音频同一性判据**（两套是不是同一录音）：时长可能只差 0.05s（编码 padding），
**全长 PCM md5 / 中段 md5 都会不同，不能据此判「不同录音」**。用**逐秒 RMS 包络相关系数**：

```bash
# ffmpeg -v error -i F -ar 8000 -ac 1 -f s16le -   → array('h') → 每秒 sr 个采样算 RMS → 得时长秒数个点位
# 两条序列的皮尔逊相关系数（可再扫 -1/0/+1s 偏移取最优）
```
实测三轨：`0.9906 / 0.9904 / 0.9900` —— 含争议轨在内**三轨同水平 = 同一录音**。
真不同版本（live vs studio）会明显掉到 0.7 以下。
（`ffprobe … astats=metadata=1:reset=1` 的 `frame_values`/`frame_tags` 在本环境**取不到值**，别用。）

**合并流程**（零文件丢失）：

```bash
cp "$DB" "$DB.bak.<日期>-<主题>"                     # 1. 备份
beet remove -a -f 'id:<被弃aid>'                     # 2. 不带 -d → 只删记录不删文件
mv "<被弃目录>" /vol2/1000/电影音乐/.flat_recycle/<描述性名字>   # 3. 归档另一套，不删
cp "<优选源>/cover.jpg" "<保留目录>/cover.jpg"         # 4. 有图册就顺手落封面
python3 -c "import sqlite3;sqlite3.connect('$DB').execute(\"update albums set artpath=? where id=?\",('<abs>/cover.jpg'.encode(),<aid>)).connection.commit()"
```
收尾自检四件：`items` 减、`albums` 减、`path 失效 0`、`重复 path 0`；
再确认被弃 aid 的 `items` 归零、被弃目录引用数归零。

**附带坑**：`ffprobe` 会把某些**正常 WAV** 误报成 `dts, 44100, 7 声道`。
别据此判文件损坏 —— 用 `file` + 手工解析 RIFF chunk（`fmt ` / `data` 的 size）确认。

#### 23b. 全库同名专辑的批量分型与处置（2026-09-29 实测 22 组）

一条只读探测脚本就能分型，判据 = **曲目 `title` 归一化重合率** + **`os.path.dirname` 分布**：

| 型 | 判据 | 处置 |
|---|---|---|
| **A 真重复** | 曲目 100% 重合、目录不同 | 保留一套，另一套归档 |
| **B 高度重叠** | 71~95%（曲目数不同） | 人工甄别是否不同版本，**别直接删** |
| **C CD 分卷** | 各 aid 文件**在同一目录**、数量成倍数 | 改名加 `CD1/2/3` + 文件分目录 |
| **D 待查** | 目录不同、曲目差异大 | 保留，人工比对 |

**A 类的「保留哪套」多一条硬判据 —— 格式与编号质量**：

- 同曲目下 **flac 优于 wav**（实测：`2004 2002年的第一场雪` flac vs `2003 …` wav）
- 文件名 **track 编号正确**的优于乱名的（实测 `人生海海` 有两套：带年份目录那套
  文件名是 `00 一颗苹果.flac`（track 全 0），无年份目录那套是规整的 `01 一颗苹果.flac`
  → 该保留**后者**，再把目录改名成带年份的，并更新 `items.path`）
- **多碟专辑不要误当重复**：实测 MJ《HIStory》是 aid 97(trk1-15=CD1) + aid 99(trk16-30=CD2)
  + aid 100(CD2 的副本) —— 前两条是**同一张双碟**，正确处置是
  `update items set album_id=97 where album_id=99` + `disctotal=2` + 删 album 99，
  再删 100 的副本；**不是把三条都当重复删掉两条**。

**C 类的标准处置**（沿用库约定，避免 track 冲突）：
给每个 aid 的新 album 名加 ` CD<N>` 后缀、文件按 aid 分到新目录、`items.disc=N`、`disctotal=N`。
**不要合并成一条 album 再连号 track** —— 那样文件名前缀与 track 会对不上。

```python
for i, aid in enumerate(aids, 1):
    new_al = f'{base_album} CD{i}'; aa2 = new_aa or aa       # new_aa 用于修噪声 albumartist
    newdir = os.path.join(M, aa2, f'{yr} ' if yr else '' + new_al)
    os.makedirs(newdir, exist_ok=True)
    for iid, p in items_of(aid):                              # 同目录内按 aid 精确分拣
        np = os.path.join(newdir, os.path.basename(p))
        if p != np: os.rename(p, np)
        c.execute('update items set path=?,album=?,albumartist=?,disc=?,disctotal=? where id=?', ...)
    c.execute('update albums set album=?,albumartist=?,disctotal=? where id=?', ...)
```
收尾别忘了 `os.rmdir` 清空的旧专辑目录，**以及**空掉的一级歌手目录
（实测 C3 把 `超/…` 迁到 `刀郎/…` 后 `Music/超` 变空）。

实测该批一次跑完：**items 7002→6893、albums 342→332、path 失效 0、重复 path 0**，
同名专辑从 22 组降到 11 组（剩 B/D 类）。归档一律 `os.rename` 到
`.flat_recycle/<日期>-dupmerge/<组名>/<相对库路径>/`，**同文件系统瞬时、零拷贝、可回溯**。

#### 23c. 「库字段 vs 文件实际路径」一致性自检（找元数据错位）

`fix_paths_all.py` 按**文件实际位置**重建 path 时不会改字段，于是会出现
「库说 albumartist=X，文件却躺在 Y/ 下」。用路径反推字段来扫：

```python
rel = os.path.relpath(path, M).split(os.sep)       # M/<albumartist>/<%if year, year ><album>/<track title>
d_aa, d_al = rel[0], re.sub(r'^\d{4} ', '', rel[1])
```

**三个必须排除的假阳性**（否则误报一堆）：

1. **beets sanitize**：`\ / : * ? " < > |` 和控制字符 → `_`，**尾部 `.` / 空格 → `_`**。
   实测 `G.E.M.`→`G.E.M_`、`L.O.V.E.`→`L.O.V.E_`、`Alan Walker/CORSAK…`→`Alan Walker_CORSAK…`。
   **比对时 `san()` 要同时作用在 `albumartist` 和 `album` 两侧**（只处理一侧会漏判成不一致）。
2. **`Various Artists` → `Compilations`**：comp 专辑的路径首层是 `Compilations`。
3. 已删除专辑的空目录（先 `os.path.isdir` 过滤）。

实测 342 张里：假阳性 5（sanitize）+ 2（Compilations）＋ **真实不一致 9 条**，
成因是早期导入把 tag 写错（如 `你要去哪里台湾巡回演唱会` 的 albumartist 被写成 `Glay`、
`摇滚四大才子` 被写成 `崔健`、`陈一发儿/New Soul` 用了 artist 当 album）。
这类要**先查清哪边是对的**再改，别一律以路径为准。

#### 23d. 回收区（`.flat_recycle/`）清理前的「零损失三判据」（2026-09-29 实测清空 16G）

用户确认清理回收区时，**先自证「删了不丢任何曲目」再动手**，三条按序做：

**判据 1 — 库内引用必须为 0（硬断言，不通过就终止）**

```python
REC='/vol2/1000/电影音乐/.flat_recycle'
ref=sum(1 for r in c.execute('select path from items') if s(r[0]).startswith(REC))
assert ref==0, '存在引用，终止!'
```

**判据 2 — 音频流指纹比对（关键：不是文件名）**

```python
import mutagen.flac
mutagen.flac.FLAC(p).info.md5_signature     # FLAC：只取决于解码后 PCM，与 tag / 文件名无关
# WAV/APE：解码中段再算
# ffmpeg -v error -ss 60 -t 30 -i F -f s16le -ac 2 -ar 44100 - | md5sum
```

**判据 3 — 音头有偏移 / 参数不同 → 换包络相关系数**（见坑 23）。注意 `ffprobe` 会把这类正常 WAV
误报 `dts, 7声道`，**不能拿 ffprobe 参数当比对依据**。

实测结果：

| 条目 | 文件 | 核验 |
|---|---|---|
| `Music_音乐_孤儿`（林俊杰合集旧副本） | 302 flac | 292 个 MD5 完全一致；剩 10 个 `(Live)` 用**解码 PCM** 补测 → **10/10 一致** |
| `underscore_王力宏重复` | 28 wav | **28/28 解码 PCM 一致** |
| `刀郎_…_源1翱视群龍版` | 10 wav | 中段 PCM 必然不同（差 0.048s 音头）→ 包络相关 0.99，同录音 |

**⚠️ 绝不能只用文件名判冗余 —— 两个方向都会错**：

- 正向假阳性：用全库 `basename → size` 映射时 `Music_音乐_孤儿` 报「276/302 命中」，
  但库里别的专辑有同名文件，**这个数字是虚的**；
- 反向漏判：`underscore_王力宏重复` 带 `.1` 后缀 → basename 命中 **0**，但 PCM 是 28/28 一致。

删完必须再跑自检，与删前**完全一致**（实测 6893 items / 332 albums / path 失效 0 / 重复 path 0）才算成功。
`.flat_recycle` **目录本身保留**（清空但留壳），供后续继续归档。

### 分轨入库的参数口径

```bash
# 专辑模式（真专辑）：用 flat_final.tsv 的 artist/album/year 覆盖 tag
beet import -q -I -A --set "album=$album" --set "albumartist=$artist" \
            --set "artist=$artist" --set "year=$year" "$d"

# 单曲模式（散装合集）：绝不 --set，否则会毁掉逐首不同的 artist
beet import -q -I -A -s "$d"
```

- **为什么统一走 `-A`（noautotag）**：这批专辑即使标签修干净，beets 的相似度也过不了 `-q`
  的阈值 —— 连 `--search-id <release>` 强制指定 release 都会 Skipping
  （曲目数一致、track 有序也没用）。`-A` 在这里是**刻意**用的，别照抄坑 1 的结论
- 模式判据用**共用名单文件**（`flat_singles.txt`，由 `flat_fix_singles.py` 导出），
  不要在导入脚本里另写一套正则 —— 两边判据漂移过一次
- **已干跑过的目录要先归档**：它们已入库但没进 `flat_done.txt`，重跑会因 beets
  文件级不去重而重复入库
- **`flat_retag.py` 的备份是唯一回滚依据**，再 `cp -n` 一份 `flat_tag_backup.orig.json` 兜底

#### 23e. 伍佰批次（2026-09-29，32 目录 / 361 文件）的「水印+阈值+繁简」组合拳

这批源数据的三个特征，缺一个都跑不动，必须同时处理：

| 症状 | 根因 | 处置 |
|---|---|---|
| `-q` 下**静默** `Skipping.`（连 `Similarity:` 行都没有） | `albumartist` 被水印串污染：`QQ群号：562125679 公众号：时光匆忙旅行者`，beets 拿它去构造 MB 的 `artist` 查询 → **0 候选** | 先洗掉三处水印（`albumartist` / `TALB` / `TPE2`） |
| 洗完水印仍 `Skipping.` | 源 tag 简体（`爱上别人是快乐的事`）vs MB 繁体（`愛上別人是快樂的事`），distance≈0.08 > 默认 `strong_rec_thresh` 0.04 | 放宽到 **0.15** 的独立配置（正确候选 0.08 vs 次佳 0.55，断层极大，安全） |

```yaml
# /tmp/beets_wubai.yaml —— 注意要连 directory/library/paths 一起写全，否则 -c 会把默认配置整个替换
match:
    strong_rec_thresh: 0.15
import:
    copy: yes          # ← 复制而非移动：源文件保留，便于线做 md5 全量校验后再清源
```

```bash
beet -c /tmp/beets_wubai.yaml import -q /path/to/album   # -c 会整体替换配置，务必写全字段
```

- **`--search-id` 不绕过阈值**：`beet import -q --search-id <release>` 实测仍 `Skipping.`
- **`tracknumber` 恒定错值 226**：整张曲目编号都是 226 → 是下载站的占位值，判为无效，
  先保留合法独值（1..n），其余按文件名顺序补齐
- **库内既有约定优先**：本库 伍佰 的既有约定是**繁体 + `& China Blue`**（见 #161《纯白的起点》），
  故 tag 繁化用 `zhconv.convert(s,'zh-tw')`，`albumartist` 统一为 `伍佰 & China Blue`；
  特例（feat./合作曲）另立 `EXC` 表：`伍佰 & 大鵬 & 李治廷` / `徐佳瑩 & 伍佰` / `伍佰 & DJ Mykal a.k.a.林哲儀`

**⚠️ 本轮真实踩到的两个工具坑**：

1. **`case "$name" in $DONE)` ——变量展开后的 `|` 不被当作模式分隔符**
   ```bash
   # ✗ 错：$DONE 里的 a|b|c 会被当成「一个字面量模式」，整个排除清单失效
   case "$name" in $DONE) continue;; esac
   # ✓ 对：显式列出，或用 if/for + 独立判断，或写成 case 的显式分支
   if [ "$name" = "$SKIP1" ] || [ "$name" = "$SKIP2" ]; then continue; fi
   ```
   后果：4 张 MB 专辑被**重复导入**、7 个单曲目录被**当专辑导入**。补救 = 删掉重复的
   `-A` 版记录，单曲目录改走 `-s` 重新入库。
2. **`beet ls 'path:5566'` 返回空**：本库 `items.path` 有 **6104 行为 SQLite BLOB**、1148 行为 TEXT，
   对 BLOB 做 `path:` 文本匹配失效。判断路径一律**读库后在 Python 里解码比对**，
   不要靠 `path:` 查询。（`decode('utf-8','replace')` 兜底）
3. **`beet remove -f id:1 id:2` 不删任何东西**：多个 query 参数被 beets 当成 **AND**。
   逐条 `beet remove -f id:N`，或用一个能唯一命中的单条件。

**源副本清理（`import.copy: yes` 的后果）**：清源前必须**全量 md5 校验**
（不要只看 size / 文件名）——实测 361 个源音频里 359 个与库内逐字节一致，
剩 2 个是 `重生`、`风平浪静` 的 mp3（beets 已保留同曲 flac，属低质冗余）→ 确认零损失后才清。

### Phase 7 — 现场演唱会「整轨大文件」（DTS/FLAC/WAV）→ 声学对齐拆轨入库

场景：一个 4.4 GB 的 `.dts` 整场音轨（5.1 / 48 kHz），**无 cue**，`ffprobe` 读不出时长。
用户要求「转码/拆轨入库」。**盲目 silencedetect 一定失败**（现场掌声不停，`-45dB` 只找到尾部静音；
`-30dB` 会检出 205 个假边界）。经验证的可靠路线如下。

**Step 1 — 解成母带**（先拿到一个可信的、能重复切片的中间件）

```bash
ffmpeg -hide_banner -y -i in.dts -ac 2 -ar 48000 -c:a flac -compression_level 5 master.flac
# 5.1→2.0 下混；约 70× 实时速度；再 ffprobe 就有 duration 了
```

**Step 2 — 自实现对数梅尔谱**（NAS 上只有 numpy，无 scipy/librosa）

```python
SR=16000; NFFT=8192; WIN=8000; HOP=4000; NB=40; FMIN=100; FMAX=6000   # → 4 Hz 帧率
# 三角梅尔滤波器组 FB(NB, NFFT//2+1)；logmel = log(FB @ |rfft(frame*WINW)|^2 + 1e-6)
# 分块处理，避免 49816×8192 的巨阵把内存打爆
```

**Step 3 — 用「库里已有的同场分轨版本」当索引去定位**（关键洞察）

只要库里已经有同场演出的分轨（**哪怕曲序是乱的、哪怕是 mp3**），就拿它的每首曲目作 query，
在母带的梅尔谱上做**归一化互相关**，逐首测出真实位置：

```python
# 单条相关（注意用共轭，不是反转数组！）
num = np.fft.irfft(np.fft.rfft(S, Nfft, axis=0) * np.conj(np.fft.rfft(q, Nfft, axis=0)), Nfft)
# 归一化：分母 = ||q|| * sqrt( Σ_band 滑窗能量_S )   ← 用 cumsum 求滑窗能量
nc  = num / (np.sqrt((q**2).sum()) * np.sqrt(np.maximum(ss, 1e-9)))
```

- **RMS 包络完全无效**：现场音源响度极平（`rms p50 −21dB / p90 −19dB`），任何响段都糊成
  0.6~0.95 相关，**偏移全乱**。必须走梅尔谱。
- **可信判据**：峰值 z-score（`(peak−median)/MAD`）达 **8~30**，且次峰只有 0.35~0.6（vs 主峰 0.79~0.98）。

**Step 4 — 排序 + 官方歌单交叉验证（必做）**

把这批偏移**排序**，检查是否「互不重叠地铺满整条时间轴」（相邻间隔 ≈ 曲目时长 + 几秒掌声）。
然后**联网搜官方曲目表**比对：本轮 54 首的对齐顺序与官方 BD 歌单**逐首完全一致**，
且 3:27:34 对齐官方 3:27:35 —— 这才敢动手切。顺带解释了一个 428 s 的“空档”= 官方第 32 项微电影。

> 反向收获：库里那份 mp3 专辑 `mb_trackid` **全为空**（从未 MB 匹配），说明其曲序是**按文件顺序瞎排的**
> —— 这是「曲序疑似错乱」的判据（查 `mb_trackid` 是否为空）。

**Step 5 — 切点与切轨**

```python
LEAD, TAIL = 1.0, 8.0
start = max(0, off[i] - LEAD)
end   = min(off[i] + dur[i] + TAIL, off[i+1] if i+1<n else TOTAL)   # 夹到下一首起点，把长 MC 甩掉
subprocess.run(['ffmpeg','-ss',f'{start:.3f}','-t',f'{end-start:.3f}','-i',MASTER,
                '-c:a','flac','-compression_level','8', fp])
```

母带是 FLAC，逐首**重新编码**（不要 `-c:a copy`，FLAC 帧内无时间索引，切点不可控）。
54 首重编约 3 分钟。之后用 mutagen 打 tag，`beet import -A -q <dir>` 入库。

**Step 6 — 用无损版替换旧的错序 mp3 版**

```bash
# 先把旧专辑整目录移进回收区（可回滚）
mv "$MUSIC/$ARTIST/2012 生命的現場" "$REC/生命的現場_mp3版_$(date +%Y%m%d)/"
beet remove -a -f 'album:生命的現場'      # 先移文件再删记录；album_id:/aid: 在 3.x 上不生效
beet import -A -q /staging/dir            # 无损 54 首按正序落回同一路径
```

至此实测：母带 12455 s、54 首无损 1.3 GB 入库，`path 失效 0 / 重复 path 0`，
与源副本逐字节 md5 全部一致后才删暂存。

---


---

## Phase 10 — 扁平大目录「散装单曲」批次（无 cue、**源无任何 tag**）
（2026-09-30 实测：《经典老歌1688首wma 5.4G》1656 首 → 入库 1066 首）

### 识别特征

`音乐/` 下出现一个**扁平**的一级目录（无子目录），里面几百上千个音频，
命名形如 `001.渡口 蔡琴.wma` / `1289.F4-流星雨-(电视剧《流星花园》插曲).wma`。
先跑 Phase 1 的扫描确认「0 个 cue」，再探 tag：

```bash
python3 -c "
import os
from mutagen.asf import ASF          # wma 用 ASF；mp3 用 mutagen.File
D='/vol2/1000/电影音乐/音乐/<目录>'
f=sorted(x for x in os.listdir(D) if x.lower().endswith('.wma'))[0]
a=ASF(os.path.join(D,f))
print({k:str(v)[:80] for k,v in a.tags.items()})"
```

**若打印出的只有 `WMFSDKVersion` / `IsVBR` / `DeviceConformanceTemplate` 这类编码器字段
—— 说明文件里根本没有音乐元数据，文件名是唯一信息源，必须重建 tag。**

### 坑 26【最坑，统计会全错】算「库内已有」必须用**导入前的库备份**

流程里要判定「哪些源曲目库里已经有了」。若在**导入之后**才去读 `beets.db` 求交集，
本次刚入库的 N 条会把自己算成「库内已有」——实测把真实值 **537 错算成 1655**，
跳过清单、原因列全部失真（且不会报错，只会输出一个看似合理的错数字）。

```bash
cp "$DB" "$DB.bak.<日期>-<主题>"          # 导入前先备份，这一步同时是「快照」
...
co = sqlite3.connect(DB + '.bak.<日期>-<主题>')   # 算 L 时读备份库，不读现库
```

顺带：批内重复集合 D 与库内重合集合 L 有交叉，别把 537+151 直接当跳过数：

```python
skip = L | D                    # 真跳过
print(len(L), len(D), len(L&D), len(L|D))   # 537 151 98 590  →  入库 = 1656-590 = 1066
```

### 命名解析：一个目录里常混着**两套**规范

《经典老歌1688首》实测：序号 0001-1288 是 `曲名 歌手`，1289-1688 是 `歌手-曲名`
（**顺序相反**）。按序号分段判别最可靠（实测例外仅 5 条）。

```python
TRACK = re.compile(r'^\s*(\d{1,4})\s*[\.\u3001]+\s*')     # 注意 1000.. 这种双点
HASH  = re.compile(r'[-_][0-9a-f]{8,}$', re.I)            # 迅雷重名哈希后缀
WSRUN = re.compile(r'[\s\u3000]{2,}')

def parse(num, rest):
    if num >= 1289:                                  # B 套：歌手-曲名
        a, t = rest.split('-', 1); return t.strip(), a.strip()   # 首个 '-'，曲名自身可含 '-'
    m = WSRUN.search(rest)
    if m:                                            # A 套：2+ 空格切
        return rest[:m.start()].strip(), rest[m.end():].strip()
    if ' ' in rest:                                  # 仅单空格 → 最后一个空格切
        i = rest.rfind(' '); return rest[:i].strip(), rest[i+1:].strip()
    return rest, ''
```

要点：

- **优先 2+ 空格切，而不是单空格**：合唱歌手内部用单空格（`当爱已成往事  李宗盛 林忆莲`
  → 歌手是整段 `李宗盛 林忆莲`），英文曲名用单空格（`La Perte 朴树` → 按最后一个空格切才对）
- B 套按**第一个** `-` 切，否则 `流星雨-(电视剧《流星花园》插曲)` 会被切碎
- 切完 `strip('-').strip()`，顺手清掉 `无地自容 黑豹-` / `选择坚强 - 指南针乐队` 这种尾部残留
- **例外表只会有个位数**（无空格、歌手连写如 `大女人曹格`、`高旗 and 超载-`），逐个人工定比写规则划算

### 歌手归一复用 Phase 8 的映射法

```python
lib_aa = {norm(aa): aa for aa in distinct_albumartist}   # 关键：全串优先
def resolve_aa(artist):
    if norm(artist) in lib_aa: return lib_aa[norm(artist)]        # 伍佰 & China Blue 这类整串直接复用
    first = SPLIT.split(artist)[0]                                # 否则取第一歌手
    return lib_aa.get(norm(first), first)
```

实测 1066 条里 **638 次命中库内既有写法**，只新增 234 个歌手目录。再对新目录做一次
「与库内既有」的前缀/归一化比对，通常只有个位数需要人工合并，例如本次：
`伍佰`→`伍佰 & China Blue`、`黑豹`→`黑豹乐队`、`李娜[女]`→`李娜`（同人异名），
`迪克仔`→`迪克牛仔`、`许韶洋`→`许绍洋`（资源站错写）。
**「前缀相同」≠「同一人」**：`张宇轩`/`张宇`、`龙梅`/`龙梅子`、`陈明真`/`陈明` 都是不同歌手，别自动并。

### 写 tag：先复制到暂存目录，在副本上写

源目录属主常是 `xunlei-app`（`drwx------`），**garson 无目录写权限**，中间产物不能落在源目录。
且直接改源文件会破坏「原始下载状态」，失去回滚依据。

```python
STAGE = '/vol2/1000/电影音乐/.wma_stage'      # 与源同文件系统，可硬链接；本次直接 copy 更稳
shutil.copy2(src, dst)
f = ASF(dst)
f['Title'] = title; f['Author'] = artist; f['WM/AlbumArtist'] = albumartist
f.save()
```

- wma 用 `Title` / `Author` / `WM/AlbumArtist` 三个键，beets 能正确读成 `title` / `artist` / `albumartist`
- 试写 3 个 → 读回验证 → `ffprobe` 确认可解码 → 再全量（1066 个约 90 秒）
- **`albumartist` 必须写**，否则落 `Music/_/`（坑 21）

### 只导入子集：用暂存目录把子集摘出来

去重后往往只导入一部分（本次 1066/1656）。直接 `beet import` 整个大目录会把跳过的也导进去。
做法 = 只复制要入库的那些到 `STAGE`，然后：

```bash
beet import -q -I -A -s /vol2/1000/电影音乐/.wma_stage     # -s 单曲模式，-A 不查 MB
```

- `-A` 在这里是**刻意**的（与 Phase 6 同理）：这批老歌简繁混杂、MB 覆盖差，让文件名重建的 tag 说话
- 单曲模式**不加 `--set`**，否则会毁掉逐首不同的 artist
- 单曲模式不建 `albums` 记录（`albums` 数量不变是正常的，别当成失败）

### 收尾与自检

```bash
# 归档：把文件移进 已转换专辑/<目录名>/，连同清单一起（别 mv 整个目录进已存在的目标，会嵌套）
find "$SRC" -maxdepth 1 -name '*.wma' -exec mv -t "$DST" {} +
rmdir "$SRC"
```

归档目录内落三个文件：`_处理说明.txt`（口径、依据、回滚方式）、`_入库清单.tsv`、`_跳过清单.tsv`（含原因与库内副本路径）。

自检五项必须全过：`items` 增量 == 入库数、`path 失效 0`、`重复 path 0`、`空目录 0`、
**新增 `.1` 重名 0**（存量 `.1` 要按 mtime 区分是否本次产生），再抽样 25 条 md5 与源比对。

### 补充：两个易错点

- **`.1` 重名按 mtime 甄别**：`find "$M" -name '*.1.*' -newermt '<开跑时间>' | wc -l`。
  本次 16 个 `.1` 全是历史遗留，若只看总数会误判成本次事故。
- **`sqlite` 修库字段时注意尾部空格**：库内存在 `刘美君 `（尾空格）与 `刘美君` 并存的情况，
  归一化比对能发现，直接 `update items set albumartist='刘美君' where albumartist='刘美君 '` 即可
  ——beets 生成路径时已 strip 尾空格，磁盘目录本来就是一个，**不需要 `beet move`**。


---

## Phase 12 — 无曲目表整轨的五路补全

（2026-09-30 实测：为《精选123部无损音乐专辑合集》收尾，25 个整轨 / 去重 22 个专辑 / 10 GB，
MB 无条目、目录无 cue。最终 **22/22 全部切分入库（219 轨），零人工提供曲目表**。）

按命中率与可靠性排序，依次试这五条路：

| # | 方法 | 命中 | 精度 |
|---|---|---|---|
| 1 | 内嵌 cuesheet | 2 张 | 零误差 |
| 2 | 同目录同名 cue 文件 | 1 张 | 零误差 |
| 3 | MusicBrainz 组合式查询 | 6 张 | <0.6% |
| 4 | 酷狗专辑接口 | 9 张 | <0.35% |
| 5 | 网易云歌名 + `silencedetect` | 3 张 | 验证式 |
| 5b | 网络搜索兜底 | 1 张 | 验证式 |

### 12.1 内嵌 cuesheet（最优先）

```python
out = subprocess.run(['ffprobe','-v','error','-show_entries','format_tags','-of','json',p],
                     capture_output=True, text=True).stdout
d = json.loads(out or '{}')
tags = {k.lower(): v for k, v in (d.get('format', {}).get('tags') or {}).items()}
cs = tags.get('cuesheet') or tags.get('cue_sheet')      # 大小写不定，两个都试
```

命中即用**原始 `INDEX 01`，绝不做缩放**——它就是这个镜像的精确切点。
注意 `ffprobe` 默认的 `default=nw=1` 输出会把长 tag 截断，**必须用 `-of json`** 才拿得到完整 cuesheet。

### 12.2 同名小文件当 cue 看

目录里出现「与音频同名、但只有几百字节到几 KB」的文件，多半是发布者把 cue 改名成了 `.APE`。

本次「齐秦-呼唤」目录里 `齐秦-[呼唤].专辑.APE` 只有 **1826 字节**，内容正是完整 11 轨 cue。
扫描时要**逐个试编码** `utf-8 → gb18030 → utf-8-sig → big5`，别只写 utf-8（本次两份 cue 实为 gb18030）。

### 12.3 MusicBrainz 组合式查询

```python
q = 'artist:"%s" AND release:"%s"' % (artist, album)   # 远优于裸 release:"X"
```

上一轮误判「MB 覆盖极低」，其实是**查询词问题**。改组合式后罗大佑 5 张全中，误差 0.07%–0.58%。
繁简都要试（MB 条目多为繁体，如 `羅大佑`）。

### 12.4 酷狗专辑接口（华语覆盖最好）

```
搜索  https://mobilecdn.kugou.com/api/v3/search/album?format=json&keyword=<q>&page=1&pagesize=6
曲目  https://mobilecdn.kugou.com/api/v3/album/song?format=json&albumid=<id>&page=1&pagesize=200
```

两个坑：

1. **证书链错误**（`Hostname mismatch`）→ 用
   `ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE`
2. **曲目名在 `filename` 字段**（格式 `歌手 - 歌名`），
   `songname` / `song_name` / `audio_name` 全是 `None`。
   取法 `fn.split(' - ', 1)[1]`；时长字段是 `duration`（秒）。

### 12.5 网易云歌名 + 本地 `silencedetect`

网易云**能拿歌名、拿不到时长**（未登录时 `dt` 被清零），正好拆成两件事做：
歌名走网络，切点走本地静音检测。

- 歌名：`/api/search/get/web?s=<q>&type=10` → 取 `result.albums[].id` → `/api/album/<id>` 读 `album.songs[].name`
- 限流很凶（连续 4 个请求后开始返回空）→ 加 `Cookie: os=pc; appver=2.9.7`，请求间隔 **≥4 s**

```bash
ffmpeg -hide_banner -i IN.wav -af silencedetect=noise=-50dB:d=0.4 -f null - 2>&1
#   → [Parsed_silencedetect] silence_start: 299.0 / silence_end: 300.1
```

#### 坑 29【踩过】silencedetect 不能配 `-v error`

它的日志是 **info 级**，`-v error` 会把日志全吞掉，表现为「一个静音点都探不到」，
极易误判成「这张专辑曲间无间隙」。用 `-hide_banner` 即可（默认 info）。

#### 判读规则（实测）

- **流行/人声专辑**：切点极准（±0.5 s），直接拿 `silence_start` 当下一轨起点
- **古典协奏曲**：弱奏段太多（帕格尼尼一张整轨 48 个静音点），**不能直接用**。
  改用法：先按 MB 乐章时长算预测切点，再在每个预测点 **±60 s** 内取最接近的长静音
- **双阈值交集法**：同时跑 `-50dB/0.4s` 与 `-60dB/0.3s`，取两者**共同点**，
  可自动剔除「歌曲内停顿」误判（本次哈琳 10 首，两阈值交集恰好 9 个切点）
- 相邻两静音点相距 **<15 s** 时只保留其一（另一个是同一间隙被噪音打断产生的二次触发）

#### 三源交叉验证（关键，别跳）

动手前必须让三个数字对上：**曲目名数 == 静音切点数 + 1**。

本次阿丽玛：网易云 **12 首** vs 酷狗 **11 首**，静音给 **12 段**。
逐轨比时长后发现缺口正好在第 3 轨，恰是「网易云有、酷狗无」的《鸿雁》——**双向自证**后才动手。

### 12.6 网络搜索兜底

冷门发烧碟（如 2009 年的汽车音乐碟《草原绝响》，国内平台只有续作「Ⅱ」），
论坛/博客存档里反而有完整原版曲目表。搜 `<专辑名> 曲目 <年代> <发行公司>` 命中率很高。
拿到曲目数后仍要与静音切点数比对（本次 11 == 11 通过）。

### 12.7 切分与入库的四个注意点

1. **cue 必须与音频同目录**——`cue_split.resolve_audio()` 用 `dirname(cue)` 找音频，且**显式排除符号链接**
   （`not os.path.islink`），所以 `ln -sf` 那套在这里不管用。源目录可写就直接把 cue 写进去。
2. `cue_split` 的轨名来自 cue 的 `TITLE`；**cue 没写 `TITLE` 时会 fallback 成 `Track NN`**。
   事后补名不必重切：按 `sorted(os.listdir())` 的顺序，用 mutagen 逐轨改写 `title` 即可。
3. 补名时**务必核对轨数**（`len(files) == len(titles)`），不等就别写，否则整张错位。
4. beets 默认是 **copy 模式**：`Music/` 里已有副本，源目录 `_split/` 会原样保留
   （本次留了 **1893 个 flac**），归档时会占双份空间，需要时另行清理。


---

---

## Phase 14 — 歌手单曲集（真单曲 + 卖家附赠 EP）批量入库

（2026-10-02 实测：《任素汐 单曲》474 MB = 15 首 flac 单曲 + 1 张 5 轨 EP；
产出 20 items / 1 album，零源损失、零新增失效路径）

### 形态识别

`待转音乐/<歌手> 单曲/` 这类暂存目录常见**两种内容混装**：

- **顶层扁平的真单曲**：`YYYY-MM-DD·曲名.flac`，每首自带 `album=<曲名>`、`albumartist=<歌手>`、`date`
  —— 是**真单曲**，**不是**坑 15 那种「合集目录名被 fill 成专辑名」的污染
- **子目录里一张正经 EP/专辑**：多轨 + `cover.jpg` + 轨数齐全

### 决策口径（动手前先问用户）

| 决策 | 推荐 | 理由 |
|---|---|---|
| 单曲形态 | **全部 singleton**（`-A -s`） | 目录语义就是「单曲」；库内 `paths.singleton=$albumartist/$title` |
| 单曲的 `album` 字段 | **保留** | 是真单曲/OST 曲，album 是有用元数据。**与坑 15 要清空 `album` 的「散装合集」不是一类** |
| EP | **album 模式** | 有 cover、多轨、是正经 release，singleton 会丢掉专辑语义 |
| 库内已有同曲 mp3 | **用无损替换** | 先证同录音（见下），再删记录 + 文件进回收区 |

### 三件必须先做的事（缺一个就出脏数据）

**1) 单曲与子专辑分开暂存 —— `-s` 是递归的**

`beet import -q -I -A -s "<目录>"` 会对目录**递归**扫描，子目录里的 EP 也会被当单曲导入。
所以两类**各自复制到独立暂存目录**再分别导入：

```bash
STAGE='/vol2/1000/电影音乐/.ren_stage'
mkdir -p "$STAGE/singles" "$STAGE/ep"
cp "$SRC"/*.flac                      "$STAGE/singles/"   # 只取顶层单曲
cp "$SRC/$EPNAME"/*.flac "$SRC/$EPNAME"/cover.jpg "$STAGE/ep/"
beet import -q -I -A -s "$STAGE/singles"
beet import -q -I -A    "$STAGE/ep"
```

入库在**副本**上做 → 源目录保持原始下载状态，是唯一回滚依据。

**2) EP 补齐三个字段（`-A` 不会替你补，它只是「不查 MB」）**

| 缺失字段 | 后果 |
|---|---|
| `albumartist` | 落 `Music/_/`（坑 21） |
| `tracknumber` | 文件名前缀全是 `00`（坑 104） |
| 伴奏轨 title 与主曲撞名 | 落盘 `.1` 重名（坑 105） |

实测源 EP 5 轨里两首「伴奏」的 title 与主曲**逐字相同**，不修就落成
`00 王招君 (…).flac` + `00 王招君 (…).1.flac`。

**3) 先查库级惯例，再决定单曲要不要走 MB 匹配**

```python
tot = cur.execute('select count(*) from items where album_id is null').fetchone()[0]
has = cur.execute("select count(*) from items where album_id is null "
                  "and mb_trackid is not null and mb_trackid<>''").fetchone()[0]
print(tot, has)        # 本库实测 3697 / 0
```

**覆盖率 0% 说明既有约定就是「单曲不匹配 MB」** —— 这时别自作聪明去匹配，
否则这一批的 singleton 会和库里 3697 条不一致。

### MB 就算查得到，也不一定匹配得上 —— 但它能拿来修标签

`artist:"<歌手>"` 的 release 搜索结果里，**单曲会以「1 轨 release」形式出现**，
能直接拿到官方曲名与发行日。但**这不等于 beets 能自动匹配**：

- 1 轨单曲 → beets 的 album 匹配通常 `Skipping.`（无候选）
- 实测 MB 上《TA·说》是 **6 轨**，源只有 **5 轨** → 轨数不等 → 永远匹配不上
  （`--search-id` 也不绕过阈值，见 23e）

**但 MB 依然是权威标签源**：源里两首伴奏与主曲 title 撞名，
MB 的写法 `主曲名(伴奏)` 一次解决「重名」+「信息量」两个问题。

```bash
# 搜索 API 不给曲目表，要按 id 再取一次（请求间隔 ≥1.2s）
curl -s -A 'ua/1.0' 'https://musicbrainz.org/ws/2/release?query=release:%22TA%C2%B7%E8%AF%B4%22&fmt=json'
curl -s -A 'ua/1.0' "https://musicbrainz.org/ws/2/release/<release-id>?inc=recordings+artist-credits&fmt=json"
```

**顺带必做「源轨数 vs MB 轨数」比对** —— 不等就是源残缺（坑 32）。
本次靠这一步发现源 EP 少了《胡广生(伴奏)》，按「缺口不硬凑」如实留空并写进说明文件。

### 替换库内旧版 mp3 的正确姿势

```bash
cp -a "$DB" "$DB.bak.$(date +%Y%m%d)-<标签>-pre"            # 1) 备份
# 2) 先证同录音：时长逐位相等即可定案（214.984014 == 214.984014），不必上 PCM 指纹
beet remove -a -f 'albumartist:Suxi Ren'                     # 3) 删记录，不加 -d（文件保留）
mv "$M/Suxi Ren" "$REC/任素汐_胡广生_SuxiRen_mp3单曲替换_$(date +%Y%m%d)"   # 4) 文件进回收区
```

- 查专辑用 `albumartist:<值>` 最稳（比 `album_id:` / `aid:` 可靠）
- **一律不加 `-d`**，让文件留在原地由 `mv` 接管，绝不 `rm`
- 替换顺手**统一拼写**：实测库内那唯一一条用的是英文 `Suxi Ren`，替换后全库统一成中文

### 收尾核对（本批实测值）

```
items  14072 → 14092 → 14091   （+15 单曲 +5 EP −1 mp3）
albums  3004 →  3005 →  3004   （+1 EP −1 mp3）
path 失效 8 → 全部【旧有】，本次新增 0
重复 path 0 · 孤儿音频 0 · 空目录 0 · 本次新增 .N 重名 0 · 库↔标签不一致 0
```

> ⚠️ 报「path 失效」前**必须与导入前的备份库做差集**，否则会把历史遗留
> （本库 8 条 GBK 乱码路径）算成本次事故。
> 同理 `.N` 重名要先排掉 `Op.35` / `No.4` 这类古典曲名假阳性（坑 13.7）。

### 归档与 m3u

- 源目录 → `已转换专辑/<批次名>/`（`shutil.move`）。目录内落：
  `_入库清单.tsv`（**5 列**：序 / 源文件 / 歌手 / 曲名 / 落盘绝对路径 ——
  Phase 11 的 m3u 脚本按 `p[0],p[2],p[3],p[4]` 取，列少了会静默漏条目）
  + `_处理说明.txt` + `_跳过清单.tsv` + `_原始标签备份_*.json` + `_批次数据.json`
- **清暂存之前，先把 `backup_*.json` 拷进归档目录**，否则会丢掉唯一的标签回滚依据
- m3u 放 `Music/<批次名>.m3u`，**相对路径**（详见 Phase 11）
- 归档完删空的父目录（本次 `待转音乐/` 变空后已 `rmdir`）
