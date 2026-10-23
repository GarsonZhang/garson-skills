---
name: to-cms
description: 将已有回答、回复、访谈记录、笔记或草稿整理成可发布的 CMS 文章，生成标题、SEO 关键词、标签、摘要、Markdown 正文和真实配图，并通过 YESCMS MCP 发布新文章；也可根据现有 YESCMS 文章地址读取原始详情、按要求修改并保存。用户要求发布到 YESCMS、上传文章配图、生成发布 JSON、使用 YESCMS MCP，或提供文章地址要求修改、更新、润色、重写并保存现有文章时使用。
---

# 转 CMS 文章

## 核心原则

- 新建文章正文使用 Markdown；修改现有文章时保持原 `contentFormat`，不要擅自把 HTML 转成 Markdown，或把 Markdown 转成 HTML。
- 默认忠于源内容，提升结构、标题、摘要、标签和 SEO 匹配度，不凭空添加无法从源内容推出的事实。
- 生成 3-8 个文章标签。标签应短、具体、可复用，用于站内归类；不要把完整长尾搜索词直接当标签。
- 生成约 10 个 SEO 关键词。关键词用数组或逗号分隔，避免重复和堆砌。
- 生成一段可直接用作文章摘要或 meta description 的摘要。
- 新建发布或准备新文章发布 JSON 时必须生成至少一张真实图片，不能只给图片提示词。图片必须同时作为文章封面和 Markdown 正文开头图。
- 修改现有文章时，只修改用户明确要求的字段；未要求更换配图时保留现有封面和正文图片，不强制生成新图。
- 通过脚本、JSON 或字符串模板构造 Markdown 时，提交前检查实际输出而非源代码转义：行内代码必须是 `` `code` ``，代码围栏必须是 `` ``` ``，不得把语言字符串转义符一并写入正文（例如 ``\` ``、``\`\`\` ``）。除非源内容明确需要展示反斜杠，发现这类序列时先修正再发布或更新。

## 类目选择

- 通过 MCP 工具 `yescms_list_categories` 从 YESCMS 站点接口读取可用文章档案类目。
- 每次发布前都必须让用户手动选择或明确确认目标档案类目；如果用户已在当前请求中指定目标类目，并明确要求“直接发布”“无需确认”“不用确认”“马上发布”等同等含义，则读取类目后校验匹配项并直接发布，不再二次确认。
- 不要默认使用 `defaultCategory`，不要因为只有一个启用类目就直接使用；即使只有一个类目，也要让用户确认。
- 如果目标类目返回 `groups`，必须同时列出可用分组，并让用户手动选择或明确确认 `groupID`；不要自行推断分组。
- 用户已经在当前请求中明确写出目标类目和分组，并同时明确要求直接发布或无需确认时，发布前不要复述等待确认；如果缺少类目、缺少必需分组，或直接发布意图不明确，才等待用户选择或确认。
- 如果 MCP 未配置或没有可用类目，提示用户先用 YESCMS MCP 配置生成器生成宿主配置片段，并在 Codex/Cursor/Claude Code/opencode 等宿主中启用 YESCMS MCP。

## 新建并发布文章

1. 从用户消息、上一条回答、附件或草稿中识别源内容。没有源内容时，请用户提供要转换的材料。
2. 调用 `yescms_list_categories` 读取类目和分组。若用户已在当前请求中明确指定目标类目（以及必需分组）并要求直接发布或无需确认，则校验匹配后继续发布；否则展示可选项，并等待用户手动选择或确认。没有明确选择/确认前，不要发布。
3. 根据源内容生成标题、摘要、SEO 关键词、文章标签和 Markdown 正文。
4. 生成至少一张适合 CMS 文章封面的真实图片。优先使用可用的图片生成工具；如果用户提供了可用图片，也可以使用用户图片。不能生成或获得图片时，不要发布，先说明缺少图片生成/上传条件。
5. 调用 MCP 工具 `yescms_upload_article_image` 上传图片，并把返回 URL 填入 `coverImageUrl`。
6. 将上传后的图片 URL 插入 Markdown 正文第一行，格式为 `![文章封面](<coverImageUrl>)`，其后空一行再进入正文标题或正文内容。
7. 如果用户要求“直接发布到 YESCMS”，调用 MCP 工具 `yescms_publish_article`。不要在技能、提示词、回答或发布 JSON 中写入 token、Authorization header 或宿主配置。
8. 如果用户只要求准备内容或生成发布 JSON，不实际调用发布工具，输出可提交给 `yescms_publish_article` 的 JSON；该 JSON 也必须包含已上传图片 URL，且 Markdown 第一行必须包含该图片。

## 修改现有文章

1. 要求用户提供标准文章地址，格式为完整 URL 或 `/archive/{category}/{id}.html`。没有文章地址时不要猜测。
2. 调用 `yescms_get_article` 读取数据库中的原始正文、`contentFormat`、标题、摘要、关键词、标签、封面、发布状态和档案附加属性；不要抓取前台 HTML 代替原始内容。
3. 根据用户要求修改内容。正文发生变化时，必须基于读取到的完整正文生成完整替换内容，并保持原 `contentFormat`；不能只提交差异片段。
4. 只向 `yescms_update_article` 传入用户明确要求改变的字段。不要重复提交未修改字段，尤其不要擅自改变 `isPublished`、`isTop`、封面、标签或档案附加属性。
5. 用户要求更换图片时，先生成或取得真实图片，再调用 `yescms_upload_article_image`，最后把返回 URL 写入明确需要更新的封面或正文位置。
6. 用户明确要求“直接修改”“直接保存”或同等含义时，可直接调用 `yescms_update_article`；否则先展示修改后的内容或变更摘要，得到确认后再保存。
7. 保存成功后返回文章地址和实际修改的字段。接口报错时原样说明原因，不改走 `yescms_publish_article`，也不把更新失败的文章当新文章发布。

修改现有文章时不重新选择类目和分组。当前 MCP 修改能力不支持静态页面自定义地址；遇到非标准文章地址时明确说明不支持。

## MCP 发布工具

发布和上传必须通过 YESCMS MCP 工具完成：

- `yescms_list_categories`
- `yescms_upload_article_image`
- `yescms_get_article`
- `yescms_update_article`
- `yescms_publish_article`

安全约束：

- 不要要求用户把 token 粘贴进技能、文章 JSON 或对话正文。
- 不要输出 `Authorization` header。
- token 应由 MCP 宿主配置或 MCP Server 运行环境持有，例如 `YESCMS_AI_TOKEN`、`YESCMS_AI_TOKEN_FILE`、`YESCMS_AI_TOKEN_COMMAND` 或 `YESCMS_CREDENTIAL_TARGET`。
- 如果 MCP 未配置或工具不可用，只生成文章内容和发布 JSON，并提示需要先配置 YESCMS MCP；不要尝试直接请求 YESCMS HTTP 接口。

更新 JSON 示例：

```json
{
  "articleUrl": "https://www.example.com/archive/news/123.html",
  "title": "<只在需要改标题时提供>",
  "content": "<只在需要改正文时提供完整正文>",
  "contentFormat": "<修改正文格式时才与 content 一起提供：html 或 markdown>",
  "summary": "<只在需要改摘要时提供>",
  "seoKeywords": ["<只在需要改关键词时提供>"],
  "tagList": ["<只在需要改标签时提供>"]
}
```

示例中的占位字段不是必填项。实际调用时删除所有未修改字段；`contentFormat` 省略时保持原格式。

发布 JSON 示例：

```json
{
  "category": "<选中的文章档案类目编号>",
  "title": "<文章标题>",
  "markdown": "<Markdown 正文>",
  "summary": "<文章摘要>",
  "seoKeywords": ["关键词1", "关键词2", "关键词3"],
  "tagList": ["标签1", "标签2", "标签3"],
  "coverImageUrl": "<通过 yescms_upload_article_image 上传后得到的图片 URL，必填>",
  "isPublished": true,
  "isTop": false,
  "groupID": "<类目接口返回的分组 groupID，可为空>",
  "shortTitle": "<类目配置中的 shortTitle 或文章短标题，可为空>",
  "linkTitle": "<类目配置中的 linkTitle 或文章链接标题，可为空>"
}
```

## 普通输出格式

除非用户要求发布 JSON 或直接发布，按以下顺序输出：

```markdown
# <文章标题>

