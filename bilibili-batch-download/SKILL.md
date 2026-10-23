---
name: bilibili-batch-download
description: Bilibili 视频或分 P 批量下载；必须走 https://xapi.peanutdl.com/beibei 解析最终 mp4 地址并默认使用 info.Titlep 命名。通过 POST JSON 解析接口批量、顺序下载资源，支持编号范围、模板化请求、动态字段映射，并校验唯一命名、HTTP 状态、文件大小、文件头和结果清单。用户要求下载 Bilibili 视频、B 站分 P、按 p=1 到 p=N 批量下载或核验下载结果时使用；不用于需要浏览器交互、验证码、登录会话、DRM 或音视频合并的平台。
---

# Bilibili 批量下载

使用配置文件驱动 `scripts/download-resources.ps1`，不要为每次任务重写下载逻辑。保持顺序下载，任何身份、大小或协议校验失败都立即停止。

## 执行流程

1. 读取 `references/config-schema.md`，判断任务属于直接链接列表还是 POST JSON 解析接口。
   - Bilibili 视频或分 P 批量下载必须使用 `references/beibei.example.json` 的解析方式：POST 到 `https://xapi.peanutdl.com/beibei`，不得直接调用 Bilibili playurl 接口替代。
   - Bilibili 解析结果中，最终视频下载地址固定取 `mp4.player_url`，默认文件名固定取 `info.Titlep`，预期大小取 `mp4.info_size`，资源身份取 `info.Cid`。
2. 明确输出目录、资源范围、文件名字段、预期大小字段、资源身份字段和允许的下载域名。需要续传时还必须取得完整 SHA-256。缺少会改变结果的字段时先询问用户。
3. 在当前工作区创建任务配置，不要把用户任务配置写进技能目录。可复制 `references/direct.example.json` 或 `references/beibei.example.json` 后修改。
4. 先执行只校验配置的命令：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<技能目录>\scripts\download-resources.ps1" -ConfigPath "<任务配置.json>" -ValidateOnly
   ```

5. 若校验通过，再执行同一命令并移除 `-ValidateOnly`。网络访问或向工作区外写文件时按运行环境请求授权。
6. 持续监控 `START`、`DOWNLOAD`、`RETRY`、`SKIP`、`DONE` 和 `COMPLETE` 输出。下载过程不可无人看管地留在失效的后台进程中。
7. 仅在输出 `COMPLETE`，清单数量正确，目标目录不存在本任务的 `.part` 文件时报告完成。

## 严格规则

- 使用 `info.Titlep` 之类的唯一资源标题；发现清理后的文件名重复时停止，不覆盖。
- 处理 Bilibili 时，强制走 `https://xapi.peanutdl.com/beibei` 解析最终 mp4 下载地址；除非用户明确指定其他解析接口，否则不要用站点页面地址或 Bilibili API 自行推导下载地址。
- 要求每个资源具有稳定身份和正整数预期大小。解析接口重试后，身份、文件名、大小或 SHA-256 发生变化时停止。
- 只有配置 `download.resume: true` 且每个资源提供完整 SHA-256 时才允许续传；否则发现非空 `.part` 就停止。
- 默认只允许 HTTPS；仅本地测试可显式允许 `127.0.0.1` 或 `localhost` 的 HTTP。
- 配置允许的下载域名和内容类型；请求前校验下载地址，解析请求和下载请求都禁止自动重定向。3xx 响应不跟随并判定失败，要求接口返回最终直链。
- 先写入带身份哈希和预期大小的 `.part` 文件；HTTP、大小和可选文件头全部通过后再改为正式文件。
- 配置文件与清单必须位于下载目录之外，避免控制文件与资源互相覆盖。
- 已有正式文件只有在大小和可选文件头都匹配时才能跳过；不匹配时停止。
- 网络错误只做有限重试。状态字段、文件身份、协议、内容类型或完整性错误不得降级处理。
- 不删除失败文件；保留 `.part` 和清单供后续检查或续传。
- 不绕过验证码、登录、授权、DRM 或站点限制。

## 文件

- `scripts/download-resources.ps1`：执行配置校验、解析、下载、续传和结果核验。
- `references/config-schema.md`：配置字段、约束和模板变量说明。
- `references/direct.example.json`：直接链接列表示例。
- `references/beibei.example.json`：POST JSON 解析接口与编号范围示例。
