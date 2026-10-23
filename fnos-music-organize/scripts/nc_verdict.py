# -*- coding: utf-8 -*-
"""网易云语义裁决：正则给候选切法，网易云判「哪一种是真艺人」。

核心洞察（实测得出）：
  - 整串命中且 musicSize 高（≥100）= 强证据表明整串是**一个真实存在的实体**
    （Simon & Garfunkel 2391 / Hall & Oates 2793 / Hillsong Young & Free 246）
  - 但「整串存在」不等于「整串是单艺人」：周杰伦 & 费玉清 也可能整串存在
    （合作曲目会被建条目）。
  - 因此闸门顺序：
      a) 整串命中 且 musicSize ≥ 100  →  整串保留（保护经典乐队/组合）
      b) 整串 miss 或 素人条目（musicSize 很小）→  切
      c) 整串命中但 musicSize < 100（疑素人占名）→  要求切出的首位也命中 → 切
"""
import json, urllib.parse, urllib.request, time, re, os

CACHE = "/tmp/a3/nc_art_cache.json"
_cached = {}
if os.path.exists(CACHE):
    _cached = json.load(open(CACHE))


def _fetch(name):
    url = ("https://music.163.com/api/cloudsearch/pc?type=100&limit=5&s=%s"
           % urllib.parse.quote(name))
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
        "Referer": "https://music.163.com/",
        "Cookie": "appver=2.0.2",
    })
    with urllib.request.urlopen(req, timeout=10) as r:
        data = json.loads(r.read().decode("utf-8"))
    arts = (data.get("result") or {}).get("artists") or []
    return [{"name": a.get("name"), "alias": a.get("alias") or [],
             "musicSize": a.get("musicSize") or 0, "id": a.get("id")} for a in arts]


def norm(s):
    try:
        from zhconv import convert
        s = convert(s or "", "zh-cn")
    except Exception:
        s = s or ""
    return re.sub(r"[\s\.·、,，&／/\-–—_]+", "", s).lower()


def query(name):
    """查缓存或网络，返回 artist 列表。"""
    if name in _cached:
        return _cached[name]
    try:
        res = _fetch(name)
    except Exception as e:
        res = {"__error__": str(e)}
    _cached[name] = res
    time.sleep(3.3)   # 网易云限速约 20/min，3.3s 间隔安全
    return res


def save_cache():
    json.dump(_cached, open(CACHE, "w"), ensure_ascii=False)


def match(name, res):
    """精确命中（去标点归一）才算，返回该 artist 或 None。"""
    if isinstance(res, dict):
        return None
    n = norm(name)
    for a in res:
        if norm(a["name"]) == n:
            return a
        for al in a["alias"]:
            if norm(al) == n:
                return a
    return None


def is_solid(name, min_music=100):
    """整串是否「强实体」：精确命中且 musicSize ≥ 阈值。"""
    res = query(name)
    m = match(name, res)
    return (m is not None and m["musicSize"] >= min_music), m
