---
name: sap-gui-automation
description: 通过现有已登录的 SAP GUI for Windows 会话执行可审计的 GUI Scripting 自动化。用于探测 SAP 会话、在指定系统和客户端打开事务码、读取或操作 SAP GUI 控件，以及把 SAP GUI 录制脚本整理成可靠自动化；不用于 SAP Fiori、RFC、OData、ABAP 后端调用或绕过 SAP 权限。
---

# SAP GUI 自动化

## 核心方式

- 复用用户已登录的 SAP GUI for Windows 会话，不处理账号、密码或验证码。
- 优先使用 VBScript、`SapROTWr.SapROTWrapper` 和 `GetROTEntry("SAPGUI")` 获取脚本引擎。此环境中 PowerShell 的 `Marshal.GetActiveObject` 和直接 COM 集合访问可能存在类型库兼容问题。
- 本机执行 SAP GUI 自动化时，默认请求桌面会话权限后再运行 `cscript.exe`，直接访问用户已登录 GUI 的 ROT 入口，避免受限进程先失败再重试。权限范围仅限本次 SAP GUI 自动化命令，不得借此扩大其他操作权限。
- 通过 SAP GUI Scripting 对象直接操作控件；设置 `.Text`、调用 `.Press` 或 `SendVKey` 不属于 Windows 键盘、鼠标模拟。
- 始终按用户指定的系统和客户端验证会话。未匹配时明确失败，不得回退到第一个连接或其他客户端。
- SAP GUI 自动化只能使用当前用户已有的 SAP 权限，不得尝试绕过权限、登录控制或安全提示。

## 权限边界

- 打开事务初始界面不等于修改 SAP 数据，可以在用户明确要求打开事务时执行。
- 填写字段、切换视图或运行只读查询，只执行用户要求的范围。
- 对当前用户有显示权限的 SAP 源代码，复制、下载或导出到本机可作为只读分析的默认步骤；不得上传、发送、同步到外部服务，也不得因此进入修改模式、保存或变更 SAP 对象。
- 自定义函数模块即使业务用途是查询，也不得仅凭名称或用途视为无副作用。执行前确认其不会写入业务数据、应用日志或其他 SAP 状态；无法确认时，先取得运行该函数的明确授权。
- 保存、过账、审批、发布、删除、批量更新或确认不可逆弹窗会改变 SAP 状态，必须有对应的明确授权。
- 遇到确认窗口、警告窗口或业务错误时停止并报告窗口标题和状态；不得自动确认、关闭或隐藏错误，除非用户已明确授权该具体动作。

## 标准流程

1. 从用户请求确定目标系统、客户端、事务码和允许执行到哪一步。缺少会影响会话选择或数据安全的信息时，先列出会话或询问用户。
2. 默认使用桌面会话权限运行随附助手，列出当前会话：

   ```powershell
   cscript.exe //nologo "<skill-dir>\scripts\sap_gui_session.vbs" list
   ```

3. 系统和客户端只有一个匹配会话时，直接打开事务：

   ```powershell
   cscript.exe //nologo "<skill-dir>\scripts\sap_gui_session.vbs" open DL8 888 MM01
   ```

4. 如果同一系统和客户端有多个会话，助手会拒绝猜测。根据 `list` 输出让用户选择，或根据请求中已明确的窗口上下文传入连接与会话索引：

   ```powershell
   cscript.exe //nologo "<skill-dir>\scripts\sap_gui_session.vbs" open DL8 888 MM01 0 1
   ```

5. 仅在输出同时确认 `System`、`Client` 和 `Transaction` 与目标一致时报告成功。任何 `ERROR`、弹窗、事务码不一致或脚本输出异常都视为失败。

## 扩展界面操作

当任务超过“列出会话”或“打开事务”时，先读取 `scripts/sap_gui_session.vbs`，复用其中的 ROT 获取、精确会话匹配、忙碌等待和错误处理方式，再在当前任务工作区创建范围明确的 VBScript：

- 控件 ID 必须来自用户提供的 SAP GUI 录制脚本、当前已验证脚本或可靠的界面探测结果，不得猜测。
- 使用 `FindById` 直接定位控件。常见操作包括 `.Text = value`、`.Press`、`.Select` 和 `SendVKey 0`。
- 在同一事务内继续操作前，除了系统、客户端和事务码，还要校验当前业务对象或数据范围。例如函数模块显示页的函数名、SE16N 的表名和已填写的筛选条件；对象不一致时立即停止。
- 探测控件树时只导出目标区域、必要工具栏和当前模态窗口 `wnd[1]`；不要递归菜单栏或大型表格。终端中文乱码时，以控件 ID、字段技术名和状态码为准，不根据乱码推断业务状态。
- 打开事务使用命令字段 `wnd[0]/tbar[0]/okcd`，写入 `/n<事务码>` 后向 `wnd[0]` 发送 `SendVKey 0`。
- 变量索引访问 SAP COM 集合时使用 `Children(CInt(index))`；不要使用此环境中已出现兼容错误的 `.Item(index)`。
- 每个关键动作后以有限超时等待 `session.Busy = False`，然后验证可观察结果。不要使用无上限循环或固定长时间等待。
- 已获得桌面会话权限后仍找不到 SAP GUI ROT 条目时，再确认 SAP GUI for Windows 已启动并登录；不得把受限进程的 ROT 隔离误报为 SAP 未启动。
- 终端中的中文窗口标题可能因代码页显示乱码；系统、客户端、事务码以及 SAP 界面实际状态仍须单独验证。
- 临时 VBScript 使用 UTF-8 无 BOM 和 CRLF 行尾；本机 `cscript.exe` 对 LF 行尾脚本可能出现错误解析。脚本限定在本次任务范围，完成后删除自行创建的临时脚本和未被用户要求保留的本地源码副本。

## ABAP 源码读取

- 在 SE37、SE80 等源码显示页，先验证对象名称和显示状态，再读取、复制、下载或导出源码。
- ABAP 编辑器控件运行时可能显示为 `GuiShell`，但可支持 `GuiAbapEditor` 扩展。复制选中源码时使用 `SelectAll` 后的 `ClipboardCopy()`；不要假定 `.Copy`、`.GetText` 或 `.SelectedText` 可用。
- 若 `ClipboardCopy()` 或对象级扩展不可用，停止并报告实际接口错误；不得改用 Windows 键盘、鼠标模拟或其他绕过方式。
- 默认只提取当前问题所需的代码片段和结论。只有用户要求完整源码时，才输出完整内容。

## 失败处理

- `SAP GUI ROT entry was not found`：先确认命令已在桌面会话权限下运行；仍失败时，再确认 SAP GUI for Windows 已启动并登录。
- `SAP GUI scripting engine is unavailable`：检查 SAP GUI 客户端和目标系统是否允许 Scripting，不要绕过组织策略。
- `Bad index type for collection access`：确认变量索引通过 `CInt` 转换，并使用 `Children(index)`。
- 多个匹配会话：列出索引并明确选择，不得默认操作第一个。
- 找到弹窗或事务码未切换成功：保持现场，报告实际窗口和事务状态，不自动继续。
