[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$JobDirectory
)

$ErrorActionPreference = 'Stop'
$JobDirectory = [System.IO.Path]::GetFullPath($JobDirectory)
$ConfigPath = Join-Path $JobDirectory 'config.json'
$QueuePath = Join-Path $JobDirectory 'queue.json'
$StatePath = Join-Path $JobDirectory 'state.json'
$LogPath = Join-Path $JobDirectory 'download.log'
$PidPath = Join-Path $JobDirectory 'controller.pid'
$IdentityPath = Join-Path $JobDirectory 'controller.identity.json'
$StopFlagPath = Join-Path $JobDirectory 'stop.flag'

function Write-Utf8File {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-AtomicJson {
    param([string]$Path, [object]$Value)
    $tempPath = "$Path.tmp-$PID"
    $json = $Value | ConvertTo-Json -Depth 12
    Write-Utf8File -Path $tempPath -Content $json
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Write-Log {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    [System.IO.File]::AppendAllText(
        $LogPath,
        $line + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Add-CommonYtDlpArguments {
    param([System.Collections.Generic.List[string]]$Arguments, [object]$Config)
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.proxy)) {
        $Arguments.Add('--proxy')
        $Arguments.Add([string]$Config.proxy)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.cookiesFile)) {
        $Arguments.Add('--cookies')
        $Arguments.Add([string]$Config.cookiesFile)
    }
}

function Get-SafeTitle {
    param([string]$Title, [string]$StripTitleRegex, [string]$Fallback)

    $value = $Title
    if (-not [string]::IsNullOrWhiteSpace($StripTitleRegex)) {
        $value = [regex]::Replace($value, $StripTitleRegex, '')
    }
    $value = [regex]::Replace($value, '[<>:"/\\|?*\x00-\x1F]', ' ')
    $value = [regex]::Replace($value, '\s+', ' ').Trim().TrimEnd([char[]]@(' ', '.'))
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Fallback }
    if ($value.Length -gt 120) { $value = $value.Substring(0, 120).TrimEnd([char[]]@(' ', '.')) }
    return $value
}

function Invoke-Metadata {
    param([object]$Config, [string]$Url)

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($arg in @('--no-playlist', '--dump-single-json', '--skip-download', '--quiet', '--no-warnings', '--socket-timeout', '30')) {
        $arguments.Add($arg)
    }
    Add-CommonYtDlpArguments -Arguments $arguments -Config $Config
    $arguments.Add($Url)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& ([string]$Config.ytDlpPath) @arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        throw "yt-dlp metadata failed with code ${exitCode}: $text"
    }
    try { return $text | ConvertFrom-Json }
    catch { throw "yt-dlp returned invalid metadata JSON: $($_.Exception.Message)" }
}

function Expand-InputUrls {
    param([object]$Config)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $expanded = @()
    foreach ($inputUrl in @($Config.urls)) {
        if (-not [bool]$Config.expandPlaylists) {
            if ($seen.Add([string]$inputUrl)) { $expanded += [string]$inputUrl }
            continue
        }

        $arguments = New-Object 'System.Collections.Generic.List[string]'
        foreach ($arg in @('--flat-playlist', '--quiet', '--no-warnings', '--print', '%(webpage_url)s')) {
            $arguments.Add($arg)
        }
        Add-CommonYtDlpArguments -Arguments $arguments -Config $Config
        $arguments.Add([string]$inputUrl)
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& ([string]$Config.ytDlpPath) @arguments 2>&1)
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if ($exitCode -ne 0) {
            $message = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
            throw "Playlist expansion failed with code ${exitCode}: $message"
        }
        foreach ($line in $output) {
            $url = ([string]$line).Trim()
            if ($url -match '^https?://' -and $seen.Add($url)) { $expanded += $url }
        }
    }
    if ($expanded.Count -eq 0) { throw 'Playlist expansion produced no video URLs.' }
    return $expanded
}

function New-Queue {
    param([object]$Config)

    $urls = @(Expand-InputUrls -Config $Config)
    $items = @()
    for ($i = 0; $i -lt $urls.Count; $i++) {
        $items += [pscustomobject][ordered]@{
            index = $i
            number = ([int]$Config.startNumber + $i)
            url = [string]$urls[$i]
            state = 'Pending'
            attempts = 0
            videoId = ''
            title = ''
            folder = ''
            file = ''
            error = ''
            finishedAt = ''
        }
    }
    Write-AtomicJson -Path $QueuePath -Value $items
    return @(Get-Content -LiteralPath $QueuePath -Encoding UTF8 -Raw | ConvertFrom-Json)
}

function Get-Queue {
    param([object]$Config)
    if (Test-Path -LiteralPath $QueuePath -PathType Leaf) {
        return @(Get-Content -LiteralPath $QueuePath -Encoding UTF8 -Raw | ConvertFrom-Json)
    }
    return @(New-Queue -Config $Config)
}

function Save-Queue {
    param([object[]]$Queue)
    Write-AtomicJson -Path $QueuePath -Value @($Queue)
}

