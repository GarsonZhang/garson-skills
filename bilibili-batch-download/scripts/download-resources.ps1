[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,
    [switch]$ValidateOnly,
    [string]$SummaryPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Test-ObjectProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }
    if ($Object -is [Collections.IDictionary]) {
        return $Object.Contains($Name)
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-ObjectProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$DefaultValue = $null,
        [switch]$Required
    )

    if (-not (Test-ObjectProperty -Object $Object -Name $Name)) {
        if ($Required) {
            throw "Missing required configuration property: $Name"
        }
        return $DefaultValue
    }
    if ($Object -is [Collections.IDictionary]) {
        return $Object[$Name]
    }
    return $Object.PSObject.Properties[$Name].Value
}

function Get-ObjectPropertyRaw {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$DefaultValue = $null,
        [switch]$Required
    )

    if (-not (Test-ObjectProperty -Object $Object -Name $Name)) {
        if ($Required) {
            throw "Missing required configuration property: $Name"
        }
        Write-Output -NoEnumerate $DefaultValue
        return
    }
    if ($Object -is [Collections.IDictionary]) {
        $value = $Object[$Name]
    }
    else {
        $value = $Object.PSObject.Properties[$Name].Value
    }
    Write-Output -NoEnumerate $value
}

function Test-JsonObjectValue {
    param([AllowNull()]$Value)

    return $null -ne $Value -and ($Value -is [Collections.IDictionary] -or $Value -is [Management.Automation.PSCustomObject])
}

function Assert-JsonObjectValue {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not (Test-JsonObjectValue -Value $Value)) {
        throw "$Name must be a JSON object."
    }
}

function Assert-HeadersObject {
    param(
        [AllowNull()]$Headers,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$BlockedNames = @()
    )

    Assert-JsonObjectValue -Value $Headers -Name $Name
    $entries = [Collections.Generic.List[object]]::new()
    if ($Headers -is [Collections.IDictionary]) {
        foreach ($key in $Headers.Keys) {
            [void]$entries.Add([pscustomobject]@{ Name = [string]$key; Value = $Headers[$key] })
        }
    }
    else {
        foreach ($property in $Headers.PSObject.Properties) {
            [void]$entries.Add([pscustomobject]@{ Name = $property.Name; Value = $property.Value })
        }
    }
    foreach ($entry in $entries) {
        $headerName = [string]$entry.Name
        if ([string]::IsNullOrWhiteSpace($headerName) -or $headerName -notmatch '^[!#$%&''*+.^_`|~0-9A-Za-z-]+$') {
            throw "$Name contains an invalid header name: $headerName"
        }
        if ($entry.Value -isnot [string]) {
            throw "$Name.$headerName must be a string."
        }
        $headerValue = [string]$entry.Value
        if ($headerValue.Contains("`r") -or $headerValue.Contains("`n") -or $headerValue.Contains([string][char]0)) {
            throw "$Name.$headerName contains a forbidden control character."
        }
        foreach ($blockedName in $BlockedNames) {
            if ($headerName.Equals($blockedName, [StringComparison]::OrdinalIgnoreCase)) {
                throw "$Name cannot set the managed header: $headerName"
            }
        }
    }
}

function Get-RequiredJsonPathSetting {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$QualifiedName
    )

    $rawValue = Get-ObjectProperty -Object $Object -Name $Name -Required
    if ($rawValue -isnot [string]) {
        throw "$QualifiedName must be a string."
    }
    $path = [string]$rawValue
    if ([string]::IsNullOrWhiteSpace($path) -or $path -cne $path.Trim() -or $path.StartsWith('.') -or $path.EndsWith('.') -or $path.Contains('..') -or $path.Contains('[') -or $path.Contains(']')) {
        throw "$QualifiedName must be a non-empty dot path without empty segments."
    }
    return $path
}

function Get-ResolverSuccessConditions {
    param([Parameter(Mandatory)]$Resolver)

    $conditions = [Collections.Generic.List[object]]::new()
    if (-not (Test-ObjectProperty -Object $Resolver -Name 'success')) {
        return $conditions.ToArray()
    }
    $rawConditions = Get-ObjectPropertyRaw -Object $Resolver -Name 'success' -Required
    if ($rawConditions -isnot [Array] -or $rawConditions.Count -eq 0) {
        throw 'resolver.success must be a non-empty JSON array when provided.'
    }
    $position = 0
    foreach ($condition in $rawConditions) {
        $position++
        Assert-JsonObjectValue -Value $condition -Name "resolver.success[$position]"
        $path = Get-RequiredJsonPathSetting -Object $condition -Name 'path' -QualifiedName "resolver.success[$position].path"
        $expectedValue = Get-ObjectProperty -Object $condition -Name 'equals' -Required
        [void]$conditions.Add([pscustomobject]@{ Path = $path; ExpectedValue = $expectedValue })
    }
    return $conditions.ToArray()
}

function Resolve-TaskPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BaseDirectory
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'A required path is empty.'
    }
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
}

function Test-PathWithinOrEqual {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Directory
    )

    $pathValue = [IO.Path]::GetFullPath($Path)
    $directoryValue = [IO.Path]::GetFullPath($Directory)
    if ($pathValue.Equals($directoryValue, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $separator = [string][IO.Path]::DirectorySeparatorChar
    $prefix = if ($directoryValue.EndsWith($separator, [StringComparison]::Ordinal)) { $directoryValue } else { "$directoryValue$separator" }
    return $pathValue.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-PathsRelated {
    param(
        [Parameter(Mandatory)][string]$First,
        [Parameter(Mandatory)][string]$Second
    )

    return (Test-PathWithinOrEqual -Path $First -Directory $Second) -or (Test-PathWithinOrEqual -Path $Second -Directory $First)
}

function Get-NormalizedSha256 {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Name,
        [switch]$AllowMissing
    )

    if ($null -eq $Value -and $AllowMissing) {
        return $null
    }
    if ($Value -isnot [string] -or [string]$Value -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "$Name must be exactly 64 hexadecimal characters."
    }
    return ([string]$Value).ToLowerInvariant()
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Expand-TemplateText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)]$Context
    )

    return $Text.Replace('{sourceUrl}', [string]$Context.SourceUrl).Replace('{index}', [string]$Context.Index)
}

function Expand-TemplateValue {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)]$Context
    )

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string]) {
        if ($Value -ceq '{index}') {
            return [int]$Context.Index
        }
        if ($Value -ceq '{sourceUrl}') {
            return [string]$Context.SourceUrl
        }
        return Expand-TemplateText -Text $Value -Context $Context
    }
    if ($Value -is [Collections.IDictionary]) {
        $expandedDictionary = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $expandedDictionary[$key] = Expand-TemplateValue -Value $Value[$key] -Context $Context
        }
        return $expandedDictionary
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $expandedObject = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $expandedObject[$property.Name] = Expand-TemplateValue -Value $property.Value -Context $Context
        }
        return $expandedObject
    }
    if ($Value -is [Collections.IEnumerable]) {
        $expandedArray = [Collections.Generic.List[object]]::new()
        foreach ($entry in $Value) {
            [void]$expandedArray.Add((Expand-TemplateValue -Value $entry -Context $Context))
        }
        return ,$expandedArray.ToArray()
    }
    return $Value
}

