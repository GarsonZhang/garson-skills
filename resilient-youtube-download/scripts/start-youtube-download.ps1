[CmdletBinding(DefaultParameterSetName = 'Direct')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Direct')]
    [ValidateNotNullOrEmpty()]
    [string[]]$Urls,

    [Parameter(Mandatory = $true, ParameterSetName = 'File')]
    [ValidateNotNullOrEmpty()]
    [string]$UrlsFile,

    [string]$OutputRoot = 'D:\CodexYoutubeDown',
    [string]$JobName = 'youtube-download',
    [ValidateRange(0, 999999)][int]$StartNumber = 1,
    [AllowEmptyString()][string]$FolderPrefix = 'Video',
    [AllowEmptyString()][string]$StripTitleRegex = '',
    [string]$SubtitleLanguages = 'en.*,en',
    [AllowEmptyString()][string]$Proxy = '',
    [AllowEmptyString()][string]$CookiesFile = '',
    [AllowEmptyString()][string]$YtDlpPath = '',
    [AllowEmptyString()][string]$FfmpegLocation = '',
    [ValidateSet('Process', 'TaskScheduler')][string]$RecoveryMode = 'Process',
    [ValidateRange(5, 300)][int]$RefreshSeconds = 10,
    [ValidateRange(1, 16)][int]$ConcurrentFragments = 4,
    [switch]$ExpandPlaylists,
    [switch]$AllowVideoWithoutAudio,
    [switch]$VerifyFullDecode,
    [switch]$NoMonitor,
    [switch]$PrepareOnly,
    [switch]$Resume
)

$ErrorActionPreference = 'Stop'
$PowerShellExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$ControllerScript = Join-Path $PSScriptRoot 'youtube-download.ps1'
$MonitorScript = Join-Path $PSScriptRoot 'monitor-youtube-download.ps1'

function Write-Utf8Json {
    param([string]$Path, [object]$Value)
    $json = $Value | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Resolve-Executable {
    param([string]$ExplicitPath, [string[]]$Names)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolved = (Resolve-Path -LiteralPath $ExplicitPath -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "Executable is not a file: $resolved"
        }
        return $resolved
    }

    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
    }
    throw "Required executable not found: $($Names -join ', ')"
}

