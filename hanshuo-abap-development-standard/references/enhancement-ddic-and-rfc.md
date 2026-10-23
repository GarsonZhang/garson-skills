# 增强、DDIC、数据库与 RFC

## 使用范围

设计、修改或审查增强、域、数据元素、结构、数据库表、视图、数据库更新或 RFC 时读取。对应原 PDF 第 14-21 章（页 81-94）。本文件保留经典基线；S/4、Clean Core 和 ABAP Cloud 同时应用 [modern-abap-and-clean-core.md](modern-abap-and-clean-core.md)。

## 增强开发

- `CLASSIC_ONLY`：对可命名的 User Exit、CMOD、BAdI、Enhancement Implementation、BTE、财务替代和 Composite Enhancement 使用公司命名规则。
- 增强点中不直接实现大段业务逻辑。`CLASSIC_ONLY` 档案可调用按规则命名的增强函数；现代档案优先调用可测试的类或已发布服务。增强入口必须记录相关实现、增强类型和执行顺序。
- `CLASSIC_ONLY`：同一业务需求依赖多个经典 Enhancement Implementation 时，将其归入同一个 Composite Enhancement，便于识别整体关系。Clean Core/ABAP Cloud 使用目标平台允许的扩展点和发布契约。
- 表或结构字段增强：在 SAP 预留的 Append Structure 内加入独立 Include Structure，不直接把业务字段散落在 Append 中。Include Structure 按一般结构规则命名。
- 增强字段必须参考明确的数据元素，不使用 Predefined Type。字段名：`ZZ<Project>_<Module>_<DevType>_<DevNumber>_<ShortName>`。
- 已投产增强字段的重命名、删除、数据元素或类型变更属于高风险变更；先提供功能和技术修改方案、where-used、数据兼容与回滚方案，再实施。

## 域

创建前先搜索是否已有标准域可复用；没有合适对象时才新建。定义时确认：基本类型、内部长度、小数位、输出长度、转换例程、负号、小写、固定值或值表。

修改前：

1. 用 where-used 查出所有数据元素以及程序、结构、表等下游对象。
2. 评估类型、长度、小数位、转换例程、大小写、负号和值范围变化的影响。
3. 确认屏幕输出、分支逻辑和持久化数据是否需要同步调整。
4. 域已用于生产表时，先形成迁移、停机/上线顺序、验证和恢复方案。

域名称的原文存在冲突，按 [governance-and-object-naming.md](governance-and-object-naming.md) 的冲突说明处理。

## 数据元素

- 创建前先复用标准数据元素。
- 常规及数据库字段使用基于 Domain 的数据元素。
- 原规范不建议用 Predefined Type 创建数据元素；此类数据元素不得用于数据库表字段。
- 引用类型只在确有类、结构等引用语义时使用。
- 修改 Domain 前做数据元素 where-used；已进入生产表时先给出修改方案。
- 需要 Change Document 的表字段，对应数据元素启用“更改文档”。
- 完整维护长、中、短和标题四类字段标签，保证 ALV/屏幕显示可用。

## 结构

- 字段组件使用数据元素，不直接用 Predefined Type。
- 配置字段或从属字段设置 Check Table；例如公司代码指向 `T001`，行项目按业务关系指向抬头表。
- 修改字段名、数据元素或删除组件前做 where-used 并评估所有程序、参数、屏幕、表类型和数据库 Include。
- 结构已 Include 到生产表时，新增、修改或删除字段都按数据库结构变更处理，先提供方案。

## 数据库表

设计时从项目级业务模型判断是否需要新表、是否可复用已有表，以及多表间关系，不能只为单个程序方便创建孤立表。

经典 DDIC 基线：

