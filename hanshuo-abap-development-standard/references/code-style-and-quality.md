# 代码风格与质量规则

## 使用范围

编写、修改或审查 ABAP 源码时读取。内容对应原 PDF 第 13 章（页 46-81）。未标注的规则在目标语言允许时作为公司经典基线；现代档案同时读取 [modern-abap-and-clean-core.md](modern-abap-and-clean-core.md)。

以下内容中，全量类型/作用域前缀、FORM、函数模块经典异常、源码修订块和 SAP GUI Pretty Printer 属于 `CLASSIC_ONLY`。禁止 Header Line、`OCCURS`、无语义名称、无依据吞错和未使用对象属于所有档案的 `REQUIRED`。

## 选择屏幕和声明

- `SELECT-OPTIONS`：`S_<name>`。
- 普通 `PARAMETERS`：`P_<name>`。
- Listbox：`LB_<name>`；Checkbox：`CB_<name>`；Radio button：`RB_<name>`；Pushbutton：`PB_<name>`。
- 选择屏幕名称受目标 SAP 系统长度限制；不要截断出无法辨认的名称。

数据定义原则：

- 只定义实际需要的类型和对象；局部专用对象不提升为全局。
- 一个过程需要过多局部对象时，按职责继续拆分过程。
- 名称必须表达含义，不使用 `i`、`n` 等无语义名称。
- 内表不使用 Header Line，不使用 `OCCURS` 预分配。
- 传输生产前通过扩展检查删除未使用对象。

## 类型与变量前缀（`CLASSIC_ONLY`）

| 类别 | 全局 | 本地 |
|---|---|---|
| 一般类型 | `TY_<name>`（原文称一般为全局） | 按项目同类规则，原文未单列 |
| 结构类型 | `GS_TYPE_<name>` | `LS_TYPE_<name>` |
| 内表类型 | `GT_TYPE_<name>` | `LT_TYPE_<name>` |
| 一般引用类型 | `G_REF_TYPE_<name>` | `L_REF_TYPE_<name>` |
| 结构引用类型 | `GS_REF_TYPE_<name>` | `LS_REF_TYPE_<name>` |
| 内表引用类型 | `GT_REF_TYPE_<name>` | `LT_REF_TYPE_<name>` |
| 对象引用类型 | `GO_REF_TYPE_<name>` | `LO_REF_TYPE_<name>` |
| 对象实例类型 | `GO_TYPE_<name>` | `LO_TYPE_<name>` |
| 一般变量 | `G_<name>` | `L_<name>` |
| 结构变量 | `GS_<name>` | `LS_<name>` |
| 内表变量 | `GT_<name>` | `LT_<name>` |
| Range 变量 | `GR_<name>` | `LR_<name>` |
| 一般引用 | `G_REF_<name>` | `L_REF_<name>` |
| 结构引用 | `GS_REF_<name>` | `LS_REF_<name>` |
| 内表引用 | `GT_REF_<name>` | `LT_REF_<name>` |
| 对象引用 | `GO_REF_<name>` | `LO_REF_<name>` |
| 对象实例 | `GO_<name>` | `LO_<name>` |
| 常量 | `C_<name>` | `LC_<name>` |

经典固定全局常量：`YES = 'X'`、`NO = space`、`TRUE = 'X'`、`FALSE = space`、`ON = '1'`、`OFF = '0'`，以及参照 `SYUCOMM` 的 `OKCODE`。只声明实际需要的常量。现代档案优先使用目标版本支持的标准布尔类型和 `abap_true`/`abap_false`，不重复声明同义常量。

## 本地类、Field Symbol 和子程序

- 本地类 `LCL_<name>`，本地接口 `LIF_<name>`；放在 `CLS` Include。
- 本地类方法 `M_<name>`、属性 `A_<name>`、事件 `EV_<name>`；其他成员规则与全局类一致。
- Field Symbol 沿用对应对象前缀并加尖括号：一般 `<G_...>/<L_...>`，结构 `<GS_...>/<LS_...>`，内表 `<GT_...>/<LT_...>`，引用 `<G_REF_...>` 等，对象实例 `<GO_...>/<LO_...>`。
- `CLASSIC_ONLY`：子程序名 `FRM_<name>`。调用方在 `PERFORM` 前判断是否需要执行，不把是否执行的总开关藏在 FORM 内部。现代档案不新建 FORM，优先职责单一的方法。

子程序参数属于 `CLASSIC_ONLY`：

| 方向 | 一般 | 结构 | 内表 | 对象 | 一般引用 | 结构引用 | 内表引用 | 对象引用 |
|---|---|---|---|---|---|---|---|---|
| USING | `U_` | `US_` | `UT_` | `UO_` | `U_REF_` | `US_REF_` | `UT_REF_` | `UO_REF_` |
| CHANGING | `C_` | `CS_` | `CT_` | `CO_` | `C_REF_` | `CS_REF_` | `CT_REF_` | `CO_REF_` |
| TABLES | `TI_` 输入 | - | `TE_` 输出 / `TC_` 可修改 | - | - | - | - | - |

参数按实际对象使用 `TYPE`（或有明确对象依据时用 `LIKE`），尽量避免 `ANY`、`CLIKE` 等泛型。

## 文本、控件和消息