function Get-InputUrls {
    if ($PSCmdlet.ParameterSetName -eq 'File') {
        $resolvedFile = (Resolve-Path -LiteralPath $UrlsFile -ErrorAction Stop).Path
        $source = Get-Content -LiteralPath $resolvedFile -Encoding UTF8
    }
    else {
        $source = $Urls
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($value in $source) {
        $url = ([string]$value).Trim()
        if ([string]::IsNullOrWhiteSpace($url) -or $url.StartsWith('#')) { continue }
        if ($url -notmatch '^https?://') { throw "Invalid URL: $url" }
        if ($seen.Add($url)) { $result.Add($url) }
    }
    if ($result.Count -eq 0) { throw 'No download URLs were provided.' }
    return @($result)
}

function Assert-CompatibleExistingConfig {
    param([object]$Existing, [object]$Desired)

    $existingUrls = @($Existing.urls)
    $desiredUrls = @($Desired.urls)
    if ($existingUrls.Count -ne $desiredUrls.Count) {
        throw 'This job name already exists with a different URL list. Use another JobName.'
    }
    for ($i = 0; $i -lt $existingUrls.Count; $i++) {
        if ([string]$existingUrls[$i] -cne [string]$desiredUrls[$i]) {
            throw 'This job name already exists with a different URL list. Use another JobName.'
        }
    }

    $properties = @(
        'outputRoot', 'startNumber', 'folderPrefix', 'stripTitleRegex',
        'subtitleLanguages', 'proxy', 'cookiesFile', 'expandPlaylists',
        'allowVideoWithoutAudio', 'verifyFullDecode', 'concurrentFragments'
    )
    foreach ($property in $properties) {
        if ([string]$Existing.$property -cne [string]$Desired.$property) {
            throw "This job name already exists with a different setting: $property. Use another JobName."
        }
    }
}

function Register-RecoveryTask {
    param([string]$TaskName, [string]$JobDirectory)

    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -JobDirectory "{1}"' -f `
        $ControllerScript, $JobDirectory
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $rootFolder = $service.GetFolder('\')
    $definition = $service.NewTask(0)
    $definition.RegistrationInfo.Description = 'Resilient yt-dlp download controller.'
    $definition.Principal.UserId = $currentUser
    $definition.Principal.LogonType = 3
    $definition.Principal.RunLevel = 0
    $definition.Settings.Enabled = $true
    $definition.Settings.StartWhenAvailable = $true
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $definition.Settings.MultipleInstances = 2
    $definition.Settings.ExecutionTimeLimit = 'PT0S'
    $definition.Settings.RestartCount = 999
    $definition.Settings.RestartInterval = 'PT1M'

    $trigger = $definition.Triggers.Create(9)
    $trigger.Enabled = $true
    $trigger.UserId = $currentUser

    $action = $definition.Actions.Create(0)
    $action.Path = $PowerShellExe
    $action.Arguments = $arguments
    $action.WorkingDirectory = $JobDirectory

    [void]$rootFolder.RegisterTaskDefinition($TaskName, $definition, 6, $null, $null, 3, $null)
    return $rootFolder.GetTask($TaskName)
}

if (-not (Test-Path -LiteralPath $ControllerScript -PathType Leaf)) {
    throw "Missing controller script: $ControllerScript"
}
if (-not (Test-Path -LiteralPath $MonitorScript -PathType Leaf)) {
    throw "Missing monitor script: $MonitorScript"
}
if ($JobName -match '[<>:"/\\|?*]' -or [string]::IsNullOrWhiteSpace($JobName)) {
    throw 'JobName contains an invalid Windows filename character or is empty.'
}

$inputUrls = @(Get-InputUrls)
$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
[System.IO.Directory]::CreateDirectory($resolvedOutputRoot) | Out-Null
$jobRoot = Join-Path $resolvedOutputRoot '.youtube-download'
$jobDirectory = Join-Path $jobRoot $JobName
[System.IO.Directory]::CreateDirectory($jobDirectory) | Out-Null

$ytDlpNames = @(
    'yt-dlp.exe',
    'yt-dlp',
    (Join-Path $resolvedOutputRoot '_tools\yt-dlp.exe'),
    'D:\CodexYoutubeDown\_tools\yt-dlp.exe'
)
$resolvedYtDlp = Resolve-Executable -ExplicitPath $YtDlpPath -Names $ytDlpNames
if ([string]::IsNullOrWhiteSpace($FfmpegLocation)) {
    $resolvedFfmpeg = Resolve-Executable -ExplicitPath '' -Names @('ffmpeg.exe', 'ffmpeg')
    $resolvedFfprobe = Resolve-Executable -ExplicitPath '' -Names @('ffprobe.exe', 'ffprobe')
    $resolvedFfmpegLocation = Split-Path -Parent $resolvedFfmpeg
    if ((Split-Path -Parent $resolvedFfprobe) -cne $resolvedFfmpegLocation) {
        throw 'ffmpeg and ffprobe must be available from the same directory or pass FfmpegLocation.'
    }
}
else {
    $resolvedFfmpegLocation = (Resolve-Path -LiteralPath $FfmpegLocation -ErrorAction Stop).Path
    foreach ($name in @('ffmpeg.exe', 'ffprobe.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $resolvedFfmpegLocation $name) -PathType Leaf)) {
            throw "Missing $name in FfmpegLocation: $resolvedFfmpegLocation"
        }
    }
}

$resolvedCookies = ''
if (-not [string]::IsNullOrWhiteSpace($CookiesFile)) {
    $resolvedCookies = (Resolve-Path -LiteralPath $CookiesFile -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedCookies -PathType Leaf)) {
        throw "CookiesFile is not a file: $resolvedCookies"
    }
}

$configPath = Join-Path $jobDirectory 'config.json'
$stopFlagPath = Join-Path $jobDirectory 'stop.flag'
$desiredConfig = [ordered]@{
    schemaVersion = 1
    jobName = $JobName
    outputRoot = $resolvedOutputRoot
    jobDirectory = $jobDirectory
    urls = $inputUrls
    startNumber = $StartNumber
    folderPrefix = $FolderPrefix
    stripTitleRegex = $StripTitleRegex
    subtitleLanguages = $SubtitleLanguages
    proxy = $Proxy
    cookiesFile = $resolvedCookies
    ytDlpPath = $resolvedYtDlp
    ffmpegLocation = $resolvedFfmpegLocation
    expandPlaylists = [bool]$ExpandPlaylists
    allowVideoWithoutAudio = [bool]$AllowVideoWithoutAudio
    verifyFullDecode = [bool]$VerifyFullDecode
    concurrentFragments = $ConcurrentFragments
    createdAt = (Get-Date).ToString('o')
}

if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $existingConfig = Get-Content -LiteralPath $configPath -Encoding UTF8 -Raw | ConvertFrom-Json
    Assert-CompatibleExistingConfig -Existing $existingConfig -Desired $desiredConfig
}
else {
    Write-Utf8Json -Path $configPath -Value $desiredConfig
}

if (Test-Path -LiteralPath $stopFlagPath -PathType Leaf) {
    if (-not $Resume) {
        throw "The job has a stop flag. Pass -Resume to remove it explicitly: $stopFlagPath"
    }
    Remove-Item -LiteralPath $stopFlagPath -Force
}

Write-Host "Job directory: $jobDirectory"
Write-Host "Config: $configPath"
if ($PrepareOnly) {
    Write-Host 'Configuration prepared; no process was started.'
    exit 0
}

if ($RecoveryMode -eq 'TaskScheduler') {
    $safeTaskSuffix = ($JobName -replace '[^A-Za-z0-9._-]', '-')
    if ($safeTaskSuffix.Length -gt 80) { $safeTaskSuffix = $safeTaskSuffix.Substring(0, 80) }
    $taskName = "Codex-YouTube-Download-$safeTaskSuffix"
    $task = Register-RecoveryTask -TaskName $taskName -JobDirectory $jobDirectory
    [void]$task.Run($null)
    Write-Host "Recovery task started: $taskName"
}
else {
    $controllerArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -JobDirectory "{1}"' -f `
        $ControllerScript, $jobDirectory
    $controller = Start-Process -FilePath $PowerShellExe `
        -ArgumentList $controllerArguments `
        -WindowStyle Hidden `
        -PassThru
    Write-Host "Download controller started. PID=$($controller.Id)"
}

if (-not $NoMonitor) {
    $monitorArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -JobDirectory "{1}" -RefreshSeconds {2}' -f `
        $MonitorScript, $jobDirectory, $RefreshSeconds
    $monitor = Start-Process -FilePath $PowerShellExe `
        -ArgumentList $monitorArguments `
        -WindowStyle Normal `
        -PassThru
    Write-Host "Progress monitor opened. PID=$($monitor.Id); refresh=${RefreshSeconds}s."
}
