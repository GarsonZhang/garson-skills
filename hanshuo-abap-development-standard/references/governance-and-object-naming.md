# 项目治理与开发对象命名

## 使用范围

设计或审查需求编号、传输请求、开发类及经典 Repository/DDIC 对象名称时读取。页码对应原 PDF V1.0。

本文件整体属于 `CLASSIC_ONLY` 经典命名基线。`CLASSIC_ECC` 默认执行；`S4_CLASSIC` 只对实际采用的经典对象执行；`S4_CLEAN_CORE` 和 `ABAP_CLOUD` 不能用本文件推动架构退回经典对象。现代 CDS、RAP 和服务对象见 [modern-abap-and-clean-core.md](modern-abap-and-clean-core.md)。

## 基础代码（第 4-9 章，页 8-12）

常用模块代码：`BC`、`FI`、`CO`、`SD`、`PP`、`MM`、`QM`、`PM`、`CA`、`SRM`、`SNC`、`APO`、`BW`；原文另列 `PS`、`WF`、`HR`、`AM`、`IS`、`ABAP`、`BASIS`。使用项目当前清单，不自行缩写新模块。

- 项目代码：3 位。项目组确定；日常运维可用 `GEN`。
- 需求号码：`<Module><DevType><DevNumber>`，示例 `PPI0103`。
- 开发号码：4 位，同一项目期次、模块和开发类型内唯一，通常取需求号最后 4 位。
- 开发类型：`R` 报表、`C` 转换、`D` 功能、`S` 子程序池、`E` 系统增强、`F` 表格打印、`I` 接口函数、`X` 一般共享开发。
- 问题号码：日常运维使用 JIRA 等系统生成的唯一编号。

## 传输请求与开发类（第 10-11 章，页 12-14）

日常运维传输请求：

```text
<Module>:<Object>-<Request Description>-<Developer Name>-<YYYYMMDD>-<Unique ID>
```

多模块用 `&` 连接；对象优先写事务代码，无事务代码时写主程序、函数组、函数或类。日期和开发者必填；不把无关对象合并到同一日常运维请求。

项目传输请求：

```text
<Project>_<Module>_DEV_<NNNN>_<Description>_<Developer>_<YYYYMMDD>
```

原文指定开发类：ECC 使用 `ZHS`，S/4 使用 `ZHS01`。这是 2018 年环境值；实际创建前必须确认目标系统当前开发包和传输层，不因本表擅自采用历史包。

## 通用原则（页 14-15）

- 正式客户化对象首字符为 `Z`；练习程序首字符为 `Y`。
- 名称中要求的项目、模块、开发类型、开发编号必须来自实际需求。
- 先确认 SAP 对该对象类型的实际长度限制；模板超长时报告冲突并请项目负责人确定缩写，不能无声截断。

## 程序、函数和类（第 12.1-12.7 节，页 15-32）

| 对象 | 模板 | 关键约束 |
|---|---|---|
| 可执行程序 | `Z<PRJ>_<MOD>_<TYPE>_<NNNN>` | 主名按原规范控制为 14 字符；扩展可加 `_NN`，但优先用不同事务代码区分，相差很大的功能拆成独立需求 |
| 可执行程序 Include | `<MAIN>_<SUFFIX>` | 后缀按需使用 `TOP`、`SEL`、`CLS`、`EVT`、`FRM`、`PBO`、`PAI` |
| 函数组 | `Z<PRJ>_<MOD>_<TYPE>_<NNN>` | 三位流水号通过 SE80 确认；非 `E` 函数组下的函数不得被增强点调用 |
| 函数组自定义 Include | `L<FUNCTION_GROUP><SUFFIX>` | 系统生成 `TOP`、`UXX` 除外；后缀可用 `SEL/CLS/EVT/FRM/PBO/PAI` |
| 函数模块 | `Z<PRJ>_<MOD>_<TYPE>_<NNNN>[_<SHORT>]` | 一般不再使用 Include，除非与标准功能整合确有需要 |
| 模块池 | `SAPMZ<PRJ>_<MOD>_<TYPE>_<NNNN>` | 一般类型为 `D`；扩展可加 `_NN`，但优先用事务代码分支 |
| 模块池 Include | `MZ<MODULE_POOL_APP_NAME>_<SUFFIX>` | 后缀 `TOP/SEL/CLS/EVT/FRM/PBO/PAI`；通常无 `SEL` |
| 子程序池 | `Z<PRJ>_<MOD>_S_<NNN>` | 流水号通过 SE38 确认；原规范不建议新用子程序池，优先函数组 |
| 子程序池 Include | `<SUBROUTINE_POOL>_<SUFFIX>` | 后缀 `TOP/CLS/FRM` |
| 共享 Include（增强） | `Z<PRJ>_<MOD>_E_<NNNN>_<NNNN>` | 前一编号为开发号，后一编号为流水号 |
| 共享 Include（其他） | `Z<PRJ>_<MOD>_<TYPE>_<NNN>[_<SHORT>]` | 三位流水号通过 SE38/SE80 确认 |
| 全局类 | `ZCL_<SHORT_DESCRIPTION>` | 方法首词用英语动词原形；属性用描述性名词，多个词用 `_` |
| 全局接口 | `ZIF_<SHORT_DESCRIPTION>` | 组件别名保持被引用接口中的组件名 |
| 本地类 | `LCL_<SHORT_DESCRIPTION>` | 标准对象增强中添加时再加需求前缀 |

