# -*- coding: utf-8 -*-
"""飞牛音乐整理流水线：盘点 → 规划 → 干跑/执行。

用法（在 NAS 上，与 artist_split.py / nc_verdict.py 同目录）：
    python3 music_organize.py --src <源目录> --dst <目标目录>            # 干跑
    python3 music_organize.py --src <源目录> --dst <目标目录> --apply    # 执行

整理规则（默认，老张 2026-10-10 定）：
  1. Tag 取数：文件 tag > 文件名「歌名 - 艺人」 > beets 补全
     （beets 仅在 tag 与文件名都拿不到 artist 时才调用；实测罕见）
  2. 目录结构：目标目录/<首位艺人>/原文件名；无艺人 → 未知艺术家/
  3. 多艺人取首位：顿号/feat 标记直接切；& / and / , 走网易云 musicSize>=100 裁决
     （见 artist_split.py；查不到网易云素人时整串保留）
  4. 同曲重复（归一化 (曲名, 首位艺人) 判重）：保留音质最好的
     （无损 > 采样率 > 位深 > 码率 > 体积）
  5. 搬运用 os.rename（同盘 mv），保留属主/权限/时间戳

安全设计：
  - 默认只读干跑，打印每一步动作；--apply 才落盘
  - 生成 plan.json 供人工复查；重复项删除前列出清单
  - 残缺文件（时长 < 15s 且码率 <= 128k）只标记 WARNING，不自动删，须人工确认
"""
import os, re, sys, json, subprocess, argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from artist_split import split_artists
import nc_verdict as nc

UNKNOWN = "未知艺术家"
AUDIO_EXT = {".mp3", ".flac", ".wav", ".ape", ".m4a", ".ogg", ".wma", ".opus", ".aiff"}


