---
name: wpf-dev-standards
description: WPF 开发规范，适用于「Claude 项目工作台」C# + WPF 桌面应用。涵盖项目目录结构、XAML 编写、数据绑定、代码隐藏、对话框模式、配置持久化、异常处理等约定。当在本项目内进行 WPF/C# 代码编写、重构或审查时使用。
---

# WPF 开发规范 — Claude 项目工作台

## 适用范围

本项目是「Claude 项目工作台」，C# + WPF 桌面工具，运行在 .NET 6 或更高版本。当前阶段为全新开发，无历史兼容负担，按最佳实践设计。

---

## 1. 项目结构

严格遵循设计文档定义的目录结构：

```
ClaudeWorkbench/
├── Models/              # 数据模型
│   ├── Provider.cs
│   ├── ModelItem.cs
│   ├── TokenItem.cs
│   └── Project.cs
├── Data/
│   └── ConfigManager.cs # 配置读写
├── Controls/            # 自定义控件
│   ├── ModelEditor.xaml(.cs)
│   └── TokenEditor.xaml(.cs)
├── Dialogs/             # 对话框
│   ├── ProviderDialog.xaml(.cs)
│   ├── ProjectDialog.xaml(.cs)
│   └── ConfigPreview.xaml(.cs)
├── MainWindow.xaml(.cs)
├── App.xaml(.cs)
└── *.csproj
```

- 一个物理文件只属于一个职责目录，不跨目录放置业务逻辑。
- 数据模型（`Models/`）是纯 POCO，不包含 UI 逻辑或文件 I/O。
- `ConfigManager` 是唯一的文件 I/O 入口，UI 层不得直接读写 JSON。

---

## 2. 代码隐藏模式

本项目使用 **代码隐藏（Code-Behind）**，不使用 MVVM 框架。原因：项目规模小（约 5 个窗口/对话框），引入 MVVM 框架会增加不必要的抽象层。

**约定：**

- 事件处理器命名：`<控件名>_<事件名>`，例如 `RunButton_Click`、`ProviderList_SelectionChanged`。
- 控件命名：`<功能>Button`、`<功能>TextBox`、`<功能>ListView`，例如 `RunButton`、`NameTextBox`。
- 控件声明放在 XAML 中，不在代码隐藏中 `new` UI 元素（数据模板除外）。
- 代码隐藏中不直接操作 `config.json`，通过 `ConfigManager` 访问。

---

## 3. XAML 编写规范

### 3.1 命名空间

```xml
<Window x:Class="ClaudeWorkbench.MainWindow"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude 项目工作台"
        Height="540" Width="900"
        MinHeight="400" MinWidth="700">
```

- `x:Class` 与 C# 类名一致。
- 窗口设 `MinHeight` / `MinWidth`，防止用户拖拽时窗口过小。

### 3.2 布局

- 首选 `Grid` 做整体布局，嵌套 `Grid` 做分栏。
- 行/列定义使用 `RowDefinition` / `ColumnDefinition`，明确指定 `Height` / `Width` 或 `*` 比例。
- 按钮区域固定高度，列表区域使用 `*` 自适应。
- 不使用 `StackPanel` 做主布局（性能差、易溢出）；按钮行可用 `WrapPanel` 或固定 `Grid` 行。

### 3.3 样式

- 控件间距统一用 `Margin`，水平间距 4，垂直间距 6。
- 按钮最小宽度 70，居中显示。
- 不内联颜色；如需统一主题色，在 `App.xaml` 中定义 `SolidColorBrush` 资源。
- 字体大小：正文 13，标题 16，错误提示 12。

### 3.4 数据绑定

- 列表控件绑定 `ObservableCollection<T>`，使用 `ItemsSource`。
- 显示文本通过 `ItemTemplate` 的 `DataTemplate` 绑定，不在代码中手动设置 `Content`。
- 对话框中的 TextBox 使用双向绑定：`{Binding ..., UpdateSourceTrigger=PropertyChanged}`。
- 组合框（ComboBox）绑定数据源，`DisplayMemberPath` 指定显示字段，`SelectedValuePath` 指定存储字段。

---

## 4. 对话框模式

所有编辑对话框（`ProviderDialog`、`ProjectDialog`）统一遵循以下约定：

### 4.1 创建与调用

```csharp
using (var dialog = new ProviderDialog(existingProvider))
{
    if (dialog.ShowDialog() == true)
    {
        var updated = dialog.Result;
        // 处理结果
    }
}
```

- 对话框构造函数接收要编辑的模型对象（可为 null，表示新建）。
- `ShowDialog()` 返回 `true` 表示保存，`false` 表示取消。
- 结果通过只读属性 `Result` 暴露，外部不直接访问对话框内部控件。
- `using` 确保窗口资源释放。

### 4.2 按钮行为

- 「保存」按钮：执行校验 → 校验通过则设置 `Result` 并 `DialogResult = true`，校验失败弹窗提示不关闭。
- 「取消」按钮：`DialogResult = false`，不保存。
- 点击窗口右上角 X 等价于取消。

### 4.3 校验规则

校验在保存时执行，不在输入时实时拦截。规则：

