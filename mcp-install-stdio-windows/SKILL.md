---
name: mcp-install-stdio-windows
description: 在 Windows 上给 WorkBuddy 安装 stdio 类型的 MCP 服务器（尤其是 npx 系第三方 MCP），并验证它真能启动。当用户给出一个 MCP 的 GitHub 仓库/npm 包要求「安装这个 MCP」「加个 MCP 连接」「配置 MCP server」，或要求修改 ~/.workbuddy/mcp.json 时使用。不适用于 HTTP/SSE 地址型 MCP 的自定义连接器场景。
agent_created: true
---

# 在 Windows 上安装 stdio MCP（npx 系）

## 核心原则

1. **先验证再写入**：不要凭 README 直接写配置就交付。用 stdin 喂 JSON-RPC 探测一次，确认服务真能起来。
2. **不要问不该问的**：能从本地文件推断的（PATH 里的 node、`~/.ssh/config`、已有 mcp.json）先自己查。
3. **合并而非覆盖**：`~/.workbuddy/mcp.json` 往往已有其他 server，必须保留。
4. **不启动 MCP 进程常驻**：写完配置只做一次性探测，由客户端去拉起。

## 步骤

### 1. 取官方配置

WebFetch 仓库 README 的 raw 地址（`https://raw.githubusercontent.com/<owner>/<repo>/main/README.md`），提取：
- npm 包名（注意可能是个人 scope，如 `@fangjunjie/xxx`）
- `command` / `args` / `env` 的确切写法
- 是否有**必填**参数（这是最容易踩的坑）

### 2. 定位 node / npx 全路径

Windows 上 MCP 客户端 spawn 时通常不带 shell，**不能直接执行 `npx`（无扩展名的 bash 脚本）或 `.cmd`**。固定套路是套一层 cmd：

```bash
which -a npx node                     # 找出实际路径
ls "<node 目录>/"                      # 确认 npx.cmd 存在
```

配置里写全路径：

```json
{
  "command": "C:\\Windows\\System32\\cmd.exe",
  "args": ["/c", "<node目录>\\npx.cmd", "-y", "<包名>", ...]
}
```

注意：全路径在 node 升级后会失效（版本目录名带版本号）。交付时要提醒用户。

### 3. 探测服务是否可启动

用 printf 喂三条 JSON-RPC（initialize / initialized / tools/list），过滤掉 npm warn：

```bash
cd /tmp && printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"1.0"}}}' \
 '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
 | "<node目录>/npx.cmd" -y <包名> <参数...> 2>&1 | grep -v "^npm warn" | head -20
```

判读：
- 有 `{"result":{"protocolVersion"...}}` → 启动成功，记下 serverInfo.version
- 有 `[ERROR] ... Missing required parameters` → 该 MCP 需要必填参数，**空配置交付是无效的**，必须向用户索取或使用占位值（占位值能让服务启动、工具可见，只是实际调用会失败）

**要测真实工具调用（而不只是 tools/list）时，必须用 `{ printf ...; sleep N; } |` 包住**，即喂完请求后 sleep（建议 20–30s）再让 stdin 关闭。否则 stdin 一关闭服务就打印 `Received stdin end, shutting down` 并退出，异步工具（如 SSH 连接、网络请求）还没返回就被杀掉，会误判成失败。

```bash
cd /tmp && { printf '%s\n' '<initialize>' '<initialized>' '<tools/call>'; sleep 25; } | "<node目录>/npx.cmd" -y <包名> <参数...> 2>&1 | grep -v "^npm warn" | head -30
```

调用工具用标准的 `{"jsonrpc":"2.0","id":N,"method":"tools/call","params":{"name":"<tool>","arguments":{...}}}`，其中键名是 `arguments`（不是 `params`，容易写错）。

### 4. 合并写入 ~/.workbuddy/mcp.json

先 Read 现有文件，把新条目加进 `mcpServers`，再用 Write 覆盖。密钥写进 `env` 字段。

### 5. 校验 JSON

```bash
"<node目录>/node.exe" -e "const j=JSON.parse(require('fs').readFileSync(process.env.USERPROFILE+'/.workbuddy/mcp.json','utf8'));console.log(Object.keys(j.mcpServers))"
```

### 6. 告知用户手动启用

配置写完**不会自动生效**。必须让用户打开连接器管理页右上角的「自定义连接器」入口，对新 server 点「信任」，才会激活。

## 常见坑

| 坑 | 表现 | 处理 |
|---|---|---|
| 必填参数缺失 | 启动即 `Missing required parameters` 并退出 | 索取参数；或先写占位值让服务能起来 |
| 直接写 `"command": "npx"` | 客户端报 spawn ENOENT / EINVAL | 用 `cmd.exe /c` + `npx.cmd` 全路径 |
| 参数与值写成同一个字符串 | 服务解析不到参数 | 每个参数和值都是 `args` 数组里的独立元素 |
| 覆盖 mcp.json | 其他 MCP 消失 | 先 Read 再合并 |
| 忘记让用户点信任 | 装完没反应 | 交付话术里明确写出这一步 |

## 顺带检查项

- 服务启动若打印安全告警（如"没有命令白名单""没有路径限制"），要在交付时转述给用户，并给出加固建议。
- 个人 scope 的 npm 包属于第三方代码，必要时提示供应链风险。
