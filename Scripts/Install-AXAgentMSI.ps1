<#

    .SYNOPSIS
        Checks if Automox is installed and the agent is running.
        if the Automox agent is not installed, this script downloads and installs the latest Automox Agent MSI.
        Your organization access key is required to install the agent.
        Additionally, you can optionally set a group path for the agent to be moved to upon installation.

    This script supports multiple nested groups via the GroupPath parameter.

    .DESCRIPTION
        Uses a WebClient object to download the latest Automox Agent MSI and
        install it with silent options and your specified organization access key.

    .PARAMETER AccessKey
        This parameter is required to run.
        Specifies the Automox Organization this device should belong to.
        Can also be referred to as "Organization Key" or
        "Unique User Key". This is a unique identifier for your organization
        and can be found in your Automox Console in these locations:

        Devices -> Add Devices
        Settings -> API

        This must be a valid GUID to allow the script to run

        -AccessKey xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

    .PARAMETER GroupPath
        Specifies the full path to the Automox Server Group to move the device to.
        Supports multiple nested groups. Do NOT include "Default Group" at the beginning.
        Use forward slashes to separate group levels.

        -GroupPath "My Parent Group/Nested Group 1/Nested Group 2/Nested Group 3"

    .PARAMETER GroupName
        (Legacy) Specifies the Automox Server Group to move the device to upon
        joining your Organization. Note that if this isn't a top-level
        Group, then you will also need to specify the ParentGroupName
        as well. For nested groups deeper than one level, use GroupPath instead.

        -GroupName "My Group Name"

    .PARAMETER ParentGroupName
        (Legacy) Specifies the Parent Group of the Server Group specified
        previously. For nested groups deeper than one level, use GroupPath instead.

        -ParentGroupName "My Parent Group Name"

    .PARAMETER VerboseLogging
        Enables detailed logging output for each step of the installation and
        group move process. Outputs success/failure status for both agent
        installation and group assignment.

        -VerboseLogging

    .PARAMETER RollbackOnFailure
        If specified and the group move fails after successful agent installation,
        the script will uninstall the Automox agent and log the rollback action.

        -RollbackOnFailure

    .NOTES
        If you prefer not to specify parameters to this script file, you may enter the values manually in the param section in the Setup region below.

    .HISTORY
        Version: 3.0.0
        Changes:
            - Added GroupPath parameter to support multiple nested groups
            - Added VerboseLogging parameter for detailed operation logging
            - Added RollbackOnFailure parameter to uninstall agent if group move fails
            - Improved error handling in Set-AxServerGroup function
            - Group move failures now return proper error codes instead of silently
            defaulting to Default Group
            - Added validation for group path before attempting move
            - Legacy GroupName and ParentGroupName parameters still supported for
            backward compatibility

        Version: 2.0.3
        Changes:
            - Fixed parameter name mismatch in Set-AxServerGroup function calls
            (-ParentGroup changed to -parentGroupName) that prevented group assignment
            when deploying via GPO with ParentGroupName specified

        Version: 2.0.2
        Changes:
            - Restored 64-bit registry check (RegistryView::Registry64) in CheckForAgent
            - Replaced PowerShell cmdlet 32-bit check with .NET RegistryView::Registry32 to
            reliably query WOW6432Node regardless of execution context
            - Both 64-bit and 32-bit (WOW6432Node) hives are now explicitly checked,
            ensuring detection works if the agent architecture changes in the future

        Version: 2.0.1
        Changes:
            - Updated CheckForAgent function to look in 32-bit registry hive

        Creation Date: May, 2025
        Updated by: Automox Professional Services Team
        Version: 2.0.0
        Changes:
            - Added functionality to restart the amagent service if it is not running
            - Before installing the agent, we will check if console.automox.com can be reached
            - This script will use Start-Transcript to log the installation process

    .EXAMPLE
        Run this script file with at least an AccessKey specified
            Install-AxAgentMsi.ps1 -AccessKey xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

        Using the GroupPath parameter for deeply nested groups
            Install-AxAgentMsi.ps1 -AccessKey xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx -GroupPath "My Parent Group/Nested Group 1/Nested Group 2/Nested Group 3" -VerboseLogging

        With rollback on failure enabled
            Install-AxAgentMsi.ps1 -AccessKey xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx -GroupPath "Production/Servers/Web" -VerboseLogging -RollbackOnFailure

        Legacy: Using GroupName and ParentGroupName (still supported)
            Install-AxAgentMsi.ps1 -AccessKey xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx -GroupName "My Group Name" -ParentGroupName "My Parent Group Name"

    .LINK
        https://www.automox.com