| 控件 | 校验 |
|------|------|
| 名称 TextBox | 不能为空、不能与已有记录重名 |
| BASE_URL TextBox | 不能为空、必须是合法 URL（`Uri.TryParse`） |
| 目录路径 TextBox | 不能为空、`Directory.Exists` 必须返回 true |
| ComboBox（供应商/TOKEN/模型） | 必须选中一项 |

校验失败时弹窗提示具体原因，焦点定位到第一个错误字段。

---

## 5. 配置持久化

### 5.1 ConfigManager 接口

```csharp
public static class ConfigManager
{
    public static AppConfig LoadAppConfig();
    public static void SaveAppConfig(AppConfig config);
    public static void WriteProjectConfig(Project project, List<Provider> providers);
    public static string GetConfigDirectory();
}
```

### 5.2 写入规则

- 写入 `config.json` 前先备份旧文件为 `config.json.bak`，最多保留最近 5 个 `.bak`。
- JSON 序列化使用 `System.Text.Json`，`WriteIndented = true`，UTF-8 编码（无 BOM）。
- 写入 `settings.local.json` 时创建 `.claude` 目录（`Directory.CreateDirectory` 幂等）。

### 5.3 读取规则

- 文件不存在 → 返回空配置（`AppConfig` 默认构造），不抛异常。
- JSON 格式错误 → 抛 `ConfigLoadException`，消息包含文件路径和原始错误；UI 层捕获后弹窗提示并备份损坏文件。
- TOKEN 值不出现在任何日志或错误消息中。

### 5.4 settings.local.json 生成规则

```csharp
var settings = new
{
    env = new
    {
        ANTHROPIC_BASE_URL = provider.BaseUrl,
        ANTHROPIC_AUTH_TOKEN = token.Value,
        ANTHROPIC_API_KEY = "",
        CLAUDE_CODE_MAX_CONTEXT_TOKENS = "1000000"
    },
    permissions = new { defaultMode = "allow" },
    model = project.ModelId
};
```

- `ANTHROPIC_API_KEY` 固定空字符串。
- `CLAUDE_CODE_MAX_CONTEXT_TOKENS` 固定 `"1000000"`。
- `permissions.defaultMode` 固定 `"allow"`。
- 整体覆盖写入，不做增量合并。

---

## 6. PowerShell 启动

```csharp
var startInfo = new ProcessStartInfo
{
    FileName = "powershell.exe",
    Arguments = "-NoExit -Command \"cd '" + project.Path + "'\"",
    UseShellExecute = true
};
Process.Start(startInfo);
```

- 路径用单引号包裹，防止路径含空格或特殊字符。
- `-NoExit` 保持窗口打开。
- `UseShellExecute = true` 确保在新窗口打开。
- 启动失败捕获异常，弹窗提示但不中断主界面。

---

## 7. 异常处理

### 7.1 弹窗规范

使用 `MessageBox`：

```csharp
MessageBox.Show(
    this,
    "项目目录不存在，请重新选择。",
    "错误",
    MessageBoxButton.OK,
    MessageBoxImage.Warning);
```

- 错误信息必须明确告知用户原因和可操作建议。
- 弹窗不输出 TOKEN 值。
- 严重错误（配置损坏）使用 `MessageBoxImage.Error`，一般错误使用 `MessageBoxImage.Warning`。

### 7.2 异常捕获层级

| 层级 | 捕获策略 |
|------|----------|
| 配置读取 | 捕获并转为 `ConfigLoadException`，携带文件路径 |
| 配置写入 | 捕获 `IOException` / `UnauthorizedAccessException`，弹窗含文件路径 |
| 一键运行 | 捕获所有异常，弹窗提示，不崩溃 |
| 按钮事件 | 顶层 try-catch，未知异常弹窗「发生未预期的错误」+ 版本信息 |

---

## 8. 注释与文档

- 公共类和方法添加 XML 注释（`/// <summary>`），说明用途和边界。
- 复杂业务分支加行内中文注释，解释「为什么」而非「做了什么」。
- 简单属性、事件处理器、字段映射不加注释。
- 不提交 `TODO` 注释；待办事项记录在 CONTEXT.md 中。

---

## 9. 验证

开发完成后运行以下检查：

```powershell
# 编译
dotnet build ClaudeWorkbench.csproj

# 单元测试（如已添加）
dotnet test

# 行尾检查（提交前）
git diff --check
```

自检验证清单（来自设计文档第 9 节）：

- [ ] 新增供应商，关闭重开，数据保留。
- [ ] 供应商删除时引用检查生效。
- [ ] 新增项目，供应商下拉切换时 TOKEN/模型下拉正确联动。
- [ ] 项目编辑预览 JSON 与实际生成一致。
- [ ] 一键运行成功生成 `settings.local.json`，内容与预期一致。
- [ ] 一键运行后 PowerShell 窗口工作目录为项目目录。
- [ ] 项目目录不存在时，编辑和运行均被拦截。
- [ ] 首次启动（无 config.json）正常创建空配置。
- [ ] config.json 被手动破坏后，应用提示并备份损坏文件。
