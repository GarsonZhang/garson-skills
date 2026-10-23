# 下载配置结构

配置文件必须是 UTF-8 JSON。脚本只接受 `schema: 1`，并要求每个资源具有唯一文件名、稳定身份和正整数预期大小。配置文件与清单必须位于下载目录之外；启用续传时还必须提供完整 SHA-256。

## 顶层字段

| 字段 | 必填 | 说明 |
|---|---|---|
| `schema` | 是 | 固定为 `1`。 |
| `destination` | 是 | 下载目录；相对路径以配置文件目录为基准。 |
| `summaryPath` | 否 | 清单路径；默认是配置文件旁的 `download-summary.json`，且必须位于下载目录外。 |
| `range` | 二选一 | 按连续编号生成来源链接。 |
| `items` | 二选一 | 明确列出资源。 |
| `resolver` | 范围模式必填 | POST JSON 解析接口配置。 |
| `download` | 是 | 下载协议、域名、类型和校验配置。 |

`range` 与 `items` 必须且只能出现一个。

## 来源定义

范围模式：

```json
"range": {
  "urlTemplate": "https://example.com/resource?p={index}",
  "start": 1,
  "end": 54
}
```

范围模式必须配置 `resolver`。`start` 与 `end` 均为正整数，且 `end >= start`。

直接列表模式：

```json
"items": [
  {
    "index": 1,
    "sourceUrl": "https://example.com/page/1",
    "downloadUrl": "https://cdn.example.com/file-1.bin",
    "fileName": "file-1.bin",
    "expectedSize": 1024,
    "identity": "resource-1"
  }
]
```

未配置 `resolver` 时，列表中的 `downloadUrl`、`fileName`、`expectedSize` 和 `identity` 全部必填。`sourceUrl` 可省略，省略后使用 `downloadUrl`。`sha256` 平时可省略；当 `download.resume` 为 `true` 时必填。

配置 `resolver` 时，每项只需 `sourceUrl`；解析结果提供其余字段。

## 解析接口

```json
"resolver": {
  "url": "https://api.example.com/resolve",
  "method": "POST",
  "contentType": "application/json; charset=utf-8",
  "timeoutSeconds": 60,
  "headers": { "Accept": "application/json" },
  "body": { "url": "{sourceUrl}", "part": "{index}" },
  "success": [
    { "path": "status", "equals": 0 }
  ],
  "response": {
    "downloadUrlPath": "data.downloadUrl",
    "fileNamePath": "data.title",
    "expectedSizePath": "data.size",
    "identityPath": "data.id",
    "sha256Path": "data.sha256"
  }
}
```

- `method` 当前只接受 `POST`。
- 解析请求不自动跟随重定向；接口必须直接返回 JSON 响应。
- 字段路径使用点分隔，只支持对象属性，不支持数组索引。
- `success` 可省略；存在时必须是非空数组，并且所有条件都必须满足。
- `sha256Path` 可省略；启用续传时必填，并且响应值必须是 64 位十六进制 SHA-256。
- `body` 和请求头字符串支持 `{sourceUrl}` 与 `{index}`。值完整等于 `{index}` 时保留为数字，否则按文本替换。
- `allowInsecureLocalhost: true` 仅允许解析接口使用本机 HTTP，不能放开远程 HTTP。

## 下载设置

| 字段 | 必填 | 说明 |
|---|---|---|
| `fileExtension` | 否 | 文件名没有该后缀时追加，例如 `.mp4`；空字符串表示不追加。 |
| `allowedHosts` | 是 | 精确域名或单层通配域名；`*.example.com` 只匹配 `a.example.com`，不匹配根域或多层子域。 |
| `allowedContentTypes` | 是 | 允许的响应类型，不含字符集参数。 |
| `headers` | 否 | 支持模板变量；`User-Agent` 与 `Referer` 会转成 curl 专用参数。 |
| `signature` | 否 | 文件头校验，使用 `offset` 加 `ascii` 或 `hex`，两者只能选一个。 |
| `resume` | 否 | 默认 `false`；为 `true` 时每个资源必须提供 SHA-256，最终哈希匹配后才完成。 |
| `maxAttempts` | 否 | 网络失败最大尝试次数，默认 `3`。 |
| `connectTimeoutSeconds` | 否 | 连接超时，默认 `30`。 |
| `maxTimeSeconds` | 否 | 单次下载最长时间，默认 `300`。 |
| `lowSpeedLimitBytes` | 否 | 低速阈值，默认 `1024`。 |
| `lowSpeedTimeSeconds` | 否 | 持续低速时间，默认 `30`。 |
| `allowInsecureLocalhost` | 否 | 仅本地测试使用，默认 `false`。 |

请求头名称必须是合法的 HTTP token，值必须是单行字符串。脚本保留 `Host`、`Content-Length`、`Transfer-Encoding`、`Connection`、`Range`、`If-Range`、`If-Match` 和 `Accept-Encoding` 等控制下载行为的请求头，配置不能覆盖。

MP4 文件头示例：

```json
"signature": { "offset": 4, "ascii": "ftyp" }
```

PDF 文件头示例：

```json
"signature": { "offset": 0, "ascii": "%PDF" }
```

`signature` 应省略或填写对象，不能写成 `null`。`ascii` 只接受 ASCII 字符；任意字节序列使用 `hex`。

## 输出与失败

- 正式文件写入前使用 `.part`，其名称绑定资源身份、预期大小和可选 SHA-256。
- `resume: false` 时发现非空 `.part` 立即停止；`resume: true` 时只在最终 SHA-256 完全匹配后提升为正式文件。
- 下载请求不自动跟随重定向；3xx 响应不跟随并判定失败，配置中必须提供最终直链。响应体可能保留在对应的 `.part` 文件中供检查。
- 已有正式文件匹配时输出 `SKIP`；不匹配时停止。
- 成功完成每项后输出 `DONE`，全部完成后输出 `COMPLETE`。
- 任一非网络校验失败立即退出非零；不删除失败文件。
