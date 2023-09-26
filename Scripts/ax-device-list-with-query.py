### Example of getting a device list with certain filtering.  Also gives the opiton of listing out only the device names using the -names_only switch.

import requests
import argparse
import time
import json
import sys

# --Function Block--#

# Exit handler (Error)
def ax_exit_error(error_code, error_message=None, system_message=None):
    print(error_code)
    if error_message is not None:
        print(error_message)
    if system_message is not None:
        print(system_message)
    sys.exit(1)

# Main API Call Function
def ax_call_api(action, api_url, ax_api_key, data=None, params=None, try_count=0, max_retries=2):
    retry_statuses = [429, 500, 502, 503, 504]
    retry_wait_timer = 5
    headers = {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + ax_api_key}

    # Make the API Call
    response = requests.request(action, api_url, params=params, headers=headers, data=json.dumps(data))

    # Check for an error to retry, re-auth, or fail
    if response.status_code in retry_statuses:
        try_count = try_count + 1
        if try_count <= max_retries:
            time.sleep(retry_wait_timer)
            return ax_call_api(action=action, api_url=api_url, ax_api_key=ax_api_key, data=data, params=params,
                               try_count=try_count, max_retries=max_retries)
        else:
            if not response:
                print(response.json())
            response.raise_for_status()
    else:
        if not response:
                print(response.json())
        response.raise_for_status()

    # Check for valid response and catch if blank or unexpected
    api_response_package = {}
    api_response_package['statusCode'] = response.status_code
    try:
        api_response_package['data'] = response.json()
    except ValueError:
        if response.text == '':
            api_response_package['data'] = None
        else:
            ax_exit_error(501, 'The server returned an unexpected server response.')
    return api_response_package

# Page wrapper for API Call
def ax_call_api_page(action, api_url, ax_api_key, data=None, params={}, max_retries=2):
    # Validate (or set) Params defaults
    if not params:
        params = {}
    if 'limit' not in params:
        params['limit'] = "500"
    if 'page' not in params:
        params['page'] = "0"
    limit_int = int(params['limit'])
    page_int = int(params['page'])

    full_data_list = []
    # Loop through pages, if needed
    while True:
        api_response_package = ax_call_api(action, api_url, ax_api_key, data=data, params=params, max_retries=max_retries)
        if api_response_package['data']:
            full_data_list.extend(api_response_package['data'])
            if len(api_response_package['data']) < limit_int:
                api_response_package['data'] = full_data_list
                return api_response_package
            page_int = page_int + 1
            params['page'] = str(page_int)
        else:
            return api_response_package

# Get Devices list filtered
def ax_device_list_get_filtered(ax_environment, groupId=None, PS_VERSION=None, pending=None, patchStatus=None, policyId=None, 
                                exception=None, managed=None, filters_is_compatible=None, sortColumns=None, sortDir=None):
    url = "https://console.automox.com/api/servers"
    querystring = {"o":ax_environment['automox-org-id']}
    if groupId:
        querystring['groupId'] = groupId
    if PS_VERSION:
        querystring['PS_VERSION'] = PS_VERSION
    if pending:
        querystring['pending'] = pending
    if patchStatus:
        querystring['patchStatus'] = patchStatus
    if policyId:
        querystring['policyId'] = policyId
    if exception:
        querystring['exception'] = exception
    if managed:
        querystring['managed'] = managed
    if filters_is_compatible:
        querystring['filters[is_compatible]'] = filters_is_compatible
    if sortColumns:
        querystring['sortColumns[]'] = sortColumns
    if sortDir:
        querystring['sortDir'] = sortDir
    action = "GET"
    # Call the API
    ax_devices_response = ax_call_api_page(action, url, ax_environment['automox-api-key'], params=querystring)
    return ax_devices_response['data']


# --Execution Block-- #
# --Parse command line arguments-- #
parser = argparse.ArgumentParser()

parser.add_argument(
    'ax_org_id',
    type=str,
    help='Automox Org ID.')

parser.add_argument(
    'ax_api_key',
    type=str,
    help='Automox API Key.')

parser.add_argument(
    '-groupId',
    type=int,
    help='(Optional) Filter based on membership to a specific Server Group ID')

parser.add_argument(
    '-PS_VERSION',
    type=int,
    help='(Future) Ignore for now.')

parser.add_argument(
    '-pending',
    type=int,
    help='(Optional) Filter based on status of pending patches (1 or 0)')

parser.add_argument(
    '-patchStatus',
    action='store_true',
    help="(Optional-Flag) Filter based on presence of ANY available patches that aren't already installed.")

parser.add_argument(
    '-policyId',
    type=int,
    help='(Optional) Filter based on association to a given Policy ID')

parser.add_argument(
    '-exception',
    type=int,
    help='(Optional) Filter based on the exception property to exclude the device from reports. Device is still monitored when excluded from reports and statistics.')

parser.add_argument(
    '-managed',
    type=int,
    help='(Future) Ignore for now.')

parser.add_argument(
    '-filters_is_compatible',
    type=int,
    help='(Optional) Filter on compatible devices: 0 = Everything.  1=Filter only compatible devices')

parser.add_argument(
    '-sortColumns',
    type=str,
    help='(Optional) The column you want to sort by.')

parser.add_argument(
    '-sortDir',
    type=str,
    help='(Optional) Sort direction (asc or desc)')

parser.add_argument(
    '-names_only',
    action='store_true',
    help='(Optional-Flag) Only print out the device names as a text list')

args = parser.parse_args()
# --End parse command line arguments-- #

# --Main-- #

# Create environment dict & vars
ax_environment = {}
ax_environment['automox-org-id'] = args.ax_org_id
ax_environment['automox-api-key'] = args.ax_api_key

# Fix pass in variables
"""if args.filters_is_compatible:
    filters_is_compatible = "true"
else:
    filters_is_compatible = None"""
if args.patchStatus:
    patchStatus = "missing"
else:
    patchStatus = None


print("Calling the API to get the device list...")
device_list = ax_device_list_get_filtered(ax_environment, groupId=args.groupId, PS_VERSION=args.PS_VERSION, pending=args.pending, patchStatus=patchStatus,
                                            policyId=args.policyId, exception=args.exception, managed=args.managed, filters_is_compatible=args.filters_is_compatible,
                                            sortColumns=args.sortColumns, sortDir=args.sortDir)

if args.names_only:
    print()
    print("Device Names only flag detected.  Device name list:")
    for device in device_list:
        print(device['display_name'])
    print()
    print("Total devices listed: " + str(len(device_list)))
else:
    print()
    print("Names only flag not detected.  JSON list:")
    print()
    print(json.dumps(device_list))
