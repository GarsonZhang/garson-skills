[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Url,

    [string]$DownloadRoot = 'D:\CodexYoutubeDown',

    [string]$YtDlpPath = 'yt-dlp',

    [ValidateSet('Metadata', 'Download')]
    [string]$Mode = 'Download',

    [string]$SubtitleLanguages = 'en-orig,en'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-Executable([string]$PathOrName) {
    if (Test-Path -LiteralPath $PathOrName -PathType Leaf) {
        return (Resolve-Path -LiteralPath $PathOrName).Path
    }

    $command = Get-Command $PathOrName -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "找不到 yt-dlp：$PathOrName"
    }

    return $command.Source
}

$ytDlp = Resolve-Executable $YtDlpPath

if ($Mode -eq 'Metadata') {
    & $ytDlp --dump-single-json --skip-download --no-warnings -- $Url
    if ($LASTEXITCODE -ne 0) {
        throw "读取 YouTube 元数据失败，退出码：$LASTEXITCODE"
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $DownloadRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $DownloadRoot -Force | Out-Null
}

# 使用视频标题创建子目录；Windows 不支持的字符由 yt-dlp 安全替换。
$outputTemplate = Join-Path $DownloadRoot '%(title)s\%(title)s.%(ext)s'

# 默认只下载英文原始字幕；简体中文字幕在完整翻译和人工复核后另存为 zh-Hans.vtt。
& $ytDlp `
    --windows-filenames `
    --newline `
    --write-info-json `
    --write-subs `
    --write-auto-subs `
    --sub-langs $SubtitleLanguages `
    --sub-format 'vtt' `
    --convert-subs 'vtt' `
    --format 'bv*[height<=1080]+ba/b[height<=1080]' `
    --merge-output-format 'mp4' `
    --output $outputTemplate `
    -- $Url

if ($LASTEXITCODE -ne 0) {
    throw "下载 YouTube 视频或字幕失败，退出码：$LASTEXITCODE"
}

