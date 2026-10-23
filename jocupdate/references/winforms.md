# WinForms 集成

使用 `GZUpdate.Client.Win`。这是 WinForms 的封装包，包含版本检查、默认进度窗口和重启流程；其对 `GZUpdate.Client` 的依赖由 NuGet 自动解析，不要同时手工引入旧的客户端 API 来实现另一套升级流程。

在项目或集中包版本管理中引用与目标框架兼容的稳定版本：

```xml
<PackageReference Include="GZUpdate.Client.Win" />
```

该包支持 .NET Framework 4.7.2 及 `net5.0-windows`、`net7.0-windows`、`net8.0-windows` 目标。其他目标框架先验证包的当前兼容性；不要仅凭编译通过假设升级执行器可运行。

## 启动升级

在 `Program.Main` 中完成 WinForms 初始化后、创建登录窗体或主窗体前配置并检查。升级过程中不要初始化插件、后台任务、单实例依赖之外的业务服务，避免占用将被替换的文件。

```csharp
using GZUpdate.Client;
using GZUpdate.Client.Win;

namespace YourApp;

internal static class Program
{
    private const string UpdateServer = "https://updates.example.com/";
    private const string UpdateProductId = "YOUR_PRODUCT_CODE";
    private const string UpgradeExecutorDllPath = "__upgrade_executor_dll";

    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();

        WinUpdateClient.Configure(
            server: UpdateServer,
            productId: UpdateProductId,
            versionType: EnumVersionType.release,
            upgradeExecutorDllPath: UpgradeExecutorDllPath);

        var updateResult = WinUpdateClient.CheckAndUpdate();
        if (updateResult.ShouldExitApplication)
        {
            return;
        }

        // 仅当当前进程仍应继续运行时，才创建业务窗体和服务。
        Application.Run(new MainForm());
    }
}
```

- .NET Framework 项目使用 `Application.EnableVisualStyles()` 和 `Application.SetCompatibleTextRenderingDefault(false)` 替代 `ApplicationConfiguration.Initialize()`。
- 产品编码、通道、升级服务 URL 与升级执行器文件名应位于单一部署配置或常量定义；它们必须与服务端产品和版本记录一致。
- `CheckAndUpdate()` 的启动模式在发现升级时显示包自带进度窗口，升级成功后自动启动新实例。调用方只以 `ShouldExitApplication` 决定是否停止旧进程的启动流程，不能仅根据 `IsUpdated` 推断。
- 检查失败时读取 `updateResult.Error` 和 `Status` 记录或呈现真实错误；是否允许以旧版本继续运行由产品策略明确决定，不能把失败显示为“当前已是最新”。
- 如果测试环境明确不应检查正式升级服务，可使用显式环境配置或仅在调试构建中跳过检查；不得把这种跳过逻辑当成生产默认行为。

## 手动检查更新

在主窗体中使用当前窗体作为 owner 调用手动模式：

```csharp
private void CheckUpdateButton_Click(object? sender, EventArgs e)
{
    WinUpdateClient.CheckAndUpdate(this, WinUpdateMode.Manual);
}
```

默认手动模式会在发现更新时询问用户，并在升级完成后提供“重启”按钮。手动升级入口必须在调用前阻止重复操作；若应用启动了插件、子进程或持有安装目录文件，先优雅关闭它们。不要在更新包替换文件时同时继续新的业务操作。

## 可选行为与自定义界面

仅当默认交互不满足产品需求时，改为传入 `WinUpdateOptions`：

```csharp
WinUpdateClient.Configure(new WinUpdateOptions
{
    Server = UpdateServer,
    ProductId = UpdateProductId,
    VersionType = EnumVersionType.release,
    UpgradeExecutorDllPath = UpgradeExecutorDllPath,
    RestartAfterStartupUpdate = true,
    RestartAfterManualUpdate = false,
    PromptBeforeManualUpdate = true,
    ShowNoUpdateMessage = true
});
```

需要保持应用主题时，实现 `IWinUpdateProgressDialogFactory` 和 `IWinUpdateProgressDialog`，并把工厂传给 `Configure`。每次升级创建新的对话框；其实现需要处理消息、下载进度、包数量进度、完成、失败以及 `EnableClose` / `RequestClose`。替换期间禁止关闭，对失败和完成才恢复关闭能力，并把后台回调安全地切换回 UI 线程。

## ZIP 构件与清理

- ZIP 内路径以发布目录为根，例如 `App.exe`、依赖 DLL 与 `plugins/...`，解压后能原位覆盖。
- 全量包包含完整可运行发布输出；增量包只包含新增或变更文件。删除文件需要由可靠的发布/升级策略显式处理，不能因为 ZIP 中缺失就假定旧文件会自动删除。
- 不要放入用户配置、数据库、日志、密钥、`__version__`、`__temp_update__`、`__temp_bak__` 或升级执行器私有数据；特别是服务地址和产品配置不能被升级包意外覆盖。
- 发布目录必须可写。对于受控或只读安装目录，使用已获授权的安装位置或安装器方案，而不是在客户端静默提升权限。