#>

param (
    [ Parameter ( Mandatory = $true ) ] [ ValidateNotNullorEmpty() ] [ String ]$AccessKey,
    [ Parameter ( Mandatory = $false ) ] [ String ] $GroupPath,
    [ Parameter ( Mandatory = $false ) ] [ String ] $GroupName,
    [ Parameter ( Mandatory = $false ) ] [ String ] $ParentGroupName,
    [ Parameter ( Mandatory = $false ) ] [ Switch ] $VerboseLogging,
    [ Parameter ( Mandatory = $false ) ] [ Switch ] $RollbackOnFailure
)

#################### Region start: Setup Variables #################

$installerUrl = "https://console.automox.com/installers/Automox_Installer-latest.msi"
$installerName = "Automox_Installer-latest.msi"
$installerPath = "${env:TEMP}\${installerName}"
$agentPath = "${env:ProgramFiles(x86)}\Automox\amagent.exe"
$logFile = "${env:TEMP}\AutomoxInstallandLaunch.log"

# Set verbose preference based on parameter
if ( $VerboseLogging ) {
    $VerbosePreference = "Continue"
} else {
    $VerbosePreference = "SilentlyContinue"
}

# Track installation and group move status for final summary
$script:AgentInstallSuccess = $false
$script:GroupMoveSuccess = $false
$script:GroupMoveAttempted = $false

#################### Region end: Setup Variables #################

# Start the transcript
Start-Transcript -Path $logFile -Append

# Write a start time to the transcript
$Date = Get-Date
Write-Verbose "Automox Installation Transcript begin: $Date"

#################### Region start: Functions #################

function CheckForAgent {
    $agentInstalled = $false

    if ( [ System.Environment ]::Is64BitOperatingSystem ) {
        $hklm64 = [ Microsoft.Win32.RegistryKey ]::OpenBaseKey( [ Microsoft.Win32.RegistryHive ]::LocalMachine, [ Microsoft.Win32.RegistryView ]::Registry64 )
        $skey64 = $hklm64.OpenSubKey( "Software\Microsoft\Windows\CurrentVersion\Uninstall" )
        $unkeys64 = $skey64.GetSubKeyNames()
        foreach ( $key in $unkeys64 ) {
            if ( $skey64.OpenSubKey( $key ).GetValue( 'DisplayName' ) -like "*Automox Agent*" -and -not ( $skey64.OpenSubKey( $key ).GetValue( "SystemComponent" ) ) ) {
                $agentInstalled = $true
            }
        }
    }

    # Check 32-bit (WOW6432Node) hive on 32/64 bit devices
    $hklm32 = [ Microsoft.Win32.RegistryKey ]::OpenBaseKey( [ Microsoft.Win32.RegistryHive ]::LocalMachine, [ Microsoft.Win32.RegistryView ]::Registry32 )
    $skey32 = $hklm32.OpenSubKey( "Software\Microsoft\Windows\CurrentVersion\Uninstall" )
    if ( $skey32 ) {
        $unkeys32 = $skey32.GetSubKeyNames()
        foreach ( $key in $unkeys32 ) {
            if ( $skey32.OpenSubKey( $key ).GetValue( 'DisplayName' ) -like "*Automox Agent*" -and -not ( $skey32.OpenSubKey( $key ).GetValue( "SystemComponent" ) ) ) {
                $agentInstalled = $true
            }
        }
    }

    return $agentInstalled
}

