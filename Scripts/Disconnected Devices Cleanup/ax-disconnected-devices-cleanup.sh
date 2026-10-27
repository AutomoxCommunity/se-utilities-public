#!/bin/bash

# SYNOPSIS
#   This script uses the Automox API to cleanup stale Automox devices that have been disconnected for longer than X days.
#
#   DISCLAIMER
#   This script will permanently remove devices from your Automox instance!
#   The amagent will need to be re-installed on any devices that are removed as a byproduct of this script run.
#   Please read through the description and implementation instructions carefully so you understand the impact this may have in your environment.
#
#   THIS SCRIPT SHOULD BE RAN LOCALLY ON A DEVICE, AND NOT AS AN AUTOMOX WORKLET.
#
# DESCRIPTION
#   This script queries an Automox organization to find devices that have been disconnected from Automox for longer than a defined number of days.
#   If the device has exceeded this threshold, it is permanently removed from the Automox console.
#   This threshold can be changed by adjusting "ageLimit" parameter in the "REQUIRED USER PARAMETERS" section of the script.
#   Because these removals are irreversible, a "dry run" mode is available to review which devices would be deleted before any actual deletion occurs.
#   This is the default run-mode of the script.
#   An optional "excludedDevices" array can also be configured to exclude specific host names from the device deletion process.
#
#   This script can be ran locally via Bash.
#
#   EXAMPLE:
#       bash ax-disconnected-devices-cleanup.sh
#
# PARAMETERS
#   apiKey (System.String) : Mandatory
#     Your Automox Platform API Key.
#     This key must be created with permissions to read and delete Devices.
#
#   EXAMPLE:
#     apiKey = 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX'
#     https://docs.automox.com/product/Product_Documentation/Settings/Managing_Keys.htm?Highlight=api%20key
#
#   orgID (Integer) : Mandatory
#     Defines your Automox Organization ID.
#     This is the Automox Org that is queried for devices in a disconnected state.
#
#   EXAMPLE:
#     orgID=123456
#     https://docs.automox.com/product/Product_Documentation/Global_Access_Management/Managing_Organizations.htm?Highlight=managing%20orgs
#
#   ageLimit (Integer) : Mandatory
#     Defines the amount of days a device can be in a disconnected state before it is purged from the target Automox Org.
#     This is defaulted to 120 days.
#
#   EXAMPLE:
#     ageLimit=120
#     In this example, devices that have been disconnected for more than 120 days will be deleted.
#
#   excludedDevices (String Array) : Optional
#     Defines a list of device host names to be excluded from the deletion process.
#     This can be a single string or an array of device names.
#     Host names must match exactly as they appear within the Automox Console.
#
#   EXAMPLE:
#     excludedDevices=("DeviceName1" "DeviceName2" "DeviceName3")
#
#   dryRun (Boolean) : Mandatory
#     Determines if the script should run in Dry Run mode.
#     This value is defaulted to true
#     With dryRun enabled, non-compliant devices will be reported on but not deleted.
#
#   EXAMPLE:
#     dryRun=true
#     With dryRun set to true, non-compliant devices WILL NOT be deleted.
#
#   EXAMPLE:
#     dryRun=false
#     With dryRun set to false, non-compliant devices WILL be deleted.
#
# NOTES
#   Additional Activity Log output can be enabled by setting VERBOSE=true.
#
#   PREREQUISITES
#     Automox Platform API key.
#     Automox orgID.
#     jq (JSON processor) must be installed on the system.
#
# HISTORY
#   Name: Manohar N
#   Date: 01/20/2026
#   Version: 1.0.0
#   Release Notes:
#     - Initial Release for macOS/bash.
#
#   Name: Kyle Gregg
#   Date: 03/18/2026
#   Version 1.0.2
#   Release Notes:
#     - Fixed piping issue in inner loop to properly report on Devices removed.
#     - Added helper function to properly display error messages.
#
#   Name: Kyle Gregg
#   Date: 10/20/2026
#   Version: 1.0.3
#   Release Notes:
#     - Modified script for Automox Community release.
#
# LINK
#   https://help.automox.com/hc/en-us/articles/5351996773012-Disconnected-Devices-Cleanup-Using-the-Console-or-PowerShell-or-Python
#   https://console.automox.com/api/docs#console-api/tag/devices
#   https://console.automox.com/api/docs#console-api/tag/devices/DELETE/servers/{deviceID}

#########################################
# REQUIRED USER PARAMETERS

# Define your Automox API Key
apiKey=""

# Define your Automox orgID
orgID=""

# Define the time delta for deleting devices disconnected longer than (in days)
ageLimit=120

# Define device host names to be excluded from the deletion process
excludedDevices=()

# Toggle for enabling a dry run of the script.
# To proceed with the deletion of non-compliant devices, set this value to false
dryRun=true

#########################################
# PREDEFINED PARAMETERS
limit=500
page=0

#########################################
# DEFINE VERBOSITY PREFERENCE
# Set VERBOSE=true to show additional output in your Activity Log.
# This can be used for troubleshooting purposes.
VERBOSE=false

#########################################
# TRACKING ARRAYS
successDelete=()
failDelete=()

#########################################
# HELPER FUNCTIONS

