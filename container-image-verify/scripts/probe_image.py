#!/usr/bin/env python3
"""探测任意 registry 上的容器镜像；可选与另一个源做同 tag 逐层比对。

用法:
  # 单源探测：存在性 / manifest 类型 / 架构 / 体积 / 组件版本
  python probe_image.py swr.cn-north-4.myhuaweicloud.com ddn-k8s/docker.io/nginx 1.31.4-alpine

  # 双源比对：同 tag 的 config + 逐层 digest（判定是否内容等价）
  python probe_image.py swr.cn-north-4.myhuaweicloud.com ddn-k8s/docker.io/nginx 1.31.4-alpine \
      --compare docker.1ms.run library/nginx

仅用标准库。token 的 realm 从 WWW-Authenticate 动态获取，适配各家 registry。
"""
import json
import ssl
import sys
import urllib.error
import urllib.request

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.docker.distribution.manifest.v1+prettyjws",
])


def norm_host(host):
    """允许只写域名（自动补 https://）。"""
    return host if host.startswith(("http://", "https://")) else "https://" + host


def http(url, headers=None, timeout=30):
    req = urllib.request.Request(url)
    req.add_header("User-Agent", "docker/27.0.0")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
        return r.status, dict(r.headers), r.read()


def token_for(host, repo):
    """按 WWW-Authenticate 提示换匿名 token；返回 (token, note)。"""
    wa = ""
    try:
        st, hd, _ = http(f"{host}/v2/")
        wa = hd.get("WWW-Authenticate", "")
    except urllib.error.HTTPError as e:
        wa = e.headers.get("WWW-Authenticate", "")
    except Exception as ex:
        return None, f"连不上: {type(ex).__name__}: {ex}"
    if not wa:
        return None, "无 WWW-Authenticate（可能匿名直读）"
    p = {}
    for part in wa.replace("Bearer ", "").split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            p[k.strip().lower()] = v.strip().strip('"')
    realm = p.get("realm")
    if not realm:
        return None, f"realm 缺失: {wa[:120]}"
    url = f"{realm}?service={p.get('service','')}&scope=repository:{repo}:pull"
    try:
        st, hd, body = http(url)
        d = json.loads(body.decode("utf-8"))
        t = d.get("token") or d.get("access_token")
        return t, f"token ok (len={len(t or '')})"
    except urllib.error.HTTPError as e:
        return None, f"token HTTP {e.code}"
    except Exception as ex:
        return None, f"token err {ex}"


def get_manifest(host, repo, ref, tok):
    h = {"Accept": ACCEPT}
    if tok:
        h["Authorization"] = "Bearer " + tok
    st, hd, body = http(f"{host}/v2/{repo}/manifests/{ref}", h)
    return json.loads(body.decode("utf-8")), hd


def get_blob(host, repo, digest, tok):
    h = {"Accept": "application/octet-stream"}
    if tok:
        h["Authorization"] = "Bearer " + tok
    st, hd, body = http(f"{host}/v2/{repo}/blobs/{digest}", h)
    return body


def resolve_amd64(host, repo, tag, tok, verbose=True):
    """返回 (manifest, digest, 说明)；自动把多平台 index 下钻到 linux/amd64。"""
    m, hd = get_manifest(host, repo, tag, tok)
    dg = hd.get("Docker-Content-Digest", "")
    if verbose:
        print(f"    mediaType = {m.get('mediaType')}")
        print(f"    digest    = {dg}")
    if m.get("manifests"):
        child = None
        for e in m.get("manifests", []):
            pl = e.get("platform", {})
            if verbose:
                print(f"    platform: {pl.get('os')}/{pl.get('architecture')}"
                      f"{('/' + pl['variant']) if pl.get('variant') else ''} -> {e['digest'][:22]}…")
            if pl.get("os") == "linux" and pl.get("architecture") in ("amd64", "x86_64"):
                child = e["digest"]
        if not child:
            return None, dg, "index 中没有 linux/amd64"
        m, hd = get_manifest(host, repo, child, tok)
        dg = hd.get("Docker-Content-Digest", child)
        if verbose:
            print(f"    → amd64 子清单 digest = {dg}")
    return m, dg, None


