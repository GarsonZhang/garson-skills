# 11 · 艺人字段切分（多艺人取首位）通用方案

适用：任何「按艺人分目录」的整理任务，尤其源文件 artist 字段是
`A、B、C` / `A & B` / `A feat. B` 这类多艺人串，需取首位艺人归目录时。

---

## 11.1 为什么不能只用正则

多艺人串的分隔符分三类，可靠度天差地别：

| 分隔符 | 例子 | 可靠度 | 处理 |
|---|---|---|---|
| 顿号「、」 | `查晨婷、张黎、王晶等` | **绝对可靠**，中文并列无歧义 | 直接切 |
| 显式标记 `feat.`/`ft.`/`with`/`×`/`╳`/`VS`/`／` | `周杰伦 feat. 袁咏琳` | **可靠**，标记语义明确 | 直接切（连前置空格吃掉） |
| 空格 + `&` / `and` | `Hillsong Young & Free` vs `Jay-Z & Kanye West` | **不可靠** | 需语义裁决 |
| 逗号 `,` | `Earth, Wind & Fire` vs `蔡依林, 周杰伦` | **不可靠** | 需语义裁决 |

**核心矛盾**：`Simon & Garfunkel`（乐队，应保留整串）与
`Jay-Z & Kanye West`（合作，应切）在**词形上完全同构**。
纯正则（无论多复杂）都无法区分——差别只在「谁是艺人」这个**外部语义**。

实测过的错误方向（别再走）：
- 按「左侧是否 ≥2 词」判乐队名 → `Hillsong Young & Free` 被认为乐队（对），
  但 `Simon & Garfunkel` 左侧只有 `Simon`（1 词）→ 被误切。
- 按「每词是否首字母大写」判乐队名 → `Earth, Wind & Fire` 全大写，判定失效。

---

## 11.2 正确方案：正则召回 + 网易云裁决

**分层设计**，网络调用只在必要时发生：

```
1) 含「、」            → 直接切，不走网络（最省）
2) 含 feat./ft./with/×// → 直接切，不走网络
3) 无可疑分隔符        → 单艺人，不走网络
4) 其余（& / and / ,）  → 网易云裁决
```

### 第 4 层的裁决闸门

```python
whole_ok, whole_m = nc.is_solid(whole串)      # 整串精确命中 且 musicSize >= 100
if whole_ok:
    return [whole串]                          # 强实体（经典乐队/组合）→ 保留
else:
    parts = 按可疑分隔符切
    return parts                              # 否则切，取首位
```

**为什么用 `musicSize >= 100`**：整串在网易云存在 ≠ 整串是单艺人
（`周杰伦 & 费玉清` 作为合作曲目也会有条目）。但**经典乐队/组合的 musicSize 都很大**：

| 整串 | 网易云 musicSize | 判定 |
|---|---|---|
| Simon & Garfunkel | 2391 | 保留 |
| Hall & Oates | 2793 | 保留 |
| Earth, Wind & Fire | 1485 | 保留 |
| The Mamas & The Papas | 909 | 保留 |
| Tyler, The Creator | 583 | 保留 |
| Hillsong Young & Free | 246 | 保留 |
| Jay-Z & Kanye West | 无整串条目 | 切 |

阈值 100 是实测值，可调。素人占名（musicSize ≤ 2）会被可靠排除。

---

## 11.3 网易云接口（NAS 直连）

```python
url = "https://music.163.com/api/cloudsearch/pc?type=100&limit=5&s=" + quote(name)
headers = {"User-Agent": "Mozilla/5.0 ...", "Referer": "https://music.163.com/",
           "Cookie": "appver=2.0.2"}
# result.artists[] → name / alias / musicSize / id
```

**必须遵守**：
- **直连，禁走代理**（境外 IP 风控 → 0 候选，坑 #76）
- **限速 3.3s/次**（官方约 20 次/分钟且按 IP 计）
- **`type=100` 是歌手检索**（不是 1=单曲）
- **精确命中才算**：用 `norm()` 去标点归一后比 `name` 或 `alias`，
  **绝不能对搜索 top1 兜底取用**（会引入大量误判）
- 结果**落盘缓存**，同一目录多次整理不重复请求

`norm()` 需含：NFKC 归一 + 去空格标点 + 小写 + **繁简归一（zhconv）**
（`張靚穎` vs `张靓颖`）。

---

## 11.4 完整实现

见 `fnos` NAS `/tmp/a3/artist_split.py`（切分器）+ `/tmp/a3/nc_verdict.py`（裁决器）。
本地副本：工作区 `fnos_dedup/artist_split.py`、`fnos_dedup/nc_verdict.py`。

调用：

```python
from artist_split import split_artists
artists, why = split_artists("查晨婷、张黎、王晶等")
primary = artists[0] if artists else "未知艺术家"
```

**回归用例（17 条，改完必跑）**：

```
顿号:      查晨婷、张黎、王晶等 → [查晨婷, 张黎, 王晶]
          雷霖、MOMO任珊      → [雷霖, MOMO任珊]
乐队保留:  Hillsong Young & Free / Simon & Garfunkel / Hall & Oates
          The Mamas & The Papas / Earth, Wind & Fire / Tyler, The Creator
合作切分:  Jay-Z & Kanye West   → [Jay-Z, Kanye West]
          周杰伦 & 费玉清        → [周杰伦, 费玉清]
          陈奕迅 and 王菲        → [陈奕迅, 王菲]
          周杰伦 feat. 袁咏琳    → [周杰伦, 袁咏琳]
          周杰伦/费玉清          → [周杰伦, 费玉清]
          和楽器バンド & 桜men    → [和楽器バンド, 桜men]
单艺人:    A-Lin / S.H.E / The Kiboomers  → 原样
```

---

## 11.5 已知残留（无法用本方案解决）

- **`The Kiboomers, Inc.`** 这类「名 + 公司后缀」会被切成 `['The Kiboomers', 'Inc.']`。
  需要额外一个英文后缀词表（inc/ltd/llc/co/corp/jr/sr/ii/iii/iv/band）在切之前拦掉。
  低频场景，未合入主流程；遇到时加 `_EN_SUFFIX` 检查即可。
- **素人歌手**：网易云查不到（如 `查晨婷`），此时 `is_solid` 返回 False → 走切分分支。
  若整串其实是单艺人（只是查不到），会被误切。**兜底规则**：切分分支要求
  「切出的首位能精确命中网易云」才真切，否则整串保留。

---

## 11.6 与「未知艺术家」兜底的关系

切完取首位后，若首位为空 → 落 `未知艺术家/`（自建表约定，见 01-import 坑 #100）。
**不要**让空 artist 直接套路径模板，会产出 `Music/<曲名>` 畸形路径。