function Write-State {
    param(
        [string]$State,
        [object[]]$Queue,
        [AllowNull()][object]$Current,
        [AllowEmptyString()][string]$ErrorMessage = ''
    )

    $completed = @($Queue | Where-Object { $_.state -eq 'Completed' }).Count
    $payload = [ordered]@{
        jobName = [string]$Config.jobName
        state = $State
        completed = $completed
        total = @($Queue).Count
        currentNumber = if ($Current) { [int]$Current.number } else { $null }
        currentUrl = if ($Current) { [string]$Current.url } else { '' }
        currentFolder = if ($Current) { [string]$Current.folder } else { '' }
        lastError = $ErrorMessage
        updatedAt = (Get-Date).ToString('o')
    }
    Write-AtomicJson -Path $StatePath -Value $payload
}

function Get-RetryDelaySeconds {
    param([int]$Attempts)
    if ($Attempts -le 1) { return 5 }
    if ($Attempts -eq 2) { return 30 }
    if ($Attempts -eq 3) { return 60 }
    if ($Attempts -eq 4) { return 120 }
    return 300
}

function Wait-WithStopCheck {
    param([int]$Seconds)
    for ($remaining = $Seconds; $remaining -gt 0; $remaining -= [Math]::Min(5, $remaining)) {
        if (Test-Path -LiteralPath $StopFlagPath -PathType Leaf) { return }
        Start-Sleep -Seconds ([Math]::Min(5, $remaining))
    }
}

function Invoke-Download {
    param([object]$Config, [object]$Item, [string]$Folder, [string]$BaseName)

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($arg in @(
        '--no-playlist', '--newline', '--continue', '--windows-filenames',
        '--format', 'bv*+ba/b', '--merge-output-format', 'mp4', '--remux-video', 'mp4',
        '--write-info-json', '--write-subs', '--write-auto-subs',
        '--sub-langs', [string]$Config.subtitleLanguages, '--sub-format', 'vtt',
        '--concurrent-fragments', [string]$Config.concurrentFragments,
        '--retries', '10', '--fragment-retries', '10', '--file-access-retries', '3',
        '--retry-sleep', 'exp=1:20', '--socket-timeout', '30', '--progress-delta', '1',
        '--progress-template', 'download:[download] %(progress._percent_str)s of %(progress._total_bytes_str)s at %(progress._speed_str)s ETA %(progress._eta_str)s',
        '--ffmpeg-location', [string]$Config.ffmpegLocation,
        '--output', (Join-Path $Folder ($BaseName + '.%(ext)s'))
    )) { $arguments.Add($arg) }
    Add-CommonYtDlpArguments -Arguments $arguments -Config $Config
    $arguments.Add([string]$Item.url)

    $tail = New-Object 'System.Collections.Generic.Queue[string]'
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & ([string]$Config.ytDlpPath) @arguments 2>&1 | ForEach-Object {
            $line = [string]$_
            Write-Log "yt-dlp $line"
            $tail.Enqueue($line)
            while ($tail.Count -gt 20) { [void]$tail.Dequeue() }
        }
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "yt-dlp failed with code ${exitCode}: $(@($tail) -join ' | ')"
    }
}

function Assert-DownloadedMedia {
    param([object]$Config, [string]$Folder, [string]$BaseName)

    $mediaPath = Join-Path $Folder ($BaseName + '.mp4')
    $infoPath = Join-Path $Folder ($BaseName + '.info.json')
    if (-not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) { throw "MP4 not found: $mediaPath" }
    if (-not (Test-Path -LiteralPath $infoPath -PathType Leaf)) { throw "info.json not found: $infoPath" }

    $ffprobe = Join-Path ([string]$Config.ffmpegLocation) 'ffprobe.exe'
    $streams = @(& $ffprobe '-v' 'error' '-show_entries' 'stream=codec_type' '-of' 'default=noprint_wrappers=1:nokey=1' $mediaPath 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "ffprobe failed: $($streams -join ' ')" }
    if (@($streams | Where-Object { ([string]$_).Trim() -eq 'video' }).Count -eq 0) {
        throw "No video stream found: $mediaPath"
    }
    if (-not [bool]$Config.allowVideoWithoutAudio -and @($streams | Where-Object { ([string]$_).Trim() -eq 'audio' }).Count -eq 0) {
        throw "No audio stream found: $mediaPath"
    }

    $standaloneAudio = @(Get-ChildItem -LiteralPath $Folder -File | Where-Object {
        $_.Extension.ToLowerInvariant() -in @('.m4a', '.mp3', '.aac', '.wav', '.opus') -and $_.Name -notlike '*.part'
    })
    if ($standaloneAudio.Count -gt 0) {
        throw "Unexpected standalone audio file: $($standaloneAudio.FullName -join ', ')"
    }

    if ([bool]$Config.verifyFullDecode) {
        $ffmpeg = Join-Path ([string]$Config.ffmpegLocation) 'ffmpeg.exe'
        $decodeOutput = @(& $ffmpeg '-v' 'error' '-i' $mediaPath '-f' 'null' 'NUL' 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Full ffmpeg decode failed: $($decodeOutput -join ' ')" }
    }
    return $mediaPath
}

function Test-NonRetryableError {
    param([string]$Message)
    return $Message -match '(?i)DRM|private video|members[- ]only|unsupported URL|sign in|confirm you.?re not a bot|captcha|age[- ]restricted'
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Missing job config: $ConfigPath"
}
$Config = Get-Content -LiteralPath $ConfigPath -Encoding UTF8 -Raw | ConvertFrom-Json

$hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
    [System.Text.Encoding]::UTF8.GetBytes($JobDirectory.ToLowerInvariant())
)
$hash = ([BitConverter]::ToString($hashBytes) -replace '-', '').Substring(0, 24)
$mutex = New-Object System.Threading.Mutex($false, "Local\CodexYouTubeDownload-$hash")
$acquired = $false
try { $acquired = $mutex.WaitOne(0, $false) }
catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) {
    Write-Log 'Another controller already owns the job mutex; exiting.'
    exit 0
}

