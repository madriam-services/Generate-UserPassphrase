# .SYNOPSIS
# Generates a random Diceware-style passphrase using the EFF large wordlist.
#
# .DESCRIPTION
# Loaded by One Identity Active Roles as a Script Module bound to a Policy
# Object. The onGetEffectivePolicy event handler is invoked by the Active
# Roles policy engine to server-side generate the value of the edsaPassword
# attribute on user objects.
#
# Randomness comes from System.Security.Cryptography.RandomNumberGenerator
# via Get-SecureRandomInt, which uses rejection sampling to produce a
# uniform integer over [0, MaxExclusive) without modulo bias.
#
# .NOTES
# Word list: Electronic Frontier Foundation,
# "EFF Large Wordlist for Passphrases"
# https://www.eff.org/dice
# Licensed under CC BY (https://creativecommons.org/licenses/by/4.0/)
# Source file:
# https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt
# The wordlist is cached locally in the ProgramData folder, and verified
# against the online source at least every -WordListRefreshIntervalDays days
# unless -SkipWordListUpdate is used.
#
# Portions of this script (notably Get-SecureRandomInt) were drafted with
# AI assistance and have been reviewed and tested by a human.
#
# .NOTES Logging
# Warning and Error events are always written to the Active Roles event log
# via the intrinsic $EventLog object (EventLog.ReportEvent). Information-
# level events are suppressed by default to keep the AR event log quiet.
# To enable them while debugging, set $script:LogInfoToEventLog = $true
# below.

# Set to $true to emit Information-level events to the Active Roles event
# log (cache lifecycle and, if enabled in onGetEffectivePolicy, per-
# passphrase generation). Warning and Error events are always logged
# regardless of this setting.
$script:LogInfoToEventLog = $false

function Write-AREventLog {
    # .SYNOPSIS
    # Writes a message to the Active Roles event log via $EventLog.
    #
    # .DESCRIPTION
    # Dispatches to $EventLog.ReportEvent using the matching
    # EDS_EVENTLOG_*_TYPE constant from $Constants. Information-level events
    # are emitted only when $script:LogInfoToEventLog is $true. Warning and
    # Error events always go through.
    #
    # The Active Roles event log entry automatically includes request
    # context (request ID, target object name, class, GUID, source
    # container), so messages should describe what the script did, not
    # which object it acted on.
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$DetailMsg1,
        [string]$DetailMsg2
    )

    if ($Level -eq 'Information' -and -not $script:LogInfoToEventLog) {
        return
    }

    $type = switch ($Level) {
        'Information' { $Constants.EDS_EVENTLOG_INFORMATION_TYPE }
        'Warning' { $Constants.EDS_EVENTLOG_WARNING_TYPE }
        'Error' { $Constants.EDS_EVENTLOG_ERROR_TYPE }
    }

    if ($PSBoundParameters.ContainsKey('DetailMsg2')) {
        $EventLog.ReportEvent($type, $Message, $DetailMsg1, $DetailMsg2)
    }
    elseif ($PSBoundParameters.ContainsKey('DetailMsg1')) {
        $EventLog.ReportEvent($type, $Message, $DetailMsg1)
    }
    else {
        $EventLog.ReportEvent($type, $Message)
    }
}

