# UniApp App-Plus Android APK 集成

此方案仅针对 `APP-PLUS` Android。不要在 H5、小程序或 iOS 分支执行 APK 检查；使用条件编译或运行时平台判断隔离调用。

## manifest 与版本规则

`manifest.json` 中维护两个不同用途的版本：

```json
{
  "versionName": "1.2.3",
  "versionCode": 123,
  "app-plus": {
    "distribute": {
      "android": {
        "permissions": [
          "<uses-permission android:name=\"android.permission.INTERNET\"/>",
          "<uses-permission android:name=\"android.permission.ACCESS_NETWORK_STATE\"/>",
          "<uses-permission android:name=\"android.permission.REQUEST_INSTALL_PACKAGES\"/>"
        ]
      }
    }
  }
}
```

- `versionName` 是给用户看的版本，如 `1.2.3`。
- `versionCode` 是正整数、单调递增且永不复用；它必须等于 JOCUpdate 发布记录的 `version`。
- 回滚时构建包含旧业务代码但使用更高 `versionCode` 的新 APK。Android 不允许覆盖安装较低 `versionCode`。
- APK 必须使用与已安装版本相同的应用 ID 和签名证书签名，否则系统安装器会拒绝覆盖。
- 只上传完整签名 APK，服务端产品使用 `updateMode=full`；增量 ZIP 不能交给 Android 安装器。

## 配置与启动

建立一个集中配置模块：

```js
export const appUpdateConfig = Object.freeze({
  serverUrl: 'https://updates.example.com',
  productId: 'YOUR_ANDROID_PRODUCT',
  versionType: 'android',
  updateMode: 'full',
})
```

在 `App.vue` 的 `onLaunch` 中仅为 App-Plus Android 调用 `checkAppUpdate()`。使用 `plus.runtime.getProperty(plus.runtime.appid, callback)` 读取实际已安装 APK 的 `versionCode`；不得读取写死字符串或只使用 `versionName`。

为防止并发下载，用模块级 `isChecking` 阻止重复检查，并确保每条成功、失败和版本非法路径都会复位。检查请求设置合理超时（例如 10 秒）；网络失败应记录诊断信息并保持当前 APK 可用，除非业务明确要求强制升级。

## 查询、选择与下载

按公共协议构造 GET 地址。响应处理必须：

1. 要求 HTTP 200、`status === 0` 且 `data` 为数组。
2. 从记录的 `files[0]` 取得下载地址，并拒绝非 HTTPS 地址。
3. 仅保留 `version > currentVersionCode` 的安全整数记录，按数值降序选择最高版本。
4. 使用 `plus.downloader.createDownload` 下载到应用私有路径，例如 `_doc/updates/app-{versionCode}.apk`。
5. 以下载器状态事件显示进度、速度和目标版本；刷新频率限制在约 250 ms，避免跨 Webview 更新导致卡顿。
6. 下载回调中要求 HTTP 200、存在文件路径，并将 `download.downloadedSize` 与服务端 `fileSizeBytes` 比较（服务端提供且大于零时）。不一致则停止安装并显示真实错误。
7. 成功后调用 `plus.runtime.install(apkPath, {}, success, fail)`，由 Android 系统安装器完成安装确认。不能绕过用户确认，也不能假设系统会自动重启应用。

典型选择逻辑：

```js
const installable = versions
  .filter(item => {
    const version = Number(item.version ?? item.Version)
    const url = Array.isArray(item.files ?? item.Files)
      ? (item.files ?? item.Files)[0]
      : ''
    return Number.isSafeInteger(version) &&
      version > currentVersionCode &&
      /^https:\/\/.+/i.test(url)
  })
  .sort((left, right) => Number(right.version ?? right.Version) - Number(left.version ?? left.Version))
const latest = installable[0] ?? null
```

如应用首页包含原生 `web-view`，普通 Vue 弹层可能被遮挡。此时创建透明 `plus.webview` 作为下载浮层，浮层仅接收格式化后的进度数据；下载完成或失败时先清除模块引用再关闭浮层，防止迟到事件写入已关闭窗口。

## 发布与验收

每次发布：递增 `versionCode`、同步 `versionName`、构建同一签名证书的完整 APK、上传到对应产品/通道/`full` 模式，服务端机器版本填写该 `versionCode`，显示版本填写 `versionName`，核对哈希与签名后发布。

首次接入版本必须手动安装。随后至少用一台旧版本设备验证：服务端无版本时不下载、有高版本时下载并调起系统安装器、文件大小不一致时不安装、签名或 `versionCode` 不匹配时系统拒绝覆盖、安装后新 APK 能再次读取正确版本号。
