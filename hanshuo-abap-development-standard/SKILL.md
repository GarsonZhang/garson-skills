---
name: hanshuo-abap-development-standard
description: "按汉硕公司规范和目标 SAP 环境设计、编写、修改或审查经典 ABAP、S/4HANA、Clean Core、ABAP Cloud、CDS、RAP、DDIC、增强、RFC、接口与传输。客户或项目已有更高优先级规范时以其为准。"
---

# 汉硕公司 ABAP 开发规范

## 目标

把汉硕 V1.0 经典开发基线与当前 SAP 开发模型结合，落实到具体方案、代码、对象命名和审查结论中。先选择目标环境，再应用规则；不能把 ECC 时代约定无条件套用到 S/4HANA、Clean Core 或 ABAP Cloud。

## 规则优先级与适用边界

1. SAP 平台、ABAP Language Version、Released API、对象类型和安全限制属于硬约束。
2. 在硬约束内，用户当前明确要求、客户规范和项目内生效规则优先于本 Skill。
3. 再按选定环境档案应用现代公司规则；没有现代规则覆盖的经典对象，才回退到汉硕《SAP 系统开发规范及指引》V1.0。
4. 每条规则按 `REQUIRED`、`RECOMMENDED`、`CLASSIC_ONLY`、`SUPERSEDED`、`PROJECT_CONFIG` 或 `SOURCE_CONFLICT` 解释，定义见 [references/profiles-and-rule-status.md](references/profiles-and-rule-status.md)。
5. 原规范发布于 2018-12-11。原文中的强制措辞只在其适用档案内保持强制，不得覆盖更高层规则或现代平台限制。
6. 不因合规审查擅自重命名已投产对象、修改生产 DDIC 结构、执行传输或数据库变更。此类操作需要影响分析、迁移与恢复方案以及明确授权。

## 工作流程

1. 确认任务类型、目标系统和 ABAP Language Version，并按 [references/profiles-and-rule-status.md](references/profiles-and-rule-status.md) 选择 `CLASSIC_ECC`、`S4_CLASSIC`、`S4_CLEAN_CORE` 或 `ABAP_CLOUD`。无法从包、对象、配置或项目文档确认，且档案会改变方案时才询问用户。
2. 确认对象类型、模块、项目代码、开发类型、开发编号、需求/JIRA 编号和是否已投产。检查客户规范、项目规则和既有同类对象；说明覆盖关系和影响。
3. 按任务读取相关参考：
   - 经典项目编号、传输、开发类和对象名称：读 [references/governance-and-object-naming.md](references/governance-and-object-naming.md)。
   - 通用与经典代码风格：读 [references/code-style-and-quality.md](references/code-style-and-quality.md)。
   - S/4HANA、Clean Core、CDS、RAP 或 ABAP Cloud：读 [references/modern-abap-and-clean-core.md](references/modern-abap-and-clean-core.md)。
   - 增强、DDIC、数据库更新、视图和 RFC：读 [references/enhancement-ddic-and-rfc.md](references/enhancement-ddic-and-rfc.md)。
   - 编写、修改或审查任何可执行代码、服务或数据访问：读 [references/security-testing-and-delivery.md](references/security-testing-and-delivery.md)。
   - 评审或交付前：读 [references/review-checklist.md](references/review-checklist.md)。
   - 仅在维护或回归测试本 Skill 时：读 [references/evaluation-scenarios.md](references/evaluation-scenarios.md)。
4. 新建对象时只使用选定档案允许的对象类型和 API。从已批准规则生成候选名称，解释组成来源；不得虚构流水号、包、发布状态或项目代码。现代对象没有公司命名规则时提出候选并标记 `PROJECT_CONFIG`，不能冒充正式规范。
5. 修改对象时先做 where-used、调用链、持久化数据、接口、权限、事务和传输影响分析。保留无关既有改动，不借机全量改名或格式化；现代项目不保留被注释掉的旧代码作为版本历史。
6. 实现后执行目标系统可用的语法检查、ABAP Unit 和项目 ATC Variant；经典系统再按需使用扩展语法检查或 Code Inspector。错误必须清零；警告和消息逐项处理，豁免必须有依据、责任人和有效期。
7. 最终给出：选定档案、执行结果、采用的规则、验证、未决冲突或风险。审查任务按“位置/对象 - 规则编号或来源 - 影响 - 建议修复”输出，未发现问题时说明检查范围和未执行项。

## 默认必须守住的规则

- 客户化对象使用目标系统允许的客户命名空间；经典对象按公司 `Z/Y` 规则，ABAP Cloud 还必须遵守发布契约和包语言版本。
- 数据和类型保持最小作用域，不使用 Header Line、`OCCURS` 或目标语言版本中的 obsolete/forbidden 对象与语法。
- 名称表达业务含义。经典前缀只在经典档案或项目明确要求时强制，现代代码不为编码类型、作用域和参数方向牺牲可读性。
- 数据访问只取所需字段，避免循环内数据库访问和重复往返；JOIN、CDS 下推、内表种类和键根据实际访问模式与测量结果选择，不使用固定数量或固定算法作为万能规则。
- 可复用业务层使用可识别的异常或结果类型，不直接耦合前台消息；在 RFC、OData 等系统边界映射为稳定、完整的错误契约。
- 增强点保持薄层；经典档案可调用增强函数，现代档案优先调用可测试的类或已发布服务。
- 数据库更新必须有明确的事务所有者、SAP LUW 边界和失败恢复策略；只有确实需要 Update Task 语义时才使用 `IN UPDATE TASK`，不能在可复用组件中任意提交事务。
- 生产 DDIC、持久化模型和公开 API 变更先做 where-used、兼容性、数据迁移、部署顺序、验证与恢复分析。
- 所有外部输入、动态调用、数据访问和服务入口都要进行权限与安全检查；敏感数据不得进入无保护日志或错误消息。
- 交付以语法检查、ABAP Unit、ATC、安全检查和变更审查为质量门禁；不得用伪注释、豁免或兜底隐藏真实问题。

## 原始依据

经典基线来自《汉硕SAP系统ABAP开发规范及指引V1.0.pdf》，2018-12-11，94 页。现代补充依据 SAP 官方 ABAP Cloud、RAP、CDS、ATC、安全编程文档和 SAP Clean ABAP 指南，于 2026-09-11 核验。参考文件保留原文页码、现代规则编号和冲突说明；后续升级应更新核验日期和受影响规则，不能仅追加新条目。