function Get-JsonPathValue {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'A JSON property path is empty.'
    }
    $current = $Object
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) {
            throw "JSON path not found: $Path"
        }
        if ($current -is [Collections.IDictionary]) {
            if (-not $current.Contains($segment)) {
                throw "JSON path not found: $Path"
            }
            $current = $current[$segment]
            continue
        }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) {
            throw "JSON path not found: $Path"
        }
        $current = $property.Value
    }
    return $current
}

function Test-JsonValueEqual {
    param(
        [AllowNull()]$Actual,
        [AllowNull()]$Expected
    )

    $actualJson = ConvertTo-Json -InputObject $Actual -Compress -Depth 32
    $expectedJson = ConvertTo-Json -InputObject $Expected -Compress -Depth 32
    return $actualJson -ceq $expectedJson
}

function Get-PositiveIntSetting {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [int]$DefaultValue
    )

    $rawValue = Get-ObjectProperty -Object $Object -Name $Name -DefaultValue $DefaultValue
    [int]$value = 0
    if (-not [int]::TryParse([string]$rawValue, [ref]$value) -or $value -le 0) {
        throw "$Name must be a positive integer."
    }
    return $value
}

function Get-BoolSetting {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [bool]$DefaultValue
    )

    $rawValue = Get-ObjectProperty -Object $Object -Name $Name -DefaultValue $DefaultValue
    if ($rawValue -is [bool]) {
        return $rawValue
    }
    [bool]$value = $false
    if (-not [bool]::TryParse([string]$rawValue, [ref]$value)) {
        throw "$Name must be true or false."
    }
    return $value
}

function Test-DnsNameStrict {
    param([Parameter(Mandatory)][string]$Name)

    if ($Name.Length -gt 253) {
        return $false
    }
    foreach ($label in $Name.Split('.')) {
        if ($label.Length -eq 0 -or $label.Length -gt 63 -or $label -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$') {
            return $false
        }
    }
    return $true
}

function Get-AllowedHostPatterns {
    param([Parameter(Mandatory)]$Download)

    $rawPatterns = Get-ObjectPropertyRaw -Object $Download -Name 'allowedHosts' -Required
    if ($rawPatterns -isnot [Array] -or $rawPatterns.Count -eq 0) {
        throw 'download.allowedHosts must be a non-empty JSON array.'
    }
    $patterns = [Collections.Generic.List[string]]::new()
    foreach ($rawPattern in $rawPatterns) {
        if ($rawPattern -isnot [string]) {
            throw 'download.allowedHosts values must be strings.'
        }
        $pattern = [string]$rawPattern
        if ([string]::IsNullOrWhiteSpace($pattern) -or $pattern -cne $pattern.Trim()) {
            throw 'download.allowedHosts contains an empty or padded value.'
        }
        $normalized = $pattern.ToLowerInvariant()
        if ($normalized.StartsWith('*.')) {
            $suffix = $normalized.Substring(2)
            if ($suffix.Contains('*') -or [uri]::CheckHostName($suffix) -ne [UriHostNameType]::Dns -or -not (Test-DnsNameStrict -Name $suffix)) {
                throw "Invalid wildcard download host: $pattern"
            }
        }
        else {
            $hostType = [uri]::CheckHostName($normalized)
            if ($normalized.Contains('*') -or $hostType -eq [UriHostNameType]::Unknown -or ($hostType -eq [UriHostNameType]::Dns -and -not (Test-DnsNameStrict -Name $normalized))) {
                throw "Invalid download host: $pattern"
            }
        }
        [void]$patterns.Add($normalized)
    }
    return $patterns.ToArray()
}

function Get-AllowedContentTypes {
    param([Parameter(Mandatory)]$Download)

    $rawTypes = Get-ObjectPropertyRaw -Object $Download -Name 'allowedContentTypes' -Required
    if ($rawTypes -isnot [Array] -or $rawTypes.Count -eq 0) {
        throw 'download.allowedContentTypes must be a non-empty JSON array.'
    }
    $types = [Collections.Generic.List[string]]::new()
    foreach ($rawType in $rawTypes) {
        if ($rawType -isnot [string]) {
            throw 'download.allowedContentTypes values must be strings.'
        }
        $contentType = [string]$rawType
        if ($contentType -cne $contentType.Trim() -or $contentType -notmatch '^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$') {
            throw "Invalid allowed content type: $contentType"
        }
        [void]$types.Add($contentType.ToLowerInvariant())
    }
    return $types.ToArray()
}

function Get-SafeUri {
    param(
        [Parameter(Mandatory)][string]$Text,
        [bool]$AllowInsecureLocalhost
    )

    if ([string]::IsNullOrWhiteSpace($Text) -or $Text -cne $Text.Trim()) {
        throw 'URL must be a non-empty value without surrounding whitespace.'
    }
    [uri]$uri = $null
    if (-not [uri]::TryCreate($Text, [UriKind]::Absolute, [ref]$uri)) {
        throw "Invalid absolute URL: $Text"
    }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo) -or -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw "URL user information and fragments are not allowed: $Text"
    }
    if ($uri.Scheme -ceq 'https') {
        return $uri
    }
    if ($uri.Scheme -ceq 'http' -and $AllowInsecureLocalhost -and $uri.IsLoopback) {
        return $uri
    }
    throw "Only HTTPS is allowed unless HTTP is explicitly enabled for localhost: $Text"
}

function Test-HostAllowed {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string[]]$Patterns
    )

    $hostValue = $HostName.ToLowerInvariant()
    foreach ($patternText in $Patterns) {
        $pattern = $patternText.Trim().ToLowerInvariant()
        if ($pattern.StartsWith('*.')) {
            $suffix = $pattern.Substring(2)
            if ($hostValue.EndsWith(".$suffix", [StringComparison]::Ordinal)) {
                $prefixLength = $hostValue.Length - $suffix.Length - 1
                if ($prefixLength -gt 0 -and -not $hostValue.Substring(0, $prefixLength).Contains('.')) {
                    return $true
                }
            }
            continue
        }
        if ($hostValue -ceq $pattern) {
            return $true
        }
    }
    return $false
}

function Assert-DownloadUri {
    param([Parameter(Mandatory)][string]$Url)

    $uri = Get-SafeUri -Text $Url -AllowInsecureLocalhost $script:allowInsecureLocalhost
    if (-not (Test-HostAllowed -HostName $uri.Host -Patterns $script:allowedHosts)) {
        throw "Download host is not allowed: $($uri.Host)"
    }
    return $uri
}

