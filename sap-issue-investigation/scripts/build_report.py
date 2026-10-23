"""将本地 SAP 案件清单和原始 PNG 生成离线 HTML，并校验证据引用。"""
import argparse
import base64
import hashlib
import html
import json
from pathlib import Path
import struct


def text(value):
    """所有案件文本均视为内容，转义后再放入 HTML。"""
    return html.escape(str(value))


def required(record, key):
    if not isinstance(record, dict):
        raise ValueError('清单条目必须是 JSON 对象')
    value = record.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f'字段 {key} 必须是非空字符串')
    return value


def inside(root, path):
    resolved = path.resolve()
    if not resolved.is_relative_to(root):
        raise ValueError(f'路径超出案件目录: {path}')
    return resolved


def prepare(case, root):
    """在任何输出前校验图片、证据编号和发现/路径引用。"""
    if not isinstance(case, dict):
        raise ValueError('案件清单必须是 JSON 对象')
    for key in ('title', 'system', 'client', 'object', 'summary', 'scope', 'execution'):
        required(case, key)
    evidence = case.get('evidence')
    if not isinstance(evidence, list) or not evidence:
        raise ValueError('evidence 至少包含一张原始 PNG')
    prepared, ids = [], set()
    for item in evidence:
        eid = required(item, 'id')
        if eid in ids:
            raise ValueError(f'重复证据 ID: {eid}')
        ids.add(eid)
        for key in ('title', 'observed_at', 'note'):
            required(item, key)
        relative = Path(required(item, 'path'))
        if relative.is_absolute():
            raise ValueError('证据路径必须相对案件目录')
        path = inside(root, root / relative)
        raw = path.read_bytes()
        if path.suffix.lower() != '.png' or len(raw) < 33 or raw[:8] != b'\x89PNG\r\n\x1a\n' or raw[12:16] != b'IHDR':
            raise ValueError(f'不是有效的 PNG 文件头: {relative}')
        width, height = struct.unpack('>II', raw[16:24])
        if not width or not height:
            raise ValueError(f'PNG 尺寸无效: {relative}')
        prepared.append({**item, 'sha256': hashlib.sha256(raw).hexdigest(),
                         'uri': 'data:image/png;base64,' + base64.b64encode(raw).decode('ascii')})
    finding_ids = set()
    for group in ('findings', 'path'):
        entries = case.get(group)
        if not isinstance(entries, list) or not entries:
            raise ValueError(f'{group} 不能为空')
        for item in entries:
            if not isinstance(item, dict):
                raise ValueError(f'{group} 条目必须是 JSON 对象')
            refs = item.get('evidence_ids')
            if not isinstance(refs, list) or not refs or any(not isinstance(ref, str) or ref not in ids for ref in refs):
                raise ValueError(f'{group} 存在缺失或未知证据引用')
            if group == 'findings':
                fid = required(item, 'id')
                if fid in finding_ids:
                    raise ValueError(f'重复发现 ID: {fid}')
                finding_ids.add(fid)
                for key in ('title', 'location', 'cause', 'impact', 'recommendation'):
                    required(item, key)
                if item.get('status') not in ('verified', 'static', 'candidate'):
                    raise ValueError('发现状态必须为 verified/static/candidate')
            else:
                required(item, 'text')
    return prepared


