<#
.SYNOPSIS
    Retrieves audit events from Automox API for a specified date range.

.DESCRIPTION
    This script queries the Automox Audit Trail API to retrieve audit events across a specified date range.
    Since the Automox API only accepts a single date per request, the script loops through each date
    in the range and aggregates all events. It also handles pagination automatically to ensure all
    events are retrieved for each date.

.PARAMETER StartDate
    The start date for the audit event query. Defaults to 7 days ago.
    Format: DateTime object or string that can be converted to DateTime (e.g., "2024-09-01")

.PARAMETER EndDate
    The end date for the audit event query. Defaults to today.
    Format: DateTime object or string that can be converted to DateTime (e.g., "2024-09-30")

.PARAMETER ApiKey
    Your Automox API key. This parameter is required.
    The API key should have permissions to access the audit trail.

.PARAMETER OrgUUID
    Your Automox organization UUID. This parameter is required.
    Format: UUID (e.g., "123e4567-e89b-12d3-a456-426614174000")

.PARAMETER Limit
    Number of events to retrieve per API request. Defaults to 500 (API maximum).
    Valid range: 1-500

.PARAMETER ActivityName
    Filter events by activity name (case-insensitive partial match).
    Examples: "Logon", "Create", "Update", "Delete"

.PARAMETER Message
    Filter events by message text (case-insensitive partial match).
    Example: "user", "policy", "device"

.PARAMETER Severity
    Filter events by severity level.
    Valid values: "Unknown", "Informational", "Low", "Medium", "High", "Critical", "Fatal", "Other"

.PARAMETER StatusId
    Filter events by status ID.
    Common values: 1 (Success), 2 (Failure)

.PARAMETER TypeName
    Filter events by type name (case-insensitive partial match).
    Examples: "Authentication", "Account Change", "Entity Management", "User Access", "Web Resource Activity"

.OUTPUTS
    System.Array
    Returns an array of audit event objects in OCSF schema format.

.EXAMPLE
    .\getAuditEvents.ps1 -ApiKey "your_api_key" -OrgUUID "your_org_uuid"

    Retrieves audit events from the last 7 days (default date range).

.EXAMPLE
    .\getAuditEvents.ps1 -ApiKey "your_api_key" -OrgUUID "your_org_uuid" -StartDate "2024-09-01" -EndDate "2024-09-30"

    Retrieves audit events for the entire month of September 2024.

.EXAMPLE
    $events = .\getAuditEvents.ps1 -ApiKey "your_api_key" -OrgUUID "your_org_uuid" -StartDate (Get-Date).AddDays(-30)
    $events | Export-Csv -Path "audit_events.csv" -NoTypeInformation

    Retrieves the last 30 days of audit events and exports them to a CSV file.

.EXAMPLE
    .\getAuditEvents.ps1 -ApiKey "your_api_key" -OrgUUID "your_org_uuid" -StartDate "2024-09-25" -EndDate "2024-09-25" -Limit 100

    Retrieves audit events for a single date (September 25, 2024) with a limit of 100 events per request.

.EXAMPLE
    .\getAuditEvents.ps1 -ApiKey "your_api_key" -OrgUUID "your_org_uuid" -ActivityName "Logon"

    Retrieves all logon events from the last 7 days.

.EXAMPLE
    .\getAuditEvents.ps1 -ApiKey "your_api_key" -OrgUUID "your_org_uuid" -Message "policy" -StartDate "2024-09-01" -EndDate "2024-09-30"

    Retrieves all events containing "policy" in the message field for September 2024.

.EXAMPLE
    .\getAuditEvents.ps1 -ApiKey "your_api_key" -OrgUUID "your_org_uuid" -StatusId 2 -Severity "High"

    Retrieves all failed (StatusId=2) high severity events from the last 7 days.

.NOTES
    API Endpoint: https://console.automox.com/api/audit-service/v1/orgs/{orgUuid}/events

    The Automox API only accepts a single date per request, so this script makes multiple API calls
    when querying a date range. For large date ranges, this may take some time to complete.

    The script automatically handles pagination using cursor-based pagination to ensure all events
    are retrieved for each date.

.LINK
    https://docs.automox.com/product/Developer/Automox_API_Reference.htm?tocpath=Developer%20Documentation%7C_____10#tag/audit-trail