function Get-SecureRandomInt {
    # .SYNOPSIS
    # Uniform integer in [0, MaxExclusive) using RandomNumberGenerator.
    #
    # .DESCRIPTION
    # Uses rejection sampling to keep each output value equally likely.
    # A raw 32-bit random number range (0..2^32) is not always divisible by
    # MaxExclusive. Using a naive modulo on the raw value would bias the
    # lower output values slightly. To avoid that, we compute the largest
    # multiple of MaxExclusive that fits in a 32-bit range ("bucket") and
    # discard any draw that lands above it before taking the modulo.
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxExclusive
    )

    if ($MaxExclusive -eq 1) {
        return 0
    }

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 4
    try {
        $n = [uint64]$MaxExclusive
        $bucket = [uint64]([math]::Floor(4294967296.0 / $n) * $n)
        do {
            $null = $rng.GetBytes($bytes)
            $r = [uint64][BitConverter]::ToUInt32($bytes, 0)
        } while ($r -ge $bucket)

        return [int]($r % $n)
    }
    finally {
        $null = $rng.Dispose()
    }
}
function Get-TitleCaseWord {
    # .SYNOPSIS
    # Converts a word to title case (first letter upper-case).
    param([string]$Word)
    if ([string]::IsNullOrEmpty($Word)) {
        return $Word
    }
    $ti = (Get-Culture).TextInfo
    return $ti.ToTitleCase($Word.ToLowerInvariant())
}
function Test-EffWordListFile {
    # .SYNOPSIS
    # Validates that a candidate file parses as a complete EFF word list.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    try {
        $null = Get-EffWordListFromPath -Path $Path
        return $true
    }
    catch {
        return $false
    }
}
function Get-EffWordListFromPath {
    # .SYNOPSIS
    # Reads and parses the EFF large word list from disk.
    param([string]$Path)

    $words = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($line -match '^\d+\s+(.+)$') {
            [void]$words.Add($Matches[1].Trim())
        }
    }

    if ($words.Count -ne 7776) {
        throw "Expected 7776 words in EFF large wordlist; found $($words.Count) in '$Path'."
    }

    return $words.ToArray()
}
function Get-EffWordList {
    # .SYNOPSIS
    # Loads the EFF word list from a path after existence checks.
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Word list not found: $Path."
    }

    return (Get-EffWordListFromPath -Path $Path)
}
function Read-EffWordListMetadata {
    # .SYNOPSIS
    # Reads cache metadata JSON from disk when present and valid.
    param([string]$MetaPath)

    if (-not (Test-Path -LiteralPath $MetaPath)) {
        return $null
    }

    $raw = [System.IO.File]::ReadAllText($MetaPath)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    try {
        return $raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}
function Write-EffWordListMetadata {
    # .SYNOPSIS
    # Writes cache metadata JSON alongside the cached word list.
    param(
        [string]$MetaPath,
        [datetime]$LastCheckedUtc,
        [string]$SourceUrl,
        [int]$RefreshIntervalDays,
        [string]$WordListFileName
    )

    $obj = [ordered]@{
        LastCheckedUtc      = $LastCheckedUtc.ToUniversalTime().ToString('o')
        SourceUrl           = $SourceUrl
        RefreshIntervalDays = $RefreshIntervalDays
        WordListFileName    = $WordListFileName
    }

    $json = $obj | ConvertTo-Json -Depth 3
    $dir = [System.IO.Path]::GetDirectoryName($MetaPath)
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }

    $temp = [System.IO.Path]::GetTempFileName()
    try {
        $null = [System.IO.File]::WriteAllText($temp, $json, [System.Text.UTF8Encoding]::new($false))
        $null = Move-Item -LiteralPath $temp -Destination $MetaPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            $null = Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}
function Test-EffWordListNeedsRefresh {
    # .SYNOPSIS
    # Determines whether the cached word list should be refreshed.
    param(
        [string]$WordListPath,
        [string]$MetaPath,
        [int]$IntervalDays
    )

    if (-not (Test-Path -LiteralPath $WordListPath)) {
        return $true
    }

    if (-not (Test-EffWordListFile -Path $WordListPath)) {
        return $true
    }

    $meta = Read-EffWordListMetadata -MetaPath $MetaPath
    if ($null -eq $meta -or [string]::IsNullOrWhiteSpace([string]$meta.LastCheckedUtc)) {
        return $true
    }

    try {
        $last = [datetime]::Parse(
            [string]$meta.LastCheckedUtc,
            $null,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
    }
    catch {
        return $true
    }

    $elapsed = [datetime]::UtcNow - $last.ToUniversalTime()
    return ($elapsed.TotalDays -ge [double]$IntervalDays)
}
function Update-EffWordListFromWeb {
    # .SYNOPSIS
    # Downloads the EFF word list and updates local cache metadata.
    param(
        [string]$DestinationPath,
        [string]$MetaPath,
        [string]$SourceUrl,
        [int]$RefreshIntervalDays,
        [string]$WordListFileName
    )

    $dir = [System.IO.Path]::GetDirectoryName($DestinationPath)
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }

    $temp = Join-Path $dir ([System.IO.Path]::GetRandomFileName() + '.download')
    try {
        Write-AREventLog -Level Information `
            -Message "Downloading EFF wordlist." `
            -DetailMsg1 "Source URL: $SourceUrl"

        $null = Invoke-WebRequest -Uri $SourceUrl -OutFile $temp -UseBasicParsing

        if (-not (Test-EffWordListFile -Path $temp)) {
            throw 'Downloaded file failed validation (expected 7776 words).'
        }

        $null = Move-Item -LiteralPath $temp -Destination $DestinationPath -Force
        $null = Write-EffWordListMetadata -MetaPath $MetaPath -LastCheckedUtc ([datetime]::UtcNow) -SourceUrl $SourceUrl -RefreshIntervalDays $RefreshIntervalDays -WordListFileName $WordListFileName

        Write-AREventLog -Level Information `
            -Message "EFF wordlist cache refreshed." `
            -DetailMsg1 "Wordlist: $DestinationPath" `
            -DetailMsg2 "Metadata: $MetaPath"
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            $null = Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}
function Ensure-EffWordListCache {
    # .SYNOPSIS
    # Ensures a valid local cache exists and refreshes it when due.
    param(
        [string]$WordListPath,
        [string]$MetaPath,
        [int]$IntervalDays,
        [bool]$SkipUpdate,
        [string]$SourceUrl,
        [string]$WordListFileName
    )

    $dir = [System.IO.Path]::GetDirectoryName($WordListPath)
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }

    $needs = Test-EffWordListNeedsRefresh -WordListPath $WordListPath -MetaPath $MetaPath -IntervalDays $IntervalDays

    if (-not $needs) {
        Write-AREventLog -Level Information `
            -Message "Using cached EFF wordlist (last checked within $IntervalDays days)."
        return
    }

    if ($SkipUpdate) {
        if (-not (Test-Path -LiteralPath $WordListPath)) {
            throw "Word list not found at '$WordListPath' and -SkipWordListUpdate was specified. Place eff_large_wordlist.txt there or allow an online update."
        }
        if (-not (Test-EffWordListFile -Path $WordListPath)) {
            throw "Word list at '$WordListPath' is invalid or incomplete."
        }
        Write-AREventLog -Level Information `
            -Message 'SkipWordListUpdate set: using existing wordlist without contacting the network.'
        return
    }

    try {
        $null = Update-EffWordListFromWeb -DestinationPath $WordListPath -MetaPath $MetaPath -SourceUrl $SourceUrl -RefreshIntervalDays $IntervalDays -WordListFileName $WordListFileName
    }
    catch {
        if (Test-Path -LiteralPath $WordListPath) {
            Write-AREventLog -Level Warning `
                -Message "Could not refresh EFF wordlist; using existing cache." `
                -DetailMsg1 "Source URL: $SourceUrl" `
                -DetailMsg2 "Reason: $($_.Exception.Message)"
        }
        else {
            throw
        }
    }
}

