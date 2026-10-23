---
name: fastreport-frx-verify
description: 离线校验 FastReport .frx 报表模板的版式与取数，不需要跑起后端、不连数据库、不需要真实打印机。当需要新建或修改 .frx 模板、怀疑报表页脚位置/数据带次数/主从取数不对、或要验证模板引用的字段名与模型是否对得上时使用。触发词：frx 校验、报表模板验证、FastReport 版式、页脚位置不对、打印模板调试、明细带重复。
agent_created: true
---

# FastReport .frx 离线渲染校验

## 为什么需要它

`.frx` 是 XML，但**版式正确性无法从 XML 读出来**。「改完看着没问题」「跑起来没报错」都不能说明版式对——
FastReport 对**引用不存在的列**是**静默忽略**的，不抛异常、不写日志，表达式直接退回默认行为。

所以唯一可靠的验证方式：**离线渲染 + 逐对象坐标转储**，把每个文本对象在第几页、落在什么 y/x、渲染出什么文字全部打出来。

## 硬前置：包版本必须与后端一致

脚手架必须引用**和目标项目完全相同的 FastReport 包版本**。版本不一致会报
`FileNotFoundException: System.Drawing.Common, Version=4.0.2.0`（FastReport 的传递依赖版本对不上）。

```xml
<!-- 先去后端查实际版本，不要抄这个数字 -->
<PackageReference Include="FastReport.Core" Version="2022.3.15" />
```

查版本：

```bash
grep -rn "FastReport" <backend>/**/*.csproj
```

失败症状与对策对照：

| 报错 | 原因 | 对策 |
| --- | --- | --- |
| `FileNotFoundException: System.Drawing.Common` | 包版本与后端不一致 | 对齐包版本（首选）；或加 `AppDomain.CurrentDomain.AssemblyResolve` 钩子回退加载后端 `bin` |
| `CS0246: 找不到 PDFExport` | 缺 using | `using FastReport.Export.Pdf;` |
| `CS1503` / `CS1061: ChildObjects` | `ChildObjects` 元素是 `object`；`Base` 上无 `AbsTop` | `if (item is not FastReport.Base child) continue;` + 判断 `child is FastReport.TextObject` |

## 步骤

### 1. 建脚手架

一个独立控制台项目（放 `tmp/<名字>/` 即可，**不要**放进业务项目、**不要**提交 `bin/obj`）。
最小项目模板见 `assets/FrxCheck.csproj`（已实测可用）：

```
tmp/frxcheck/
  FrxCheck.csproj      # net8.0 或与后端一致；引用 FastReport.Core
  Program.cs           # 加载 frx → 注入假数据 → Prepare() → 转储 → 导 PDF
  variants/            # 对照实验用的模板变体
```

一份完整的参考实现（含逐对象坐标转储、对照实验框架、假数据构造）在 `D:\Projects\MINIERP\tmp\frxcheck\Program.cs`。

### 2. 假数据要覆盖「会出问题的那一档」

**关键：假数据必须复现最恶劣的结构**，否则测不出来。经验是至少构造：

- 一张**含 2 个明细段**的单据（考验页脚是否被吞 / 是否重复出）
- 一张**只含 1 个段**的单据（考验是否多出一遍）
- 合计数字**各不相同**（`50/140` vs `15/40`），这样一眼能看出页脚取到的是哪张单的数

取数是否正确，靠**数字对得上**判断，不能靠"有页脚"判断。

### 3. 注册数据 + Prepare

按模板里声明的数据源名注册（`RegisterData(列表, "别名")`），逐个 `GetDataSource(name).Enabled = true`，然后 `Prepare()`。

### 4. 逐页转储对象坐标（校验的核心）

按**页序**遍历已排版页面，打印每个文本对象的 `AbsLeft/AbsTop/Width` 与渲染文本：

```csharp
foreach (var page in report.PreparedPages) {          // 逐页
    foreach (var obj in page.AllObjects) {            // 页内全部对象
        if (obj is not FastReport.TextObject text) continue;
        Console.WriteLine($"p{pageNo} y={text.AbsTop:F2} x={text.AbsLeft:F2} w={text.Width:F2} | {text.Text}");
    }
}
```

判读方式（这是真正有价值的部分）：

- **y 坐标的先后顺序 = 打印顺序**。页脚 y 比明细小 → 页脚跑到明细前面了（次数对但位置错）。
- **同一段文字在第 1 页出现几次** → 直接看出「每段各出一遍」这类重复。
- **页脚里的数字** → 和第几张单的合计数比对，判断有没有取到下一张单的数据。

### 5. 导出 PDF 留存证据

`report.Export(new PDFExport(), path)`，产物作为可复查的证据，不要只靠控制台输出。

## 陷阱清单（都是实测踩过的）

1. **`BusinessObjectDataSource/Column` 是白名单。** 模型上多出来的属性**不会**自动进模板字典；表达式引用未声明的列会**静默失效**。想用某字段，必须先在 frx 里声明该 `<Column>`，再重新注册数据。
2. **主从带的「单据级页脚」不是挂哪都行。** 在 `M → O → D` 三层主从下，页脚要「每张单据恰好一次且位于明细之后」，实测（FastReport 2022.3.15）：

   | 挂法 | 结果 |
   | --- | --- |
   | `DataFooterBand` 挂主带 M | 单据段数 > 1 时**整段被丢掉**；加 `KeepWithData` 无效 |
   | `ChildBand` 挂主带 M | 次数对、取数对，但落在明细**之前** |
   | `DataFooterBand` 挂明细段带 O | 变成**每段各出一遍**整单合计 |
   | 上者 + `Visible="[O.IsLastOrder]"` | 表达式**被静默忽略**，仍每段一次 |
   | `PageFooterBand` | 每页一次，但**取到下一张单据的数**——错数据比缺页脚更糟 |
   | **单独一个"每单一行"的数据源 F + `Relation M_F`，作为明细段带的兄弟带** | **唯一正确** |

   后端可**把同一份主列表按别名 `F` 再注册一次**，不必另造重复模型。

3. **编码是反向约定。** 源码文件通常 UTF-8 无 BOM + CRLF，但 **`.frx` 是 UTF-8 带 BOM + CRLF**。用同一套归一化规则处理会破坏模板。
4. **Python 读写要关掉换行转换。** `io.open(path, "rb")` 或加 `newline=""`；默认的文本模式会把 `\r\n` 归一成 `\n`，导致按 `\r\n` 做的字符串匹配**全部静默失配**（表现为"替换没生效"但没有任何报错）。
5. **对照实验要真的变更。** 生成变体后先 `diff` 一眼确认文件确实不同——否则可能整轮实验都在测同一个模板。
6. **固定列数表头。** 若模板把尺码列**写死**（如 10 列），超出会直接报错而不是截断；这个上限通常由后端常量（如 `MaxPrintSizeCount`）和模板共同决定，两边要一起改。

## 边界

离线渲染只能证明**版式和取数逻辑**正确。它**不能**替代：

- **HTTP 实测**（接口鉴权、参数绑定、文件名编码）
- **真实打印机试打**（纸张尺寸、边距、字体替换）
- **真实数据下的取数正确性**（假数据覆盖不到的口径问题）

交付时必须把这三项明确列为未验证项，不要用"离线 PASS"冒充"功能完成"。