function Get-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)

    $safeName = $Name.Normalize([Text.NormalizationForm]::FormC)
    foreach ($invalidCharacter in [IO.Path]::GetInvalidFileNameChars()) {
        $safeName = $safeName.Replace([string]$invalidCharacter, '_')
    }
    $safeName = $safeName.Trim().TrimEnd([char[]]@('.', ' '))
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        throw 'The resolved file name is empty after sanitization.'
    }
    if ($safeName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
        throw "The resolved file name is reserved by Windows: $safeName"
    }
    return $safeName
}

function Add-ConfiguredExtension {
    param([Parameter(Mandatory)][string]$FileName)

    if ([string]::IsNullOrEmpty($script:fileExtension)) {
        return $FileName
    }
    if ($FileName.EndsWith($script:fileExtension, [StringComparison]::OrdinalIgnoreCase)) {
        return $FileName
    }
    return "$FileName$($script:fileExtension)"
}

function Get-IdentityHash {
    param([Parameter(Mandatory)][string]$Identity)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Identity)
        $hash = $sha256.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()).Substring(0, 32)
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-ResourcePaths {
    param(
        [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)][string]$FileName
    )

    $finalPath = Join-Path $script:destinationFullPath $FileName
    $identityMaterial = "$($Job.Identity)`n$($Job.ExpectedSize)`n$($Job.ExpectedSha256)"
    $identityHash = Get-IdentityHash -Identity $identityMaterial
    $partialPath = "$finalPath.$identityHash.$($Job.ExpectedSize).part"
    if ($finalPath.Length -ge 240 -or $partialPath.Length -ge 240) {
        throw "Target path is too long: $finalPath"
    }
    return [pscustomobject]@{ Final = $finalPath; Partial = $partialPath }
}

function Assert-ResourcePathTypes {
    param(
        [Parameter(Mandatory)][string]$FinalPath,
        [Parameter(Mandatory)][string]$PartialPath
    )

    if ((Test-Path -LiteralPath $FinalPath) -and -not (Test-Path -LiteralPath $FinalPath -PathType Leaf)) {
        throw "Final resource path exists and is not a file: $FinalPath"
    }
    if ((Test-Path -LiteralPath $PartialPath) -and -not (Test-Path -LiteralPath $PartialPath -PathType Leaf)) {
        throw "Partial resource path exists and is not a file: $PartialPath"
    }
}

function Convert-HexTextToBytes {
    param([Parameter(Mandatory)][string]$HexText)

    $normalized = $HexText.Replace(' ', '')
    if ($normalized.Length -eq 0 -or $normalized.Length % 2 -ne 0 -or $normalized -notmatch '^[0-9a-fA-F]+$') {
        throw 'signature.hex must contain an even number of hexadecimal characters.'
    }
    $bytes = [byte[]]::new($normalized.Length / 2)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $bytes[$index] = [Convert]::ToByte($normalized.Substring($index * 2, 2), 16)
    }
    return ,$bytes
}

function Get-SignatureSpec {
    param([AllowNull()]$Signature)

    if ($null -eq $Signature) {
        return $null
    }
    Assert-JsonObjectValue -Value $Signature -Name 'download.signature'
    [long]$offset = 0
    $rawOffset = Get-ObjectProperty -Object $Signature -Name 'offset' -DefaultValue 0
    if (-not [long]::TryParse([string]$rawOffset, [ref]$offset) -or $offset -lt 0) {
        throw 'signature.offset must be a non-negative integer.'
    }
    $hasAscii = Test-ObjectProperty -Object $Signature -Name 'ascii'
    $hasHex = Test-ObjectProperty -Object $Signature -Name 'hex'
    if ($hasAscii -eq $hasHex) {
        throw 'signature must contain exactly one of ascii or hex.'
    }
    $expectedBytes = if ($hasAscii) {
        $asciiRaw = Get-ObjectProperty -Object $Signature -Name 'ascii' -Required
        if ($asciiRaw -isnot [string] -or [string]::IsNullOrEmpty([string]$asciiRaw)) {
            throw 'signature.ascii must be a non-empty string.'
        }
        $ascii = [string]$asciiRaw
        foreach ($character in $ascii.ToCharArray()) {
            if ([int]$character -gt 127) {
                throw 'signature.ascii can contain only ASCII characters.'
            }
        }
        [Text.Encoding]::ASCII.GetBytes($ascii)
    }
    else {
        $hexRaw = Get-ObjectProperty -Object $Signature -Name 'hex' -Required
        if ($hexRaw -isnot [string]) {
            throw 'signature.hex must be a string.'
        }
        Convert-HexTextToBytes -HexText ([string]$hexRaw)
    }
    if ($offset -gt [long]::MaxValue - $expectedBytes.LongLength) {
        throw 'signature offset and length exceed the supported range.'
    }
    return [pscustomobject]@{
        Offset = $offset
        Bytes = [byte[]]$expectedBytes
        MinimumLength = $offset + $expectedBytes.Length
    }
}

function Test-FileSignature {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowTooShort
    )

    if ($null -eq $script:signatureSpec) {
        return $true
    }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -lt $script:signatureSpec.MinimumLength) {
            return [bool]$AllowTooShort
        }
        [void]$stream.Seek($script:signatureSpec.Offset, [IO.SeekOrigin]::Begin)
        $buffer = [byte[]]::new($script:signatureSpec.Bytes.Length)
        if ($stream.Read($buffer, 0, $buffer.Length) -ne $buffer.Length) {
            return $false
        }
        for ($index = 0; $index -lt $buffer.Length; $index++) {
            if ($buffer[$index] -ne $script:signatureSpec.Bytes[$index]) {
                return $false
            }
        }
        return $true
    }
    finally {
        $stream.Dispose()
    }
}