档案类目：<类目名称或 category>

SEO关键词：关键词1, 关键词2, 关键词3, 关键词4, 关键词5, 关键词6, 关键词7, 关键词8, 关键词9, 关键词10

文章标签：标签1;标签2;标签3;标签4

摘要：<文章摘要>

<Markdown 正文>

配图：<已生成并上传的图片 URL；该 URL 也必须作为 coverImageUrl，并出现在 Markdown 正文第一行>
```

## 配图要求

新建文章时必须生成至少一张真实图片，并通过 `yescms_upload_article_image` 上传后用于：

- `coverImageUrl`
- Markdown 正文第一行：`![文章封面](<coverImageUrl>)`

图片生成提示词应包含：

- 画面主体和场景
- 视觉风格
- 构图方式
- 情绪与色彩方向
- 推荐画幅，通常文章封面使用 `16:9`

提示词示例：

```text
一张精致的 16:9 CMS 文章封面图，画面展示<核心主题>，包含<关键辅助视觉元素>，现代编辑风格，构图干净，专业而温暖的光线，图片中不出现文字。
```

如果当前环境无法生成图片或上传图片，不要发布文章；先告诉用户需要启用图片生成能力、提供本地图片，或修复 `yescms_upload_article_image`。

修改现有文章时，仅在用户要求更换封面或正文图片时执行本节；否则保留已有图片。
