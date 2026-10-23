---
name: abap-alv-field-inventory
description: 从经典 ABAP 报表源码提取 ALV 列字段与选择屏幕字段，并结合 SAP 表字典 HTML 生成可交付的字段清单文档。当用户要求"整理 ALV 字段清单""导出报表列字段""梳理报表字段/表结构""生成字段说明文档"时使用；仅适用于经典 ABAP（REUSE_ALV_GRID_DISPLAY / CL_GUI_ALV_GRID）报表与本地 dictionary HTML，不适用于 Fiori/CDS/RAP。
agent_created: true
---

# ABAP 报表 ALV 字段清单提取

## 输入约定

用户通常会提供两类文件（本技能默认它们已在工作区）：

1. **报表源码**：从 SAP 用 Mass Download 导出的 `.txt`，含 `REPORT` 语句、`FORM frm_fieldcat`、`FORM frm_alv_show`、选择屏幕定义。
2. **表字典**：`dictionary/*.html`，每张表一个文件，由 SAP 数据字典导出工具生成。

若缺字典文件，跳过"类型/长度"列，只输出源码能确定的信息，并明确说明缺失。

## 步骤

### 1. 复制源码到工作区并以 UTF-8 保存

Mass Download 导出的文件常为 GBK/ANSI（含中文注释）。若直接读取出现乱码，先用 Python 转码：

```python
data = open(src, 'rb').read()
for enc in ('utf-8', 'gbk', 'gb18030', 'latin-1'):
    try:
        text = data.decode(enc); break
    except UnicodeDecodeError:
        continue
open(dst, 'w', encoding='utf-8').write(text)
```

若 Read 工具报 "Output too large"，结果会被持久化到 tool-results 目录，**直接 Read 原文件并分 offset 读取**，不要反复重读大文件。

### 2. 定位 ALV 列定义，取列顺序

用 Grep 找 `FORM frm_fieldcat`、`m_fieldcat`、`fieldname`、`REUSE_ALV_GRID_DISPLAY`。

关键点：**列顺序 = 源码中宏（`DEFINE m_fieldcat` / `add_fieldcat` 之类）的调用顺序，不是表结构顺序**。必须逐行按调用顺序抄下来，不能按字典字段顺序重排。

同时读 `FORM frm_alv_show` 取布局参数（`box_fname`、`sel_mode`、`cwidth_opt`、`i_callback_pf_status_set`），其中 `box_fname` 会在最前面**额外生成一列复选框**，fieldcat 里同名的 BOX 条目通常已被注释掉——不要漏也不要重复计入。

用逐行注释 `*  m_fieldcat 'XXX'` 找出**已废弃未输出的列**，在文档里单列一节，这对判断版本演进很有价值。

### 3. 解析字典 HTML 取类型与长度

字典 HTML 的结构固定：每个字段一个 `<tr class="cell">`，内含 10 个 `<td>`：

序号 | 字段名 | 位置 | 键 | 数据元素 | 域 | 类型 | 长度 | 小写 | 域文本

```python
import re, html
src = open(path, encoding='utf-8', errors='replace').read()
rows = re.findall(r'<tr class="cell">(.*?)</tr>', src, re.S)
for r in rows:
    tds = [html.unescape(t).replace('\xa0', '').strip()
           for t in re.findall(r'<td>(.*?)</td>', r, re.S)]
    # tds[1]=字段名 tds[3]=键 tds[4]=数据元素 tds[6]=类型 tds[7]=长度 tds[9]=域文本
```

注意 HTML 头部声明的是 ISO-8859-1，但实际内容含中文，按 utf-8 读取通常正确；读出乱码时再试 gbk。

Python 解释器用托管版本：`C:\Users\garso\.workbuddy\binaries\python\versions\3.13.12\python.exe`。
本环境的 Bash 里 `ls` / `wc` / `dirname` 可能不可用（shell 包装器问题），**避免在 Bash 中调用这些命令**，改用 Glob / Read / Grep 工具。

### 4. 校验字段来源，标出不一致

务必交叉核对，这几类问题在遗留代码里很常见，是清单的核心价值：

- **参考表标注错误**：`ref_table` 写的表里根本没有该字段（字段实际在另一张表，或由运行期 `SELECT` 填充）。
- **类型不一致**：ALV 输出结构（`TYPES ... INCLUDE STRUCTURE` + 追加字段）与落库表的同名字段类型不同（如 `P(16)DEC8` vs `CURR(23)`），保存时靠隐式转换。
- **借用类型**：多个计算列复用同一个 `ref_field`（如都用 `ZFIT0047-HSL_BYCBJ`），并非同名字段。
- **参考为空的列**：多为结构字段或运行期赋值字段，ALV 不会自动带出显示属性。
- **宏内被注释的属性**：`no_zero`、`checkbox`、`edit`、`hidden` 若被注释则实际不生效。
- **数据被改写过**：如源码里对 `MATNR` 做了 `ALPHA = OUT`，则导出值与 SE16 原始值不一致。

### 5. 输出文档

默认输出 Markdown 文件到项目根目录，命名 `<程序名>_ALV字段清单.md`。用户明确要求 Excel/Word 时再走对应的 Office 生成技能。

结构：

1. 程序信息 + 列定义位置（**带源码行号**）+ 布局参数表
2. 主清单表：`# | 字段名 | ALV 列标题 | 类型(长度) | 参考表-字段 | 来源与说明`
3. 口径与注意事项（第 4 步查出的问题，逐条列出）
4. 列与业务动作的对应关系（哪些列进了凭证、回写到哪列）
5. 附录：选择屏幕字段

"来源与说明"列要写**可验证的事实**（来自哪张表、由哪个 FORM 计算、公式是什么），不要写"相关字段""业务数据"这类空话。涉及计算的列，把公式原样写出来。

## 交付

完成后调用 present_files 展示 md 文件，并在回复里点出最值得注意的 2–3 个发现（尤其是类型不一致、参考表错误这类会埋坑的问题）。
