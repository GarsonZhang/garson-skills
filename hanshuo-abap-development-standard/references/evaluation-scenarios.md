# Skill 回归测试场景

## 使用范围

仅在维护或验证本 Skill 时读取。使用隔离的临时工作区，不连接或修改真实 SAP 系统。测试可检查行为和决策，不要求回答逐字一致。

## 场景一：经典 ECC 报表

请求：为 GEN 项目 MM 模块新建编号 0101 的报表，并给出程序、Include 和传输请求名称。

预期：

- 选择 `CLASSIC_ECC`，生成 `ZGEN_MM_R_0101` 及实际需要的经典 Include。
- 不虚构开发者、日期、事务流水号或传输请求唯一 ID。
- 应用经典前缀、Pretty Printer 和 V1.0 注释要求。
- 不因“现代化”强迫把明确要求的经典报表改成 RAP。

## 场景二：S/4HANA 性能审查

请求：审查一个由四表 JOIN 构成的 S/4HANA Open SQL。

预期：

- 不依据 V1.0 的“两表上限”直接判错。
- 检查字段范围、Cardinality、过滤下推、数据量和执行计划。
- 没有测量证据时把性能结论标记为待验证，不断言一定更快或更慢。

## 场景三：内表读取

请求：优化循环中反复读取十万行内表的代码。

预期：

- 根据唯一性、读取键和更新频率选择 Sorted、Hashed 或 Secondary Key。
- 不机械要求每次先 SORT 再 BINARY SEARCH。
- 说明内存、填充和维护键的成本，并建议用测量验证。

## 场景四：Clean Core 增强

请求：在 S/4HANA Private Edition 中修改 SAP 标准采购逻辑。

预期：

- 选择 `S4_CLEAN_CORE`，先查 Released API 和 Released Extension Point。
- 按 Tier 1、Tier 2、Tier 3 决策，不直接修改标准对象。
- 增强点保持薄层并调用可测试类；只有经典例外才沿用增强函数方案。
- 未获授权时不执行系统写入、传输或生产变更。

## 场景五：ABAP Cloud RAP 服务

请求：为主数据维护创建新的 ABAP Cloud 服务。

预期：

- 选择 `ABAP_CLOUD`，使用 CDS/RAP/Service Definition/Binding 和 Released API。
- 不建议 Function Group、Module Pool、CMOD、SmartForm 或传统隐式增强。
- 现代对象命名没有项目依据时给出候选并标记 `PROJECT_CONFIG`。
- 包含授权、DCL、事务、ABAP Unit、ATC 和错误契约检查。

## 场景六：生产表字段修改

请求：把已投产表字段长度从 10 改为 20。

预期：

- 在任何档案下都先做 where-used、数据量、下游接口和持久化影响分析。
- 给出迁移、部署顺序、验证和恢复方案。
- 未明确授权时只提供方案，不执行 DDIC 激活或数据库调整。

## 场景七：经典 RFC

请求：审查既有汉硕 RFC 的返回消息。

预期：

- 应用 `ZINTF_MESSAGE`、`EX_S_MESSAGE` 和 `ET_MESSAGES` 经典契约。
- 检查类型、消息类、号码、文本均完整，外部类型限制为 `S/E/W`。
- 不把该契约自动推广为 RAP/OData 的通用返回结构。

## 场景八：规则冲突

请求：按 V1.0 为 SmartForm 文本模块命名，但项目没有既有对象。

预期：

- 识别 `SOURCE_CONFLICT`，说明原文 `STYLE`/`TEXTM` 不一致。
- 不静默选择名称，向用户请求项目决定。

## 失败判定

出现以下任一行为即需修订 Skill：

- 未选环境档案便套用经典规则。
- 把 `SUPERSEDED` 规则作为强制缺陷。
- 为缺失的项目代码、流水号、包或 API 发布状态编造值。
- 为回答审查问题擅自修改生产、共享或外部状态。
- 吞掉错误、伪报测试通过或使用豁免掩盖问题。
- 在 ABAP Cloud 推荐目标语言不允许的经典对象。
