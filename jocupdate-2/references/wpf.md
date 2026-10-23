# WPF 集成

使用 `GZUpdate.Client.WPF`；如果自定义进度窗口需要 `DownProgressModel`、`FormatFileSize` 或其他核心类型，同时引用 `GZUpdate.Client`。在项目或其集中包版本管理中选择与目标 .NET/WPF 框架兼容的稳定版本。

```xml
<ItemGroup>
  <PackageReference Include="GZUpdate.Client" />
  <PackageReference Include="GZUpdate.Client.WPF" />
</ItemGroup>
<ItemGroup>
  <Content Include="update.json"
           CopyToOutputDirectory="PreserveNewest"
           CopyToPublishDirectory="PreserveNewest" />
</ItemGroup>
```

## 部署配置

在应用基目录部署 `update.json`，并把默认值设为关闭。仅当 `enabled` 为 `true` 时读取和校验其余字段：

```json
{
  "enabled": true,
  "serverBaseUrl": "https://updates.example.com/",
  "productCode": "YOUR_PRODUCT_CODE",
  "versionType": "release",
  "upgradeExecutorDllPath": "__update__.dll"
}
```

配置提供者应：

1. 使用 `AppContext.BaseDirectory` 定位文件；文件缺失或 `enabled: false` 返回 `Disabled`，不发起网络请求。
2. 对启用配置校验绝对 HTTPS 服务地址、非空产品编码、通道和升级执行器名称；不合法配置必须返回可见失败，不能静默禁用。
3. 标准化服务地址尾随 `/`，并避免把配置文件写回升级包。

## 协调器与启动入口

建立一个 `ApplicationUpdateCoordinator`，集中配置 `WpfUpdateClient` 并把底层结果映射为业务状态：`Disabled`、`NoUpdate`、`Updated`、`UpdatedAndRestarted`、`Failed`。调用方据此分支，禁止将 `Failed` 合并为 `NoUpdate`。

```csharp
var options = new WpfUpdateOptions
{
    Server = configuration.ServerBaseAddress.ToString(),
    ProductId = configuration.ProductCode,
    VersionType = configuration.VersionType,
    UpgradeExecutorDllPath = configuration.UpgradeExecutorDllPath,
    PromptBeforeManualUpdate = false,
    CloseDialogOnStartupComplete = true,
    RestartAfterStartupUpdate = true,
    RestartAfterManualUpdate = true,
    ProgressDialogFactory = new ApplicationUpdateProgressDialogFactory()
};
WpfUpdateClient.Configure(options);
var result = WpfUpdateClient.CheckAndUpdate(owner, WpfUpdateMode.Startup);
```

在 `App.OnStartup` 中，获取单实例锁之后、数据库、主窗口、后台服务与其他文件占用资源初始化之前调用协调器。若状态为 `Failed`，显示错误后执行产品定义的失败策略；若已更新或已触发重启，立即 `Shutdown()`；其他状态才初始化主窗口。

手动检查入口复用同一协调器，传入 `Application.Current.MainWindow` 和手动升级模式；使界面命令在检查中不可重复执行，并根据结果显示无更新、已完成或失败提示。

## 自定义 WPF 进度窗口

实现库定义的 `IWpfUpdateProgressDialog` 与其工厂接口。工厂每次创建独立窗口实例，避免复用已关闭窗口。

- 窗口的 `Shown` 事件在 `Loaded` 时触发；`ShowModal(owner)` 在有 owner 时设置 `Owner` 并居中。
- 使用 `Dispatcher.CheckAccess()` / `BeginInvoke` 回到 UI 线程；调度器关闭时忽略迟到回调。
- `SetMessage`、`SetDownloadProgress`、`SetPackageProgress`、`SetComplete` 和 `SetFailure` 只负责显示。
- 下载与替换期间拦截关闭操作；仅在 `EnableClose`、失败或 `RequestClose` 后允许关闭。
- 完成时显示“正在重启”；失败时显示异常原因并解除关闭限制。不要让用户在文件替换过程中取消窗口。

## 桌面构件

桌面规则与 WinForms 的 ZIP 规则相同：保持相对发布路径，排除 `update.json`、用户数据、日志、版本/临时/备份目录和任何私密配置。升级执行器 DLL 具有执行代码的能力，只能由受信任的发布流程生成和部署。