try {
    Write-Utf8File -Path $PidPath -Content ([string]$PID)
    $process = Get-Process -Id $PID -ErrorAction Stop
    Write-AtomicJson -Path $IdentityPath -Value ([ordered]@{
        pid = $PID
        role = 'youtube-download-controller'
        startTimeUtcTicks = $process.StartTime.ToUniversalTime().Ticks
    })
    Write-Log "Controller started. PID=$PID"

    $queue = @(Get-Queue -Config $Config)
    while ($true) {
        if (Test-Path -LiteralPath $StopFlagPath -PathType Leaf) {
            Write-State -State 'Stopped' -Queue $queue -Current $null
            Write-Log 'Stop flag detected; controller exited cooperatively.'
            exit 0
        }

        $item = @($queue | Where-Object { $_.state -ne 'Completed' } | Sort-Object {[int]$_.index} | Select-Object -First 1)
        if ($item.Count -eq 0) {
            Write-State -State 'Completed' -Queue $queue -Current $null
            Write-Log 'All queue items completed.'
            exit 0
        }
        $item = $item[0]

        try {
            $item.attempts = [int]$item.attempts + 1
            $item.state = 'Preparing'
            $item.error = ''
            Save-Queue -Queue $queue
            Write-State -State 'Preparing' -Queue $queue -Current $item

            if ([string]::IsNullOrWhiteSpace([string]$item.folder)) {
                $metadata = Invoke-Metadata -Config $Config -Url ([string]$item.url)
                $fallback = if ($metadata.id) { [string]$metadata.id } else { "item-$($item.number)" }
                $safeTitle = Get-SafeTitle -Title ([string]$metadata.title) -StripTitleRegex ([string]$Config.stripTitleRegex) -Fallback $fallback
                $number = '{0:D2}' -f [int]$item.number
                $folderName = if ([string]::IsNullOrWhiteSpace([string]$Config.folderPrefix)) {
                    "$number - $safeTitle"
                }
                else {
                    "$($Config.folderPrefix) $number - $safeTitle"
                }
                $item.videoId = [string]$metadata.id
                $item.title = [string]$metadata.title
                $item.folder = Join-Path ([string]$Config.outputRoot) $folderName
                [System.IO.Directory]::CreateDirectory([string]$item.folder) | Out-Null
                Save-Queue -Queue $queue
            }

            $folder = [string]$item.folder
            $baseName = Split-Path -Leaf $folder
            [System.IO.Directory]::CreateDirectory($folder) | Out-Null
            $item.state = 'Downloading'
            Save-Queue -Queue $queue
            Write-State -State 'Downloading' -Queue $queue -Current $item
            Write-Log "Starting item $($item.number): $($item.url) -> $folder"

            Invoke-Download -Config $Config -Item $item -Folder $folder -BaseName $baseName
            $mediaPath = Assert-DownloadedMedia -Config $Config -Folder $folder -BaseName $baseName

            $item.file = $mediaPath
            $item.state = 'Completed'
            $item.error = ''
            $item.finishedAt = (Get-Date).ToString('o')
            Save-Queue -Queue $queue
            Write-State -State 'Running' -Queue $queue -Current $null
            Write-Log "Completed item $($item.number): $mediaPath"
        }
        catch {
            $message = $_.Exception.Message
            $item.error = $message
            if (Test-NonRetryableError -Message $message) {
                $item.state = 'Blocked'
                Save-Queue -Queue $queue
                Write-State -State 'Blocked' -Queue $queue -Current $item -ErrorMessage $message
                Write-Log "Blocked item $($item.number): $message"
                exit 0
            }

            $item.state = 'Retrying'
            Save-Queue -Queue $queue
            $delay = Get-RetryDelaySeconds -Attempts ([int]$item.attempts)
            Write-State -State 'Retrying' -Queue $queue -Current $item -ErrorMessage $message
            Write-Log "Retry item $($item.number) in ${delay}s after error: $message"
            Wait-WithStopCheck -Seconds $delay
        }
    }
}
finally {
    if ($acquired) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    $mutex.Dispose()
}