function DownloadAndInstall-AxAgent {
    param (
        [ Parameter ( Mandatory = $false ) ] [ String ] $installerUrl = "https://console.automox.com/installers/Automox_Installer-latest.msi",
        [ Parameter ( Mandatory = $true ) ] [ String ] $installerPath = "${env:TEMP}\${installerName}",
        [ Parameter ( Mandatory = $true ) ] [ String ] $AccessKey
    )

    # set TLS requirements
    [ Net.ServicePointManager ]::SecurityProtocol = [ Net.SecurityProtocolType ]::Tls -bor [ Net.SecurityProtocolType ]::Tls11 -bor [ Net.SecurityProtocolType ]::Tls12 -bor [ Net.SecurityProtocolType ]::Tls13

    # Step 1: Download the installer
    Write-Output "Downloading started..."
    $downloader = New-Object System.Net.WebClient
    try {
        $downloader.DownloadFile( "$installerUrl", "$installerPath" )
        Write-Output "Download succeeded, attempting install"
    } catch {
        Write-Error "Download failed. Installation stopped. Error: $( $_.Exception.Message )"
        Stop-Transcript
        exit 1
    }

    # Step 2: Install the agent
    Write-Output "Starting installation of $installerPath"
    $process = Start-Process 'msiexec.exe' -ArgumentList "/i `"$installerPath`" /qn /norestart ACCESSKEY=$AccessKey" -Wait -PassThru

    # Return the exit code
    return $process.ExitCode
}

function CheckAutomoxConsole {
    $tcpResult = Test-NetConnection -ComputerName console.automox.com -Port 443
    $tcpReachable = $tcpResult.TcpTestSucceeded
    if ( $tcpReachable ) {
        Write-Verbose "Automox Console is reachable - Script Proceeding"
        return $true
    } else {
        Write-Error "Automox Console is NOT reachable - Script exiting without making changes (Exit Code 1)"
        return $false
    }
}

function Set-AxServerGroup {
    <#
        .SYNOPSIS
        Sets the Automox agent to a specified group path.

        .DESCRIPTION
        Supports both legacy (GroupName/ParentGroupName) and new (GroupPath) parameters.
        Returns $true on success, $false on failure.
    #>
    param (
        [ Parameter ( Mandatory = $false ) ] [ String ] $GroupPath,
        [ Parameter ( Mandatory = $false ) ] [ String ] $GroupName,
        [ Parameter ( Mandatory = $false ) ] [ String ] $parentGroupName
    )

    # Build the full group path
    if ( -not [ string ]::IsNullOrEmpty( $GroupPath ) ) {
        # New GroupPath parameter - supports multiple nested groups
        # Clean up the path: remove leading/trailing slashes and "Default Group" if user included it
        $cleanPath = $GroupPath.Trim().Trim( '/' )
        if ( $cleanPath -like "Default Group/*" ) {
            $cleanPath = $cleanPath.Substring( 14 ) # Remove "Default Group/"
        } elseif ( $cleanPath -eq "Default Group" ) {
            $cleanPath = ""
        }

        if ( [ string ]::IsNullOrEmpty( $cleanPath ) ) {
            $fullGroupPath = "Default Group"
        } else {
            $fullGroupPath = "Default Group/$cleanPath"
        }

        Write-Verbose "Using GroupPath parameter: $fullGroupPath"
    } elseif ( -not [ string ]::IsNullOrEmpty( $ParentGroupName ) -and -not [ string ]::IsNullOrEmpty( $GroupName ) ) {
        # Legacy: Parent and child group specified
        $fullGroupPath = "Default Group/$ParentGroupName/$GroupName"
        Write-Verbose "Using legacy parameters (Parent/Child): $fullGroupPath"
    } elseif ( -not [ string ]::IsNullOrEmpty( $GroupName ) ) {
        # Legacy: Only child group specified (direct child of Default Group)
        $fullGroupPath = "Default Group/$GroupName"
        Write-Verbose "Using legacy parameter (GroupName only): $fullGroupPath"
    } else {
        Write-Warning "No group path specified. Device will remain in Default Group."
        return $true
    }

    Write-Verbose "Attempting to move device to group: $fullGroupPath"

    # Execute the group assignment
    try {
        $argList = "--setgrp `"$fullGroupPath`""
        Write-Verbose "Executing: $agentPath $argList"

        $setgrpProcess = Start-Process -FilePath $agentPath -ArgumentList $argList -Wait -PassThru -NoNewWindow

        if ( $setgrpProcess.ExitCode -ne 0 ) {
            Write-Warning "amagent --setgrp returned exit code: $( $setgrpProcess.ExitCode )"
            Write-Error "Group move command failed. The specified group path may not exist: $fullGroupPath"
            return $false
        }

        Write-Verbose "Group assignment command completed successfully"

        # Deregister to apply the new group
        Write-Verbose "Executing: $agentPath --deregister"
        $deregProcess = Start-Process -FilePath $agentPath -ArgumentList "--deregister" -Wait -PassThru -NoNewWindow

        if ( $deregProcess.ExitCode -ne 0 ) {
            Write-Warning "amagent --deregister returned exit code: $( $deregProcess.ExitCode )"
        }

        # Set the access key
        Write-Verbose "Executing: $agentPath --setkey [REDACTED]"
        $setkeyProcess = Start-Process -FilePath $agentPath -ArgumentList "--setkey $AccessKey" -Wait -PassThru -NoNewWindow

        if ( $setkeyProcess.ExitCode -ne 0 ) {
            Write-Warning "amagent --setkey returned exit code: $( $setkeyProcess.ExitCode )"
        }

        Write-Verbose "Waiting 15 seconds for agent to process changes..."
        Start-Sleep 15

        # Restart the agent service to complete registration with group config
        Write-Verbose "Restarting amagent service..."
        Stop-Service -Name "amagent" -Force -PassThru -ErrorAction Stop
        Start-Sleep 15
        Start-Service -Name "amagent" -PassThru -ErrorAction Stop

        Write-Verbose "Group move completed successfully"
        return $true
    } catch {
        Write-Error "Error during group move operation: $( $_.Exception.Message )"
        return $false
    }
}

