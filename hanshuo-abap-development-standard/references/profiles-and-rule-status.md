# 环境档案与规则状态

## 使用范围

每次使用本 Skill 时先读取，用于确定哪些规则真正适用。没有选定档案前，不得把 V1.0 经典规则作为当前系统的统一强制规则。

## 规则状态

| 状态 | 含义 | 执行方式 |
|---|---|---|
| `REQUIRED` | 当前档案的强制要求 | 不符合即报告或修复；不能无声跳过 |
| `RECOMMENDED` | 默认推荐 | 有更合适方案时可偏离，但说明原因和影响 |
| `CLASSIC_ONLY` | 仅经典 ABAP/ECC 基线适用 | 不套用到 ABAP Cloud；S/4 需结合档案判断 |
| `SUPERSEDED` | 已被现代规则取代 | 仅用于解释历史代码，不作为新开发要求 |
| `PROJECT_CONFIG` | 必须由项目或目标系统确定 | 查项目资料或系统，不能自行虚构 |
| `SOURCE_CONFLICT` | V1.0 原文内部冲突 | 查既有对象或补充规范；仍不明确时请求用户决定 |

客户或项目规则覆盖公司规则时，在交付结论中记录覆盖的规则和依据。SAP 平台硬限制、安全要求和 Released API 限制不能被低层规则覆盖。

## 环境档案

### `CLASSIC_ECC`

适用于 ECC、传统 SAP GUI、经典 Report/Module Pool/Function Group、传统 DDIC 和经典增强。

- V1.0 对象命名、Include、参数前缀、Pretty Printer 和经典传输规则默认适用。
- `FORM`、Function Module、`TABLES` 参数和传统消息异常模式允许用于既有架构；新建前仍评估是否可用类和方法简化。
- SLIN、SCI/Code Inspector 可作为质量工具；目标系统支持 ATC 时优先纳入 ATC。
- 不因经典档案继续采用 Header Line、`OCCURS` 或已明确 obsolete 的语法。

### `S4_CLASSIC`

适用于 S/4HANA On-Premise/Private Edition 中仍使用经典语言版本和经典扩展的包。

- 保留兼容所需的 V1.0 规则，但新开发优先类、接口、现代 Open SQL、CDS View Entity 和 ADT。
- 禁止把“JOIN 不超过两个表”“WHERE 字段顺序决定性能”“统一 SORT + BINARY SEARCH”等 V1.0 经验规则作为硬门禁。
- 使用 ATC 检查 S/4HANA 兼容性、性能、安全和可迁移性。
- 直接访问或增强 SAP 标准对象前，先查可用的 Released API 和扩展点。

### `S4_CLEAN_CORE`

适用于以 Clean Core 为目标的 S/4HANA On-Premise/Private Edition。

- Tier 1：优先 ABAP Cloud 开发模型，只使用 Released API 和 Released Extension Point。
- Tier 2：确无 Released API 时，用隔离、窄接口封装未发布对象，并记录替换路线和 ATC 结果。
- Tier 3：经典开发仅作为经过批准的例外，隔离影响并记录退出计划。
- 数据模型优先 CDS View Entity；事务应用和服务优先 RAP。
- 经典 V1.0 命名只能约束实际使用的经典对象，不能驱动架构退回经典实现。

### `ABAP_CLOUD`

适用于 SAP BTP ABAP Environment、S/4HANA Cloud ABAP Environment 或语言版本为 ABAP for Cloud Development 的包。

- 只使用目标环境允许的语法、Repository 对象和 Released API。
- 使用 ADT、CDS、RAP、服务定义/绑定及云允许的扩展机制。
- 不新建经典 Report/Module Pool/Function Group/FORM、传统隐式增强或其他目标语言版本不允许的对象。
- V1.0 的函数组、Include、`TABLES`、CMOD、SmartForm、SE80/SE38/SE93 等规则标记为 `CLASSIC_ONLY`，不作为 Cloud 实现方案。
- ATC Cloud-ready 检查和 ABAP Unit 属于交付门禁。

## 档案判定证据

按以下顺序确认：

1. 项目 `AGENTS-Proj.md`、架构文档或客户开发规范中的明确声明。
2. 软件组件、开发包的 ABAP Language Version、API State 和目标系统版本。
3. 当前对象类型、同包既有实现及配置的 ATC Variant。
4. 用户明确说明。

仅凭目录名、事务代码或“正在做 S/4 项目”不能判定为 ABAP Cloud。若档案影响对象类型、API 或兼容策略且证据不足，先询问用户。

## V1.0 规则迁移表

| V1.0 规则 | 当前状态 | 现代执行方式 |
|---|---|---|
| `G_/L_/GT_/LS_/IM_/EX_` 等全量前缀 | `CLASSIC_ONLY` | 经典档案按项目执行；现代档案优先业务语义名称 |
| FORM、子程序池、函数组拆分 | `CLASSIC_ONLY` | 新开发优先类、接口和短方法 |
| 函数/方法统一 `MESSAGE ... RAISING` | `CLASSIC_ONLY` | 可复用层用类异常或结果类型，系统边界再映射消息 |
| JOIN 最多两个表 | `SUPERSEDED` | 根据数据模型、选择性、下推和执行计划决定 |
| WHERE 字段按索引顺序 | `SUPERSEDED` | SQL 保持清晰，使用目标系统执行计划和测量判断 |
| 标准表统一 SORT 后 BINARY SEARCH | `SUPERSEDED` | 按访问模式选择 Sorted/Hashed/Secondary Key 或显式排序查找 |
| 配置表必须完全缓存 | `SUPERSEDED` | 根据读写比例、表大小、失效频率和一致性选择缓存策略 |
| 所有数据库更新必须 Update Task | `SUPERSEDED` | 由事务所有者决定 LUW；只在需要更新任务语义时使用 |
| 对话屏幕字段使用 `TABLES` | `CLASSIC_ONLY` | 仅经典 Dynpro 兼容；现代代码使用目标语言允许的声明 |
| 修改代码保留注释掉的旧实现 | `CLASSIC_ONLY` | 有强制审计要求时保留；现代受版本管理项目删除死代码 |
| 增强点必须调用函数模块 | `CLASSIC_ONLY` | 薄增强层调用可测试类/服务；经典方案可保留增强函数 |
| `MANDT` 必须作为第一关键字段 | `CLASSIC_ONLY` | 经典 client-dependent DDIC 表执行；CDS/RAP/Cloud 按对象客户端模型 |
| `ZHS`、`ZHS01`、固定权限组和 CMOD 项目 | `PROJECT_CONFIG` | 创建前在当前系统确认存在性和归属 |
| 域、SmartForm 文本模块命名冲突 | `SOURCE_CONFLICT` | 查既有对象或请求项目决定 |
| `ZINTF_MESSAGE` 双消息参数 | `CLASSIC_ONLY` | 适用于汉硕经典 RFC；新服务定义独立版本化错误契约 |

## 官方依据

最后核验：2026-09-11。

- ABAP Cloud Development Model：https://help.sap.com/docs/abap-cloud/abap-cloud-background-concepts-and-overview/abap-cloud-development-model
- Public Released APIs：https://help.sap.com/docs/abap-cloud/abap-cloud/public-released-apis
- SAP Clean Core 三层模型背景：https://help.sap.com/doc/112b8531132e43398ed50b2ad38ab14b/latest/en-US/ffa919727c624f25a95bd2f9443244f4.pdf
