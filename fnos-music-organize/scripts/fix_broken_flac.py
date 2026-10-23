# -*- coding: utf-8 -*-
"""修复被「标签写入」破坏的 FLAC（元数据块结构坏了，但音频帧完好）。

典型症状（ro-music 实测）：
  - ffprobe 报 `Invalid data found when processing input`，文件完全不可读
  - 服务端任务状态 `completed_with_warnings`，警告形如
    `标签嵌入失败: Attempt to access memory outside buffer bounds`
  - 文件头 `fLaC` 正确、全文件无零尾（说明音频数据其实在）

原理：FLAC = fLaC + 元数据块链 + 音频帧。标签写入把元数据块的长度/结构写坏
（常见是 VORBIS_COMMENT 长度虚高、其后补零），音频帧本身往往完好。
做法：保留原 STREAMINFO（字节 8..42），从第一个能通过试解码的帧同步起点
重建 `fLaC + STREAMINFO(末块) + data[帧起点:]`，再用 ffmpeg 按文件名回写
title/artist。原件先移入隔离区，可回滚。

用法（在 NAS 上，需 ffprobe/ffmpeg）：
    python3 fix_broken_flac.py --src <目录> --trash <隔离区目录>            # 干跑
    python3 fix_broken_flac.py --src <目录> --trash <隔离区目录> --apply    # 执行
"""
import os, re, argparse, subprocess, shutil

WORK = "/tmp/a3/repairwork"


def ffprobe(p):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                        "format=duration,bit_rate", "-of", "csv=p=0", p],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def decode(p, t=None):
    """返回 (是否干净解码, 错误片段)。t 秒数用于快速试解码。"""
    cmd = ["ffmpeg", "-v", "error"]
    if t:
        cmd += ["-t", str(t)]
    cmd += ["-i", p, "-f", "null", "-"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return (not r.stderr.strip()), r.stderr.strip()[:70]


def parse_name(b):
    stem = os.path.splitext(b)[0]
    m = re.match(r"^(?P<t>.+?)\s+-\s+(?P<a>.+)$", stem)
    return (m.group("t").strip(), m.group("a").strip()) if m else (stem, "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--trash", required=True, help="隔离区目录（原件先移到这里）")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--scan-limit", type=int, default=2 * 1024 * 1024,
                    help="扫描帧同步的最大偏移（默认 2MB）")
    a = ap.parse_args()
    os.makedirs(WORK, exist_ok=True)

    names = [n for n in sorted(os.listdir(a.src))
             if os.path.splitext(n)[1].lower() == ".flac"
             and os.path.isfile(os.path.join(a.src, n))]
    rows = []
    for n in names:
        p = os.path.join(a.src, n)
        if ffprobe(p):
            continue                      # 能读 → 不是坏文件
        with open(p, "rb") as f:
            data = f.read()
        if data[:4] != b"fLaC":
            rows.append((n, "非 fLaC 头，跳过")); continue
        si = data[8:42]                    # STREAMINFO 载荷（34B）
        cands, i = [], 42
        lim = min(len(data) - 1, a.scan_limit)
        while i < lim:
            if data[i] == 0xFF and (data[i + 1] & 0xFE) == 0xF8:
                cands.append(i)
            i += 1
        rb = os.path.join(WORK, "rb.flac")
        picked = None
        for c in cands:
            with open(rb, "wb") as f:
                f.write(b"fLaC")
                f.write(bytes([0x80]))     # 末块标记 + type=0(STREAMINFO)
                f.write((34).to_bytes(3, "big"))
                f.write(si)
                f.write(data[c:])
            ok, _ = decode(rb, t=5)
            if ok:
                picked = c
                break
        if picked is None:
            rows.append((n, "未找到可用帧起点（候选 %d，试着手工处理或重下）" % len(cands)))
            continue
        title, artist = parse_name(n)
        fin = os.path.join(WORK, "final.flac")
        if os.path.exists(fin):
            os.remove(fin)
        subprocess.run(["ffmpeg", "-v", "error", "-i", rb, "-c", "copy",
                        "-metadata", "title=" + title,
                        "-metadata", "artist=" + artist, "-y", fin],
                       capture_output=True, text=True)
        if not os.path.exists(fin):
            rows.append((n, "重打标签失败")); continue
        ok, err = decode(fin)
        if not ok:
            rows.append((n, "重建后全解码仍有错: " + err)); continue
        dur = ffprobe(fin)
        if a.apply:
            os.makedirs(a.trash, exist_ok=True)
            shutil.move(p, os.path.join(a.trash, n))
            shutil.move(fin, p)
        rows.append((n, "OK  帧起点=%d  时长/码率=%s" % (picked, dur)))

    print("=== %s：坏文件 %d 个 ===" % ("APPLY" if a.apply else "DRY-RUN", len(rows)))
    for n, s in rows:
        print("  %-46s %s" % (n[:45], s))
    if rows and not a.apply:
        print("\n（干跑，未落盘；加 --apply 执行）")


main()