function Get-SourceItems {
    param([Parameter(Mandatory)]$Configuration)

    $hasRange = Test-ObjectProperty -Object $Configuration -Name 'range'
    $hasItems = Test-ObjectProperty -Object $Configuration -Name 'items'
    if ($hasRange -eq $hasItems) {
        throw 'Configuration must contain exactly one of range or items.'
    }

    $sources = [Collections.Generic.List[object]]::new()
    $seenIndexes = [Collections.Generic.HashSet[int]]::new()
    if ($hasRange) {
        if (-not $script:resolverEnabled) {
            throw 'range mode requires resolver configuration.'
        }
        $range = Get-ObjectProperty -Object $Configuration -Name 'range' -Required
        Assert-JsonObjectValue -Value $range -Name 'range'
        $templateRaw = Get-ObjectProperty -Object $range -Name 'urlTemplate' -Required
        if ($templateRaw -isnot [string]) {
            throw 'range.urlTemplate must be a string.'
        }
        $template = [string]$templateRaw
        if (-not $template.Contains('{index}')) {
            throw 'range.urlTemplate must contain {index}.'
        }
        [int]$start = 0
        [int]$end = 0
        if (-not [int]::TryParse([string](Get-ObjectProperty -Object $range -Name 'start' -Required), [ref]$start) -or $start -le 0) {
            throw 'range.start must be a positive integer.'
        }
        if (-not [int]::TryParse([string](Get-ObjectProperty -Object $range -Name 'end' -Required), [ref]$end) -or $end -lt $start) {
            throw 'range.end must be an integer greater than or equal to range.start.'
        }
        foreach ($index in $start..$end) {
            $context = [pscustomobject]@{ Index = $index; SourceUrl = '' }
            $sourceUrl = Expand-TemplateText -Text $template -Context $context
            [void]$sources.Add([pscustomobject]@{ Index = $index; SourceUrl = $sourceUrl; Raw = $null })
        }
        return $sources.ToArray()
    }

    $rawItems = Get-ObjectPropertyRaw -Object $Configuration -Name 'items' -Required
    if ($rawItems -isnot [Array] -or $rawItems.Count -eq 0) {
        throw 'items must be a non-empty JSON array.'
    }
    $position = 0
    foreach ($rawItem in $rawItems) {
        $position++
        Assert-JsonObjectValue -Value $rawItem -Name "items[$position]"
        [int]$itemIndex = $position
        if (Test-ObjectProperty -Object $rawItem -Name 'index') {
            if (-not [int]::TryParse([string](Get-ObjectProperty -Object $rawItem -Name 'index' -Required), [ref]$itemIndex) -or $itemIndex -le 0) {
                throw "items[$position].index must be a positive integer."
            }
        }
        if (-not $seenIndexes.Add($itemIndex)) {
            throw "Duplicate item index: $itemIndex"
        }
        $sourceUrl = if (Test-ObjectProperty -Object $rawItem -Name 'sourceUrl') {
            $sourceUrlRaw = Get-ObjectProperty -Object $rawItem -Name 'sourceUrl' -Required
            if ($sourceUrlRaw -isnot [string]) {
                throw "items[$position].sourceUrl must be a string."
            }
            [string]$sourceUrlRaw
        }
        elseif (-not $script:resolverEnabled -and (Test-ObjectProperty -Object $rawItem -Name 'downloadUrl')) {
            $downloadUrlRaw = Get-ObjectProperty -Object $rawItem -Name 'downloadUrl' -Required
            if ($downloadUrlRaw -isnot [string]) {
                throw "items[$position].downloadUrl must be a string."
            }
            [string]$downloadUrlRaw
        }
        else {
            throw "items[$position].sourceUrl is required."
        }
        [void]$sources.Add([pscustomobject]@{ Index = $itemIndex; SourceUrl = $sourceUrl; Raw = $rawItem })
    }
    return $sources.ToArray()
}

function Resolve-ResourceJob {
    param([Parameter(Mandatory)]$Source)

    $context = [pscustomobject]@{ Index = $Source.Index; SourceUrl = $Source.SourceUrl }
    if ($script:resolverEnabled) {
        $expandedHeaders = Expand-TemplateValue -Value $script:resolverHeaders -Context $context
        $requestHeaders = @{}
        if ($null -ne $expandedHeaders) {
            foreach ($key in $expandedHeaders.Keys) {
                $requestHeaders[[string]$key] = [string]$expandedHeaders[$key]
            }
        }
        $expandedBody = Expand-TemplateValue -Value $script:resolverBody -Context $context
        $requestBody = ConvertTo-Json -InputObject $expandedBody -Compress -Depth 32
        $response = Invoke-RestMethod -Uri $script:resolverUri.AbsoluteUri -Method Post -ContentType $script:resolverContentType -Headers $requestHeaders -Body $requestBody -TimeoutSec $script:resolverTimeoutSeconds -MaximumRedirection 0

        foreach ($condition in $script:resolverSuccessConditions) {
            $conditionPath = [string]$condition.Path
            $expectedValue = $condition.ExpectedValue
            $actualValue = Get-JsonPathValue -Object $response -Path $conditionPath
            if (-not (Test-JsonValueEqual -Actual $actualValue -Expected $expectedValue)) {
                throw "Resolver success condition failed at path: $conditionPath"
            }
        }

        $downloadUrlRaw = Get-JsonPathValue -Object $response -Path $script:downloadUrlPath
        $fileNameRaw = Get-JsonPathValue -Object $response -Path $script:fileNamePath
        $expectedSizeRaw = Get-JsonPathValue -Object $response -Path $script:expectedSizePath
        $identityRaw = Get-JsonPathValue -Object $response -Path $script:identityPath
        if ($downloadUrlRaw -isnot [string] -or $fileNameRaw -isnot [string] -or $identityRaw -isnot [string]) {
            throw "Resource $($Source.Index) resolver URL, file name, and identity values must be strings."
        }
        $downloadUrl = [string]$downloadUrlRaw
        $fileName = [string]$fileNameRaw
        $identity = [string]$identityRaw
        $expectedSha256 = if ($null -ne $script:sha256Path) {
            Get-NormalizedSha256 -Value (Get-JsonPathValue -Object $response -Path $script:sha256Path) -Name "Resource $($Source.Index) sha256"
        }
        else {
            $null
        }
    }
    else {
        $downloadUrlRaw = Get-ObjectProperty -Object $Source.Raw -Name 'downloadUrl' -Required
        $fileNameRaw = Get-ObjectProperty -Object $Source.Raw -Name 'fileName' -Required
        $expectedSizeRaw = Get-ObjectProperty -Object $Source.Raw -Name 'expectedSize' -Required
        $identityRaw = Get-ObjectProperty -Object $Source.Raw -Name 'identity' -Required
        if ($downloadUrlRaw -isnot [string] -or $fileNameRaw -isnot [string] -or $identityRaw -isnot [string]) {
            throw "Resource $($Source.Index) URL, file name, and identity values must be strings."
        }
        $downloadUrl = [string]$downloadUrlRaw
        $fileName = [string]$fileNameRaw
        $identity = [string]$identityRaw
        $expectedSha256 = if (Test-ObjectProperty -Object $Source.Raw -Name 'sha256') {
            Get-NormalizedSha256 -Value (Get-ObjectProperty -Object $Source.Raw -Name 'sha256' -Required) -Name "Resource $($Source.Index) sha256"
        }
        else {
            $null
        }
    }

    [long]$expectedSize = 0
    if (-not [long]::TryParse([string]$expectedSizeRaw, [ref]$expectedSize) -or $expectedSize -le 0) {
        throw "Resource $($Source.Index) has an invalid expected size."
    }
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        throw "Resource $($Source.Index) has an empty file name."
    }
    if ([string]::IsNullOrWhiteSpace($identity)) {
        throw "Resource $($Source.Index) has an empty identity."
    }
    if ($null -ne $script:signatureSpec -and $script:signatureSpec.MinimumLength -gt $expectedSize) {
        throw "Resource $($Source.Index) is smaller than the configured signature minimum length."
    }
    if ($script:resumeEnabled -and $null -eq $expectedSha256) {
        throw "Resource $($Source.Index) must provide sha256 when download.resume is true."
    }
    [void](Assert-DownloadUri -Url $downloadUrl)

    return [pscustomobject]@{
        Index = [int]$Source.Index
        SourceUrl = [string]$Source.SourceUrl
        DownloadUrl = $downloadUrl
        FileName = $fileName
        ExpectedSize = $expectedSize
        Identity = $identity
        ExpectedSha256 = $expectedSha256
    }
}

