import datetime
import requests
import argparse
import time
import json
import sys
import csv
import os

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

# Modify device
def ax_device_put(ax_environment, ax_device_id, server_group_id=None, ip_addrs=None, exception=None, tags=None, custom_name=None):
    url = "https://console.automox.com/api/servers/" + str(ax_device_id)
    querystring = {"o":ax_environment['automox-org-id']}
    action = "PUT"
    # Build the update package
    update_data = {}
    if server_group_id:
        update_data['server_group_id'] = server_group_id
    if ip_addrs:
        update_data['ip_addrs'] = ip_addrs
    if exception:
        update_data['exception'] = exception
    if tags:
        update_data['tags'] = tags
    if custom_name:
        update_data['custom_name'] = custom_name
    # Call the API
    return ax_call_api(action, url, ax_environment['automox-api-key'], params=querystring, data=update_data)

# Get groups list
def ax_group_list_get(ax_environment):
    url = "https://console.automox.com/api/servergroups"
    querystring = {"o":ax_environment['automox-org-id']}
    action = "GET"
    # Call the API
    ax_devices_response = ax_call_api_page(action, url, ax_environment['automox-api-key'], params=querystring)
    return ax_devices_response['data']

# Load the CSV file into Dict
def ax_file_load_csv(file_name,file_encoding='utf-8-sig'):
    csv_list = []
    file_name_and_path = os.path.join(os.path.dirname(os.path.realpath(__file__)), file_name)
    with open(file_name_and_path, mode='r',encoding=file_encoding) as csv_file:
        file_reader = csv.DictReader(csv_file)
        for row in file_reader:
            csv_list.append(row)
    return csv_list

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
    'csv_file',
    type=str,
    help='File name (and path, if needed) for the CSV file to sync groups for.')

args = parser.parse_args()
# --End parse command line arguments-- #

# --Main-- #

# Create environment dict & vars
ax_environment = {}
ax_environment['automox-org-id'] = args.ax_org_id
ax_environment['automox-api-key'] = args.ax_api_key

csv_file = args.csv_file

current_datetime = datetime.datetime.now()
print("Current date and time:", current_datetime)

print()
print("Loading the CSV...")
csv_list = ax_file_load_csv(csv_file)

print("Calling the API to get the device list and group list...")
device_list = ax_device_list_get(ax_environment)
group_list = ax_group_list_get(ax_environment)

print("Converitng group list into index for later use...")
group_index = {}
for group in group_list:
    if group['name']:
        group_index[group['name']] = group['id']

print("Matching device changes based on CSV values...")
devices_to_update = []
for csv_device in csv_list:
    found = False
    for device in device_list:
        if device['display_name'] == csv_device['Server']:
            found = True
            updated_device = {}
            updated_device['display_name'] = device['display_name']
            updated_device['id'] = device['id']
            if csv_device['Current Schedule (IST)'] in group_index:
                updated_device['server_group_id'] = group_index[csv_device['Current Schedule (IST)']]
                devices_to_update.append(updated_device)
            else:
                print("Warning - group " + csv_device['Current Schedule (IST)'] + " not found in existing group list!  Skipping device " + updated_device['display_name'])
    if not found:
        print("Warning - device from CSV " + csv_device['Server'] + " not found in Automox!  Skipping device.")

if len(devices_to_update) > 0:
    print("Updating devices using the API...")
    print()
    for updated_device in devices_to_update:
        print("Updating device " + updated_device['display_name'])
        response = ax_device_put(ax_environment, updated_device['id'], server_group_id=updated_device['server_group_id'])

    print("Done!")
else:
    print("Did not find anything to do!")
