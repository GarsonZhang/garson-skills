# 现代 ABAP、CDS、RAP 与 Clean Core

## 使用范围

选择 `S4_CLASSIC`、`S4_CLEAN_CORE` 或 `ABAP_CLOUD`，或任务涉及 CDS、RAP、OData、Released API、ADT 和现代 Open SQL 时读取。规则编号用于审查和豁免记录。

## 架构与 API

- `MOD-ARCH-001` `REQUIRED`：先检查是否存在 SAP Released API、Released CDS Entity 或 Released Extension Point；ABAP Cloud 不得直接依赖未发布对象。
- `MOD-ARCH-002` `REQUIRED`：Clean Core 项目按 Tier 1、Tier 2、Tier 3 隔离依赖。Tier 2 封装必须窄、可替换并有迁移说明；Tier 3 经典开发必须是获批例外。
- `MOD-ARCH-003` `RECOMMENDED`：新业务逻辑使用职责单一的类和接口，不以新建函数组、FORM 或大 Include 作为默认模块化方式。
- `MOD-ARCH-004` `REQUIRED`：包边界、API State 和依赖方向清晰；不得绕过发布契约建立隐式耦合。
- `MOD-ARCH-005` `RECOMMENDED`：依赖通过构造器、接口或框架允许的注入点传入，使业务逻辑可隔离测试。

## CDS 数据模型

- `MOD-CDS-001` `RECOMMENDED`：S/4 新数据模型优先 CDS View Entity，不新建 obsolete 的 DDIC-based CDS View。
- `MOD-CDS-002` `REQUIRED`：实体、元素、Association、Composition 和 Cardinality 表达真实业务语义；不为复用方便声明错误基数。
- `MOD-CDS-003` `REQUIRED`：只暴露消费者需要的字段，维护金额/币种、数量/单位、日期时间及文本关系等必要语义。
- `MOD-CDS-004` `REQUIRED`：需要实例级数据权限时定义并测试 DCL；`WITH PRIVILEGED ACCESS` 只能在明确授权的受控边界使用并说明原因。
- `MOD-CDS-005` `RECOMMENDED`：接口实体、投影实体、消费模型和服务暴露分层，避免消费者直接绑定持久化表。
- `MOD-CDS-006` `PROJECT_CONFIG`：CDS、DCL、Metadata Extension 和 Service 对象命名由项目批准。项目未定义时可以提出 `ZI_`/`ZC_` 等候选分层，但必须标记为候选，不能冒充汉硕 V1.0 原规则。

## RAP 与服务

- `MOD-RAP-001` `RECOMMENDED`：事务型 Fiori/OData 应用优先 RAP Business Object；明确 Root、Composition、Behavior、Projection、Service Definition 和 Service Binding 的职责。
- `MOD-RAP-002` `REQUIRED`：在 Behavior Definition 中明确授权、锁、ETag、草稿、校验、确定、动作和保存语义，只启用业务需要的能力。
- `MOD-RAP-003` `REQUIRED`：Managed 与 Unmanaged 模式按持久化所有权和既有业务 API 选择，不为减少代码盲目采用 Managed，也不为沿用旧代码默认采用 Unmanaged。
- `MOD-RAP-004` `REQUIRED`：使用 RAP/EML 时遵守框架事务边界，不在 Behavior 实现中任意 `COMMIT WORK` 或 `ROLLBACK WORK`。
- `MOD-RAP-005` `REQUIRED`：服务契约包含稳定的字段语义、错误反馈、授权和版本兼容策略；公开后进行破坏性变更前必须评估消费者。
- `MOD-RAP-006` `PROJECT_CONFIG`：RAP 对象命名遵循项目生成器和分层规范；流水号、业务对象短名和包归属必须来自项目，不自行编造。

## 现代代码风格

- `MOD-CODE-001` `REQUIRED`：变量、方法和类型使用可读的业务语义名称；短方法内不强制编码作用域、参数方向和数据种类的匈牙利式前缀。
- `MOD-CODE-002` `RECOMMENDED`：方法保持单一职责，减少嵌套；优先 Guard Clause、提取方法和多态，而不是按条件命中概率组织复杂分支。
- `MOD-CODE-003` `REQUIRED`：新建可复用层使用类异常或明确结果类型；不要在业务类中直接发布依赖 SAP GUI 上下文的消息。
- `MOD-CODE-004` `RECOMMENDED`：布尔值使用目标系统支持的标准布尔类型和 `abap_true`/`abap_false`，不重复定义 `YES/NO/TRUE/FALSE`。
- `MOD-CODE-005` `RECOMMENDED`：使用内联声明、构造表达式、表表达式和现代 Open SQL 时仍保持类型、失败路径和边界清晰，不以“新语法”替代可读设计。
- `MOD-CODE-006` `REQUIRED`：代码注释解释业务原因、限制和非直观取舍；现代受版本管理项目删除被注释掉的旧实现，不在源码中复制提交历史。

