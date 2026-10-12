#!/bin/bash

#================================================================
# HEADER
#================================================================
# SYNOPSIS
#	This script can be used with endpoint management software like
#	Jamf Pro, Intune, Munki, etc., as a postinstall script for the
#	Automox installer to finish the installation process of the
#	Automox agent.
#
# DESCRIPTION
#	This enters the Automox access key and loads the launchdaemon
# 	to complete the installation of the Automox agent.
#
# USAGE
#	./amagent_postinstall.sh
#
#================================================================
# IMPLEMENTATION
#	version         amagent_postinstall (www.automox.com) 1.0
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

/usr/local/bin/amagent --setkey "${accessKey}"

if [ "$(launchctl list | grep -c automox)" -lt 1 ]; then
    launchctl load /Library/LaunchDaemons/com.automox.agent.plist
fi

exit
