---
name: npm-docker-native-deps
slug: npm-docker-native-deps
version: 1.0.0
description: Fix "Cannot find native binding" / missing platform packages when `npm ci` runs in a Docker container but package-lock.json was generated on Windows/macOS. Covers npm/cli#4828, surgical lockfile patching, and verifying platform-specific installs without the target OS.
metadata: {"agent_created": true}
---

# 修复 npm 锁文件缺少跨平台原生依赖（Docker 构建失败）

## 何时触发

构建日志里出现下面任一特征，就该用本流程：

```
Error: Cannot find native binding. npm has a bug related to optional
dependencies (https://github.com/npm/cli/issues/4828)
  cause: Cannot find module '@rolldown/binding-linux-x64-musl'
         Cannot find module '@tailwindcss/oxide-linux-x64-musl'
         Cannot find module 'lightningcss-linux-x64-musl'
```

- `npm ci` 在容器里「安装成功」但 `npm run build` / `node` 启动时报缺原生绑定
- 常见于 Vite 8+（Rolldown）、Tailwind 4（`@tailwindcss/oxide`）、`lightningcss`、`esbuild`、`@oxc-parser`、`sharp`、`@swc/core`
- 基础镜像是 alpine（musl）或 slim（glibc），而锁文件是在 Windows/macOS 上生成的

## 根因

npm 在**已存在 `node_modules`** 的机器上生成 `package-lock.json` 时，`packages` 段只写入**当前平台**的可选原生依赖，其它平台全部漏记（npm/cli#4828）。

`npm ci` **严格按锁文件安装，不会自行补齐**。所以容器里那些跨平台原生包压根不会被装出来。

量化判断：锁文件里带 `os` 约束的条目数 vs npm 正常解析应有的数量（通常 60+）。

## 诊断（3 步确认）

```bash
# 1. 列出锁文件里所有平台条目
grep -o '"node_modules/[^"]*-win32[^"]*": {' package-lock.json | sort -u
grep -o '"node_modules/[^"]*-linux[^"]*": {' package-lock.json | sort -u

# 2. 看父包的 optionalDependencies 清单（通常这份是【全的】，缺的是 packages 段实体）
grep -n -A20 '"node_modules/rolldown"' package-lock.json | grep optionalDependencies -A18

# 3. 生成一份 npm 权威对照锁文件，看正常应该有多少平台条目
mkdir /tmp/ref && cp package.json /tmp/ref/ && cd /tmp/ref
npm install --package-lock-only --no-audit --no-fund
```

用 node 脚本穷举带 `os` 字段的条目（比 grep 可靠）：

```js
const j = require("./package-lock.json");
for (const [k, v] of Object.entries(j.packages || {}))
  if (v && v.os) console.log(k, v.version, v.os, v.cpu, v.libc || "-");
```

## 方案选择（实测结论）

| 方案 | 结论 |
|---|---|
| `npm install --package-lock-only --os=linux --cpu=x64 --libc=musl` | ❌ 无效，npm 输出 `up to date`，锁文件一字不动 |
| 同上再加 `--force` | ❌ 无效，输出与原文**逐字节相同** |
| 删掉锁文件让 npm 重新解析 | ⚠️ 能补全，但会连带漂移几十个包（实测 66 个，含 react / supabase / 各 tanstack 子包）。只有在「顺手升级依赖」可接受时才用 |
| **定点补条目（推荐）** | ✅ 最小 diff、零版本漂移 |

## 定点补条目的做法

**核心技巧：字段值不手打，从同族已有条目克隆。**

锁文件里通常已经有一个「当前平台」的同族条目（如 `...-win32-x64-msvc`），它的 `version` / `cpu` / `license` / `optional` / `engines` / `funding` 与目标平台条目**完全一致**，只需把 `os` 换掉：

```js
const j = JSON.parse(fs.readFileSync("package-lock.json", "utf8"));
const P = j.packages;
for (const k of Object.keys(P)) {
  if (!k.endsWith("-win32-x64-msvc")) continue;
  const clone = JSON.parse(JSON.stringify(P[k]));
  clone.os = ["linux"];                       // 唯一改动
  P[k.replace("-win32-x64-msvc", "-linux-x64-musl")] = clone;
}
```

动手前**必须**先拿 npm 生成的对照锁文件逐字段比对（去掉 `resolved`/`integrity` 后应完全一致），确证「克隆 + 改 os」是等价变换。版本若不一致（npm 新解析会漂版本），**保留项目已固定的版本**。

### 四个坑（都会导致「改完还是失败」）

1. **别同时补 `linux-x64-gnu` 和 `linux-x64-musl`**
   npm 往往不在条目里记 `libc` 字段，两条同时存在会让容器把两个绑定都装上，运行时可能加载错的那个。基础镜像是 alpine（musl）就**只补 musl**，是精确解。

2. **`resolved`/`integrity` 跟随原文件风格**
   若原锁文件大部分条目没有这两个字段（说明刻意保持 registry 无关，比如要兼容私有镜像），补条目时也别写。写死 `registry.npmjs.org` 的 URL 在只有内网镜像的构建机上会直接失败。

3. **CRLF 陷阱（Windows）**
   `core.autocrlf=true` 时工作区是 CRLF、仓库 blob 是 LF。改写后写回必须保持 CRLF，否则整个文件都会显示成改动。

   先确认：`git ls-files --eol package-lock.json` → `i/lf w/crlf`。
   写回：`text.replace(/\n/g, "\r\n")`（JSON.stringify 已把字符串内换行转义，全局替换安全）。

4. **键序**
   npm 写 `packages` 是按字典序的。合并后重新按字典序排一遍，diff 才干净（若原文件本来就排好序，重排不会产生额外改动）。

## 验证（没有目标 OS 也能验）

关键手段：**npm 支持用 `--os` / `--cpu` / `--libc` 覆盖平台探测**，在 Windows 上也能真实模拟 linux/musl 安装行为（平台过滤、下载、安装都会按覆盖后的平台走）。

```bash
# 对照组：原始锁文件
npm ci --os=linux --cpu=x64 --libc=musl --no-audit --no-fund
# 实验组：补丁后的锁文件
npm ci --os=linux --cpu=x64 --libc=musl --no-audit --no-fund
```

然后核对三件事：

```bash
# ① 安装包数应正好多出「补了几条」那么多（如 436 → 441）
# ② 目标平台原生包目录确实存在，且含 .node 二进制
ls node_modules/@rolldown/binding-linux-x64-musl/*.node
# ③ 另一平台的条目被正确过滤（证明 os/cpu 过滤真的生效）
ls node_modules/@rolldown/binding-win32-x64-msvc   # 应不存在
```

最后再跑一次**默认平台**（不传 `--os` 等）：包数与改动前一致、仍装本机绑定、无 `EUSAGE`/不同步报错 → 证明本地开发零回归。

## 收尾

- 在 Dockerfile 的 `npm ci` 上方加注释：**「不要删掉/重新生成这个锁文件就完事」**，说明缺哪几个平台条目、为什么。否则下一个人重生成锁文件会再踩一次。
- 若项目 CI 从某个远端仓库拉代码，改完记得推上去，否则 CI 仍用旧文件（这类「改了但没生效」的循环极耗时间）。
