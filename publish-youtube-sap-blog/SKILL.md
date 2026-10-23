---
name: publish-youtube-sap-blog
description: Convert YouTube SAP S/4HANA training videos into accurate Chinese tutorials with preserved source media, reviewed Simplified Chinese WebVTT subtitles, full-resolution SAP interface screenshots, mandatory Chinese recreation of every non-SAP-interface visual, SAP official fact-checking, and direct YESCMS publication. Use when the user provides a YouTube SAP training URL and asks Codex to read or summarize the video, create a Chinese blog, download or translate subtitles, capture clear screenshots, translate and recreate non-SAP visuals, follow a numbered SAP training title format, save downloaded video/audio/subtitles, or publish the result to the YESCMS SAP category.
---

# Publish YouTube SAP Blog

Turn one SAP training video into a traceable Chinese article and publish it only when the user requests publication. Preserve the video's teaching order while correcting configuration-specific claims with official SAP sources.

## Required companion skill

Load and follow `to-cms` before any YESCMS upload or publication. User-provided category and no-confirmation instructions override `to-cms`'s normal category confirmation step.

## Workflow

### 1. Lock the request constraints

Extract these values before acting:

- YouTube URL and playlist index;
- requested CMS category;
- title pattern and video-number width;
- whether publication is authorized without another confirmation;
- where downloaded video, audio, and subtitle files must be retained.

Use the playlist index as the video number unless the user supplies another sequence number. Format two-digit numbers with leading zeroes, for example `04`.
Honor plan-only or draft-only wording literally: do not download, upload, or publish until a later request explicitly authorizes those actions.

### 2. Read project memory

Read `CONTEXT.md`, local `AGENTS.md`, and `lessons.md` when present. Preserve previous publishing conventions and record the new result in `CONTEXT.md` after completion.

### 3. Acquire metadata and source material

Prefer a purpose-built YouTube connector or `yt-dlp`; do not scrape the visible YouTube page for media URLs.

On Windows, use `scripts/download-youtube.ps1` when `yt-dlp` is available. Pass the user-requested download root. The default personal root is `D:\CodexYoutubeDown`.

For any long-running or multi-video download, run `yt-dlp` under two independent recovery layers. The inner supervisor must check every 10 seconds and restart the downloader from the first incomplete item with resumable `.part` files and bounded backoff. The outer guard must restart the inner supervisor if it exits before the status manifest reports every requested item as complete. On Windows, register the outer guard as a current-user scheduled task with `IgnoreNew`, no execution time limit, and one-minute failure restarts so it also survives an outer-guard crash or user logon. Use singleton locks, PID files, an explicit stop flag, and persistent logs. Treat a fully completed manifest or an explicit stop flag as a normal terminal state and never relaunch after either condition. Start the scheduled outer guard independently of the current Codex task before continuing with article work.

First read metadata and confirm:

- exact video title;
- duration;
- playlist index;
- available subtitle languages;
- source resolution.