全局类/接口的固定成员形式：

- 属性：描述性名词；标准类增强属性加 `Z<Project><Module><Type><Number>_`。
- 方法：动词开头；属性访问 `SET_<attribute>` / `GET_<attribute>`，事件处理 `ON_<event>`，布尔询问 `IS_<adjective>`，检查 `CHECK_<object>`。
- 事件：`<noun>_<past-tense-verb>`。
- 类内本地类型：`<name>_TYPE`。
- `IS_...` 方法返回 `X`/空格且不抛异常；`CHECK_...` 可抛异常。
- 标准类增强的方法、事件、类型和别名均加 `Z<Project><Module><Type><Number>_` 前缀。

函数和方法参数前缀属于 `CLASSIC_ONLY`：

| 方向 | 一般 | 结构 | 内表 | 对象 | 一般引用 | 结构引用 | 内表引用 | 对象引用 |
|---|---|---|---|---|---|---|---|---|
| IMPORTING | `IM_` | `IM_S_` | `IM_T_` | `IM_O_` | `IM_REF_` | `IM_REF_S_` | `IM_REF_T_` | `IM_REF_O_` |
| EXPORTING | `EX_` | `EX_S_` | `EX_T_` | `EX_O_` | `EX_REF_` | `EX_REF_S_` | `EX_REF_T_` | `EX_REF_O_` |
| CHANGING | `CH_` | `CH_S_` | `CH_T_` | `CH_O_` | `CH_REF_` | `CH_REF_S_` | `CH_REF_T_` | `CH_REF_O_` |
| RETURNING | `RE_` | `RE_S_` | `RE_T_` | `RE_O_` | `RE_REF_` | `RE_REF_S_` | `RE_REF_T_` | `RE_REF_O_` |

经典函数模块 `TABLES` 参数：只输入 `IT_`、可修改 `CT_`、只输出 `ET_`。标准函数/方法增强参数需在上述前缀前再加 `Z<Project><Module><Type><Number>_`。现代方法和 ABAP Cloud 不套用此参数编码。

推荐异常名称：`ACTION_NOT_SUPPORTED`、`CANCELLED`、`EXISTING`、`FAILED`、`<operation>_FAILED`、`FOREIGN_LOCK`、`INCONSISTENT`、`<object>_INCONSISTENT`、`INVALID`、`<object>_INVALID`、`INTERNAL_ERROR`、`NOT_AUTHORIZED`、`NOT_CUSTOMIZED`、`<object>_NOT_CUSTOMIZED`、`NOT_FOUND`、`<object>_NOT_FOUND`、`NOT_QUALIFIED`、`<object>_NOT_QUALIFIED`、`NUMBER_ERROR`、`SYSTEM_ERROR`。

## 事务、消息和 DDIC 名称（第 12.8-12.20 节，页 32-38）