def probe(p):
    """ffprobe 列表传参读元数据（坑 #47：路径含特殊字符时不能用 shell 拼接）。"""
    r = subprocess.run(["ffprobe", "-v", "error", "-show_format", "-show_streams",
                        "-of", "json", p], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return json.loads(r.stdout)


def parse_name(basename):
    """文件名「歌名 - 艺人」解析；注意 - 前后必须有空格，防误切 A-Lin。"""
    stem = os.path.splitext(basename)[0]
    m = re.match(r"^(?P<t>.+?)\s+-\s+(?P<a>.+)$", stem)
    return (m.group("t").strip(), m.group("a").strip()) if m else (None, None)


def norm(s):
    """归一化：繁简 + 去空格标点 + 小写（判重键用）。"""
    try:
        from zhconv import convert
        s = convert(s or "", "zh-cn")
    except Exception:
        s = s or ""
    return re.sub(r"[\s\(\)（）\[\]【】·、,，.。!！?？\-_+'’]+", "", s).lower()


def qkey(info, size):
    """音质排序键：无损 > 采样率 > 位深 > 码率 > 体积。
    不按体积排（坑 #81：wav 无标签体积最大但会把 flac 挤掉）。"""
    a = next((s for s in (info or {}).get("streams", []) if s.get("codec_type") == "audio"), {})
    f = (info or {}).get("format", {})
    codec = (a.get("codec_name") or "").lower()
    lossless = 1 if codec in ("flac", "alac", "ape", "wav", "aiff") or codec.startswith("pcm") else 0
    return (lossless,
            int(a.get("sample_rate") or 0),
            int(a.get("bits_per_raw_sample") or a.get("bits_per_sample") or 0),
            int(a.get("bit_rate") or f.get("bit_rate") or 0),
            size)


def survey(src):
    rows, warn = [], []
    for name in sorted(os.listdir(src)):
        p = os.path.join(src, name)
        if not os.path.isfile(p) or os.path.splitext(name)[1].lower() not in AUDIO_EXT:
            continue
        info = probe(p)
        if info is None:
            warn.append({"file": name, "issue": "ffprobe 失败，可能非音频/损坏"})
            continue
        tg = {k.lower(): v for k, v in ((info.get("format") or {}).get("tags") or {}).items()}
        nt, na = parse_name(name)
        # 坑：标签含 U+FFFD（坏编码，典型是老的 Windows 抓轨）或为空时必须回退文件名——
        # 否则会把文件塞进一个乱码目录名，且不同文件的乱码 title 撞车导致误判重复。
        _tt = tg.get("title") or ""
        _aa = tg.get("artist") or tg.get("album_artist") or ""
        title = nt if (not _tt or "\ufffd" in _tt) else _tt
        artist_raw = na if (not _aa or "\ufffd" in _aa) else _aa
        # 判据收集但不在 survey 阶段切 —— 切分（含网易云）放 plan 阶段统一做
        dur = float((info.get("format") or {}).get("duration") or 0)
        if dur < 15:
            a = next((s for s in info.get("streams", []) if s.get("codec_type") == "audio"), {})
            br = int(a.get("bit_rate") or (info.get("format") or {}).get("bit_rate") or 0)
            if br <= 128000:
                warn.append({"file": name, "issue": "疑似残缺（%.1fs / %dk）" % (dur, br // 1000)})
        rows.append({"file": name, "size": os.path.getsize(p), "title": title,
                     "artist_raw": artist_raw, "info_summary": {"dur": dur}, "_info": info})
    return rows, warn


def plan(rows):
    keep, drop_dup, beets_needed, multi = [], [], [], []
    for r in rows:
        artists, why = split_artists(r["artist_raw"])
        primary = artists[0] if artists else None
        if len(artists) > 1:
            multi.append({"file": r["file"], "artists": artists, "primary": primary, "why": why})
        if not primary or not r["title"]:
            beets_needed.append(r["file"])
        r["primary"] = primary or UNKNOWN
        r["why"] = why
        keep.append(r)
    # 同曲去重：归一化 (曲名, 首位艺人)
    groups = {}
    for r in keep:
        groups.setdefault((norm(r["title"]), norm(r["primary"])), []).append(r)
    final = []
    for key, grp in groups.items():
        if len(grp) > 1:
            best = max(grp, key=lambda x: tuple(qkey(x["_info"], x["size"])))
            for r in grp:
                if r is not best:
                    drop_dup.append({"file": r["file"], "kept": best["file"]})
                    keep.remove(r)
    return keep, drop_dup, beets_needed, multi


def dest_conflict_check(dst, keep):
    """执行前必查：与目标目录已有文件的冲突（坑：os.rename 目标存在时 POSIX 静默覆盖）。

    三类：
      same-name  —— 目标路径已存在同名文件。再按内容判：
                     同一文件（dur/size/br 相同）→ skip_src（删源即可，库内已有一份）
                     内容不同 → 无法自动定夺，列 needs_review 让人工确认
      same-song  —— 归一化 (title, primary) 与库内已有歌曲相同但文件名不同
                   （典型 flac-vs-mp3）。逐对 ffprobe 比音质：
                     源更好 → replace（先删库内旧文件再搬源）
                     库内更好/同级 → skip_src
    返回 (skip_src, replace, needs_review)：
      skip_src:   [{file, reason, dest}] —— 源文件应删/丢弃，库内不动
      replace:    [{file, primary, old_file}] —— 搬源并删库内 old_file
      needs_review: [{file, dest, note}] —— 内容不同的同名冲突，必须人工裁决
    """
    # 目标库索引：文件名 -> 路径；归一化 (title, 首位艺人) -> 路径
    dest_names = {}
    dest_songs = {}
    for root, _d, files in os.walk(dst):
        for f in files:
            fp = os.path.join(root, f)
            dest_names[fp] = fp
            nt, na = parse_name(f)
            if nt and na:
                dest_songs.setdefault((norm(nt), norm(split_artists(na, use_nc=False)[0][0]
                                                   if split_artists(na, use_nc=False)[0] else na)),
                                      []).append(fp)

    skip_src, replace, needs_review = [], [], []
    for k in keep:
        dstp = os.path.join(dst, k["primary"], k["file"])
        if dstp in dest_names:
            # 同名：比内容
            si = probe(os.path.join(k["_src_dir"], k["file"])) if k.get("_src_dir") else None
            di = probe(dstp)
            sa = next((s for s in (si or {}).get("streams", []) if s.get("codec_type") == "audio"), {})
            da = next((s for s in (di or {}).get("streams", []) if s.get("codec_type") == "audio"), {})
            sbr = int(sa.get("bit_rate") or (si or {}).get("format", {}).get("bit_rate") or 0)
            dbr = int(da.get("bit_rate") or (di or {}).get("format", {}).get("bit_rate") or 0)
            if sbr == dbr and k["size"] == os.path.getsize(dstp):
                skip_src.append({"file": k["file"], "reason": "与库内同一文件", "dest": dstp})
            else:
                needs_review.append({"file": k["file"], "dest": dstp,
                                     "note": "同名但内容不同，无法自动定夺"})
            continue
        # 同曲不同名（flac-vs-mp3 等）
        key = (norm(k["title"]), norm(k["primary"]))
        if key in dest_songs:
            existing = dest_songs[key][0]
            si = qkey(k["_info"], k["size"])
            dii = probe(existing)
            dsize = os.path.getsize(existing)
            if tuple(si) > tuple(qkey(dii, dsize)):
                replace.append({"file": k["file"], "primary": k["primary"],
                                "old_file": os.path.basename(existing)})
            else:
                skip_src.append({"file": k["file"], "reason": "库内已有同级/更好", "dest": existing})
    return skip_src, replace, needs_review


def apply_plan(src, dst, keep, drop_dup, warn, do_apply,
               skip_src=None, replace=None):
    made = set()
    actions = 0
    skip_names = {s["file"] for s in (skip_src or [])}
    replace_names = {r["file"] for r in (replace or [])}
    # 1) 批内重复删音质差的
    for d in drop_dup:
        p = os.path.join(src, d["file"])
        print("[DROP-DUP]", p, "→ 保留", d["kept"])
        if do_apply and os.path.exists(p):
            os.remove(p)
        actions += 1
    # 2) 与库内同一文件/库内更好 → 删源（库内不动）
    for s in (skip_src or []):
        print("[SKIP-SRC]", s["file"], "-", s["reason"])
        if do_apply:
            p = os.path.join(src, s["file"])
            if os.path.exists(p):
                os.remove(p)
        actions += 1
    # 3) 源更好 → 删库内旧文件 + 搬源
    for r in (replace or []):
        oldp = os.path.join(dst, r["primary"], r["old_file"])
        dstp = os.path.join(dst, r["primary"], r["file"])
        print("[REPLACE]", r["file"], "->", r["primary"] + "/", "删旧", r["old_file"])
        if do_apply:
            if os.path.exists(oldp):
                os.remove(oldp)
            os.makedirs(os.path.dirname(dstp), exist_ok=True)
            os.rename(os.path.join(src, r["file"]), dstp)
        actions += 1
    # 4) 正常搬运（排除已 skip/replace 的）
    for r in keep:
        if r["file"] in skip_names or r["file"] in replace_names:
            continue
        dstdir = os.path.join(dst, r["primary"])
        dstp = os.path.join(dstdir, r["file"])
        if dstdir not in made:
            print("[MKDIR ]", dstdir + "/")
            made.add(dstdir)
        print("[MOVE  ]", r["file"], "->", r["primary"] + "/", "[%s]" % r["why"])
        if do_apply:
            os.makedirs(dstdir, exist_ok=True)
            if os.path.exists(dstp):   # 兜底：冲突检查漏网时不静默覆盖
                print("  !! DST-EXISTS 跳过:", dstp)
                continue
            os.rename(os.path.join(src, r["file"]), dstp)
        actions += 1
    print("\n=== %s ===" % ("APPLY" if do_apply else "DRY-RUN"))
    print("目录 %d · 搬运 %d · 替换 %d · 跳源 %d · 删重复 %d · 疑似残缺 %d（不自动删）" % (
        len(made), len(keep) - len(skip_names) - len(replace_names),
        len(replace or []), len(skip_src or []), len(drop_dup), len(warn)))
    return actions


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--dst", required=True)
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    rows, warn = survey(args.src)
    for r in rows:
        r["_src_dir"] = args.src   # 冲突检查比内容时要用源路径
    if warn:
        print("=== 疑似残缺/异常（仅警告，不自动删，需人工确认）===")
        for w in warn:
            print("  ?", w["file"], "-", w["issue"])
        print()
    keep, drop_dup, beets, multi = plan(rows)
    if beets:
        print("== 需 beets 补全 tag 的文件 %d ==" % len(beets))
        for b in beets:
            print("  ", b)
    if multi:
        print("== 多艺人切分 %d ==" % len(multi))
        for m in multi:
            print("   %-40s %s → %s [%s]" % (m["file"][:40], m["artists"], m["primary"], m["why"]))

    # 执行前必查：与目标目录的冲突（同名静默覆盖 / 同曲不同名）
    skip_src, replace, needs_review = [], [], []
    if os.path.isdir(args.dst):
        skip_src, replace, needs_review = dest_conflict_check(args.dst, keep)
    if needs_review:
        # 老张 2026-10-10 修正裁决（最终版）：同名但内容不同（不同抓轨/母带）→
        # 按音质参数对比，保留参数最高的；参数相同 → 保留体积最大的。
        # 赢的可能是库内旧文件（此时删源），不是无脑用源替换。
        # qkey 已含此序：无损 > 采样率 > 位深 > 码率 > 体积。
        print("== 同名不同内容 → 按音质参数裁决 %d（参数同级取体积大者）==" % len(needs_review))
        for c in needs_review:
            sp = os.path.join(args.src, c["file"])
            si = probe(sp)
            di = probe(c["dest"])
            sq = tuple(qkey(si, os.path.getsize(sp)))
            dq = tuple(qkey(di, os.path.getsize(c["dest"])))
            primary = c["dest"].split("/")[-2]
            if sq > dq:
                print("   +", c["file"], "源更好 → 替换库内")
                replace.append({"file": c["file"], "primary": primary,
                                "old_file": os.path.basename(c["dest"])})
            else:
                print("   -", c["file"], "库内同级/更好 → 删源")
                skip_src.append({"file": c["file"], "reason": "同名冲突，库内参数同级/更高",
                                 "dest": c["dest"]})
    if skip_src:
        print("== 与库内冲突 → 跳源 %d ==" % len(skip_src))
        for s in skip_src:
            print("   -", s["file"], "-", s["reason"])
    if replace:
        print("== 源更好 → 替换库内 %d ==" % len(replace))
        for r in replace:
            print("   +", r["file"], "=>", r["primary"] + "/ (删", r["old_file"] + ")")

    nc.save_cache()
    json.dump({"keep": [{"file": k["file"], "title": k["title"], "primary": k["primary"]}
                        for k in keep],
               "drop_dup": drop_dup, "warn": warn, "beets_needed": beets,
               "skip_src": skip_src, "replace": replace, "needs_review": needs_review},
              open("/tmp/a3/plan.json", "w"), ensure_ascii=False, indent=1)
    apply_plan(args.src, args.dst, keep, drop_dup, warn, args.apply,
               skip_src=skip_src, replace=replace)


if __name__ == "__main__":
    main()
