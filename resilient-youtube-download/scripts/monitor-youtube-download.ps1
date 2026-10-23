[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$JobDirectory,
    [ValidateRange(5, 300)][int]$RefreshSeconds = 10
)

$ErrorActionPreference = 'Stop'
$JobDirectory = [System.IO.Path]::GetFullPath($JobDirectory)
$ConfigPath = Join-Path $JobDirectory 'config.json'
$QueuePath = Join-Path $JobDirectory 'queue.json'
$StatePath = Join-Path $JobDirectory 'state.json'
$LogPath = Join-Path $JobDirectory 'download.log'
$PidPath = Join-Path $JobDirectory 'controller.pid'
$IdentityPath = Join-Path $JobDirectory 'controller.identity.json'
$MonitorPidPath = Join-Path $JobDirectory 'monitor.pid'

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "找不到任务配置：$ConfigPath"
}
$config = Get-Content -LiteralPath $ConfigPath -Encoding UTF8 -Raw | ConvertFrom-Json
try { $Host.UI.RawUI.WindowTitle = "YouTube 下载进度 - $($config.jobName)（每 $RefreshSeconds 秒刷新）" } catch { }
[System.IO.File]::WriteAllText($MonitorPidPath, [string]$PID, (New-Object System.Text.UTF8Encoding($false)))

function Get-ControllerProcess {
    if (-not (Test-Path -LiteralPath $PidPath -PathType Leaf)) { return $null }
    if (-not (Test-Path -LiteralPath $IdentityPath -PathType Leaf)) { return $null }
    $pidText = (Get-Content -LiteralPath $PidPath -Encoding UTF8 -Raw).Trim()
    $controllerPid = 0
    if (-not [int]::TryParse($pidText, [ref]$controllerPid)) { return $null }
    try {
        $identity = Get-Content -LiteralPath $IdentityPath -Encoding UTF8 -Raw | ConvertFrom-Json
        $process = Get-Process -Id $controllerPid -ErrorAction SilentlyContinue
        if (-not $process) { return $null }
        if ([int]$identity.pid -ne $controllerPid) { return $null }
        if ([string]$identity.role -ne 'youtube-download-controller') { return $null }
        if ([long]$identity.startTimeUtcTicks -ne $process.StartTime.ToUniversalTime().Ticks) { return $null }
        return $process
    }
    catch { return $null }
}

while ($true) {
    Clear-Host
    Write-Host "YouTube 下载进度：$($config.jobName)" -ForegroundColor Cyan
    Write-Host "每 $RefreshSeconds 秒刷新；关闭此窗口不会停止后台下载。" -ForegroundColor DarkGray
    Write-Host ('-' * 88) -ForegroundColor DarkGray

    $controller = Get-ControllerProcess
    if ($controller) {
        Write-Host "控制进程：PID $($controller.Id)（运行中）" -ForegroundColor Green
    }
    else {
        Write-Host '控制进程：当前不存在；任务计划模式可能正在等待自动恢复。' -ForegroundColor Yellow
    }

    $state = $null
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        try { $state = Get-Content -LiteralPath $StatePath -Encoding UTF8 -Raw | ConvertFrom-Json } catch { }
    }
    if ($state) {
        $color = if ($state.state -eq 'Completed') { 'Green' } elseif ($state.state -eq 'Blocked') { 'Red' } else { 'White' }
        Write-Host "状态：$($state.state)；完成：$($state.completed)/$($state.total)" -ForegroundColor $color
        if ($state.currentNumber -ne $null) { Write-Host "当前编号：$($state.currentNumber)" }
        if (-not [string]::IsNullOrWhiteSpace([string]$state.currentFolder)) { Write-Host "当前目录：$($state.currentFolder)" }
        if (-not [string]::IsNullOrWhiteSpace([string]$state.lastError)) {
            Write-Host "最近错误：$($state.lastError)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host '状态：正在初始化队列。'
    }

    if (Test-Path -LiteralPath $QueuePath -PathType Leaf) {
        try {
            $queue = @(Get-Content -LiteralPath $QueuePath -Encoding UTF8 -Raw | ConvertFrom-Json)
            Write-Host ('-' * 88) -ForegroundColor DarkGray
            $queue | Select-Object @{Name='编号';Expression={$_.number}}, @{Name='状态';Expression={$_.state}}, @{Name='标题';Expression={$_.title}} | Format-Table -AutoSize
        }
        catch { Write-Host "队列暂时不可读：$($_.Exception.Message)" -ForegroundColor Yellow }
    }

    if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
        $latestProgress = Get-Content -LiteralPath $LogPath -Encoding UTF8 -Tail 500 |
            Where-Object { $_ -match '\[download\].*\d+(?:\.\d+)?%' } |
            Select-Object -Last 1
        if ($latestProgress) {
            Write-Host ('-' * 88) -ForegroundColor DarkGray
            Write-Host $latestProgress -ForegroundColor White
        }
    }

    Write-Host ('-' * 88) -ForegroundColor DarkGray
    Write-Host "任务目录：$JobDirectory" -ForegroundColor DarkGray
    Write-Host "本次刷新：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')；下次约 $RefreshSeconds 秒后。" -ForegroundColor DarkGray
    Start-Sleep -Seconds $RefreshSeconds
}