def render(case, evidence):
    """内嵌原图、发现与调用路径，不引入远程资源或执行案件文字。"""
    links = {e['id']: f'evidence-{n}' for n, e in enumerate(evidence, 1)}

    def refs(item):
        return '、'.join(f'<a href="#{links[eid]}">{text(eid)}</a>' for eid in item['evidence_ids'])

    status = {'verified': '已验证', 'static': '静态发现，未动态触发', 'candidate': '待验证'}
    findings = ''.join(
        f'<article><h3>{text(f["id"])} · {text(f["title"])}</h3>'
        f'<p class="meta">{status[f["status"]]} · {text(f["location"])} · 证据 {refs(f)}</p>'
        f'<p><b>原因：</b>{text(f["cause"])}</p><p><b>影响：</b>{text(f["impact"])}</p>'
        f'<p><b>建议：</b>{text(f["recommendation"])}</p></article>' for f in case['findings'])
    pictures = ''.join(
        f'<figure id="{links[e["id"]]}"><figcaption><b>{text(e["id"])} · {text(e["title"])}</b>'
        f'<span>{text(e["observed_at"])} · {text(e["note"])}</span></figcaption>'
        f'<img src="{e["uri"]}" alt="{text(e["title"])}" loading="lazy">'
        f'<details><summary>原始文件与完整性</summary><p>{text(e["path"])}</p>'
        f'<p class="hash">SHA-256: {e["sha256"]}</p>'
        f'<a download="{text(Path(e["path"]).name)}" href="{e["uri"]}">下载原始 PNG</a></details></figure>' for e in evidence)
    paths = ''.join(f'<li>{text(p["text"])} <small>（{refs(p)}）</small></li>' for p in case['path'])
    requirements = ''.join(f'<blockquote>{text(required(r,"text"))}<footer>{text(required(r,"source"))}</footer></blockquote>' for r in case.get('requirements', []))
    checks = ''.join(f'<tr><td>{text(required(c,"name"))}</td><td>{text(required(c,"result"))}</td></tr>' for c in case.get('checks', []))
    limits = ''.join(f'<li>{text(v)}</li>' for v in case.get('limitations', []))
    style = '''
    :root{color-scheme:light}*{box-sizing:border-box}body{margin:0;background:#f3f6fa;color:#172b45;font:16px/1.8 "Segoe UI","Microsoft YaHei",sans-serif}main{max-width:1080px;margin:auto;padding:32px 24px}header,section{padding:26px 30px;background:#fff;border:1px solid #dce4ed;margin:18px 0;border-radius:4px}header{border-top:5px solid #2563eb}h1{font-size:30px;line-height:1.4}h2{font-size:23px}h3{font-size:19px}p,li{white-space:pre-wrap;overflow-wrap:anywhere}.lead{font-size:19px}.meta,small,footer{color:#475569;font-size:14px}a{color:#174fb5;text-underline-offset:3px}a:focus-visible,summary:focus-visible{outline:3px solid #2563eb;outline-offset:3px}nav{display:flex;gap:16px;flex-wrap:wrap}article{padding:12px 0;border-top:1px solid #dce4ed}figure{margin:26px 0;border:1px solid #dce4ed;background:#f8fafc}figcaption{background:#edf3fa;padding:15px}figcaption span{display:block;font-size:14px;white-space:pre-wrap;overflow-wrap:anywhere}img{display:block;width:100%;height:auto}details{padding:12px 16px}summary{cursor:pointer;color:#174fb5}.hash{font:12px/1.7 Consolas,monospace;overflow-wrap:anywhere}table{width:100%;border-collapse:collapse}th,td{text-align:left;vertical-align:top;padding:12px;border-bottom:1px solid #dce4ed;overflow-wrap:anywhere}blockquote{background:#f6f8fc;margin:16px 0;padding:14px 18px;border-left:3px solid #8facd1;white-space:pre-wrap}blockquote footer{margin-top:8px}.scroll{overflow:auto}@media(max-width:640px){main{padding:12px}header,section{padding:20px 16px}h1{font-size:25px}.lead{font-size:17px}}@media print{body{background:#fff}main{max-width:none;padding:0}nav,details{display:none}header,section{padding:18px;border-radius:0}figure{break-inside:avoid}h2,h3{break-after:avoid}}
    '''
    return f'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{text(case['title'])}</title><style>{style}</style></head><body><main>
<header><p class="meta">SAP 问题排查 · {text(case['system'])} / {text(case['client'])} · {text(case['object'])}</p><h1>{text(case['title'])}</h1><p class="lead">{text(case['summary'])}</p><p>{text(case['scope'])}</p></header>
<nav aria-label="报告导航"><a href="#findings">发现</a><a href="#path">执行路径</a><a href="#evidence">截图证据</a><a href="#requirements">需求依据</a><a href="#checks">验证与限制</a></nav>
<section id="findings"><h2>发现与建议</h2>{findings}</section><section id="path"><h2>执行路径</h2><ol>{paths}</ol></section><section id="evidence"><h2>原始截图证据</h2><p>图片内嵌，可离线阅读。完整性校验不代替业务内容核验。</p>{pictures}</section>
<section id="requirements"><h2>需求依据</h2>{requirements or '<p>未提供需求依据；不能据此发明业务规则。</p>'}</section>
<section id="checks"><h2>验证与限制</h2><p>{text(case['execution'])}</p><div class="scroll"><table><thead><tr><th>检查</th><th>实际结果</th></tr></thead><tbody>{checks}</tbody></table></div><ul>{limits}</ul></section></main></body></html>'''


def build(input_path, output_path, overwrite=False):
    """验证完整后写报告和证据摘要；默认保护已有文件。"""
    input_path = Path(input_path).resolve()
    root = input_path.parent
    output = inside(root, Path(output_path))
    if output.suffix.lower() != '.html':
        raise ValueError('输出扩展名必须为 .html')
    manifest = inside(root, output.with_suffix('.evidence.json'))
    if manifest == input_path:
        raise ValueError('证据摘要不能覆盖输入清单')
    if not overwrite and (output.exists() or manifest.exists()):
        raise ValueError('输出已存在；获准替换后才可使用 --overwrite')
    raw = input_path.read_bytes()
    case = json.loads(raw.decode('utf-8-sig'))
    evidence = prepare(case, root)
    page = render(case, evidence)
    digest = {'input_sha256': hashlib.sha256(raw).hexdigest(),
              'evidence': [{k: v for k, v in e.items() if k != 'uri'} for e in evidence]}
    output.parent.mkdir(parents=True, exist_ok=True)
    for path, content in ((output, page), (manifest, json.dumps(digest, ensure_ascii=False, indent=2))):
        path.write_bytes(content.replace('\r\n', '\n').replace('\n', '\r\n').encode('utf-8'))
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('case_json', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--overwrite', action='store_true')
    args = parser.parse_args()
    try:
        output = build(args.case_json, args.output, args.overwrite)
    except (ValueError, OSError, TypeError, KeyError) as exc:
        parser.exit(2, f'ERROR: {exc}\n')
    print(output)


if __name__ == '__main__':
    main()