# Provides a function to allow Automox to read the Error Message upon an Exit 1.
function errMessage() {
	echo "$1" >&2
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo "[VERBOSE] $1"
    fi
}

is_excluded() {
    local device_name="$1"
    for excluded in "${excludedDevices[@]}"; do
        if [ "$device_name" = "$excluded" ]; then
            return 0
        fi
    done
    return 1
}

#########################################
# CHECK FOR REQUIRED PARAMETERS

if [ -z "$apiKey" ]; then
    errMessage "ERROR: An Automox API Key is required for this script. Please review the script's description for instructions on implementation. Now exiting."
    exit 87
fi

if [ -z "$orgID" ]; then
    errMessage "ERROR: orgID is required. Please set the orgID parameter."
    exit 87
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    errMessage "ERROR: jq is required but not installed. Please install jq to use this script."
    exit 87
fi

#########################################
# BEGIN REMEDIATION

log_verbose "Querying Automox Org $orgID for disconnected devices."

while true; do
    url="https://console.automox.com/api/servers?o=$orgID&page=$page&limit=$limit"
    
    response=$(curl -s -H "Authorization: Bearer $apiKey" "$url")
    
    if [ $? -ne 0 ]; then
        errMessage "ERROR: Failed to query Automox API."
        exit 87
    fi
    
    device_count=$(echo "$response" | jq 'length')
    
    if [ "$device_count" -eq 0 ]; then
        break
    fi
    
    while read -r device; do
        device_name=$(echo "$device" | jq -r '.name')
        device_id=$(echo "$device" | jq -r '.id')
        last_disconnect=$(echo "$device" | jq -r '.last_disconnect_time')
        
        # Check if device is in excluded list
        if is_excluded "$device_name"; then
            log_verbose "Skipping excluded device: $device_name"
            continue
        fi
        
        # Skip devices without a disconnect time
        if [ "$last_disconnect" = "null" ] || [ -z "$last_disconnect" ]; then
            log_verbose "Device Name: $device_name does not have a valid last disconnect time and was skipped."
            continue
        fi
        
        # Calculate days disconnected
        current_timestamp=$(date +%s)
        disconnect_timestamp=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${last_disconnect:0:19}" +%s 2>/dev/null)
        
        if [ $? -ne 0 ]; then
            log_verbose "Device Name: $device_name has invalid disconnect time format."
            continue
        fi
        
        days_disconnected=$(( (current_timestamp - disconnect_timestamp) / 86400 ))
        
        # Check if device exceeds age limit
        if [ "$days_disconnected" -ge "$ageLimit" ]; then
            log_verbose "Device Name: $device_name has been disconnected for over $days_disconnected days."
            
            # Define the delete URI
            delURI="https://console.automox.com/api/servers/$device_id?o=$orgID"
            
            # Check if the script is in Dry Run mode
            if [ "$dryRun" = false ]; then
                # Attempt to delete the device
                http_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE -H "Authorization: Bearer $apiKey" "$delURI")
                
                if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 204 ]; then
                    log_verbose "Successfully Deleted Server: $device_name"
                    successDelete+=("$device_name|$device_id|$last_disconnect|$days_disconnected")
                else
                    log_verbose "Failed to Delete Server: $device_name (HTTP $http_code)"
                    failDelete+=("$device_name|$device_id|$last_disconnect|$days_disconnected")
                fi
            else
                # Dry Run mode is enabled
                echo "DRY RUN: $device_name has been disconnected for over $days_disconnected days and would be deleted."
            fi
        fi
    done < <(echo "$response" | jq -c '.[]')
    
    # Check if we should continue to next page
    if [ "$device_count" -lt "$limit" ]; then
        break
    fi
    
    page=$((page + 1))
done

#########################################
# OUTPUT REMEDIATION RESULTS

# Display the final report for successful deletions
if [ ${#successDelete[@]} -gt 0 ]; then
    echo ""
    echo "Successful Deletions:"
    echo "------------------------------------------------------------"
    printf "%-30s %-15s %-25s %-20s\n" "Device Name" "Device ID" "Last Disconnected Time" "Days Disconnected"
    echo "------------------------------------------------------------"
    for entry in "${successDelete[@]}"; do
        IFS='|' read -r name id disconnect days <<< "$entry"
        printf "%-30s %-15s %-25s %-20s\n" "$name" "$id" "$disconnect" "$days"
    done
    echo ""
fi

# Display the final report for failed deletions
if [ ${#failDelete[@]} -gt 0 ]; then
    echo ""
    echo "Failed Deletions:"
    echo "------------------------------------------------------------"
    printf "%-30s %-15s %-25s %-20s\n" "Device Name" "Device ID" "Last Disconnected Time" "Days Disconnected"
    echo "------------------------------------------------------------"
    for entry in "${failDelete[@]}"; do
        IFS='|' read -r name id disconnect days <<< "$entry"
        printf "%-30s %-15s %-25s %-20s\n" "$name" "$id" "$disconnect" "$days"
    done
    echo ""
fi

# Check if no devices were processed
if [ ${#successDelete[@]} -eq 0 ] && [ ${#failDelete[@]} -eq 0 ]; then
    echo "No devices were processed for deletion."
    echo "No disconnected devices were found that met the desired threshold. Now exiting."
fi

exit 0
