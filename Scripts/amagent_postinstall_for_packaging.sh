#!/bin/bash

#================================================================
# HEADER
#================================================================
# SYNOPSIS
#	This script can be repackaged as a postinstall script for
#	the Automox installer to install the Automox agent using
#	endpoint management software like Jamf Pro, Intune, Munki, etc.
#
# DESCRIPTION
#	This enters the Automox access key and loads the launchdaemon
# 	to complete the installation of the Automox agent.
#
# USAGE
#	./amagent_postinstall_for_packaging.sh
#
#================================================================
# IMPLEMENTATION
#	version         amagent_postinstall_for_packaging (www.automox.com) 1.0
#	author          Matt Bauer
#
#================================================================
# HISTORY
#	10/29/2021 : mbauer : Script creation
#
#================================================================
# END_OF_HEADER
#================================================================

accessKey=""
installerDir=$(dirname "$0")
installerName=""

/usr/sbin/installer -dumplog -verbose -pkg "${installerDir}"/"${installerName}" -tgt /

/usr/local/bin/amagent --setkey "${accessKey}"

if [ "$(launchctl list | grep -c automox)" -lt 1 ]; then
    launchctl load /Library/LaunchDaemons/com.automox.agent.plist
fi

exit