#>

param(
    [Parameter(Mandatory=$false)]
    [datetime]$StartDate = (Get-Date).AddDays(-7),

    [Parameter(Mandatory=$false)]
    [datetime]$EndDate = (Get-Date),

    [Parameter(Mandatory=$true)]
    [string]$ApiKey,

    [Parameter(Mandatory=$true)]
    [string]$OrgUUID,

    [Parameter(Mandatory=$false)]
    [int]$Limit = 500,

    [Parameter(Mandatory=$false)]
    [string]$ActivityName,

    [Parameter(Mandatory=$false)]
    [string]$Message,

    [Parameter(Mandatory=$false)]
    [ValidateSet("Unknown", "Informational", "Low", "Medium", "High", "Critical", "Fatal", "Other")]
    [string]$Severity,

    [Parameter(Mandatory=$false)]
    [int]$StatusId,

    [Parameter(Mandatory=$false)]
    [string]$TypeName
)

$headers = @{
    "Authorization" = "Bearer $ApiKey"
    "Content-Type" = "application/json"
    "x-ax-organization-uuid" = $OrgUUID
}

$allEvents = @()

# Loop through each date in the range
$currentDate = $StartDate.Date
while ($currentDate -le $EndDate.Date) {
    $dateString = $currentDate.ToString("yyyy-MM-dd")
    Write-Host "Fetching events for $dateString..." -ForegroundColor Cyan

    $cursor = $null
    $hasMorePages = $true

    # Handle pagination for each date
    while ($hasMorePages) {
        $url = "https://console.automox.com/api/audit-service/v1/orgs/$OrgUUID/events?date=$dateString&limit=$Limit"

        if ($cursor) {
            $url += "&cursor=$cursor"
        }

        try {
            $response = (Invoke-WebRequest -Method Get -Uri $url -Headers $headers -UseBasicParsing).Content | ConvertFrom-Json

            if ($response.data -and $response.data.Count -gt 0) {
                $allEvents += $response.data
                Write-Host "  Retrieved $($response.data.Count) events" -ForegroundColor Green

                # Check if there are more pages
                if ($response.data.Count -eq $Limit) {
                    # Get the last event's ID as cursor for next page
                    $cursor = $response.data[-1].metadata.uid
                } else {
                    $hasMorePages = $false
                }
            } else {
                $hasMorePages = $false
            }
        } catch {
            Write-Host "  Error fetching events: $_" -ForegroundColor Red
            $hasMorePages = $false
        }
    }

    $currentDate = $currentDate.AddDays(1)
}

Write-Host "`nTotal events retrieved: $($allEvents.Count)" -ForegroundColor Yellow

# Apply client-side filtering if filter parameters are specified
$filteredEvents = $allEvents

if ($ActivityName) {
    $filteredEvents = $filteredEvents | Where-Object { $_.activity_name -like "*$ActivityName*" }
    Write-Host "Filtered by ActivityName '$ActivityName': $($filteredEvents.Count) events" -ForegroundColor Magenta
}

if ($Message) {
    $filteredEvents = $filteredEvents | Where-Object { $_.message -like "*$Message*" }
    Write-Host "Filtered by Message '$Message': $($filteredEvents.Count) events" -ForegroundColor Magenta
}

if ($Severity) {
    $filteredEvents = $filteredEvents | Where-Object { $_.severity -eq $Severity }
    Write-Host "Filtered by Severity '$Severity': $($filteredEvents.Count) events" -ForegroundColor Magenta
}

if ($StatusId) {
    $filteredEvents = $filteredEvents | Where-Object { $_.status_id -eq $StatusId }
    Write-Host "Filtered by StatusId '$StatusId': $($filteredEvents.Count) events" -ForegroundColor Magenta
}

if ($TypeName) {
    $filteredEvents = $filteredEvents | Where-Object { $_.type_name -like "*$TypeName*" }
    Write-Host "Filtered by TypeName '$TypeName': $($filteredEvents.Count) events" -ForegroundColor Magenta
}

if ($filteredEvents.Count -ne $allEvents.Count) {
    Write-Host "`nFinal filtered result: $($filteredEvents.Count) events" -ForegroundColor Yellow
}

return $filteredEvents