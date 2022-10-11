#!/bin/bash

#this script is designed to deploy the Automox Agent to MacOS Devices. You will need to add your Automox Agent Access Key to the $key variable in line 6.

#####################USER INPUT#####################
key="your_access_key"
####################################################


sudo curl -A 'ax:ax-agent-deployer/S1 0.1.2 (Mac)' -sS 'https://console.automox.com/downloadInstaller?accesskey=$key' | sudo bash