function Test-ContentTypeAllowed {
    param([Parameter(Mandatory)][string]$ContentType)

    $baseType = $ContentType.Split(';')[0].Trim()
    foreach ($allowedType in $script:allowedContentTypes) {
        if ($baseType.Equals($allowedType, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-DownloadHeaderArguments {
    param([Parameter(Mandatory)]$Context)

    $arguments = [Collections.Generic.List[string]]::new()
    if ($null -eq $script:downloadHeaders) {
        return $arguments.ToArray()
    }
    $expandedHeaders = Expand-TemplateValue -Value $script:downloadHeaders -Context $Context
    foreach ($key in $expandedHeaders.Keys) {
        $name = [string]$key
        $value = [string]$expandedHeaders[$key]
        if ($name.Equals('User-Agent', [StringComparison]::OrdinalIgnoreCase)) {
            [void]$arguments.Add('--user-agent')
            [void]$arguments.Add($value)
            continue
        }
        if ($name.Equals('Referer', [StringComparison]::OrdinalIgnoreCase)) {
            [void]$arguments.Add('--referer')
            [void]$arguments.Add($value)
            continue
        }
        [void]$arguments.Add('--header')
        [void]$arguments.Add("${name}: $value")
    }
    return $arguments.ToArray()
}

function Test-RetryableException {
    param([Parameter(Mandatory)]$Exception)

    if ($Exception -is [Net.WebException]) {
        return $null -eq $Exception.Response
    }
    return $false
}

function Assert-ExistingSummaryCompatible {
    if (-not (Test-Path -LiteralPath $script:summaryFullPath)) {
        return
    }
    if (-not (Test-Path -LiteralPath $script:summaryFullPath -PathType Leaf)) {
        throw "Summary path is not a file: $($script:summaryFullPath)"
    }
    try {
        $existingSummary = Get-Content -LiteralPath $script:summaryFullPath -Encoding UTF8 -Raw | ConvertFrom-Json
        Assert-JsonObjectValue -Value $existingSummary -Name 'existing summary'
        [int]$existingSchema = 0
        if (-not [int]::TryParse([string](Get-ObjectProperty -Object $existingSummary -Name 'schema' -Required), [ref]$existingSchema) -or $existingSchema -ne 1) {
            throw 'Existing summary schema is not 1.'
        }
        $existingConfiguration = [string](Get-ObjectProperty -Object $existingSummary -Name 'configuration' -Required)
        $existingDestination = [string](Get-ObjectProperty -Object $existingSummary -Name 'destination' -Required)
        if (-not $existingConfiguration.Equals($script:configFullPath, [StringComparison]::OrdinalIgnoreCase) -or -not $existingDestination.Equals($script:destinationFullPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Existing summary belongs to a different configuration or destination.'
        }
    }
    catch {
        throw "Existing summary is not safe to replace: $($_.Exception.Message)"
    }
}

function Save-DownloadSummary {
    $summaryDirectory = Split-Path -Parent $script:summaryFullPath
    if (Test-Path -LiteralPath $summaryDirectory) {
        if (-not (Test-Path -LiteralPath $summaryDirectory -PathType Container)) {
            throw "Summary parent path is not a directory: $summaryDirectory"
        }
    }
    else {
        [void](New-Item -ItemType Directory -Path $summaryDirectory -Force)
    }
    if (Test-Path -LiteralPath $script:summaryFullPath -PathType Container) {
        throw "Summary path is a directory: $($script:summaryFullPath)"
    }
    if (Test-Path -LiteralPath $script:summaryTemporaryFullPath) {
        throw "Summary temporary path already exists: $($script:summaryTemporaryFullPath)"
    }
    $summary = [ordered]@{
        schema = 1
        configuration = $script:configFullPath
        destination = $script:destinationFullPath
        total = $script:sources.Count
        items = @($script:results)
    }
    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:summaryTemporaryFullPath -Encoding UTF8
    Move-Item -LiteralPath $script:summaryTemporaryFullPath -Destination $script:summaryFullPath -Force
    if (-not (Test-Path -LiteralPath $script:summaryFullPath -PathType Leaf) -or (Test-Path -LiteralPath $script:summaryTemporaryFullPath)) {
        throw "Summary replacement did not produce the expected file: $($script:summaryFullPath)"
    }
}

$script:configFullPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$configDirectory = Split-Path -Parent $script:configFullPath
$configuration = Get-Content -LiteralPath $script:configFullPath -Encoding UTF8 -Raw | ConvertFrom-Json
if ($null -eq $configuration) {
    throw 'Configuration JSON is empty.'
}
Assert-JsonObjectValue -Value $configuration -Name 'configuration'
[int]$schema = 0
if (-not [int]::TryParse([string](Get-ObjectProperty -Object $configuration -Name 'schema' -Required), [ref]$schema) -or $schema -ne 1) {
    throw 'Only configuration schema 1 is supported.'
}

$destinationRaw = Get-ObjectProperty -Object $configuration -Name 'destination' -Required
if ($destinationRaw -isnot [string]) {
    throw 'destination must be a string.'
}
$destinationValue = [string]$destinationRaw
$script:destinationFullPath = Resolve-TaskPath -Path $destinationValue -BaseDirectory $configDirectory
if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
    $configuredSummaryRaw = Get-ObjectProperty -Object $configuration -Name 'summaryPath' -DefaultValue 'download-summary.json'
    if ($configuredSummaryRaw -isnot [string]) {
        throw 'summaryPath must be a string.'
    }
    $configuredSummary = [string]$configuredSummaryRaw
    $script:summaryFullPath = Resolve-TaskPath -Path $configuredSummary -BaseDirectory $configDirectory
}
else {
    $script:summaryFullPath = Resolve-TaskPath -Path $SummaryPath -BaseDirectory $configDirectory
}
$script:summaryTemporaryFullPath = "$($script:summaryFullPath).tmp"
foreach ($controlPath in @($script:configFullPath, $script:summaryFullPath, $script:summaryTemporaryFullPath)) {
    if (Test-PathsRelated -First $controlPath -Second $script:destinationFullPath) {
        throw "Configuration and summary paths must be outside and unrelated to the destination: $controlPath"
    }
}
if ((Test-PathsRelated -First $script:summaryFullPath -Second $script:configFullPath) -or (Test-PathsRelated -First $script:summaryTemporaryFullPath -Second $script:configFullPath)) {
    throw 'Summary paths conflict with the configuration path.'
}
if (Test-Path -LiteralPath $script:summaryFullPath -PathType Container) {
    throw "Summary path is a directory: $($script:summaryFullPath)"
}
if (Test-Path -LiteralPath $script:summaryTemporaryFullPath) {
    throw "Summary temporary path already exists: $($script:summaryTemporaryFullPath)"
}

$script:resolverEnabled = Test-ObjectProperty -Object $configuration -Name 'resolver'
$script:resolverHeaders = $null
$script:resolverBody = $null
$script:resolverSuccessConditions = @()
if ($script:resolverEnabled) {
    $resolver = Get-ObjectProperty -Object $configuration -Name 'resolver' -Required
    Assert-JsonObjectValue -Value $resolver -Name 'resolver'
    $resolverMethodRaw = Get-ObjectProperty -Object $resolver -Name 'method' -DefaultValue 'POST'
    if ($resolverMethodRaw -isnot [string]) {
        throw 'resolver.method must be a string.'
    }
    $resolverMethod = [string]$resolverMethodRaw
    if (-not $resolverMethod.Equals('POST', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'resolver.method must be POST.'
    }
    $resolverAllowsLocalHttp = Get-BoolSetting -Object $resolver -Name 'allowInsecureLocalhost' -DefaultValue $false
    $script:resolverUri = Get-SafeUri -Text ([string](Get-ObjectProperty -Object $resolver -Name 'url' -Required)) -AllowInsecureLocalhost $resolverAllowsLocalHttp
    $resolverContentTypeRaw = Get-ObjectProperty -Object $resolver -Name 'contentType' -DefaultValue 'application/json; charset=utf-8'
    if ($resolverContentTypeRaw -isnot [string]) {
        throw 'resolver.contentType must be a string.'
    }
    $script:resolverContentType = [string]$resolverContentTypeRaw
    if ([string]::IsNullOrWhiteSpace($script:resolverContentType) -or $script:resolverContentType.Contains("`r") -or $script:resolverContentType.Contains("`n")) {
        throw 'resolver.contentType must be a non-empty single-line value.'
    }
    $script:resolverTimeoutSeconds = Get-PositiveIntSetting -Object $resolver -Name 'timeoutSeconds' -DefaultValue 60
    $script:resolverHeaders = Get-ObjectProperty -Object $resolver -Name 'headers' -DefaultValue ([ordered]@{})
    Assert-HeadersObject -Headers $script:resolverHeaders -Name 'resolver.headers' -BlockedNames @('Host', 'Content-Length', 'Transfer-Encoding', 'Connection')
    $script:resolverBody = Get-ObjectProperty -Object $resolver -Name 'body' -Required
    Assert-JsonObjectValue -Value $script:resolverBody -Name 'resolver.body'
    $script:resolverSuccessConditions = @(Get-ResolverSuccessConditions -Resolver $resolver)
    $resolverResponse = Get-ObjectProperty -Object $resolver -Name 'response' -Required
    Assert-JsonObjectValue -Value $resolverResponse -Name 'resolver.response'
    $script:downloadUrlPath = Get-RequiredJsonPathSetting -Object $resolverResponse -Name 'downloadUrlPath' -QualifiedName 'resolver.response.downloadUrlPath'
    $script:fileNamePath = Get-RequiredJsonPathSetting -Object $resolverResponse -Name 'fileNamePath' -QualifiedName 'resolver.response.fileNamePath'
    $script:expectedSizePath = Get-RequiredJsonPathSetting -Object $resolverResponse -Name 'expectedSizePath' -QualifiedName 'resolver.response.expectedSizePath'
    $script:identityPath = Get-RequiredJsonPathSetting -Object $resolverResponse -Name 'identityPath' -QualifiedName 'resolver.response.identityPath'
    $script:sha256Path = if (Test-ObjectProperty -Object $resolverResponse -Name 'sha256Path') {
        Get-RequiredJsonPathSetting -Object $resolverResponse -Name 'sha256Path' -QualifiedName 'resolver.response.sha256Path'
    }
    else {
        $null
    }
}
else {
    $script:sha256Path = $null
}

$download = Get-ObjectProperty -Object $configuration -Name 'download' -Required
Assert-JsonObjectValue -Value $download -Name 'download'
$fileExtensionRaw = Get-ObjectProperty -Object $download -Name 'fileExtension' -DefaultValue ''
if ($fileExtensionRaw -isnot [string]) {
    throw 'download.fileExtension must be a string.'
}
$script:fileExtension = [string]$fileExtensionRaw
if (-not [string]::IsNullOrEmpty($script:fileExtension) -and (-not $script:fileExtension.StartsWith('.') -or $script:fileExtension.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0)) {
    throw 'download.fileExtension must be empty or a valid extension beginning with a dot.'
}
$script:allowedHosts = @(Get-AllowedHostPatterns -Download $download)
$script:allowedContentTypes = @(Get-AllowedContentTypes -Download $download)
$script:downloadHeaders = Get-ObjectProperty -Object $download -Name 'headers' -DefaultValue ([ordered]@{})
Assert-HeadersObject -Headers $script:downloadHeaders -Name 'download.headers' -BlockedNames @('Host', 'Content-Length', 'Transfer-Encoding', 'Connection', 'Range', 'If-Range', 'If-Match', 'Accept-Encoding')
$script:allowInsecureLocalhost = Get-BoolSetting -Object $download -Name 'allowInsecureLocalhost' -DefaultValue $false
$script:resumeEnabled = Get-BoolSetting -Object $download -Name 'resume' -DefaultValue $false
if ($script:resolverEnabled -and $script:resumeEnabled -and $null -eq $script:sha256Path) {
    throw 'resolver.response.sha256Path is required when download.resume is true.'
}
$script:maxAttempts = Get-PositiveIntSetting -Object $download -Name 'maxAttempts' -DefaultValue 3
$script:connectTimeoutSeconds = Get-PositiveIntSetting -Object $download -Name 'connectTimeoutSeconds' -DefaultValue 30
$script:maxTimeSeconds = Get-PositiveIntSetting -Object $download -Name 'maxTimeSeconds' -DefaultValue 300
$script:lowSpeedLimitBytes = Get-PositiveIntSetting -Object $download -Name 'lowSpeedLimitBytes' -DefaultValue 1024
$script:lowSpeedTimeSeconds = Get-PositiveIntSetting -Object $download -Name 'lowSpeedTimeSeconds' -DefaultValue 30
$signatureValue = Get-ObjectProperty -Object $download -Name 'signature' -DefaultValue $null
if ((Test-ObjectProperty -Object $download -Name 'signature') -and $null -eq $signatureValue) {
    throw 'download.signature cannot be null; omit it when no signature check is needed.'
}
$script:signatureSpec = Get-SignatureSpec -Signature $signatureValue

$script:sources = @(Get-SourceItems -Configuration $configuration)
foreach ($source in $script:sources) {
    $allowSourceLocalHttp = $script:allowInsecureLocalhost
    if ($script:resolverEnabled -and $script:resolverUri.IsLoopback -and $script:resolverUri.Scheme -ceq 'http') {
        $allowSourceLocalHttp = $true
    }
    [void](Get-SafeUri -Text $source.SourceUrl -AllowInsecureLocalhost $allowSourceLocalHttp)
}
if ((Test-Path -LiteralPath $script:destinationFullPath) -and -not (Test-Path -LiteralPath $script:destinationFullPath -PathType Container)) {
    throw "Destination path exists and is not a directory: $($script:destinationFullPath)"
}
Assert-ExistingSummaryCompatible

if ($ValidateOnly) {
    if (-not $script:resolverEnabled) {
        $validatedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $validatedIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($source in $script:sources) {
            $job = Resolve-ResourceJob -Source $source
            $fileName = Add-ConfiguredExtension -FileName (Get-SafeFileName -Name $job.FileName)
            $resourcePaths = Get-ResourcePaths -Job $job -FileName $fileName
            Assert-ResourcePathTypes -FinalPath $resourcePaths.Final -PartialPath $resourcePaths.Partial
            if (-not $validatedNames.Add($fileName)) {
                throw "Duplicate sanitized file name: $fileName"
            }
            if (-not $validatedIdentities.Add($job.Identity)) {
                throw "Duplicate resource identity: $($job.Identity)"
            }
        }
    }
    $mode = if ($script:resolverEnabled) { 'resolver' } else { 'direct' }
    Write-Host "VALID|$mode|$($script:sources.Count)|$($script:destinationFullPath)|$($script:summaryFullPath)"
    exit 0
}

$curlCommand = Get-Command curl.exe -ErrorAction SilentlyContinue
if ($null -eq $curlCommand) {
    throw 'curl.exe was not found.'
}
$curlVersionLine = [string](& curl.exe --disable --version | Select-Object -First 1)
if ($curlVersionLine -notmatch '^curl\s+([0-9]+\.[0-9]+\.[0-9]+)') {
    throw "Unable to parse curl version: $curlVersionLine"
}
$curlVersion = [version]$Matches[1]
if ($curlVersion -lt [version]'7.84.0') {
    throw "curl 7.84.0 or newer is required; found $curlVersion."
}

[void](New-Item -ItemType Directory -Path $script:destinationFullPath -Force)
$driveRoot = [IO.Path]::GetPathRoot($script:destinationFullPath)
if ([string]::IsNullOrWhiteSpace($driveRoot)) {
    throw "Unable to determine destination drive: $($script:destinationFullPath)"
}
$drive = [IO.DriveInfo]::new($driveRoot)
$script:results = [Collections.Generic.List[object]]::new()
$seenNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$seenIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$protocolList = if ($script:allowInsecureLocalhost) { '=http,https' } else { '=https' }

try {
    $ordinal = 0
    foreach ($source in $script:sources) {
        $ordinal++
        Write-Host "START|$ordinal|$($script:sources.Count)|$($source.Index)"
        $lockedFileName = $null
        $lockedIdentity = $null
        $lockedExpectedSize = 0L
        $lockedExpectedSha256 = $null

        for ($attempt = 1; $attempt -le $script:maxAttempts; $attempt++) {
            try {
                $job = Resolve-ResourceJob -Source $source
                $fileName = Add-ConfiguredExtension -FileName (Get-SafeFileName -Name $job.FileName)
                if ($null -eq $lockedFileName) {
                    if (-not $seenNames.Add($fileName)) {
                        throw "Duplicate sanitized file name: $fileName"
                    }
                    if (-not $seenIdentities.Add($job.Identity)) {
                        throw "Duplicate resource identity: $($job.Identity)"
                    }
                    $lockedFileName = $fileName
                    $lockedIdentity = $job.Identity
                    $lockedExpectedSize = $job.ExpectedSize
                    $lockedExpectedSha256 = $job.ExpectedSha256
                }
                elseif ($fileName -cne $lockedFileName -or $job.Identity -cne $lockedIdentity -or $job.ExpectedSize -ne $lockedExpectedSize -or $job.ExpectedSha256 -cne $lockedExpectedSha256) {
                    throw "Resource $($job.Index) changed identity, file name, size, or sha256 during retry."
                }

                $resourcePaths = Get-ResourcePaths -Job $job -FileName $fileName
                $finalPath = $resourcePaths.Final
                $partialPath = $resourcePaths.Partial
                Assert-ResourcePathTypes -FinalPath $finalPath -PartialPath $partialPath

                if (Test-Path -LiteralPath $finalPath -PathType Leaf) {
                    if (Test-Path -LiteralPath $partialPath -PathType Leaf) {
                        throw "Both final and partial files exist for resource $($job.Index)."
                    }
                    $existingFile = Get-Item -LiteralPath $finalPath
                    if ($existingFile.Length -ne $job.ExpectedSize -or -not (Test-FileSignature -Path $finalPath) -or ($null -ne $job.ExpectedSha256 -and (Get-FileSha256 -Path $finalPath) -cne $job.ExpectedSha256)) {
                        throw "Existing file does not match expected size, signature, or sha256: $finalPath"
                    }
                    [void]$script:results.Add([pscustomobject]@{
                        index = $job.Index
                        sourceUrl = $job.SourceUrl
                        identity = $job.Identity
                        file = $fileName
                        bytes = $existingFile.Length
                        sha256 = $job.ExpectedSha256
                        status = 'verified-existing'
                    })
                    Save-DownloadSummary
                    Write-Host "SKIP|$($job.Index)|$fileName|$($existingFile.Length)"
                    break
                }

                $partialLength = 0L
                if (Test-Path -LiteralPath $partialPath -PathType Leaf) {
                    $partialLength = (Get-Item -LiteralPath $partialPath).Length
                    if ($partialLength -gt $job.ExpectedSize) {
                        throw "Partial file is larger than expected: $partialPath"
                    }
                    if ($partialLength -eq $job.ExpectedSize) {
                        throw "A full-size partial file exists without a verified HTTP result: $partialPath"
                    }
                    if ($partialLength -gt 0 -and -not $script:resumeEnabled) {
                        throw "A partial file exists but safe resume is disabled: $partialPath"
                    }
                    if ($partialLength -gt 0 -and -not (Test-FileSignature -Path $partialPath -AllowTooShort)) {
                        throw "Partial file signature is invalid: $partialPath"
                    }
                }

                $remainingBytes = $job.ExpectedSize - $partialLength
                if ($drive.AvailableFreeSpace -lt $remainingBytes) {
                    throw "Insufficient free space; at least $remainingBytes bytes are required."
                }

                $context = [pscustomobject]@{ Index = $job.Index; SourceUrl = $job.SourceUrl }
                $curlArguments = [Collections.Generic.List[string]]::new()
                [void]$curlArguments.Add('--disable')
                foreach ($argument in @(
                    '--no-location',
                    '--max-redirs', '0',
                    '--fail',
                    '--show-error',
                    '--silent',
                    '--proto', $protocolList,
                    '--connect-timeout', [string]$script:connectTimeoutSeconds,
                    '--max-time', [string]$script:maxTimeSeconds,
                    '--speed-limit', [string]$script:lowSpeedLimitBytes,
                    '--speed-time', [string]$script:lowSpeedTimeSeconds
                )) {
                    [void]$curlArguments.Add([string]$argument)
                }
                [void]$curlArguments.Add('--header')
                [void]$curlArguments.Add('Accept-Encoding: identity')
                foreach ($headerArgument in @(Get-DownloadHeaderArguments -Context $context)) {
                    [void]$curlArguments.Add([string]$headerArgument)
                }
                foreach ($argument in @(
                    '--output', $partialPath,
                    '--write-out', '%{http_code}\t%{content_type}\t%{size_download}\t%header{content-range}\t%{url_effective}'
                )) {
                    [void]$curlArguments.Add([string]$argument)
                }
                if ($partialLength -gt 0) {
                    [void]$curlArguments.Add('--continue-at')
                    [void]$curlArguments.Add('-')
                }
                [void]$curlArguments.Add($job.DownloadUrl)

                Write-Host "DOWNLOAD|$($job.Index)|$attempt|$fileName|$partialLength|$($job.ExpectedSize)"
                $previousErrorActionPreference = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    $curlOutput = @(& curl.exe @curlArguments 2>&1)
                    $curlExitCode = $LASTEXITCODE
                }
                finally {
                    $ErrorActionPreference = $previousErrorActionPreference
                }
                if ($curlExitCode -ne 0) {
                    $curlFailureMessage = "curl failed with exit code ${curlExitCode}: $($curlOutput -join ' ')"
                    if (@(5, 6, 7, 18, 28, 35, 52, 55, 56, 92, 95, 96) -contains $curlExitCode) {
                        $failedPartialLength = if (Test-Path -LiteralPath $partialPath -PathType Leaf) { (Get-Item -LiteralPath $partialPath).Length } else { 0L }
                        if ($failedPartialLength -gt 0 -and -not $script:resumeEnabled) {
                            throw "$curlFailureMessage Safe resume is disabled, so the partial file was preserved without retry."
                        }
                        throw ([Net.WebException]::new($curlFailureMessage))
                    }
                    throw $curlFailureMessage
                }
                $statusLine = [string]($curlOutput | Select-Object -Last 1)
                $statusFields = $statusLine.Split([char]"`t", 5)
                if ($statusFields.Count -ne 5) {
                    throw "Unexpected curl status output: $statusLine"
                }
                [long]$downloadedThisAttempt = 0
                if (-not [long]::TryParse($statusFields[2], [ref]$downloadedThisAttempt)) {
                    throw "Invalid size_download in curl output: $statusLine"
                }
                if (-not (Test-ContentTypeAllowed -ContentType $statusFields[1])) {
                    throw "Unexpected content type: $($statusFields[1])"
                }
                $effectiveUri = Assert-DownloadUri -Url $statusFields[4]
                if ($partialLength -eq 0) {
                    if ($statusFields[0] -cne '200' -or $downloadedThisAttempt -ne $job.ExpectedSize -or -not [string]::IsNullOrWhiteSpace($statusFields[3])) {
                        throw "A new download did not return one complete HTTP 200 response: $statusLine"
                    }
                }
                else {
                    $expectedRange = "bytes $partialLength-$($job.ExpectedSize - 1)/$($job.ExpectedSize)"
                    if ($statusFields[0] -cne '206' -or $downloadedThisAttempt -ne ($job.ExpectedSize - $partialLength) -or $statusFields[3] -cne $expectedRange) {
                        throw "Resumed response does not match the expected byte range: $statusLine"
                    }
                }

                $downloadedFile = Get-Item -LiteralPath $partialPath
                if ($downloadedFile.Length -ne $job.ExpectedSize) {
                    throw "Downloaded size mismatch; expected $($job.ExpectedSize), actual $($downloadedFile.Length)."
                }
                if (-not (Test-FileSignature -Path $partialPath)) {
                    throw "Downloaded file signature is invalid: $partialPath"
                }
                if ($null -ne $job.ExpectedSha256 -and (Get-FileSha256 -Path $partialPath) -cne $job.ExpectedSha256) {
                    throw "Downloaded file sha256 does not match the expected value: $partialPath"
                }

                Assert-ResourcePathTypes -FinalPath $finalPath -PartialPath $partialPath
                if (Test-Path -LiteralPath $finalPath) {
                    throw "Final resource path appeared during download: $finalPath"
                }
                [IO.File]::Move($partialPath, $finalPath)
                [void]$script:results.Add([pscustomobject]@{
                    index = $job.Index
                    sourceUrl = $job.SourceUrl
                    identity = $job.Identity
                    file = $fileName
                    bytes = $downloadedFile.Length
                    sha256 = $job.ExpectedSha256
                    status = 'downloaded'
                })
                Save-DownloadSummary
                Write-Host "DONE|$($job.Index)|$fileName|$($downloadedFile.Length)|$($effectiveUri.Host)"
                break
            }
            catch {
                if ($attempt -ge $script:maxAttempts -or -not (Test-RetryableException -Exception $_.Exception)) {
                    throw
                }
                Write-Host "RETRY|$($source.Index)|$attempt|$($_.Exception.Message)"
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
    }

    if ($script:results.Count -ne $script:sources.Count) {
        throw "Unexpected final result count: expected $($script:sources.Count), actual $($script:results.Count)."
    }
    $remainingPartials = @(Get-ChildItem -LiteralPath $script:destinationFullPath -File -Force -Filter '*.part')
    if ($remainingPartials.Count -ne 0) {
        throw "Partial files remain after completion: $($remainingPartials.FullName -join ', ')"
    }

    Save-DownloadSummary
    $totalBytes = ($script:results | Measure-Object -Property bytes -Sum).Sum
    Write-Host "COMPLETE|$($script:results.Count)|$totalBytes|$($script:destinationFullPath)|$($script:summaryFullPath)"
}
catch {
    $originalError = $_
    try {
        Save-DownloadSummary
    }
    catch {
        Write-Warning "Failed to save summary after the main error: $($_.Exception.Message)"
    }
    $originalMessage = 'Download failed with an empty error record.'
    if ($null -ne $originalError) {
        $candidateMessage = [string]$originalError
        if ([string]::IsNullOrWhiteSpace($candidateMessage) -and $null -ne $originalError.Exception) {
            $candidateMessage = [string]$originalError.Exception.Message
        }
        if (-not [string]::IsNullOrWhiteSpace($candidateMessage)) {
            $originalMessage = $candidateMessage
        }
    }
    [Console]::Error.WriteLine($originalMessage)
    exit 1
}
