---
name: resilient-youtube-download
description: Download one or many YouTube videos with local yt-dlp and ffmpeg into clean per-video folders while preserving merged MP4 media, info JSON, requested WebVTT subtitles, and a Simplified Chinese zh-Hans subtitle track. Provides resumable sequential queues, a parallel Chinese-subtitle worker, retry backoff, optional proxy or cookies, a 10-second progress monitor, state/log files, and optional Windows Task Scheduler recovery. Use when the user asks to download, prefetch, resume, batch-process, add Chinese subtitles, monitor, or automatically restart YouTube video or playlist downloads. Do not use for DRM content, CAPTCHA bypass, account-password handling, or browser automation.
---

# Reliable YouTube downloads

Use the bundled PowerShell scripts. Do not open the Codex browser for acquisition when `yt-dlp` can handle the URL.

## Core rules

1. Use local `yt-dlp`, `ffmpeg`, and `ffprobe`.
2. Download video and audio together and merge/remux to MP4. Do not extract or retain a standalone audio deliverable.
3. Keep the MP4, `.info.json`, requested original/automatic `.vtt` subtitles, job state, and logs.
4. Start the independent Chinese-subtitle worker by default. For every completed video, keep an existing valid `*.zh-Hans.vtt`; otherwise save YouTube's Simplified Chinese WebVTT rendition from `.info.json`. Validate the WebVTT header, timestamps, and Chinese text before accepting it.
5. Never request or store the user's account password. Accept a cookie file only when the user explicitly provides its path; never modify or delete it.
6. Do not bypass CAPTCHA, bot checks, DRM, or platform access controls. Report the blocker.
7. Use a proxy only when the user gives or approves it. Passing `-Proxy` affects only the download and subtitle jobs. When the user explicitly approves switching nodes, prefer an isolated job-local sidecar; never change the global Clash selection or system proxy.
8. Preserve partial files for `yt-dlp` resume. Do not delete failed downloads unless the user explicitly asks.

## Start a job

Run `scripts/start-youtube-download.ps1` with direct URLs or a UTF-8 text file containing one URL per line. Blank lines and lines beginning with `#` are ignored.

```powershell
$skill = 'D:\Program\.codex\skills\resilient-youtube-download'
& "$skill\scripts\start-youtube-download.ps1" `
  -Urls @('https://www.youtube.com/watch?v=VIDEO_ID') `
  -OutputRoot 'D:\CodexYoutubeDown' `
  -JobName 'my-course'
```

For an approved job-local proxy and a visible 10-second monitor:

```powershell
& "$skill\scripts\start-youtube-download.ps1" `
  -UrlsFile 'D:\downloads\urls.txt' `
  -OutputRoot 'D:\downloads' `
  -JobName 'course-a' `
  -Proxy 'http://127.0.0.1:7890' `
  -RefreshSeconds 10
```

Useful options:

- `-StartNumber 21`: start folder numbering at 21.
- `-FolderPrefix 'Video'`: create `Video NN - title`; pass an empty string for `NN - title`.
- `-StripTitleRegex '^SAP S/4HANA .*? -\s*'`: remove an explicit title prefix before naming.
- `-SubtitleLanguages 'en.*,en,zh-Hans'`: choose subtitle languages.
- `-SubtitleLanguages 'none'`: skip original-language subtitle requests; the independent `zh-Hans` worker still runs.
- `-SkipChineseSubtitles`: explicitly disable the default Chinese-subtitle worker.
- `-ExpandPlaylists`: expand playlist URLs; omit it to treat every input as one video and force `--no-playlist`.
- `-CookiesFile 'D:\secure\youtube-cookies.txt'`: use an explicitly supplied cookie file without changing it.
- `-RecoveryMode TaskScheduler`: register a per-job recovery task. This is a persistent system change, so use it only when the user explicitly asks for crash/reboot recovery or approves it.
- `-VerifyFullDecode`: perform a full ffmpeg decode after download; this can take roughly the video duration or longer.
- `-PrepareOnly`: validate tools and write job configuration without starting downloads.
- `-Resume`: remove this job's cooperative stop flag and resume an existing job.

The default process mode retries network and `yt-dlp` failures inside one controller. It also starts `scripts/ensure-zh-subtitles.ps1` as a separate hidden process. Task Scheduler mode also restarts the controller after an unexpected process exit or user logon.

## Chinese subtitle worker

The worker processes only stable MP4 files that already contain video and audio. It never overwrites an existing invalid Chinese subtitle; it reports the exact file instead. It uses no proxy unless `-Proxy` was explicitly passed to the job.

For a previously downloaded root, start one worker manually:

```powershell
& "$skill\scripts\ensure-zh-subtitles.ps1" `
  -OutputRoot 'D:\downloads\course-a' `
  -ExpectedCount 60 `
  -MaxAttemptsPerItem 3 `
  -FfprobePath 'D:\tools\ffmpeg\bin\ffprobe.exe'
```

Read `.youtube-download\zh-subtitle-worker\state.json` and `subtitle.log` to monitor a root worker. A job worker stores the same files under `<job-directory>\zh-subtitle-worker`.

The worker never retries one video forever. `-MaxAttemptsPerItem` defaults to `3`; after that limit it writes `blocked.json`, skips that item, and eventually exits with state `Blocked` after every available item is either complete or blocked.

For repeated HTTP 429 responses:

1. Request a cooperative stop and read `blocked.json`.
2. Use only a user-approved job-local proxy. If the user explicitly asked to switch nodes, start or change an isolated sidecar instead of changing the global Clash or system proxy.
3. Verify the new node with a fresh `curl.exe --proxy` process: confirm a new egress IP and confirm one blocked subtitle URL returns HTTP 200 with a valid Chinese `WEBVTT` body.
4. Restart with `-Proxy` and a new `-WorkerName`, so the new node receives a fresh bounded attempt budget.

## Monitor and stop

The start script opens `scripts/monitor-youtube-download.ps1` unless `-NoMonitor` is passed. Closing the monitor never stops the download.

To reopen a monitor:

```powershell
& "$skill\scripts\monitor-youtube-download.ps1" `
  -JobDirectory 'D:\downloads\.youtube-download\course-a' `
  -RefreshSeconds 10
```

To request a cooperative stop after the current `yt-dlp` invocation returns:

```powershell
& "$skill\scripts\stop-youtube-download.ps1" `
  -JobDirectory 'D:\downloads\.youtube-download\course-a'
```

Do not kill processes or unregister recovery tasks unless the user explicitly requests it.

## Verify completion

Read `state.json`, `queue.json`, and `download.log` inside the job directory. Completion requires:

- job state `Completed`;
- every queue item state `Completed`;
- one valid MP4 per item;
- `ffprobe` confirms a video stream and, unless explicitly allowed, an audio stream;
- `.info.json` exists;
- no final standalone `.m4a`, `.mp3`, `.aac`, `.wav`, or `.opus` deliverable;
- requested subtitles are preserved when YouTube provides them.
- the Chinese-subtitle worker state is `Completed` and every completed video has a valid `*.zh-Hans.vtt`, unless the user explicitly passed `-SkipChineseSubtitles`.

If `.info.json` has no Simplified Chinese WebVTT rendition, record and report that exact video; do not fabricate a subtitle file.