- 文本元素优先写为带文本符号的文字字面量，如 `'Please Enter Your Name'(001)`，而不是孤立的 `TEXT-001`，提高可读性。
- Table Control：`CTRL_<SCREEN_NUMBER>_<DESCRIPTION>`。
- 每条程序消息明确消息类和消息号，便于 where-used 定位。
- `CLASSIC_ONLY`：经典函数或方法中的错误除特殊增强限制外，用 `MESSAGE E... RAISING <exception>` 同时返回消息与异常；不得只 `MESSAGE` 或只 `RAISE`。
- 调用过程必须接收并按上下文处理全部声明失败。经典调用只有在被调过程确实使用 `MESSAGE ... RAISING` 时才能沿用系统消息；现代可复用层使用类异常或明确结果类型，在 UI/RFC/OData 边界映射消息。
- 消息收集场景仍需保留对应消息类/号码的静态引用，便于 where-used；使用不可达代码时写明原因。
- 前台程序原则上不发布 `X` 或 `A` 消息；`E` 消息后必须允许用户更正。

## 数据簇与宏

- `IMPORT`/`EXPORT` 数据簇必须成对封装在职责明确、带上下文注释的函数中；同一函数组内使用相近名称并以 `IMP`/`EXP` 区分。
- 按需要提供 `FREE` 或 `DELETE` 函数，并通过 where-used 保持数据簇读写可追踪。
- 除确需动态处理外不使用宏；必须使用时命名为 `M_<name>`。宏不可调试且导入后占用内存。

## 控制流和内表

- V1.0 建议按条件命中概率排列嵌套 `IF`、`AND` 和 `OR`；当前将其标记为 `CLASSIC_ONLY` 性能建议。现代代码优先业务可读性、Guard Clause 和短方法，只有测量证明条件顺序重要时才按成本或概率调整。
- 对同一对象做多个等值判断时用 `CASE`，不写长 `ELSEIF` 链。
- 已知 LOOP 条件或索引范围时写在 `LOOP ... WHERE` 或 `FROM ... TO` 中，不在循环体内重复过滤。
- `SORT` 明确列出排序字段。
- `SUPERSEDED`：不再统一要求标准内表先排序再 `BINARY SEARCH`。根据唯一性、读取键、数据量和更新频率选择 Standard、Sorted、Hashed 或 Secondary Key；只有 Standard Table 确需临时二分查找时，才保证排序键与读取键一致后使用 `BINARY SEARCH`。
- 记录数用 `LINES( )` 或 `DESCRIBE TABLE`，不循环计数。

## Open SQL 与内存

- 不使用嵌套 `SELECT`。
- `SUPERSEDED`：原规范的 JOIN 不超过两个表不再作为门禁。根据数据模型、选择性、Cardinality、下推能力和执行计划判断；拆分查询也必须评估额外数据库往返和应用层关联成本。
- `SELECT` 只列出需要字段，不用无依据的全字段读取。
- `SUPERSEDED`：不以 `WHERE` 文本字段顺序认定索引优化完成。SQL 保持清晰，并以目标数据库的执行计划和测量结果验证。
- `RECOMMENDED`：V1.0 将 Range 条件超过 5000 条作为拆分预警；当前应结合目标系统限制、数据分布和执行计划决定，拆分时同时控制数据库往返次数。
- 减少数据库往返，避免重复连接和重复查询。
- 内表结构只包含实际需要字段，不为方便直接声明整个宽表结构。

## 屏幕输出与废弃语法

- ALV 或 Table Control 输出内表必须参考 DDIC 结构、表或视图。
- `CLASSIC_ONLY`：原规范要求对话屏幕的单字段输入/输出对象通过 `TABLES` 引用 DDIC 对象。只在经典 Dynpro 兼容场景使用；现代代码按目标语言允许的声明实现。
- 不使用 ABAP Keyword Documentation 标记为 obsolete 的语句和概念。原文列举：`RANGES`、`BEGIN OF ... OCCURS`、`CALL DIALOG`、`SEARCH`、`ON CHANGE OF`。

## 注释与修订追踪

`CLASSIC_ONLY`：主程序、函数组 TOP、函数模块和方法按 V1.0 使用对象抬头，至少包含：

- Object 名称和功能描述。
- 版本/项目、需求或问题号、程序员、日期、问题描述、传输请求 ID。
- 新建时问题描述可写“新创建程序”；修改时增加修订记录并同步功能描述。

增强相关函数在抬头下增加 `Enhancement context`：列出相关函数、增强方式和执行顺序。

`CLASSIC_ONLY`：项目仍要求源码审计块时，大段新增或修改代码使用成对的开始/结束注释，包含操作类型、人员、日期和传输请求；简短修改可在行尾标记传输请求。现代受版本管理项目不复制提交历史、不保留注释掉的旧实现；只有客户审计规则明确要求时才保留修订块。

一般性注释至少覆盖：非固定常量、不可达代码、硬编码、重要 `IF`/`CASE` 分支；重点解释原因和业务背景。

## 排版与静态检查

- 每条 ABAP 指令独立一行；不使用冒号语句链把多个声明或指令写在同一行。
- 含多个附加关键字、操作符或逻辑符号的声明、消息、条件、运算和 SQL 按语义分行并对齐。
- `CLASSIC_ONLY`：SAP GUI Pretty Printer 启用 `Indent`、`Convert Uppercase/Lowercase` 和 `Keyword Uppercase`。ADT/ABAP Cloud 使用项目格式化配置。
- 所有档案以项目 ATC Variant 为主要静态门禁；经典系统可补充扩展语法检查和 Code Inspector。错误不允许保留，警告和消息逐项处理。
- 只有确认检查结果确属设计所需，且记录原因、责任人和有效期时，才按检查器提示使用伪注释或豁免；不得批量掩盖真实问题。
