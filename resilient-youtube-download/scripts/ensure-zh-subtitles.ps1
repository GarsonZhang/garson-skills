[CmdletBinding(DefaultParameterSetName = 'Root')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Root')]
    [string]$OutputRoot,

    [Parameter(Mandatory = $true, ParameterSetName = 'Job')]
    [string]$JobDirectory,

    [ValidateRange(0, 999999)][int]$ExpectedCount = 0,
    [ValidateRange(5, 300)][int]$RefreshSeconds = 10,
    [ValidateRange(0, 300)][int]$RequestSpacingSeconds = 5,
    [ValidateRange(1, 100)][int]$MaxAttemptsPerItem = 3,
    [AllowEmptyString()][string]$Proxy = '',
    [AllowEmptyString()][string]$FfprobePath = '',
    [string]$WorkerName = 'zh-subtitle-worker'
)

$ErrorActionPreference = 'Stop'
$Curl = 'C:\Windows\System32\curl.exe'

function Write-Utf8File {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-AtomicJson {
    param([string]$Path, [object]$Value)
    $tempPath = "$Path.tmp-$PID"
    Write-Utf8File -Path $tempPath -Content ($Value | ConvertTo-Json -Depth 12)
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

if (-not (Test-Path -LiteralPath $Curl -PathType Leaf)) {
    throw "找不到 curl.exe：$Curl"
}

if ($PSCmdlet.ParameterSetName -eq 'Job') {
    $JobDirectory = [System.IO.Path]::GetFullPath($JobDirectory)
    $configPath = Join-Path $JobDirectory 'config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "找不到下载任务配置：$configPath"
    }
    $config = Get-Content -LiteralPath $configPath -Encoding UTF8 -Raw | ConvertFrom-Json
    $OutputRoot = [System.IO.Path]::GetFullPath([string]$config.outputRoot)
    $WorkerDirectory = Join-Path $JobDirectory $WorkerName
    if ([string]::IsNullOrWhiteSpace($FfprobePath)) {
        $FfprobePath = Join-Path ([string]$config.ffmpegLocation) 'ffprobe.exe'
    }
}
else {
    $OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
    $WorkerDirectory = Join-Path (Join-Path $OutputRoot '.youtube-download') $WorkerName
}

if ($WorkerName -match '[<>:"/\\|?*]' -or [string]::IsNullOrWhiteSpace($WorkerName)) {
    throw 'WorkerName 包含无效的 Windows 文件名字符或为空。'
}

if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
    throw "找不到输出目录：$OutputRoot"
}
if ([string]::IsNullOrWhiteSpace($FfprobePath)) {
    $command = Get-Command 'ffprobe.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $FfprobePath = $command.Source }
}
if ([string]::IsNullOrWhiteSpace($FfprobePath) -or -not (Test-Path -LiteralPath $FfprobePath -PathType Leaf)) {
    throw '找不到 ffprobe.exe；请传入 -FfprobePath。'
}

[System.IO.Directory]::CreateDirectory($WorkerDirectory) | Out-Null
$LogPath = Join-Path $WorkerDirectory 'subtitle.log'
$StatePath = Join-Path $WorkerDirectory 'state.json'
$PidPath = Join-Path $WorkerDirectory 'worker.pid'
$IdentityPath = Join-Path $WorkerDirectory 'worker.identity.json'
$StopFlagPath = Join-Path $WorkerDirectory 'stop.flag'
$BlockedPath = Join-Path $WorkerDirectory 'blocked.json'