function New-Password() {
    # .SYNOPSIS
    # Generates a Diceware-style passphrase using configured options.
    #
    # .DESCRIPTION
    # Selects $NumberOfWords words from the EFF large wordlist using a
    # cryptographically secure uniform RNG, optionally title-cases them, and
    # optionally appends a single random digit to one of the words. Words are
    # joined with $WordSeparator and returned as a single string.
    #
    # .PARAMETER NumberOfWords
    # Number of words in the passphrase. Defaults to 3.
    #
    # .PARAMETER WordSeparator
    # String placed between words. Defaults to '-'.
    #
    # .PARAMETER Capitalisation
    # When $true (default), each word is title-cased.
    #
    # .PARAMETER IncludeNumber
    # When $true (default), one random digit (0-9) is appended to one of the
    # randomly chosen words.
    #
    # .PARAMETER WordListRefreshIntervalDays
    # Maximum age (in days) of the cached wordlist before it is re-downloaded
    # from the EFF. Range 1-365, default 30. Ignored when -SkipWordListUpdate
    # is set.
    #
    # .PARAMETER SkipWordListUpdate
    # When set, the script will never reach the network. A valid local
    # wordlist cache must already exist.
    param(
        [ValidateRange(1, [int]::MaxValue)]
        [int]$NumberOfWords = 3,
        [string]$WordSeparator = '-',
        [bool]$Capitalisation = $true,
        [bool]$IncludeNumber = $true,
        [ValidateRange(1, 365)]
        [int]$WordListRefreshIntervalDays = 30,
        [switch]$SkipWordListUpdate
    )

    $effWordListSourceUrl = 'https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt'
    $effWordListCacheDir = Join-Path $env:ProgramData 'One Identity\Active Roles'
    $effWordListCacheFileName = 'eff_large_wordlist.txt'
    $effWordListMetadataFileName = 'eff_large_wordlist.metadata.json'

    $WordListPath = Join-Path $effWordListCacheDir $effWordListCacheFileName
    $metaPath = Join-Path $effWordListCacheDir $effWordListMetadataFileName

    $null = Ensure-EffWordListCache -WordListPath $WordListPath -MetaPath $metaPath -IntervalDays $WordListRefreshIntervalDays -SkipUpdate:$SkipWordListUpdate -SourceUrl $effWordListSourceUrl -WordListFileName $effWordListCacheFileName

    $effWords = Get-EffWordList -Path $WordListPath
    $wordCount = $effWords.Length
    $words = New-Object string[] $NumberOfWords

    for ($i = 0; $i -lt $NumberOfWords; $i++) {
        $idx = Get-SecureRandomInt -MaxExclusive $wordCount
        $w = $effWords[$idx]
        if ($Capitalisation) {
            $w = Get-TitleCaseWord -Word $w
        }
        $words[$i] = $w
    }

    if ($IncludeNumber) {
        $target = Get-SecureRandomInt -MaxExclusive $NumberOfWords
        $digit = Get-SecureRandomInt -MaxExclusive 10
        $words[$target] = $words[$target] + $digit.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }

    return ($words -join $WordSeparator)

}

