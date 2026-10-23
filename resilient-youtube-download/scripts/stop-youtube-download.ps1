[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$JobDirectory
)

$ErrorActionPreference = 'Stop'
$JobDirectory = [System.IO.Path]::GetFullPath($JobDirectory)
$ConfigPath = Join-Path $JobDirectory 'config.json'
$StopFlagPath = Join-Path $JobDirectory 'stop.flag'
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "找不到任务配置：$ConfigPath"
}

$message = "Stop requested at $(Get-Date -Format 'o'). The controller will stop cooperatively after the active yt-dlp invocation returns."
[System.IO.File]::WriteAllText($StopFlagPath, $message, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "已写入停止标志：$StopFlagPath"
Write-Host '当前 yt-dlp 调用返回后，控制进程将停止；不会删除视频、分片、字幕或 cookie 文件。'
