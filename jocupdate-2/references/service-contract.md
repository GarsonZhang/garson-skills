# JOCUpdate 服务端协议与发布约束

## 版本检查

向公开服务发起：

```text
GET {serverBaseUrl}/checkversion?productID={productCode}&version={currentVersion}&versionType={channel}&updateMode={full|incremental}&machineCode={optionalMachineCode}
```

- 所有查询参数均应 URL 编码。
- `serverBaseUrl` 去除尾部 `/` 后再拼接路径。
- `productID` 是服务端产品编码，不是展示名称。
- `version` 是可比较的正整数机器版本；`versionType` 必须与服务端记录中配置的通道精确匹配。
- `updateMode` 只能使用 `incremental` 或 `full`。全量模式的服务端只返回版本号最高的一条可用记录；增量模式可以返回多个包。
- 接口只返回版本号高于当前值、状态为“已发布”且具备文件哈希与签名的记录。草稿和已下架记录对客户端不可见。

成功响应的主体为 `status: 0`，数据在 `data` 中。每条版本记录至少包含：

```json
{
  "version": 103,
  "versionTxt": "1.0.3",
  "description": "修复说明",
  "reboot": "Y",
  "fileSizeBytes": 12345678,
  "fileSha256": "…",
  "fileSignature": "…",
  "signatureAlgorithm": "RSA-SHA256",
  "files": ["https://updates.example.com/data/packages/app-103.zip"]
}
```

JSON 序列化策略可能使字段变为 PascalCase；若客户端自己解析响应，可兼容两种大小写，但不能接受缺失、非数组或 `status != 0` 的响应。

## 信任与完整性

- 生产环境必须使用 HTTPS 检查和下载。客户端应拒绝 HTTP 下载地址。
- 服务端为上传的升级构件计算文件大小、SHA256 和 RSA-SHA256 签名。能直接使用官方桌面客户端库时，优先让它完成协议兼容和校验。
- 自行实现下载器（例如 UniApp）至少比较已下载字节数与 `fileSizeBytes`；如运行环境可获得 SHA256 和嵌入的服务端公钥，应在调用安装器前验证 `fileSha256` 与 `fileSignature`。校验失败立即停止，不安装文件。
- Android 系统安装器还会校验应用 ID、签名证书和 `versionCode`；这不是下载完整性校验的替代品。

## 发布规则

- 版本机器号必须单调递增。回滚发布也使用更高的机器版本，并把代码内容回退到目标版本，而不是发布较低版本号。
- `versionTxt` 只用于展示，不能驱动版本排序。
- 每份构件上传后核对下载地址、大小、哈希、签名、通道与更新模式；然后发布草稿。
- 发布一个可用的测试版本前，保留已知可回退的构件和发布记录。下架会停止向新检查请求返回该版本，但不会撤销已下载的文件。
