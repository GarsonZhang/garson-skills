[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VideoPath,

    [Parameter(Mandatory = $true)]
    [string[]]$Timestamps,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [string]$FfmpegPath = 'ffmpeg'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $VideoPath -PathType Leaf)) {
    throw "视频文件不存在：$VideoPath"
}

$ffmpeg = if (Test-Path -LiteralPath $FfmpegPath -PathType Leaf) {
    (Resolve-Path -LiteralPath $FfmpegPath).Path
} else {
    $command = Get-Command $FfmpegPath -ErrorAction SilentlyContinue
    if ($null -eq $command) { throw "找不到 ffmpeg：$FfmpegPath" }
    $command.Source
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$results = New-Object System.Collections.Generic.List[string]

foreach ($timestamp in $Timestamps) {
    if ($timestamp -notmatch '^\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?$') {
        throw "时间点格式无效：$timestamp；请使用 HH:mm:ss 或 HH:mm:ss.fff"
    }

    $safeTimestamp = $timestamp -replace '[:.]', '-'
    $outputPath = Join-Path $OutputDirectory "frame-$safeTimestamp.png"

    # PNG 按源视频分辨率导出，不做放大、锐化或压缩转换。
    & $ffmpeg -hide_banner -loglevel error -ss $timestamp -i $VideoPath -frames:v 1 -y $outputPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw "提取视频帧失败：$timestamp"
    }

    $results.Add((Resolve-Path -LiteralPath $outputPath).Path)
}

$results

