<#
    .SYNOPSIS
    Searches CBS servicing logs and Windows Event Logs for evidence of a Windows update rollback or
    finalization failure for a specified KB.

    .DESCRIPTION
    This script scans:
    - CBS servicing logs (CBS.log and CbsPersist_*.log)
    - Key Windows Event Logs that commonly capture servicing / update rollback activity

    To avoid misleading results, the script is "KB-gated":
        - If the KB string is NOT found anywhere in CBS logs, the script stops after writing a clear message.
        (This prevents generic "rollback"/"0x800f" matches from being misattributed to the requested KB.)

    .OUTPUTS
    Text file containing matching CBS log entries and matching Windows Event Log entries written to a
    KB-specific folder under C:\Temp.

    .EXAMPLE
    PS C:\> .\Find-KBRollback.ps1 -KB KB5066586

    .EXAMPLE
    PS C:\> .\Find-KBRollback.ps1 -KB 5066586

    .NOTES
    - Requires administrative privileges to access CBS logs and some event channels.
    - Results depend on log retention and availability.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$KB,

    # How far back to search Windows Event Logs
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 365)]
    [int]$EventLookbackDays = 14,

    # Limit events per channel to keep output manageable
    [Parameter(Mandatory = $false)]
    [ValidateRange(50, 5000)]
    [int]$MaxEventsPerLog = 1000
)

# Normalize KB input (accepts "5066586" or "KB5066586")
if ($KB -notmatch '^KB\d+$') {
    if ($KB -match '^\d+$') {
        $KB = "KB$KB"
    } else {
        throw "Invalid KB format. Use 'KB#######' or '#######'. Received: $KB"
    }
}

# Search patterns (CBS)
$patterns = @($KB, 'rollback', 'revert', 'failed to finalize', '0x800f')

# Output location (KB-specific)
$outDir  = "C:\Temp\${KB}_Triage"
$outFile = Join-Path $outDir "KB_Rollback_Evidence.txt"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# CBS log files
$files = @("$env:windir\Logs\CBS\CBS.log") +
         (Get-ChildItem "$env:windir\Logs\CBS\CbsPersist_*.log" -ErrorAction SilentlyContinue |
          Select-Object -ExpandProperty FullName)

# Collect output
$outLines = @()
$outLines += "==== KB Rollback / Finalize Evidence ===="
$outLines += "Timestamp: $(Get-Date)"
$outLines += "KB: $KB"
$outLines += "CBS Patterns: $($patterns -join ', ')"
$outLines += "Event Lookback (days): $EventLookbackDays"
$outLines += "========================================"
$outLines += ""

# -----------------------
# KB GATING (CBS PRESENCE)
# -----------------------
$kbFound = $false
foreach ($f in $files) {
    if (Test-Path $f) {
        if (Select-String -Path $f -Pattern $KB -SimpleMatch -Quiet -ErrorAction SilentlyContinue) {
            $kbFound = $true
            break
        }
    }
}

if (-not $kbFound) {
    $outLines += "ERROR: The KB identifier '$KB' was NOT found in CBS logs."
    $outLines += "To avoid misattributing generic rollback/failure indicators, the script will stop here."
    $outLines += "Verify the KB value, CBS log retention window, or whether the update is referenced by package identity instead of KB."
    $outLines += ""
    $outLines += "Search complete."
    $outLines += "Output: $outFile"

    $outLines | Out-File -FilePath $outFile -Encoding Unicode
    return
}

# -----------------------
# CBS LOG SEARCH SECTION
# -----------------------
$outLines += "==== CBS LOG SEARCH ===="
$outLines += ""

foreach ($f in $files) {
    if (Test-Path $f) {
        $outLines += "---- FILE: $f ----"

        $hits = Select-String -Path $f -Pattern $patterns -SimpleMatch -ErrorAction SilentlyContinue |
                Sort-Object LineNumber

        if (-not $hits) {
            $outLines += "(no matches)"
            $outLines += ""
            continue
        }

        foreach ($h in $hits) {
            $outLines += "[$f] Line $($h.LineNumber)"
            $outLines += $h.Line.Trim()
            $outLines += ""
        }
    }
}

$outLines += "==== END CBS LOG SEARCH ===="
$outLines += ""

# -----------------------------
# WINDOWS EVENT LOGS SECTION
# -----------------------------
$outLines += "==== WINDOWS EVENT LOG SEARCH ===="
$outLines += ""

$eventStart = (Get-Date).AddDays(-$EventLookbackDays)

# Channels that commonly contain servicing/rollback/update evidence
$channels = @(
    "Microsoft-Windows-Servicing/Operational",
    "Microsoft-Windows-WindowsUpdateClient/Operational",
    "Setup",
    "System"
)

# Keywords to detect rollback-like behavior in event messages
# (KB must be present in message to be included)
$eventKeywords = @(
    "rollback",
    "rolled back",
    "revert",
    "reverted",
    "failed",
    "finalize",
    "0x800f"
)

foreach ($logName in $channels) {
    $outLines += "---- EVENT LOG: $logName (since $($eventStart.ToString('yyyy-MM-dd HH:mm:ss'))) ----"

    # Skip channels that don't exist on the system
    if (-not (Get-WinEvent -ListLog $logName -ErrorAction SilentlyContinue)) {
        $outLines += "(event log channel not present on this system)"
        $outLines += ""
        continue
    }

    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName = $logName; StartTime = $eventStart } -ErrorAction Stop |
                  Sort-Object TimeCreated -Descending |
                  Select-Object -First $MaxEventsPerLog
    } catch {
        $outLines += "(unable to read this channel: $($_.Exception.Message))"
        $outLines += ""
        continue
    }

    # Include only events that reference the KB, and also match at least one rollback/failure keyword
    $filteredMatches = foreach ($e in $events) {
        $msg = $e.Message
        if (-not $msg) { continue }

        if ($msg -notlike "*$KB*") { continue }

        foreach ($kw in $eventKeywords) {
            if ($msg -like "*$kw*") { $e; break }
        }
    }

    if (-not $filteredMatches) {
        $outLines += "(no matches)"
        $outLines += ""
        continue
    }

    foreach ($e in ($filteredMatches | Sort-Object TimeCreated)) {
        $outLines += "Time: $($e.TimeCreated) | Provider: $($e.ProviderName) | EventID: $($e.Id) | Level: $($e.LevelDisplayName)"
        $outLines += "Message: $($e.Message -replace '\r?\n',' ')"  # one-line message for readability
        $outLines += ""
    }
}

$outLines += "==== END WINDOWS EVENT LOG SEARCH ===="
$outLines += ""

# Final status
$outLines += "Search complete."
$outLines += "Output: $outFile"

# Output log
$outLines | Out-File -FilePath $outFile -Encoding Unicode