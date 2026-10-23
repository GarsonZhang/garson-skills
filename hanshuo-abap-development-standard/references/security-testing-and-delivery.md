# 安全、测试与交付门禁

## 使用范围

编写、修改或审查任何可执行代码、服务、增强、权限控制或数据访问时读取。规则编号用于审查结论、ATC 豁免和整改追踪。

## 安全设计

- `SEC-AUTH-001` `REQUIRED`：每个入口识别调用者、业务对象、操作和数据范围，执行适当的启动权限、`AUTHORITY-CHECK`、RAP 授权或 CDS DCL；不能仅依赖隐藏按钮或事务码可见性。
- `SEC-AUTH-002` `REQUIRED`：CDS 实例权限使用 DCL 时测试允许和拒绝路径；`WITH PRIVILEGED ACCESS` 必须有明确业务授权、最小范围和审查说明。
- `SEC-IN-001` `REQUIRED`：所有外部输入按业务允许值校验长度、格式、范围和关联关系；校验发生在数据用于权限、动态语句、文件路径或持久化之前。
- `SEC-DYN-001` `REQUIRED`：动态 SQL、动态类/方法/函数/事务/程序调用只接受固定允许名单或经过白名单 API 验证的值；不能把外部输入直接拼入动态语句。
- `SEC-OUT-001` `REQUIRED`：错误、日志和接口消息不暴露密码、令牌、连接信息、个人敏感数据、内部路径或不必要的技术细节。
- `SEC-RFC-001` `REQUIRED`：RFC、OData 和其他远程入口验证授权、可信目标、最小权限和输入；动态 RFC 目标或函数名不得由未校验输入控制。
- `SEC-DATA-001` `REQUIRED`：读取和修改数据遵循最小权限；绕过客户端、DCL、授权对象或标准业务 API 的行为必须有明确技术依据和批准。

## 自动化测试

- `TST-UNIT-001` `REQUIRED`：新增或修改的核心业务规则、计算、校验和状态转换必须有 ABAP Unit，除非目标系统确实不支持或改动不可隔离；不能用“手工测试过”替代可行的单元测试。
- `TST-ISO-001` `RECOMMENDED`：通过接口和依赖注入隔离数据库、RFC、时钟、用户上下文和外部服务。
- `TST-DB-001` `RECOMMENDED`：数据库逻辑使用目标版本支持的 ABAP SQL/CDS Test Double Framework；测试不得读写生产或共享业务数据。
- `TST-RAP-001` `RECOMMENDED`：RAP 行为、事件和跨 BO 逻辑使用相应 Test Double 或集成测试验证 Save Sequence、授权、锁、消息和失败路径。
- `TST-CASE-001` `REQUIRED`：至少覆盖正常、边界、无权限、无数据、重复调用、异常和事务失败中与改动相关的场景。
- `TST-DATA-001` `REQUIRED`：测试数据可重复、最小化且无敏感信息；清理或隔离测试副作用。

## 静态检查与豁免

- `QUA-ATC-001` `REQUIRED`：使用项目批准的 ATC Variant 作为主要静态质量门禁；ABAP Cloud 使用 Cloud-ready 检查，S/4 项目包含兼容性、性能和 API 使用检查。
- `QUA-ATC-002` `REQUIRED`：语法和 ATC 错误必须清零。警告必须修复或形成可审计豁免，不能批量隐藏。
- `QUA-EXM-001` `REQUIRED`：ATC/SCI 伪注释或豁免记录具体原因、适用对象、责任人和有效期；规则、上下文或代码变化后重新评估。
- `QUA-CVA-001` `RECOMMENDED`：系统具备许可和配置时，通过 ATC 启用 SAP Code Vulnerability Analyzer；否则至少运行现有安全检查并人工覆盖本文件的安全规则。
- `QUA-LEG-001` `CLASSIC_ONLY`：SLIN 和 SCI/Code Inspector 可补充经典系统检查，但不能替代目标环境已配置的 ATC 和自动化测试。

## 代码审查

- `REV-CHG-001` `REQUIRED`：以本次变更及其直接影响为中心审查，不因审查扩展到无关重构。
- `REV-DES-001` `REQUIRED`：检查真实业务目标、职责边界、数据流、异常路径、事务、权限、性能和可测试性，不只检查格式与命名。
- `REV-COMP-001` `REQUIRED`：公开 API、持久化结构和生产增强检查向后兼容、消费者影响、部署顺序和恢复路径。
- `REV-EVI-001` `REQUIRED`：问题结论包含对象或位置、规则编号/来源、触发条件、影响和可执行修复建议；推测与已验证事实分开。

## 接口错误与运行可观察性

- `OPS-ERR-001` `REQUIRED`：系统边界返回稳定、可机器判断的错误码或消息类型，同时保留可供运维定位的相关 ID；不向调用方泄露内部堆栈或敏感数据。
- `OPS-IDEM-001` `REQUIRED`：可能重试的写接口明确幂等键、重复请求行为或不可重试条件。
- `OPS-LOG-001` `REQUIRED`：关键失败日志包含业务对象标识、操作和相关 ID，且经过脱敏；成功日志和明细日志按实际运维需要控制，避免噪声。
- `OPS-FAIL-001` `REQUIRED`：异常、更新任务失败、RAP 保存失败和远程调用失败必须对调用方或监控可见，不能吞掉后返回成功。

## 传输与交付

- `DEL-DEP-001` `REQUIRED`：确认 Repository、DDIC、权限、配置和服务对象的依赖及传输顺序，避免引用未激活或尚未到达目标系统的对象。
- `DEL-DATA-001` `REQUIRED`：表结构、域、数据元素、CDS 契约或公开 API 的破坏性变更必须有兼容、迁移、验证和恢复方案。
- `DEL-ENV-001` `REQUIRED`：测试、迁移、部署和传输仅在授权环境执行；分析或生成修改不代表获准操作生产或共享系统。
- `DEL-EVI-001` `REQUIRED`：交付报告列出目标档案、影响对象、测试、ATC Variant、豁免、未验证项和剩余风险。

## 官方依据

最后核验：2026-09-11。

- ABAP Unit 与 ATC：https://help.sap.com/docs/abap-cloud/abap-development-tools-for-visual-studio-code/testing-and-quality-checking
- ABAP Cloud 测试策略：https://help.sap.com/docs/abap-cloud/abap-cloud/test
- ABAP SQL Test Double：https://help.sap.com/docs/abap-cloud/abap-development-tools-user-guide/abap-sql-test-double-framework
- SAP Code Vulnerability Analyzer：https://help.sap.com/docs/ABAP_PLATFORM_NEW/1a93b7a44ac146b5ad9b6fd95c1223cc/e6f9668fa26e4680955165acb2b0fb40.html
- CDS 权限模型：https://help.sap.com/docs/ABAP_PLATFORM_NEW/ad77b44570314f6d8c3a8a807273084c/42e2fef6fdd74d7e9195d58aae2b83f6.html
- 动态调用安全：https://help.sap.com/docs/abap-cloud/abap-keyword/dynamic-calls
- SAP ABAP Code Review：https://github.com/SAP/styleguides/blob/main/abap-code-review/ABAPCodeReview.md
