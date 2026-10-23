---
name: reverse-skill-router
description: Use the reverse-skill repository from Codex for authorized reverse engineering, security analysis, CTF, and defensive testing tasks. Requires the reverse-skill repository to be available as the current workspace or an explicitly supplied local path.
---

# Reverse Skill Codex adapter

## 本机安装入口

本安装随附的上游仓库位于 [repository/](repository/)，绝对路径为 `D:\Program\.codex\skills\reverse-skill-router\repository`。在其它工程中调用本技能且未另指定仓库时，从该目录读取 `README_AI.md`、`RULES.md` 和相关 `skills/<模块>/SKILL.md`，无需切换或替换当前工程。

工具连接沿用当前会话已提供的 MCP；下载新工具、启动额外服务或修改 MCP 配置仍需属于用户明确要求的范围。安装本技能本身不执行上游 bootstrap、router、case-init 或工具探测脚本。

This plugin is an optional Codex entry point. The repository remains the canonical, client-neutral implementation.

When the current workspace is the `reverse-skill` repository:

1. Read `RULES.md` at the repository root.
2. Run the platform-native `skills/scripts/master-route` entry with the user's task to select the PRIMARY skill from `skills/config/routing.json`.
3. Before any target action, create and validate `work/<case>/scope.md` with the platform-native `case-init` and `case-guard` scripts.
4. Open the selected `skills/<PRIMARY>/SKILL.md` and follow its task-specific instructions.
5. Resolve tools only through the generated `skills/tool-index.md`; do not register MCP servers or install tools unless the user requested that action.

If the repository is not the current workspace and no local repository path was supplied, explain that this adapter does not bundle a second copy of the router. Ask the user to open or clone `https://github.com/zhaoxuya520/reverse-skill` and then continue from its `RULES.md`.

Do not treat the presence of this plugin, a target name, or a sample path as authorization. Authorization comes from the repository's scope contract.
