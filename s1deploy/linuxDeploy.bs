#!/bin/bash 

#This script is designed to deploy the Automox Agent to Windows Devices. You will need to add your Automox Agent Access Key to the $key variable in line 6.

#####################USER INPUT#####################
key="your_access_key"
####################################################

curl -A 'ax:ax-agent-deployer/S1 0.1.2 (Linux)' -sS 'https://console.automox.com/downloadInstaller?accesskey=$key' | sudo bash && sleep 5 && sudo service amagent start
