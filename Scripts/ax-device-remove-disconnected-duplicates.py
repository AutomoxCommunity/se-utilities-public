import datetime
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

# Get Devices list(with details)
def ax_device_list_get(ax_environment):
    url = "https://console.automox.com/api/servers"
    querystring = {"o":ax_environment['automox-org-id']}
    action = "GET"
    # Call the API
    ax_devices_response = ax_call_api_page(action, url, ax_environment['automox-api-key'], params=querystring)
    return ax_devices_response['data']

# Delete Device
def ax_device_delete(ax_environment, ax_device_id):
    url = "https://console.automox.com/api/servers/" + str(ax_device_id)
    querystring = {"o":ax_environment['automox-org-id']}
    action = "DELETE"
    # Call the API
    return ax_call_api(action, url, ax_environment['automox-api-key'], params=querystring)


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
    '-mintuesDisconnectFor',
    type=int,
    default=10,
    help='(Optional) - Time in minutes the client should be disconnected for, at minimum.')

args = parser.parse_args()
# --End parse command line arguments-- #

# --Main-- #

# Create environment dict
ax_environment = {}
ax_environment['automox-org-id'] = args.ax_org_id
ax_environment['automox-api-key'] = args.ax_api_key

current_datetime = datetime.datetime.now()
print("Current date and time:", current_datetime)

response_data = ax_device_list_get(ax_environment)

# Create a temp working list
working_names = []

# Create a list of the names from the dicts
for device in response_data:
    working_names.append(device["display_name"])

# Now Find dup names
duplicate_names = set([x for x in working_names if working_names.count(x) > 1])

# Convert the set into a list
duplicate_names = list(duplicate_names)

# Get delta minutes calc
cutoff_time = datetime.datetime.utcnow() - datetime.timedelta(minutes=args.mintuesDisconnectFor)

# Create list to be deleted
devices_to_remove = []

# Find any devices that are a duplicate that are disconnected for greater than X minues
for device in response_data:
    if device['last_disconnect_time'] is not None:
        if device['display_name'] in duplicate_names:
            last_disconnect_time = datetime.datetime.strptime(device['last_disconnect_time'].split("+")[0], "%Y-%m-%dT%H:%M:%S")

            # If device has been disconnected before the cutoff date, include it in the list
            if last_disconnect_time < cutoff_time:
                print("Device " + str(device['name']) + " with Device ID " + str(device['id']) + " will be deleted.")
                devices_to_remove.append(device)

# Remove the devices
if len(devices_to_remove) > 0:
    for device in devices_to_remove:
        print("removing device from Automox console: "+ device['display_name'])
        response = ax_device_delete(ax_environment, device['id'])
        print(response)
else:
    print("Nothing to remove!")