function onGetEffectivePolicy($request) {
    # .SYNOPSIS
    # One Identity Active Roles "OnGetEffectivePolicy" event handler.
    #
    # .DESCRIPTION
    # Invoked by Active Roles when the UI asks for the effective policy on a
    # directory object. For user objects, this handler:
    #   1. Marks edsaPassword as server-side generated so the UI hides the
    #      manual password field.
    #   2. When Active Roles asks for the full effective policy info for
    #      edsaPassword, generates a passphrase via New-Password and returns
    #      it as the suggested value.
    #
    # The $request parameter is supplied by the Active Roles script host and
    # represents the current policy request.
    if ($request.Class -ne "user") {
        return
    }

    $null = $request.SetEffectivePolicyInfo("edsaPassword", $constants.EDS_EPI_UI_SERVER_SIDE_GENERATED, $true)

    $controlFullPolicyInfo = [string]::Empty
    try {
        $controlFullPolicyInfo = $request.GetInControl($constants.EDS_CONTROL_FULL_EFFECTIVE_POLICY_INFO)
    }
    catch {}
    if ($controlFullPolicyInfo -ne "edsaPassword") {
        return
    }

    $newPwd = New-Password -NumberOfWords 3 -WordSeparator "-" -Capitalisation $true -IncludeNumber $true

    # Per-generation audit event. Gated by $script:LogInfoToEventLog (off by
    # default) so it does not flood the AR event log in normal operation.
    # Set $script:LogInfoToEventLog = $true at the top of this script to
    # enable. The generated passphrase value is intentionally NOT logged;
    # only the fact that one was generated. The AR engine already prepends
    # the target user's context (name, GUID, container) to the entry.
    Write-AREventLog -Level Information `
        -Message "Generated a server-side passphrase for edsaPassword."

    $null = $request.SetEffectivePolicyInfo("edsaPassword", $constants.EDS_EPI_UI_GENERATED_VALUE, $newPwd)
}