## 数据访问与性能

- `MOD-DATA-001` `REQUIRED`：避免 SELECT in LOOP 和逐行数据库更新；使用集合式读取、批量写入或框架事务能力。
- `MOD-DATA-002` `REQUIRED`：只读取需要字段，并尽早下推筛选、聚合和关联；不能为减少 ABAP 代码制造不可维护的深层 CDS 堆叠。
- `MOD-DATA-003` `REQUIRED`：JOIN 数量不是合规指标。根据数据量、选择性、Cardinality、下推能力和执行计划判断；性能结论必须有 SAT、ST05、SQL Monitor、PlanViz 或项目认可的测量依据。
- `MOD-DATA-004` `REQUIRED`：内表按访问方式声明为 Standard、Sorted 或 Hashed；大表存在第二种稳定访问路径时评估 Secondary Key，同时考虑填充、更新和内存成本。
- `MOD-DATA-005` `RECOMMENDED`：仅在 Standard Table 确需临时二分查找时使用显式 `SORT` 加 `BINARY SEARCH`，并保证排序键、方向和读取键一致。
- `MOD-DATA-006` `REQUIRED`：表缓存策略依据表大小、读写比例、访问键、失效频率和一致性要求选择；“配置表”身份本身不能推出必须完全缓存。
- `MOD-DATA-007` `REQUIRED`：SQL 保持声明式和可读；不得仅靠调整 `WHERE` 文本字段顺序声称已完成索引优化，需结合目标数据库和执行计划。

## 事务与持久化

- `MOD-TX-001` `REQUIRED`：每个写场景明确事务所有者、SAP LUW 边界、成功条件、失败传播和恢复策略。
- `MOD-TX-002` `REQUIRED`：可复用类、函数、BAdI 和底层数据访问组件不得擅自 `COMMIT WORK`；由应用边界、框架或明确的事务协调者提交。
- `MOD-TX-003` `RECOMMENDED`：只有需要 SAP Update Task 的延迟/解耦更新语义时才注册 `IN UPDATE TASK`，并验证更新失败的可观察性。
- `MOD-TX-004` `REQUIRED`：多对象更新保证原子性或明确补偿策略；禁止捕获错误后返回虚假成功。
- `MOD-TX-005` `REQUIRED`：RAP 使用框架 Save Sequence 和事务缓冲，不把经典 LUW 模式直接移植到 Behavior 实现。

## 接口选择

- `MOD-INT-001` `RECOMMENDED`：新 Web API 或 Fiori 场景优先评估 RAP/OData；RFC 只在消费者、平台能力或既有集成确实需要时采用。
- `MOD-INT-002` `REQUIRED`：接口契约明确业务错误码、消息文本、相关 ID、幂等性、重试、分页、时区、日期、币种、单位和兼容策略中实际需要的部分。
- `MOD-INT-003` `REQUIRED`：调用 SAP 标准能力优先 Released API；不得以直接读写标准表替代缺失的接口设计。
- `MOD-INT-004` `REQUIRED`：经典 RFC 的 `ZINTF_MESSAGE` 规则仅适用于该公司 RFC 契约，不能自动套用到 OData、RAP 或其他协议。

## 官方依据

最后核验：2026-09-11。

- ABAP Cloud Development Model：https://help.sap.com/docs/abap-cloud/abap-cloud-background-concepts-and-overview/abap-cloud-development-model
- Public Released APIs：https://help.sap.com/docs/abap-cloud/abap-cloud/public-released-apis
- RAP：https://help.sap.com/docs/ABAP_Cloud/abap-cloud-docs_abap-keyword-documentation_abap-for-cloud-development/abap-restful-application-programming-model
- CDS View Entities：https://help.sap.com/docs/abap-cloud/abap-data-models/cds-view-entities-8b3e8e8b8797432abecd7d1fbb6d5c12
- CDS Feature Tables：https://help.sap.com/docs/ABAP_Cloud/abap-cloud-docs_abap-keyword-documentation_abap-for-cloud-development/abencds_language_elements.html
- SAP HANA 查询处理：https://help.sap.com/docs/abap-cloud/abap-data-models/concept
- Internal Table Keys：https://help.sap.com/docs/abap-cloud/abap-concepts/distinguishing-table-keys-in-internal-tables
- SAP Clean ABAP：https://github.com/SAP/styleguides/blob/main/clean-abap/CleanABAP.md