def describe(host, repo, tag, label="目标"):
    print(f"\n[{label}] {host}/{repo}:{tag}")
    tok, note = token_for(host, repo)
    print(f"    认证: {note}")
    try:
        m, dg, err = resolve_amd64(host, repo, tag, tok)
    except urllib.error.HTTPError as e:
        print(f"    ❌ tag 不可读: HTTP {e.code}（不存在或需认证）")
        return None
    except Exception as ex:
        print(f"    ❌ {type(ex).__name__}: {ex}")
        return None
    if err:
        print(f"    ❌ {err}")
        return None

    layers = m.get("layers", [])
    total = sum(l.get("size", 0) for l in layers)
    print(f"    层数 = {len(layers)}   压缩体积 = {total/1024/1024:.1f} MB")
    cfg = None
    cd = m.get("config", {}).get("digest")
    try:
        cfg = json.loads(get_blob(host, repo, cd, tok).decode("utf-8"))
        cc = cfg.get("config", {}) or {}
        print(f"    config.digest = {cd}")
        print(f"    architecture  = {cfg.get('architecture')}   os = {cfg.get('os')}")
        print(f"    created       = {cfg.get('created')}")
        print(f"    Env           = {json.dumps(cc.get('Env', []), ensure_ascii=False)}")
        print(f"    Cmd           = {json.dumps(cc.get('Cmd'), ensure_ascii=False)}")
        print(f"    Entrypoint    = {json.dumps(cc.get('Entrypoint'), ensure_ascii=False)}")
        print(f"    Labels        = {json.dumps(cc.get('Labels', {}), ensure_ascii=False)}")
    except Exception as ex:
        print(f"    config 读取失败: {ex}")
    return {"manifest": m, "digest": dg, "layers": layers, "config_digest": cd,
            "config": cfg, "token": tok, "total": total}


def compare(a, b, a_label, b_label):
    print("\n" + "=" * 70)
    print("逐项比对")
    print("=" * 70)
    ok = True
    if a["config_digest"] and a["config_digest"] == b["config_digest"]:
        print(f"  config digest  ✅ 相同  {a['config_digest']}")
    else:
        ok = False
        print(f"  config digest  ❌ 不同\n      {a_label}: {a['config_digest']}\n      {b_label}: {b['config_digest']}")
    la, lb = a["layers"], b["layers"]
    if len(la) != len(lb):
        ok = False
        print(f"  层数           ❌ {a_label}={len(la)} / {b_label}={len(lb)}")
    else:
        print(f"  层数           ✅ 都是 {len(la)}")
    same = 0
    for i in range(max(len(la), len(lb))):
        x = la[i].get("digest") if i < len(la) else None
        y = lb[i].get("digest") if i < len(lb) else None
        if x == y:
            same += 1
        else:
            ok = False
        print(f"    layer{i:>2}  {'SAME' if x == y else 'DIFF'}  {str(x)[:34]}…  {str(y)[:34]}…")
    print(f"\n  相同层 = {same}/{len(la)}")
    print("\n  ✅ 内容等价（只是外层 manifest 包装不同）" if ok
          else "\n  ⚠️ 存在实质差异，不是同一份内容")
    return ok


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    host, repo, tag = norm_host(argv[1]), argv[2], argv[3]
    a = describe(host, repo, tag, "目标")
    if not a:
        print("\n结论: tag 不可用（不存在 / 需认证 / 网络不可达）")
        return 1

    if "--compare" in argv:
        i = argv.index("--compare")
        if i + 2 > len(argv) - 1:
            print("--compare 需要两个参数: <host> <repo>")
            return 2
        chost, crepo = norm_host(argv[i + 1]), argv[i + 2]
        b = describe(chost, crepo, tag, "对照")
        if b:
            compare(a, b, f"{host}/{repo}", f"{chost}/{crepo}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
