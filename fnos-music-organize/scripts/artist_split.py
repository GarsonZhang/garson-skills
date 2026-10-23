# -*- coding: utf-8 -*-
"""最终版艺人切分器：正则召回 + 网易云裁决。

正则只负责「& / and / , 」这些可疑分隔符的候选生成；
是否真的切，交给网易云语义裁决（nc_verdict）。
顿号和 feat./ft./with/×// 是明确标记，直接切，不走网络。
"""
import re
import nc_verdict as nc

_CJK = re.compile(r"[\u4e00-\u9fff\u3400-\u4dbf]")
# 明确合作标记：直接切
_FEAT = re.compile(r"\s*(?:feat(?:uring)?\.?|ft\.?|with|w/|×|✕|╳|VS\.?|vs\.?|／|/)\s*")
# 可疑分隔符：& and ,（需网易云裁决）
_SUSPECT = re.compile(r"\s+(?:&|and)\s+|\s*,\s*")


def _cleanup(parts):
    out = []
    for p in parts:
        p = re.sub(r"[等]\s*$", "", p.strip()).strip()
        if p:
            out.append(p)
    return out


def split_artists(raw, use_nc=True):
    """返回 (艺人列表, 裁决理由)。"""
    if not raw:
        return [], "empty"
    s = raw.strip()

    # 1) 顿号：绝对切
    if "、" in s:
        return _cleanup(s.split("、")), "wuhao"

    # 2) feat./ft./with/×// ：绝对切
    if _FEAT.search(s):
        return _cleanup(_FEAT.split(s)), "feat"

    # 3) 无可疑分隔符 → 单艺人
    if not _SUSPECT.search(s):
        return _cleanup([s]), "single"

    # 4) 可疑分隔符 → 网易云裁决
    if not use_nc:
        return _cleanup(_SUSPECT.split(s)), "suspect-nonc"

    whole_ok, whole_m = nc.is_solid(s)
    if whole_ok:
        # 整串是强实体（经典乐队/组合）→ 保留
        return _cleanup([s]), "nc-whole(music=%d)" % whole_m["musicSize"]

    # 整串不是强实体 → 切，并逐段过「首位是否真艺人」的复核
    parts = _cleanup(_SUSPECT.split(s))
    if len(parts) < 2:
        return parts, "nc-split-nofx"
    head_ok, head_m = nc.is_solid(parts[0], min_music=1)
    reason = "nc-split(head=%s)" % ("hit" if head_ok else "miss")
    return parts, reason


if __name__ == "__main__":
    cases = [
        ("查晨婷、张黎、王晶等", ["查晨婷", "张黎", "王晶"]),
        ("雷霖、MOMO任珊", ["雷霖", "MOMO任珊"]),
        ("Hillsong Young & Free", ["Hillsong Young & Free"]),
        ("Simon & Garfunkel", ["Simon & Garfunkel"]),
        ("Hall & Oates", ["Hall & Oates"]),
        ("The Mamas & The Papas", ["The Mamas & The Papas"]),
        ("Earth, Wind & Fire", ["Earth, Wind & Fire"]),
        ("Tyler, The Creator", ["Tyler, The Creator"]),
        ("The Kiboomers, Inc.", ["The Kiboomers, Inc."]),
        ("Jay-Z & Kanye West", ["Jay-Z", "Kanye West"]),
        ("周杰伦 & 费玉清", ["周杰伦", "费玉清"]),
        ("陈奕迅 and 王菲", ["陈奕迅", "王菲"]),
        ("周杰伦 feat. 袁咏琳", ["周杰伦", "袁咏琳"]),
        ("周杰伦/费玉清", ["周杰伦", "费玉清"]),
        ("和楽器バンド & 桜men", ["和楽器バンド", "桜men"]),
        ("A-Lin", ["A-Lin"]),
        ("S.H.E", ["S.H.E"]),
    ]
    print("%-3s %-30s %-34s %s" % ("", "输入", "结果", "裁决"))
    ok = 0
    for s, exp in cases:
        got, why = split_artists(s)
        good = got == exp
        if good:
            ok += 1
        print("%s %-30s %-34s %s" % ("OK " if good else "!! ", s, str(got), why))
    nc.save_cache()
    print("\n%d/%d 通过" % (ok, len(cases)))