| 对象 | 模板 | 说明 |
|---|---|---|
| 事务代码 | `Z<MOD><NNNN>[<NN>]` | 主流水号通过 SE93 确认；末两位可表示创建/修改/显示等分支 |
| 消息类 | `Z<PRJ>_<MOD>_<NNN>` | 流水号通过 SE91 确认 |
| 数据库表 | `Z<PRJ>_<MOD><NNNN>[<NNN>]` | 一个需求多表时加三位流水号；明确公用表可用经批准的短名称代替开发号 |
| 视图 | `Z<PRJ>_<MOD>V<NNNN>[<NNN>]` | 一个需求多视图时加三位流水号 |
| 结构 | `Z<PRJ>_<MOD><TYPE>_<SHORT>` | 简短描述中建议带开发编号，如 `ZMES_MMD_0302_OUTPUT` |
| 标准对象派生表类型 | `Z<STANDARD_OBJECT>_TAB` | 如 `ZVBAK_TAB` |
| 客户化对象派生表类型 | `<Z_OBJECT>_TAB` | 如 `<custom_structure>_TAB` |
| Range 表类型 | `Z<DATA_ELEMENT>_RANGE_TAB` | 必须基于数据元素；行结构建议 `_RANGE_LINE` |
| 其他表类型 | `Z<DESCRIPTIVE_NAME>_TAB` | 无合理解释不得采用 |
| 数据元素 | `ZE_<SHORT>` | 名称尽量简短明确 |
| 域 | 见下方冲突说明 | 新建前确认当前约定 |
| 类型池 | `Z<SHORT>` | 原文建议模块加两位流水号，如 `ZPP01` |
| 基本/复合搜索帮助 | `ZSHB_<MOD>_<SHORT>` / `ZSHC_<MOD>_<SHORT>` | `B` 基本，`C` 复合 |
| 锁对象 | `EZ<SHORT>` | 最好用被锁表或字段名 |
| 号码范围 | `Z<SHORT>` | 最好用号码对应字段名，原规范总长最多 9 |
| 更改对象 | `Z<SHORT>` | 使用描述性名称，原规范总长最多 9 |

## SmartForm、经典增强和权限对象名称（第 12.21-12.33 节，页 39-46）

| 对象 | 模板/规则 |
|---|---|
| SmartForm 表格 | `Z<PRJ>_<MOD>_<NNNN>_<NN>_FORM_V<NNN>` |
| SmartForm 样式 | `Z<PRJ>_<MOD>_<NNNN>_STYLE_<NN>_V<NNN>` |
| SmartForm 文本模块 | 见下方冲突说明 |
| 标准文本 | `Z<PRJ>_<MOD>_<NNNN>_<TEXTID>_<LANG>_V<NNN>`，语言码查 T002 |
| CMOD 项目 | 按模块：`ZFIEH`、`ZCOEH`、`ZMMEH`、`ZPPEH`、`ZSDEH`、`ZSNCEH`、`ZSLCEH` |
| 传统 BAdI 实现 | `Z<MOD>IMPL_<BADI_SHORT>` |
| 与 BAdI 整合的增强实现 | `ZBADI_<BADI_DEFINITION>_<NNNN>` |
| 新增强实现 | `ZEHM_<PRJ>_<MOD>_<TYPE>_<NNNN>_<NNNN>` |
| 复合增强实现 | `ZCEI_<PRJ>_<MOD>_<TYPE>_<NNNN>_<NNNN>` |
| 权限对象类 | `Z_<MOD>` |
| 权限对象 | `Z_<MOD>_<SHORT>` |
| Web Dynpro | `Z_<PRJ>_<PREFIX>_<SHORT>`；前缀 `COM/APP/COC/APC/FAP/FCC/FFC/FGC/FAC` |
| Query 用户组/信息集/查询 | `Z<MOD>_<SHORT>`；查询前缀尽量与信息集一致 |

权限组固定映射属于 `PROJECT_CONFIG`：`ZMM`、`ZPP`、`ZSD`、`ZFI`、`ZCO`、`ZSNC`、`ZSRM`。新建表和视图按模块分配；实际系统若有更新映射，以项目配置为准。

## 原文冲突和处理方式

- 域：位置表推导为 `ZD_<DESCRIPTION>`，示例却是 `ZDO_LOGNUMBER`。任务涉及新域命名时必须查目标系统同类对象或项目补充规范；查不到就向用户说明冲突并确认。
- SmartForm 文本模块：字段表写固定串 `STYLE`，说明文字写 `TEXTM`，示例名称又使用 `STYLE`。不得静默选择；先查项目既有文本模块，再请求确定。
- 消息类：位置编号在原文疑似错位，但示例稳定对应 `Z<PRJ>_<MOD>_<NNN>`，本参考按结构和示例整理。
- 原文中的包、CMOD 项目和权限组是当时系统值。创建前验证当前系统，不能仅凭本 Skill 推断这些对象一定存在。