- `CLASSIC_ONLY`：client-dependent 经典 DDIC 表的第一关键字段为 `MANDT`，参考数据元素 `MANDT`。CDS、RAP 和 ABAP Cloud 按对象的客户端处理模型，不机械添加客户端字段。
- Delivery Class：业务/主数据/程序日志用 `A`；客户维护的配置表用 `C`。
- `SUPERSEDED`：配置表不再因用途自动要求完全缓存。根据表大小、读写比例、访问键、失效频率和一致性选择单记录、通用区域、完全缓存或不缓存；经典维护需求确实存在时再使用 Table Maintenance Generator。
- 业务表和主数据表不得缓存。
- 业务和主数据表保存创建/最后修改的用户、日期、时间。原文正文建议 `ZHS_ADMIN` 及 `ZHS_ADMIN_ADD/ZHS_ADMIN_DATE/ZHS_ADMIN_MOD`，截图展示 `ZHS_ADMIN`；实施前以目标系统现有审计 Include 为准。
- 有多语言描述的主数据建立语言相关文本表，结构参考 MARA/MAKT 模式。
- 每个字段参考合适的数据元素；不直接用 Predefined Type，也不使用基于 Predefined Type 的数据元素。
- 配置或从属字段设置 Check Table。
- 数据库表和维护界面都按模块设置权限组。

已传输生产或已有数据的表发生以下变化时，必须先有修改、迁移、验证和恢复方案：删除表、删除/增加主键、删除字段、修改字段域/类型/长度、修改域值范围。创建或修改 DDIC 定义不等于授权执行数据库调整。

## 数据库更新

- `SUPERSEDED`：不再要求所有数据库更新都通过 Update Task。每个写场景必须明确事务所有者、SAP LUW 边界、失败传播和恢复策略；只有需要更新任务语义时才使用 `IN UPDATE TASK`。
- 可复用类、函数、BAdI 和底层数据访问组件不得擅自 `COMMIT WORK`；由应用边界、框架或明确事务协调者提交。RAP 使用框架 Save Sequence。
- 不在未获授权的生产或共享环境执行写入。审查时检查提前提交、遗漏失败反馈、更新任务不可观察和多对象不一致风险。

## 视图

- 自定义视图的主数据源表含客户端关键字段时，输出字段也必须包含主数据源客户端字段。
- 维护视图不得修改 SAP 标准表，相关标准表字段设为只读。
- 维护视图必须配置权限组。
- `RECOMMENDED`：S/4 新数据模型优先 CDS View Entity；上述规则主要约束经典 DDIC View 和 Maintenance View。

## RFC 消息协议（`CLASSIC_ONLY`）

以下内容是汉硕经典 RFC 的既有契约，不推广到 RAP/OData 或其他协议。所有适用该契约的 RFC 除业务参数外提供：

- `EXPORTING EX_S_MESSAGE`：整体处理结果。
- `TABLES ET_MESSAGES`：明细消息；原签名标注 Optional，但规范又要求两个参数都必须返回消息，按公司行为契约处理为必有且非空。

两个参数参考 `ZINTF_MESSAGE`。原文截图字段为：

| 字段 | 参考类型 | 含义 |
|---|---|---|
| `TYPE` | `BAPI_MTYPE` | 消息类型 |
| `ID` | `SYMSGID` | 消息类 |
| `NUMBER` | `SYMSGNO` | 消息号 |
| `MESSAGE` | `BAPI_MSG` | 消息文本 |

查询/读取 RFC：`EX_S_MESSAGE` 返回整体成功或未找到结果；`ET_MESSAGES` 返回成功消息或附加整体消息。

更新/过账/保存 RFC：发生错误时 `EX_S_MESSAGE` 返回整体错误，`ET_MESSAGES` 返回明细错误；成功时两者分别返回整体和明细成功消息。

消息约束：

- 对外只返回 `S`、`E`、`W`。
- 内部 `I` 转为 `S`；`X`、`A` 转为 `E`。
- 每条消息必须同时具备类型、消息类、消息号和文本；任一缺失均视为缺陷。
- `EX_S_MESSAGE` 和 `ET_MESSAGES` 任一没有返回消息均视为缺陷。
- 外部系统主要按消息类型判断结果；对意外类型应按错误处理并记录协议缺陷。

新建接口先按 [modern-abap-and-clean-core.md](modern-abap-and-clean-core.md) 选择协议，并定义版本化错误码、消息、相关 ID、幂等性、重试及业务数据语义；不能为了复用本节而默认选择 RFC。
