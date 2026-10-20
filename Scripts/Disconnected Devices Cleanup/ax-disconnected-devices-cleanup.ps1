<#

.SYNOPSIS
	This script uses the Automox API to cleanup stale Automox devices that have been disconnected for longer than X days.

	DISCLAIMER
	This script will permanently remove devices from your Automox instance!
	The amagent will need to be re-installed on any devices that are removed as a byproduct of this script run.
	Please read through the description and implementation instructions carefully so you understand the impact this may have in your environment.

    It is recommended to run this script locally and not in an Automox Worklet.

.DESCRIPTION
	This script queries an Automox organization to find devices that have been disconnected from Automox for longer than a defined number of days.	
	If the device has exceeded this threshold, it is permanently removed from the Automox console.
	This threshold can be changed by adjusting "ageLimit" parameter in the "REQUIRED USER PARAMETERS" section of the worklet.
	Because these removals are irreversible, a "dry run" mode is available to review which devices would be deleted before any actual deletion occurs.
	This is the default run-mode of the script.
	An optional "excludedDevice" array can also be configured to exclude specific host names from the device deletion process.

    This script can be ran locally via Powershell using the parameters below.

.EXAMPLE
    .\ax-disconnected-devices-cleanup.ps1 -apiKey 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX' -orgID XXXXXX

.PARAMETER apiKey
	[ System.String ] : Mandatory
		Your Automox Platform API Key.
		This key must be created with permissions to read and delete Devices.

.EXAMPLE
    apiKey = 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX'
	https://docs.automox.com/product/Product_Documentation/Settings/Managing_Keys.htm?Highlight=api%20key

.PARAMETER orgID
	[ System.Int32 ] : Mandatory
		Defines your Automox Organization ID.
		This is the Automox Org that is queried for devices in a disconnected state.

.EXAMPLE
	orgID = 123456
	https://docs.automox.com/product/Product_Documentation/Global_Access_Management/Managing_Organizations.htm?Highlight=managing%20orgs

.PARAMETER ageLimit
	[ System.Int32 ] : Mandatory
		Defines the amount of days a device can be in a disconnected state before it is purged from the target Automox Org.
		This is defaulted to 120 days.

.EXAMPLE
	$ageLimit = 120
		In this example, devices that have been disconnected for more than 120 days will be deleted.

.PARAMETER excludedDevices
	[ System.String ] : Optional
		Defines a list of device host names to be excluded from the deletion process.
		This can be a single string or an array of device names.
        Host names must match exactly as they appear within the Automox Console.

.EXAMPLE
    $excludedDevices = @(
        "DeviceName1",
        "DeviceName2",
        "DeviceName3"
    )

.PARAMETER dryRun
	[ System.Boolean ] : Mandatory
		Determines if the script should run in Dry Run mode.
		This value is defaulted to $true
		With dryRun enabled, non-compliant devices will be reported on but not deleted.

.EXAMPLE
	$dryRun = $true
		With dryRun set to $true, non-compliant devices WILL NOT be deleted.

.EXAMPLE
	$dryRun = $false
		With dryRun set to $false, non-compliant devices WILL be deleted.

.NOTES
	Additional Activity Log output can be enabled by uncommenting $VerbosePreference.

	PREREQUISITES
		Automox Platform API key.
		Automox orgID.


.HISTORY
	Name: John Guarracino
	Date: 11/09/2023
	Version: 1.0.0
	Release Notes:
		- Initial Release.

	Name: John Guarracino
	Date: 04/04/2025
	Version: 1.0.1
	Release Notes:
		- Added ability to exclude devices from being processed for deletion.
		- Updated help text and usage instructions.

	Name: John Guarracino
	Date: 07/28/2026
	Version: 1.0.2
	Release Notes:
		- Fixed pagination logic to correctly iterate through all API result pages.
		- Corrected while condition to reference proper array property.

    Name: Kyle Gregg
    Date: 10/20/2026
    Version: 1.0.3
    Release Notes:
        - Modified script for Automox Community release.

.LINK
	https://help.automox.com/hc/en-us/articles/5351996773012-Disconnected-Devices-Cleanup-Using-the-Console-or-PowerShell-or-Python
	https://console.automox.com/api/docs#console-api/tag/devices
	https://console.automox.com/api/docs#console-api/tag/devices/DELETE/servers/{deviceID}

#>

#########################################
# REQUIRED USER PARAMETERS

[CmdletBinding()]
param
(
	[Parameter(Mandatory = $true, HelpMessage = 'Your Automox Platform API Key.')]
	[ValidateNotNullOrEmpty()]
	[string]$apiKey,

	[Parameter(Mandatory = $true, HelpMessage = 'Your Automox Organization ID.')]
	[ValidateRange(1, [int]::MaxValue)]
	[int]$orgID
)