function CleanUp-AxAgent {
    <#
    .SYNOPSIS
    Uninstalls the Automox agent (used for rollback on group move failure).
    Based on the CleanUp-AxAgent.ps1 script methodology.
    #>
    Write-Verbose "Initiating agent rollback/uninstall..."

    try {
        # Determine install path based on OS architecture
        $OS64Arch = [ Environment ]::Is64BitProcess
        if ( $OS64Arch ) {
            $rollbackInstallPath = "${env:ProgramFiles(x86)}\Automox"
        } else {
            $rollbackInstallPath = "${env:ProgramFiles}\Automox"
        }
        $logPath = "C:\ProgramData\amagent"

        # Step 1: Uninstall via MSI using registry lookup (preferred method)
        $uninstReg = @( 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall' )
        $appName = 'Automox Agent'
        $installed = @( Get-ChildItem $uninstReg -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { ( $_.DisplayName -match $appName ) } )

        if ( $installed ) {
            Write-Verbose "ROLLBACK: Found Automox Agent installation. Uninstalling via MSI..."
            $process = Start-Process msiexec.exe -ArgumentList "/x $( $installed.PSChildName ) /qn REBOOT=ReallySuppress" -Wait -PassThru
            Write-Verbose "ROLLBACK: MSI uninstall completed with Exit Code: $( $process.ExitCode )"
        } else {
            Write-Warning "ROLLBACK: No MSI installation found in registry. Proceeding with cleanup steps."
        }

        # Step 2: Stop amagent process if running
        $agentProcess = Get-Process amagent -ErrorAction SilentlyContinue
        if ( $null -ne $agentProcess ) {
            Write-Verbose "ROLLBACK: Stopping Automox agent process"
            Stop-Process $agentProcess -Force -ErrorAction SilentlyContinue
        }

        # Step 3: Remove amagent service
        $svcExists = Get-WmiObject -Class Win32_Service -Filter "Name='amagent'"
        if ( $null -ne $svcExists ) {
            Write-Verbose "ROLLBACK: Removing Automox agent service"
            $svcExists | Remove-WmiObject
        }

        # Step 4: Stop remotecontrold process if running
        $rcProcess = Get-Process remotecontrold -ErrorAction SilentlyContinue
        if ( $null -ne $rcProcess ) {
            Write-Verbose "ROLLBACK: Stopping remote control process"
            Stop-Process $rcProcess -Force -ErrorAction SilentlyContinue
        }

        # Step 5: Remove remotecontrold service
        $rcSvcExists = Get-WmiObject -Class Win32_Service -Filter "Name='remotecontrold'"
        if ( $null -ne $rcSvcExists ) {
            Write-Verbose "ROLLBACK: Removing Automox remote control service"
            $rcSvcExists | Remove-WmiObject
        }

        # Step 6: Stop amagent-watchdog process if running (introduced in agent 2.3.34)
        $watchdogProcess = Get-Process amagent-watchdog -ErrorAction SilentlyContinue
        if ( $null -ne $watchdogProcess ) {
            Write-Verbose "ROLLBACK: Stopping Automox Agent Watchdog process"
            Stop-Process $watchdogProcess -Force -ErrorAction SilentlyContinue
        }

        # Step 7: Remove watchdog service (guard on binary path to avoid removing non-Automox services)
        $watchdogSvc = Get-WmiObject -Class Win32_Service -Filter "Name='watchdog'" | Where-Object { $_.PathName -match 'amagent-watchdog' }
        if ( $null -ne $watchdogSvc ) {
            Write-Verbose "ROLLBACK: Removing Automox Agent Watchdog service"
            $watchdogSvc | Remove-WmiObject
        }

        # Step 8: Clean up msiexec processes and remove data directories
        Get-Process msiexe[c] -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

        if ( Test-Path $logPath ) {
            Write-Verbose "ROLLBACK: Removing $logPath"
            Remove-Item -Path $logPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        if ( Test-Path $rollbackInstallPath ) {
            Write-Verbose "ROLLBACK: Removing $rollbackInstallPath"
            # Account for removal of exec#### folders that may give access denied errors
            Get-ChildItem -Path $rollbackInstallPath -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.PSIsContainer -eq $true -and ( Get-ChildItem -Path $_.FullName ) -eq $null } |
                Remove-Item -ErrorAction SilentlyContinue
            Remove-Item -Path $rollbackInstallPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Output "ROLLBACK: Automox agent uninstalled due to group move failure."
        return $true
    } catch {
        Write-Error "ROLLBACK: Error during uninstall: $( $_.Exception.Message )"
        return $false
    }
}

function Write-InstallationSummary {
    <#
        .SYNOPSIS
        Outputs the final installation summary based on operation results.
    #>
    param (
        [ Parameter ( Mandatory = $true ) ] [ bool ] $AgentSuccess,
        [ Parameter ( Mandatory = $true ) ] [ bool ] $GroupMoveAttempted,
        [ Parameter ( Mandatory = $true ) ] [ bool ] $GroupMoveSuccess
    )

    Write-Output ""
    Write-Output "============================================"
    Write-Output "INSTALLATION SUMMARY"
    Write-Output "============================================"

    if ( $AgentSuccess -and $GroupMoveAttempted -and $GroupMoveSuccess ) {
        Write-Output "Agent installed: SUCCESS, Group move: SUCCESS"
    } elseif ( $AgentSuccess -and $GroupMoveAttempted -and -not $GroupMoveSuccess ) {
        Write-Output "Agent installed: SUCCESS, Group move: FAILED"
    } elseif ( $AgentSuccess -and -not $GroupMoveAttempted ) {
        Write-Output "Agent installed: SUCCESS, Group move: NOT ATTEMPTED (no group specified)"
    } elseif ( -not $AgentSuccess ) {
        Write-Output "Agent installed: FAILED"
    }

    Write-Output "============================================"
    Write-Output ""
}

#################### Region End: Functions #################

##################### Main Script Start #####################

# Validate parameter combinations
if ( -not [ string ]::IsNullOrEmpty( $GroupPath ) -and ( -not [ string ]::IsNullOrEmpty( $GroupName ) -or -not [ string ]::IsNullOrEmpty( $ParentGroupName ) ) ) {
    Write-Warning "Both GroupPath and legacy GroupName/ParentGroupName parameters specified. GroupPath will take precedence."
}

# Determine if a group move is requested
$groupMoveRequested = -not [ string ]::IsNullOrEmpty( $GroupPath ) -or -not [ string ]::IsNullOrEmpty( $GroupName )

if ( $VerboseLogging ) {
    Write-Output "Verbose logging enabled"
    if ( $groupMoveRequested ) {
        if ( -not [ string ]::IsNullOrEmpty( $GroupPath ) ) {
            Write-Output "Target group path: $GroupPath"
        } else {
            $targetPath = if ( $ParentGroupName ) { "$ParentGroupName/$GroupName" } else { $GroupName }
            Write-Output "Target group path: $targetPath"
        }
    }
    if ( $RollbackOnFailure ) {
        Write-Output "Rollback on failure: ENABLED"
    }
}

### Check if the Automox Agent is installed ###
Write-Verbose "Checking if amagent is installed"
$agentInstalled = CheckForAgent

if ( $agentInstalled ) {
    Write-Verbose "Automox Agent is installed. Checking that amagent service is running..."
    $script:AgentInstallSuccess = $true
} else {
    Write-Output "Automox Agent is not installed. Proceeding with download and installation..."
    # Check if the Automox Console is reachable
    if ( -not ( CheckAutomoxConsole ) ) {
        Write-Error "Automox Console is not reachable. Exiting script without making changes."
        Write-InstallationSummary -AgentSuccess $false -GroupMoveAttempted $false -GroupMoveSuccess $false
        Stop-Transcript
        exit 1
    }
    $exitCode = DownloadAndInstall-AxAgent -installerUrl $installerUrl -installerPath $installerPath -AccessKey $AccessKey
    Write-Output "Installation completed with Exit Code $exitCode"
}


### Check if the Automox Agent Service is running ###
### If the service fails to start, we will run our installer again ###
$service = Get-Service -Name amagent -ErrorAction SilentlyContinue

if ( $service.Status -eq "Running" -and $agentInstalled ) {
    Write-Output "Agent Service is installed and Running."
    $script:AgentInstallSuccess = $true

    # Check if we need to perform a group move for an already-installed agent
    if ( $groupMoveRequested ) {
        Write-Verbose "Agent already installed. Attempting group move..."
        $script:GroupMoveAttempted = $true

        if ( -not [ string ]::IsNullOrEmpty( $GroupPath ) ) {
            $script:GroupMoveSuccess = Set-AxServerGroup -GroupPath $GroupPath
        } elseif ( -not [ string ]::IsNullOrEmpty( $ParentGroupName ) ) {
            $script:GroupMoveSuccess = Set-AxServerGroup -GroupName $GroupName -parentGroupName $ParentGroupName
        } else {
            $script:GroupMoveSuccess = Set-AxServerGroup -GroupName $GroupName
        }

        if ( -not $script:GroupMoveSuccess ) {
            Write-Error "Group move failed for already-installed agent."
            Write-InstallationSummary -AgentSuccess $true -GroupMoveAttempted $true -GroupMoveSuccess $false
            Stop-Transcript
            exit 1
        }
    }

    Write-InstallationSummary -AgentSuccess $true -GroupMoveAttempted $script:GroupMoveAttempted -GroupMoveSuccess $script:GroupMoveSuccess
    Write-Output "Script Completed Successfully... Exiting"
    Stop-Transcript
    exit 0
} elseif ( ( $null -ne $agentInstalled ) -and ( $service.Status -ne "Running" ) ) {
    Write-Output "amagent service is installed but not Running"
    # Attempt to start the Service. Exit 0 for success, if it fails we will attempt a reinstall of the agent
    try {
        Write-Verbose "Attempting to start amagent service"
        Start-Service -Name amagent -ErrorAction Stop
        $script:AgentInstallSuccess = $true
    } catch {
        Write-Error "Service failed to start. Attempting to restart the service"
        Write-InstallationSummary -AgentSuccess $false -GroupMoveAttempted $false -GroupMoveSuccess $false
        Stop-Transcript
        exit 1
    }
}


### Here is where the exit code for the MSI is evaluated ###
### Check if $exitCode is valid (not null, empty, or whitespace)
### If an error is encountered, we will exit the script without setting groups ###
if ( -not [ String ]::IsNullOrEmpty( $exitCode ) -and -not [ String ]::IsNullOrWhiteSpace( $exitCode ) ) {
    Switch ( $exitCode ) {
        { ( $_ -in @( '0', '1641', '3010' ) ) } {
            Write-Output "Download and installation process completed successfully"
            $script:AgentInstallSuccess = $true

            # Handle group move if requested
            if ( $groupMoveRequested ) {
                $script:GroupMoveAttempted = $true

                # Determine group path and attempt move
                if ( -not [ string ]::IsNullOrEmpty( $GroupPath ) ) {
                    Write-Output "Moving Device to Group Path: $GroupPath"
                    $script:GroupMoveSuccess = Set-AxServerGroup -GroupPath $GroupPath
                } elseif ( -not [ string ]::IsNullOrEmpty( $ParentGroupName ) -and -not [ string ]::IsNullOrEmpty( $GroupName ) ) {
                    Write-Output "Moving Device to Group: $GroupName under Parent Group: $ParentGroupName"
                    $script:GroupMoveSuccess = Set-AxServerGroup -GroupName $GroupName -parentGroupName $ParentGroupName
                } elseif ( -not [ string ]::IsNullOrEmpty( $GroupName ) ) {
                    Write-Output "Moving Device to Group: $GroupName"
                    $script:GroupMoveSuccess = Set-AxServerGroup -GroupName $GroupName
                }

                # Handle group move failure
                if ( -not $script:GroupMoveSuccess ) {
                    Write-Error "Group move failed. The specified group path may not exist in the Automox Console."

                    if ( $RollbackOnFailure ) {
                        Write-Output "RollbackOnFailure is enabled. Initiating agent uninstall..."
                        $rollbackSuccess = CleanUp-AxAgent
                        Write-InstallationSummary -AgentSuccess $false -GroupMoveAttempted $true -GroupMoveSuccess $false
                        Stop-Transcript
                        exit 1
                    } else {
                        Write-Warning "Agent installed but group move failed. Device may be in Default Group."
                        Write-Warning "Use -RollbackOnFailure to automatically uninstall the agent when group move fails."
                        Write-InstallationSummary -AgentSuccess $true -GroupMoveAttempted $true -GroupMoveSuccess $false
                        Stop-Transcript
                        exit 1
                    }
                }

                Write-InstallationSummary -AgentSuccess $true -GroupMoveAttempted $true -GroupMoveSuccess $true
                Write-Output "Installation Script has finished successfully. Exit Code 0"
                Stop-Transcript
                exit 0
            } else {
                Write-Output "No Group was specified. Device will remain in Default Group"
                Write-InstallationSummary -AgentSuccess $true -GroupMoveAttempted $false -GroupMoveSuccess $false
                Write-Output "Installation Script has finished successfully. Exit Code 0"
                Stop-Transcript
                exit 0
            }
        }

        Default {
            Write-Error "Installation failed with exit code: $exitCode"
            Write-InstallationSummary -AgentSuccess $false -GroupMoveAttempted $false -GroupMoveSuccess $false
            Stop-Transcript
            exit $exitCode
        }
    }
} else {
    Write-Output "Installation was not required. Script Exiting without errors"
    Write-InstallationSummary -AgentSuccess $true -GroupMoveAttempted $false -GroupMoveSuccess $false
    Stop-Transcript
    exit 0
}

##################### Main Script End #####################