When full media or subtitles are downloaded, keep them in `<download-root>\<video-title>\`. Use filesystem-safe title characters without replacing the logical title in the article.

Download original/manual captions first. If only automatic captions exist, keep the original automatic caption file. Do not repeatedly retry translated subtitles after HTTP 429; continue from the preserved original captions or perform a complete local transcription when audio is available.

Whenever a downloaded source subtitle is not Simplified Chinese, create a reviewed Simplified Chinese subtitle during translation:

- keep the original subtitle file unchanged;
- translate the complete spoken content, not only the excerpts used in the article;
- preserve cue order and timestamps so the Chinese subtitle remains synchronized with the video;
- save valid UTF-8 WebVTT as `<video-title>.zh-Hans.vtt` in the same `<download-root>\<video-title>\` directory;
- preserve necessary identifiers such as `MM01`, `ROH`, SAP product names, field codes, and organization codes while translating their explanations;
- review the full file for missing cues, untranslated explanatory sentences, broken timestamps, invalid `WEBVTT` structure, and encoding errors;
- do not treat an unreviewed YouTube auto-translation as the finished Chinese subtitle.

### 4. Build an evidence outline

Read the complete subtitle or transcription and create a timestamped outline. Separate:

- topics actually explained;
- agenda items merely announced;
- instructor examples;
- system-specific configuration;
- claims that need SAP official verification.

Never state that an agenda item was taught when the video ended before it. Retain exact example values such as transaction codes, plants, material types, and number ranges, but label configurable values as examples.

### 5. Select and create images

Inspect frames across the full video before choosing screenshots. Use `scripts/extract-video-frames.ps1` for exact timestamps.

For SAP GUI or SAP Fiori interface screenshots:

- export PNG at the source resolution;
- prefer 1920×1080 when the source provides it;
- do not upscale, sharpen, blur, or recompress;
- avoid transient errors, menus covering key fields, cursor annotations, notification overlays, and unrelated desktop windows;
- select only frames that materially support an article step.

For every image that is not an SAP GUI or SAP Fiori interface screenshot:

- never use the original video frame directly in the article;
- always recreate it as a clean 1920×1080 Chinese visual, including slides, diagrams, charts, tables, photos, and decorative illustrations;
- translate every translatable visible word, sentence, label, annotation, legend, and heading into Chinese;
- retain only identifiers that must remain unchanged, such as `MM01`, `ROH`, SAP product names, field codes, and organization codes; add a concise Chinese explanation when needed;
- preserve the original information, relationships, sequence, and meaning instead of copying its low-resolution styling;
- use readable Chinese fonts, high contrast, and short labels;
- inspect the finished image and reject it if untranslated explanatory text remains;
- never present a recreated image as an original SAP GUI or SAP Fiori screenshot.

Create at least one real image. Prefer one Chinese cover/overview diagram plus three to six original SAP GUI or SAP Fiori interface screenshots for an operational lesson.

### 6. Fact-check SAP behavior

Search current primary SAP sources before publication. Prefer SAP Learning and SAP Help. Verify at least:

- transaction-code meaning;
- organizational levels;
- master-data view ownership;
- fields that cannot be changed after creation;
- configurable material-type, numbering, procurement, and valuation behavior.

Use official information to correct or qualify the article without rewriting the instructor's demonstrated sequence. Explicitly distinguish `视频示例` from `SAP 标准规则` and `本系统配置`.

### 7. Write the Chinese article

Use this title form unless the user supplies another exact rule:

`SAP S/4HANA MM模块培训 NN - 主题`

Write the cover image as the first Markdown line. Then include:

- a short lesson objective;
- concepts in the video's order;
- tables for material types, transactions, mappings, or common mistakes;
- numbered operating steps with screenshots placed immediately after the relevant explanation;
- configurable-value warnings;
- a clear lesson boundary when planned topics were not reached;
- the source video and official SAP references.

Do not pad the article with generic SAP history or unrelated module knowledge. Keep the Chinese terminology consistent and retain important English UI labels in parentheses when helpful.

Before publishing, read `references/publication-checklist.md` completely and pass every applicable check.

### 8. Upload and publish

When the user explicitly requests the SAP category and no reconfirmation, list categories once, resolve the category slug, and publish without asking again. For the established YESCMS site, use category `sap` only after the category listing confirms it.
If the selected category has no groups, omit `groupID`; never invent a group or block publication on a nonexistent group choice.

Upload all images with compression disabled. Use the uploaded cover URL as:

- the first Markdown image;
- `coverImageUrl`;
- the first entry in `imageUrls`.

Publish with `isPublished: true`, the original YouTube URL, a concise summary, relevant SEO keywords, and three to eight tags. Do not publish if the title, category, cover, or Markdown body is missing.

### 9. Verify and record

Open the public article URL and verify:

- HTTP 200;
- exact title;
- cover URL;
- at least one body marker;
- expected category path.

Update `CONTEXT.md` with video ID, local source folder, image count, article ID, article URL, title, and key fact-check decisions.

Report only the published URL, verified status, retained local folder, generated Chinese subtitle filename, image count/resolution, and skills used. Do not suggest unrelated improvements after completion.

## Failure rules

- Stop and report the exact blocker when neither captions nor usable audio can be obtained.
- Do not invent transcript content, SAP configuration, screenshots, CMS responses, or verification results.
- Preserve already-downloaded media, original subtitles, and generated Chinese subtitles; never delete them as cleanup.
- Do not publish a draft when the user authorized a finished article.
- Do not silently reduce screenshot resolution or enable CMS compression.