function Write-Log {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    [System.IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-State {
    param(
        [string]$State,
        [int]$Completed,
        [int]$Target,
        [int]$Blocked = 0,
        [AllowEmptyString()][string]$CurrentFolder = '',
        [AllowEmptyString()][string]$LastError = ''
    )
    Write-AtomicJson -Path $StatePath -Value ([ordered]@{
        state = $State
        completed = $Completed
        target = $Target
        blocked = $Blocked
        currentFolder = $CurrentFolder
        lastError = $LastError
        updatedAt = (Get-Date).ToString('o')
    })
}

function Write-BlockedState {
    param([hashtable]$Items)
    Write-AtomicJson -Path $BlockedPath -Value ([ordered]@{
        maxAttemptsPerItem = $MaxAttemptsPerItem
        blocked = @($Items.Values | Sort-Object folder)
        updatedAt = (Get-Date).ToString('o')
    })
}

function Wait-WithStopCheck {
    param([int]$Seconds)
    for ($remaining = $Seconds; $remaining -gt 0; $remaining -= [Math]::Min(5, $remaining)) {
        if (Test-Path -LiteralPath $StopFlagPath -PathType Leaf) { return }
        Start-Sleep -Seconds ([Math]::Min(5, $remaining))
    }
}

function Get-TargetDirectories {
    if ($PSCmdlet.ParameterSetName -eq 'Root') {
        return @(Get-ChildItem -LiteralPath $OutputRoot -Directory | Where-Object { $_.Name -match '^Video\s+\d+\s+-\s+' } | Sort-Object Name)
    }

    $queuePath = Join-Path $JobDirectory 'queue.json'
    if (-not (Test-Path -LiteralPath $queuePath -PathType Leaf)) { return @() }
    $parsedQueue = Get-Content -LiteralPath $queuePath -Encoding UTF8 -Raw | ConvertFrom-Json
    $queue = @($parsedQueue)
    $directories = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($queue | Where-Object { $_.state -eq 'Completed' -and -not [string]::IsNullOrWhiteSpace([string]$_.folder) })) {
        if (Test-Path -LiteralPath ([string]$item.folder) -PathType Container) {
            $directories.Add((Get-Item -LiteralPath ([string]$item.folder)))
        }
    }
    return @($directories | Sort-Object Name)
}

function Test-VttFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt 64) { return $false }
    $text = Get-Content -LiteralPath $Path -Encoding UTF8 -Raw
    if (-not $text.StartsWith('WEBVTT')) { return $false }
    if ($text -notmatch '\d{2}:\d{2}:\d{2}\.\d{3}\s+-->\s+\d{2}:\d{2}:\d{2}\.\d{3}') { return $false }
    if ($text -notmatch '[\u4e00-\u9fff]') { return $false }
    return $true
}

function Test-MediaReady {
    param([System.IO.DirectoryInfo]$Directory)
    $mediaParts = @(Get-ChildItem -LiteralPath $Directory.FullName -File -Filter '*.part' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*.zh-Hans.vtt.part' })
    if ($mediaParts.Count -gt 0) { return $false }
    $media = Get-ChildItem -LiteralPath $Directory.FullName -File -Filter '*.mp4' -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending | Select-Object -First 1
    if (-not $media -or $media.Length -le 0) { return $false }
    if (((Get-Date) - $media.LastWriteTime).TotalSeconds -lt 5) { return $false }
    $streams = @(& $FfprobePath '-v' 'error' '-show_entries' 'stream=codec_type' '-of' 'default=noprint_wrappers=1:nokey=1' $media.FullName 2>&1)
    if ($LASTEXITCODE -ne 0) { return $false }
    return (@($streams | Where-Object { ([string]$_).Trim() -eq 'video' }).Count -gt 0 -and
        @($streams | Where-Object { ([string]$_).Trim() -eq 'audio' }).Count -gt 0)
}

function Get-ZhHansVttUrl {
    param([object]$Info)
    foreach ($groupName in @('subtitles', 'automatic_captions')) {
        $group = $Info.$groupName
        if (-not $group) { continue }
        $property = $group.PSObject.Properties['zh-Hans']
        if (-not $property) { continue }
        $entry = @($property.Value | Where-Object { $_.ext -eq 'vtt' } | Select-Object -First 1)
        if ($entry.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$entry[0].url)) {
            return [string]$entry[0].url
        }
    }
    throw 'info.json 没有可用的 zh-Hans WebVTT 轨道。'
}

function Get-SubtitleOutputPath {
    param([System.IO.DirectoryInfo]$Directory, [System.IO.FileInfo]$InfoFile)
    $baseName = $InfoFile.Name.Substring(0, $InfoFile.Name.Length - '.info.json'.Length)
    return Join-Path $Directory.FullName ($baseName + '.zh-Hans.vtt')
}

function Save-ZhHansSubtitle {
    param([System.IO.DirectoryInfo]$Directory)
    $infoFile = Get-ChildItem -LiteralPath $Directory.FullName -File -Filter '*.info.json' | Select-Object -First 1
    if (-not $infoFile) { throw '缺少 info.json。' }
    $outputPath = Get-SubtitleOutputPath -Directory $Directory -InfoFile $infoFile
    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
        if (Test-VttFile -Path $outputPath) { return $outputPath }
        throw "现有中文字幕无效，拒绝覆盖：$outputPath"
    }

    $info = Get-Content -LiteralPath $infoFile.FullName -Encoding UTF8 -Raw | ConvertFrom-Json
    $url = Get-ZhHansVttUrl -Info $info
    $tempPath = $outputPath + '.part'
    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($arg in @('--location', '--silent', '--show-error', '--connect-timeout', '15', '--max-time', '60', '--output', $tempPath, '--write-out', '%{http_code}')) {
        $arguments.Add($arg)
    }
    if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
        $arguments.Add('--proxy')
        $arguments.Add($Proxy)
    }
    $arguments.Add($url)
    $response = @(& $Curl @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $httpCode = if ($response.Count -gt 0) { ([string]$response[-1]).Trim() } else { '' }
    if ($exitCode -ne 0 -or $httpCode -ne '200') {
        throw "中文字幕下载失败：curl=$exitCode，HTTP=$httpCode"
    }
    if (-not (Test-VttFile -Path $tempPath)) {
        throw "下载的中文字幕不是有效简体中文 WebVTT：$tempPath"
    }
    Move-Item -LiteralPath $tempPath -Destination $outputPath
    return $outputPath
}

$hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($WorkerDirectory.ToLowerInvariant()))
$hash = ([BitConverter]::ToString($hashBytes) -replace '-', '').Substring(0, 24)
$mutex = New-Object System.Threading.Mutex($false, "Local\CodexYouTubeZhSubtitle-$hash")
$acquired = $false
try { $acquired = $mutex.WaitOne(0, $false) }
catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) {
    Write-Log '已有中文字幕进程占用该任务，当前进程退出。'
    exit 0
}

$attempts = @{}
$nextAttempt = @{}
$blocked = @{}
if (Test-Path -LiteralPath $BlockedPath -PathType Leaf) {
    try {
        $blockedState = Get-Content -LiteralPath $BlockedPath -Encoding UTF8 -Raw | ConvertFrom-Json
        foreach ($entry in @($blockedState.blocked)) {
            $folder = [string]$entry.folder
            if (-not [string]::IsNullOrWhiteSpace($folder)) {
                $blocked[$folder.ToLowerInvariant()] = $entry
            }
        }
    }
    catch {
        throw "中文字幕阻塞清单无效：$BlockedPath；$($_.Exception.Message)"
    }
}
try {
    Write-Utf8File -Path $PidPath -Content ([string]$PID)
    $process = Get-Process -Id $PID -ErrorAction Stop
    Write-AtomicJson -Path $IdentityPath -Value ([ordered]@{ pid = $PID; role = 'youtube-zh-subtitle-worker'; startTimeUtcTicks = $process.StartTime.ToUniversalTime().Ticks })
    Write-Log "中文字幕进程启动。PID=$PID；输出目录=$OutputRoot"

    while ($true) {
        if (Test-Path -LiteralPath $StopFlagPath -PathType Leaf) {
            $completed = 0
            if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
                try { $completed = [int](Get-Content -LiteralPath $StatePath -Encoding UTF8 -Raw | ConvertFrom-Json).completed } catch { }
            }
            Write-State -State 'Stopped' -Completed $completed -Target $ExpectedCount -Blocked $blocked.Count
            Write-Log '检测到协作停止标志；中文字幕进程退出。'
            exit 0
        }
        $directories = @(Get-TargetDirectories)
        $validCount = 0
        $ready = New-Object System.Collections.Generic.List[object]
        $blockedChanged = $false
        foreach ($directory in $directories) {
            $key = $directory.FullName.ToLowerInvariant()
            $zh = Get-ChildItem -LiteralPath $directory.FullName -File -Filter '*.zh-Hans.vtt' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($zh) {
                if (-not (Test-VttFile -Path $zh.FullName)) { throw "发现无效中文字幕：$($zh.FullName)" }
                $validCount++
                if ($blocked.ContainsKey($key)) {
                    $blocked.Remove($key)
                    $blockedChanged = $true
                }
                continue
            }
            if ($blocked.ContainsKey($key)) { continue }
            if (Test-MediaReady -Directory $directory) { $ready.Add($directory) }
        }
        if ($blockedChanged) { Write-BlockedState -Items $blocked }

        $target = if ($ExpectedCount -gt 0) { $ExpectedCount } else { $directories.Count }
        if ($ExpectedCount -gt 0 -and $validCount -ge $ExpectedCount) {
            Write-State -State 'Completed' -Completed $validCount -Target $target -Blocked 0
            Write-Log "中文字幕全部完成：$validCount/$target"
            exit 0
        }
        if ($PSCmdlet.ParameterSetName -eq 'Root' -and $directories.Count -gt 0 -and
            ($ExpectedCount -eq 0 -or $directories.Count -ge $ExpectedCount) -and
            ($validCount + $blocked.Count) -ge $target) {
            Write-State -State 'Blocked' -Completed $validCount -Target $target -Blocked $blocked.Count `
                -LastError "有 $($blocked.Count) 条字幕达到单条重试上限；需要验证并切换已批准的任务代理或节点。"
            Write-Log "中文字幕进程停止重试：完成 $validCount/$target，阻塞 $($blocked.Count)；详见 $BlockedPath"
            exit 2
        }

        if ($PSCmdlet.ParameterSetName -eq 'Job') {
            $jobStatePath = Join-Path $JobDirectory 'state.json'
            $jobState = if (Test-Path -LiteralPath $jobStatePath -PathType Leaf) { Get-Content -LiteralPath $jobStatePath -Encoding UTF8 -Raw | ConvertFrom-Json } else { $null }
            $queuePath = Join-Path $JobDirectory 'queue.json'
            $queueCount = 0
            if (Test-Path -LiteralPath $queuePath -PathType Leaf) {
                $parsedQueue = Get-Content -LiteralPath $queuePath -Encoding UTF8 -Raw | ConvertFrom-Json
                $queueCount = @($parsedQueue).Count
            }
            $target = $queueCount
            if ($jobState -and [string]$jobState.state -eq 'Completed' -and $queueCount -gt 0 -and $validCount -ge $queueCount) {
                Write-State -State 'Completed' -Completed $validCount -Target $target -Blocked 0
                Write-Log "中文字幕全部完成：$validCount/$target"
                exit 0
            }
            if ($jobState -and [string]$jobState.state -eq 'Completed' -and $queueCount -gt 0 -and
                ($validCount + $blocked.Count) -ge $queueCount) {
                Write-State -State 'Blocked' -Completed $validCount -Target $target -Blocked $blocked.Count `
                    -LastError "有 $($blocked.Count) 条字幕达到单条重试上限；需要验证并切换已批准的任务代理或节点。"
                Write-Log "中文字幕进程停止重试：完成 $validCount/$target，阻塞 $($blocked.Count)；详见 $BlockedPath"
                exit 2
            }
            if ($jobState -and [string]$jobState.state -eq 'Stopped' -and $ready.Count -eq 0) {
                Write-State -State 'Stopped' -Completed $validCount -Target $target -Blocked $blocked.Count
                Write-Log "下载任务已停止；本进程处理完现有视频后退出：$validCount/$target"
                exit 0
            }
        }

        $processed = $false
        $orderedReady = @($ready | Sort-Object `
            @{ Expression = {
                $sortKey = $_.FullName.ToLowerInvariant()
                if ($attempts.ContainsKey($sortKey)) { [int]$attempts[$sortKey] } else { 0 }
            } },
            @{ Expression = { $_.Name } })
        foreach ($directory in $orderedReady) {
            $key = $directory.FullName.ToLowerInvariant()
            if ($nextAttempt.ContainsKey($key) -and (Get-Date) -lt $nextAttempt[$key]) { continue }
            try {
                Write-State -State 'Translating' -Completed $validCount -Target $target -Blocked $blocked.Count -CurrentFolder $directory.FullName
                $path = Save-ZhHansSubtitle -Directory $directory
                $attempts.Remove($key)
                $nextAttempt.Remove($key)
                $validCount++
                Write-Log "中文字幕完成：$path"
                $processed = $true
                if ($RequestSpacingSeconds -gt 0) { Wait-WithStopCheck -Seconds $RequestSpacingSeconds }
            }
            catch {
                $count = if ($attempts.ContainsKey($key)) { [int]$attempts[$key] + 1 } else { 1 }
                $attempts[$key] = $count
                $message = $_.Exception.Message
                if ($count -ge $MaxAttemptsPerItem) {
                    $blocked[$key] = [pscustomobject][ordered]@{
                        folder = $directory.FullName
                        attempts = $count
                        error = $message
                        blockedAt = (Get-Date).ToString('o')
                    }
                    $nextAttempt.Remove($key)
                    Write-BlockedState -Items $blocked
                    Write-State -State 'Blocked' -Completed $validCount -Target $target -Blocked $blocked.Count `
                        -CurrentFolder $directory.FullName -LastError $message
                    Write-Log "中文字幕达到单条重试上限 $count/$MaxAttemptsPerItem，不再重试：$($directory.FullName)；$message"
                }
                else {
                    $delay = if ($count -le 1) { 30 } elseif ($count -eq 2) { 60 } elseif ($count -eq 3) { 120 } else { 300 }
                    $nextAttempt[$key] = (Get-Date).AddSeconds($delay)
                    Write-State -State 'Retrying' -Completed $validCount -Target $target -Blocked $blocked.Count -CurrentFolder $directory.FullName -LastError $message
                    Write-Log "中文字幕将在 ${delay}s 后重试（$count/$MaxAttemptsPerItem）：$($directory.FullName)；$message"
                }
                if ($RequestSpacingSeconds -gt 0) { Wait-WithStopCheck -Seconds $RequestSpacingSeconds }
                $processed = $true
            }
            break
        }

        if (-not $processed) {
            Write-State -State 'Waiting' -Completed $validCount -Target $target -Blocked $blocked.Count
            Wait-WithStopCheck -Seconds $RefreshSeconds
        }
    }
}
finally {
    if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
}