#########################################
# MODIFABLE VARIABLES

# Define the time delta for deleting devices disconnected longer than
$ageLimit = 120

# Define device host names to be excluded from the deletion process
$excludedDevices = @(

)

# Toggle for enabling a dry run of the script.
# To proceed with the deletion of non-compliant devices, set this value to $false
$dryRun = $true

#########################################
# PREDEFINED PARAMETERS
$headers = @{ "Authorization" = "Bearer $apiKey" }
$limit = 500
$page = 0
$url = "https://console.automox.com/api/servers?o=$orgID&page=$page&limit=$limit"
$successDelete = [System.Collections.ArrayList]::New()
$failDelete = [System.Collections.ArrayList]::New()

#########################################
# DEFINE VERBOSITY PREFERENCE
# Uncommenting $VerbosePreference will show additional output in your Activity Log.
# This can be used for troubleshooting purposes.
# $VerbosePreference = 'Continue'


#########################################
# BEGIN REMEDIATION

Write-Verbose "Querying Automox Org $orgID for disconnected devices."
Do
{
	$url = "https://console.automox.com/api/servers?o=$orgID&page=$page&limit=$limit"
	$devices = (Invoke-RestMethod -Uri $url -Headers $headers)
	ForEach ($device in $devices)
	{
		# Exclude devices that are in the excluded list from being processed for deletion
        If ($excludedDevices -contains $device.name)
        {
            Write-Verbose "Skipping excluded device: $($device.name)."
            Continue
        }

		# Exclude devices without a disconnect time. This indicates they are still checking in.
        If ($null -eq $device.last_disconnect_time)
		{
			Write-Verbose "Device Name: $($device.name) does not have a valid last disconnect time and was skipped."
			Continue
		}

		# Define the last disconnected timestamp
		$lastDisconnect = [System.DateTime]$device.last_disconnect_time

		# Resolve the time delta
		$delta = [System.TimeSpan] ([System.DateTime]::Now - $lastDisconnect)

		# Evaluate if the device has been disconnected for longer than the allowed range
		If ($delta.Days -ge $ageLimit)
		{
			Write-Verbose "Device Name: $($device.name) has been disconnected for over $($delta.Days) days."

			$device = $device |
				Select-Object @{ Name = "Device Name"; Expression =  { $_.name } },
					@{ Name = "Device ID"; Expression =  { $_.id } },
					@{ Name = "Last Disconnected Time"; Expression =  { $_.last_disconnect_time } },
					@{ Name = "Days Disconnected"; Expression =  { $delta.Days } }

			# Define the delete URI
			$delURI = "https://console.automox.com/api/servers/$($device."Device ID")?o=$orgID"

			# Check if the script is in Dry Run mode
			# If Dry Run is set to $false, proceed with the device deletion process.
			If (-Not $dryRun)
			{
				Try
				{
					# Invoke Automox API to delete the device
					Invoke-WebRequest -UseBasicParsing -Method Delete -Uri $delURI -Headers $headers | Out-Null
					Write-Verbose "Successfully Deleted Server: $($device."Device Name")"
					[void] $successDelete.Add($device)
				}

				Catch
				{
					Write-Verbose "Failed to Delete Server: $($device."Device Name")"
					[void] $failDelete.Add($device)
				}
			}

			# Dry Run mode is enabled.
			Else
			{
				Write-Output "DRY RUN: $($device."Device Name") has been disconnected for over $($delta.Days) days and would be deleted."
			}
		}
	}

	# Iterate through next page
	$page += 1
}

While ($devices.Count -ge $limit)

#########################################
# OUTPUT REMEDIATION RESULTS

# Display the final report for successful deletions
If ($successDelete.Count -gt 0)
{
	Write-Output "Successful Deletions:"
	$successDelete | Format-Table -Property "Device Name", "Device ID", "Last Disconnected Time", "Days Disconnected" -AutoSize
}

# Display the final report for failed deletions
If ($failDelete.Count -gt 0)
{
	Write-Output "Failed Deletions:"
	$failDelete | Format-Table -Property "Device Name", "Device ID", "Last Disconnected Time", "Days Disconnected" -AutoSize
}

# Check if no devices were processed
If ($successDelete.Count -eq 0 -and $failDelete.Count -eq 0)
{
	Write-Output "No devices were processed for deletion."
	Write-Output "No disconnected devices were found that met the desired threshold. Now exiting."
}

Exit 0