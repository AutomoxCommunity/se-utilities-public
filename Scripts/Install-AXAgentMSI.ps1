<#
    .SYNOPSIS
        Downloads and installs the latest Automox Agent with optional group assignment.

    .DESCRIPTION
        This script downloads and installs the latest Automox Agent if it is not already installed.
        It uses a WebClient object to download the latest Automox Agent MSI and install it with silent options and your specified organization access key.
        Upon completion of the installation, the script will validate the amagent service is started and optionally move the device to a specified group path or group name.
        Your organization access key is required to install the agent.    
        This script supports multiple nested groups via the GroupPath parameter.

    .PARAMETER AccessKey
        This parameter is required to run.
        Specifies the Automox Organization this device should belong to.
        This is a unique identifier for your organization and can be found in your Automox Console in these locations:

        Devices -> Add Devices
        Settings -> Secrets & Keys -> Agent Access Key

        This must be a valid GUID to allow the script to run.
            EXAMPLE: -AccessKey xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

    .PARAMETER GroupPath
        Specifies the full path to the Automox Server Group to move the device to.
        Supports multiple nested groups. Do NOT include "Default Group" at the beginning.
        Use forward slashes to separate group levels:

            EXAMPLE: -GroupPath "My Parent Group/Nested Group 1/Nested Group 2/Nested Group 3"

    .PARAMETER GroupName
        (Legacy) Specifies the Automox Server Group to move the device to upon joining your Organization.
        Note that if this isn't a top-level Group, then you will also need to specify the ParentGroupName
        as well. Do NOT include "Default Group" at the beginning.

            EXAMPLE: -GroupName "My Group Name"

        Note: For nested groups deeper than one level, use $GroupPath instead.

    .PARAMETER ParentGroupName
        Specifies the Parent Group of the Server Group specified previously.

            EXAMPLE: -ParentGroupName "My Parent Group Name"

    .PARAMETER VerboseLogging
        Enables detailed logging output for each step of the installation and group move process.
        Outputs success/failure status for both agent installation and group assignment.

            EXAMPLE: -VerboseLogging

    .PARAMETER RollbackOnFailure
        If specified and the group move fails after successful agent installation, the script will uninstall the Automox agent and log the rollback action.

            EXAMPLE: -RollbackOnFailure

    .PARAMETER CleanupInstaller
        If specified, the downloaded MSI installer will be removed from the temp directory after installation completes (regardless of success or failure).

            EXAMPLE: -CleanupInstaller

    .INPUTS
        None. This script does not accept pipeline input.

    .OUTPUTS
        System.Int32. Returns exit code 0 on success, 1 on failure.

    .EXAMPLE
        Run this script file with at least an AccessKey specified
            Install-AxAgentMsi.ps1 -AccessKey xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

        Using the GroupPath parameter for deeply nested groups
            Install-AxAgentMsi.ps1 -AccessKey xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx -GroupPath "My Parent Group/Nested Group 1/Nested Group 2/Nested Group 3" -VerboseLogging

        With rollback on failure enabled
            Install-AxAgentMsi.ps1 -AccessKey xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx -GroupPath "Production/Servers/Web" -VerboseLogging -RollbackOnFailure

        With installer cleanup enabled
            Install-AxAgentMsi.ps1 -AccessKey xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx -GroupPath "Production/Servers" -CleanupInstaller

        Legacy: Using Legacy GroupName and ParentGroupName
            Install-AxAgentMsi.ps1 -AccessKey xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx -GroupName "My Group Name" -ParentGroupName "My Parent Group Name"

    .NOTES
        If you prefer not to specify parameters to this script file, you may hardcode the values manually in the param section on lines 137-160.
        Any mandatory parameters should be set to $false for the script to run without prompting for input.

    .HISTORY
        Date: 8/4/2026
        Version: 3.0.0
        Release Notes:
            - Added GroupPath parameter to support multiple nested groups
            - Added VerboseLogging parameter for detailed operation logging
            - Added RollbackOnFailure parameter to uninstall agent if group move fails
            - Improved error handling in Set-AxServerGroup function
            - Group move failures now return proper error codes instead of silently deploying to the Default Group
            - Added validation for group path before attempting move
            - Legacy GroupName and ParentGroupName parameters still supported for backward compatibility
            - Added downloadFile function with TLS 1.2 enforcement and error handling
            - Added file size validation for downloaded installer
            - Added CleanupInstaller parameter to optionally remove MSI after installation
            - Added GUID validation for AccessKey parameter
            - Replaced deprecated Get-WmiObject with Get-CimInstance
            - Implemented default timeout agent installation Start-Process call

        Date: 6/10/2026
        Version: 2.0.3
        Release Notes:
            - Fixed parameter name mismatch in Set-AxServerGroup function calls
              (-ParentGroup changed to -parentGroupName) that prevented group assignment
              when deploying via GPO with ParentGroupName specified

        Date: 3/10/2026
        Version: 2.0.2
        Release Notes:
            - Restored 64-bit registry check (RegistryView::Registry64) in checkForAxAgent
            - Replaced PowerShell cmdlet 32-bit check with .NET RegistryView::Registry32 to
              reliably query WOW6432Node regardless of execution context
            - Both 64-bit and 32-bit (WOW6432Node) hives are now explicitly checked,
              ensuring detection works if the agent architecture changes in the future

        Date: 2/19/2026
        Version: 2.0.1
        Release Notes:
            - Updated checkForAxAgent function to look in 32-bit registry hive

        Date: 5/19/2026
        Version: 2.0.0
        Release Notes:
            - Added functionality to restart the amagent service if it is not running
            - Before installing the agent, we will check if console.automox.com can be reached
            - This script will use Start-Transcript to log the installation process

    .LINK
        https://docs.automox.com/product/Product_Documentation/Agents/Agent_Installation/Bulk_Agent_Deployment/Deploying_the_Automox_Agent_in_Bulk.htm#DeployingonWindowsUsingPowerShell

#>

param (
    [ Parameter( Mandatory = $true ) ]
    [ ValidateNotNullOrEmpty() ]
    [ ValidatePattern( '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' ) ]
    [ String ]$AccessKey,

    [ Parameter( Mandatory = $false ) ]
    [ String ]$GroupPath,

    [ Parameter( Mandatory = $false ) ]
    [ String ]$GroupName,

    [ Parameter( Mandatory = $false ) ]
    [ String ]$ParentGroupName,

    [ Parameter( Mandatory = $false ) ]
    [ Switch ]$VerboseLogging,

    [ Parameter( Mandatory = $false ) ]
    [ Switch ]$RollbackOnFailure,

    [ Parameter( Mandatory = $false ) ]
    [ Switch ]$CleanupInstaller
)

#region Constants
$script:INSTALLER_URL = "https://console.automox.com/installers/Automox_Installer-latest.msi"
$script:INSTALLER_FILENAME = "Automox_Installer-latest.msi"
$script:DEFAULT_GROUP_NAME = "Default Group"
$script:DEFAULT_GROUP_PREFIX = "Default Group/"
$script:SERVICE_RESTART_DELAY_SECONDS = 15
$script:INSTALLATION_TIMEOUT_SECONDS = 300
# Defining MSI exit codes: 0 = Success, 1641 = Reboot initiated, 3010 = Reboot required
$script:MSI_SUCCESS_EXIT_CODES = @( 0, 1641, 3010 )
# Defining minimum expected installer size in bytes (approximately 30 MB - allows for variance)
$script:MINIMUM_INSTALLER_SIZE_BYTES = 30 * 1024 * 1024
#endregion Constants

#region Setup Variables
$installerPath = Join-Path -Path $env:TEMP -ChildPath $script:INSTALLER_FILENAME
$agentPath = "${env:ProgramFiles(x86)}\Automox\amagent.exe"
$logFile = Join-Path -Path $env:TEMP -ChildPath "AutomoxInstallandLaunch.log"

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
#endregion Setup Variables

# Start the transcript
Start-Transcript -Path $logFile -Append

# Write a start time to the transcript
$Date = Get-Date
Write-Verbose "Automox Installation Transcript begin: $Date"

#region Functions

function checkForAxAgent {
    <#
        .SYNOPSIS
        Checks if the Automox Agent is installed by querying the registry.

        .DESCRIPTION
        Queries both 64-bit and 32-bit registry hives to detect Automox Agent installation.
        Properly disposes of registry key handles to prevent resource leaks.

        .OUTPUTS
        System.Boolean. Returns $true if agent is installed, $false otherwise.
    #>
    $agentInstalled = $false
    $uninstallPath = "Software\Microsoft\Windows\CurrentVersion\Uninstall"

    try {
        # Check 64-bit registry hive
        if ( [ System.Environment ]::Is64BitOperatingSystem ) {
            $hklm64 = $null
            $skey64 = $null
            try {
                $hklm64 = [ Microsoft.Win32.RegistryKey ]::OpenBaseKey(
                    [ Microsoft.Win32.RegistryHive ]::LocalMachine,
                    [ Microsoft.Win32.RegistryView ]::Registry64
                )
                $skey64 = $hklm64.OpenSubKey( $uninstallPath )
                if ( $skey64 ) {
                    foreach ( $keyName in $skey64.GetSubKeyNames() ) {
                        $subKey = $null
                        try {
                            $subKey = $skey64.OpenSubKey( $keyName )
                            if ( $subKey ) {
                                $displayName = $subKey.GetValue( 'DisplayName' )
                                $systemComponent = $subKey.GetValue( 'SystemComponent' )
                                if ( $displayName -like "*Automox Agent*" -and -not $systemComponent ) {
                                    $agentInstalled = $true
                                    break
                                }
                            }
                        } finally {
                            if ( $subKey ) { $subKey.Dispose() }
                        }
                    }
                }
            } finally {
                if ( $skey64 ) { $skey64.Dispose() }
                if ( $hklm64 ) { $hklm64.Dispose() }
            }
        }

        # Check 32-bit (WOW6432Node) hive on 32/64 bit devices
        if ( -not $agentInstalled ) {
            $hklm32 = $null
            $skey32 = $null
            try {
                $hklm32 = [ Microsoft.Win32.RegistryKey ]::OpenBaseKey(
                    [ Microsoft.Win32.RegistryHive ]::LocalMachine,
                    [ Microsoft.Win32.RegistryView ]::Registry32
                )
                $skey32 = $hklm32.OpenSubKey( $uninstallPath )
                if ( $skey32 ) {
                    foreach ( $keyName in $skey32.GetSubKeyNames() ) {
                        $subKey = $null
                        try {
                            $subKey = $skey32.OpenSubKey( $keyName )
                            if ( $subKey ) {
                                $displayName = $subKey.GetValue( 'DisplayName' )
                                $systemComponent = $subKey.GetValue( 'SystemComponent' )
                                if ( $displayName -like "*Automox Agent*" -and -not $systemComponent ) {
                                    $agentInstalled = $true
                                    break
                                }
                            }
                        } finally {
                            if ( $subKey ) { $subKey.Dispose() }
                        }
                    }
                }
            } finally {
                if ( $skey32 ) { $skey32.Dispose() }
                if ( $hklm32 ) { $hklm32.Dispose() }
            }
        }
    } catch {
        Write-Warning "Error checking registry for Automox Agent: $( $_.Exception.Message )"
    }

    return $agentInstalled

}

function downloadFile {
    <#
        .SYNOPSIS
        Downloads a file from a URL to a specified output path.

        .DESCRIPTION
        Helper function to download a file using WebClient with proper TLS configuration
        and error handling. Disposes of WebClient after use.

        .PARAMETER Url
        The URL to download from.

        .PARAMETER Output
        The local file path to save the downloaded file.

        .OUTPUTS
        System.Boolean. Returns $true on success, $false on failure.
    #>
    param (
        [ Parameter( Position = 0, Mandatory = $true ) ]
        [ String ]$Url,

        [ Parameter( Position = 1, Mandatory = $true ) ]
        [ String ]$Output
    )

    $webClient = $null
    try {
        # Set TLS requirements
        [ Net.ServicePointManager ]::SecurityProtocol = [ Net.SecurityProtocolType ]::Tls12 -bor [ Net.SecurityProtocolType ]::Tls13

        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile( $Url, $Output )
        return $true
    } catch [ System.Net.WebException ] {
        $response = $_.Exception.Response

        if ( $_.Exception.Message -like '*Could not create SSL/TLS secure channel*' ) {
            Write-Error ( "Download failed due to a TLS issue. Ensure that TLS 1.2 is enabled. `r`nError: " + $_.Exception.Message )
        } elseif ( $null -ne $_.Exception.InnerException ) {
            Write-Error ( "Download failed. Ensure that the URL is correct. `r`nError: " + $_.Exception.InnerException.Message )
        } elseif ( $response -is [ System.Net.HttpWebResponse ] ) {
            if ( $response.StatusCode -eq [ System.Net.HttpStatusCode ]::BadRequest -and $response.StatusDescription -match 'SSL/TLS' ) {
                Write-Error ( "Download failed due to a TLS issue. Ensure that TLS 1.2 is enabled. `r`nError: " + $_.Exception.InnerException.Message )
            } else {
                Write-Error ( "Download failed with an unknown error. `r`nError: " + $_.Exception.InnerException.Message )
            }
        } else {
            Write-Error ( "Download failed. `r`nError: " + $_.Exception.Message )
        }
        return $false
    } catch [ System.ArgumentNullException ] {
        Write-Error ( "Download failed. Ensure that the path exists. `r`nError: " + $_.Exception.Message )
        return $false
    } catch {
        Write-Error ( "Download failed with an unexpected error. `r`nError: " + $_.Exception.Message )
        return $false
    } finally {
        if ( $webClient ) {
            $webClient.Dispose()
        }
    }
}

function installAxAgent {
    <#
        .SYNOPSIS
        Installs the Automox Agent using msiexec.

        .DESCRIPTION
        Executes the MSI installer with the specified access key and waits for completion.
        Handles timeout scenarios and validates exit codes.

        .PARAMETER InstallerPath
        Full path to the MSI installer file.

        .PARAMETER AccessKey
        The Automox organization access key.

        .PARAMETER InstallArgs
        Additional arguments to pass to msiexec. Defaults to silent install with no restart.

        .PARAMETER TimeoutSeconds
        Maximum time to wait for installation. Defaults to script constant.

        .OUTPUTS
        System.Int32. Returns the MSI exit code.
    #>
    param (
        [ Parameter( Mandatory = $true ) ]
        [ String ]$InstallerPath,

        [ Parameter( Mandatory = $true ) ]
        [ String ]$AccessKey,

        [ Parameter( Mandatory = $false ) ]
        [ String[] ]$InstallArgs = @( '/qn', '/norestart' ),

        [ Parameter( Mandatory = $false ) ]
        [ Int ]$TimeoutSeconds = $script:INSTALLATION_TIMEOUT_SECONDS
    )

    # Build the full argument list
    $fullArgs = @( "/i", "`"$InstallerPath`"" ) + $InstallArgs + @( "ACCESSKEY=$AccessKey" )

    Write-Verbose "Starting installation of $InstallerPath"
    Write-Verbose "msiexec arguments: $( $fullArgs -join ' ' )"

    try {
        $startProcessParams = @{
            FilePath     = 'msiexec.exe'
            ArgumentList = $fullArgs
            PassThru     = $true
        }
        $proc = Start-Process @startProcessParams
        $proc | Wait-Process -Timeout $TimeoutSeconds -ErrorAction SilentlyContinue

        if ( -not $proc.HasExited ) {
            Write-Warning "Timed out waiting for installer to finish after $TimeoutSeconds seconds. Attempting to terminate."
            while ( -not $proc.HasExited ) {
                $proc | Stop-Process -Force
                Start-Sleep -Seconds 1
            }
            throw "Installation timed out after $TimeoutSeconds seconds."
        } elseif ( $proc.ExitCode -notin $script:MSI_SUCCESS_EXIT_CODES ) {
            throw "Installation failed with exit code $( $proc.ExitCode )."
        } else {
            Write-Verbose "Installation completed successfully with exit code $( $proc.ExitCode )"
            return $proc.ExitCode
        }
    } catch {
        Write-Error "Installation failed. Error: $( $_.Exception.Message )"
        return 1
    }
}

function checkAutomoxConsole {
    <#
        .SYNOPSIS
        Checks if the Automox Console is reachable.

        .DESCRIPTION
        Performs a TCP connection test to console.automox.com on port 443
        to verify network connectivity before attempting installation.

        .OUTPUTS
        System.Boolean. Returns $true if console is reachable, $false otherwise.
    #>
    $testNetConnectionParams = @{
        ComputerName = 'console.automox.com'
        Port         = 443
    }
    $tcpResult = Test-NetConnection @testNetConnectionParams

    if ( $tcpResult.TcpTestSucceeded ) {
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
        Configures the agent with the specified group and access key, then restarts the service.

        .PARAMETER GroupPath
        Full path to the target group (new method).

        .PARAMETER GroupName
        Name of the target group (legacy method).

        .PARAMETER ParentGroupName
        Name of the parent group (legacy method).

        .PARAMETER AccessKey
        The Automox organization access key.

        .PARAMETER AgentPath
        Path to the amagent.exe executable.

        .OUTPUTS
        System.Boolean. Returns $true on success, $false on failure.
    #>
    param (
        [ Parameter( Mandatory = $false ) ]
        [ String ]$GroupPath,

        [ Parameter( Mandatory = $false ) ]
        [ String ]$GroupName,

        [ Parameter( Mandatory = $false ) ]
        [ String ]$ParentGroupName,

        [ Parameter( Mandatory = $true ) ]
        [ String ]$AccessKey,

        [ Parameter( Mandatory = $true ) ]
        [ String ]$AgentPath
    )

    # Build the full group path
    if ( -not [ String ]::IsNullOrEmpty( $GroupPath ) ) {
        # New GroupPath parameter - supports multiple nested groups
        # Clean up the path: remove leading/trailing slashes and "Default Group"
        $cleanPath = $GroupPath.Trim().Trim( '/' )
        if ( $cleanPath.StartsWith( $script:DEFAULT_GROUP_PREFIX, [ StringComparison ]::OrdinalIgnoreCase ) ) {
            $cleanPath = $cleanPath.Substring( $script:DEFAULT_GROUP_PREFIX.Length )
        } elseif ( $cleanPath -eq $script:DEFAULT_GROUP_NAME ) {
            $cleanPath = ""
        }

        if ( [ String ]::IsNullOrEmpty( $cleanPath ) ) {
            $fullGroupPath = $script:DEFAULT_GROUP_NAME
        } else {
            $fullGroupPath = "$( $script:DEFAULT_GROUP_NAME )/$cleanPath"
        }

        Write-Verbose "Using GroupPath parameter: $fullGroupPath"
    } elseif ( -not [ String ]::IsNullOrEmpty( $ParentGroupName ) -and -not [ String ]::IsNullOrEmpty( $GroupName ) ) {
        # Legacy: Parent and child group specified
        $fullGroupPath = "$( $script:DEFAULT_GROUP_NAME )/$ParentGroupName/$GroupName"
        Write-Verbose "Using legacy parameters (Parent/Child): $fullGroupPath"
    } elseif ( -not [ String ]::IsNullOrEmpty( $GroupName ) ) {
        # Legacy: Only child group specified (direct child of Default Group)
        $fullGroupPath = "$( $script:DEFAULT_GROUP_NAME )/$GroupName"
        Write-Verbose "Using legacy parameter (GroupName only): $fullGroupPath"
    } else {
        Write-Warning "No group path specified. Device will remain in Default Group."
        return $true
    }

    Write-Verbose "Attempting to move device to group: $fullGroupPath"

    # Execute the group assignment
    try {
        $argList = "--setgrp `"$fullGroupPath`""
        Write-Verbose "Executing: $AgentPath $argList"

        $startProcessParams = @{
            FilePath     = $AgentPath
            ArgumentList = $argList
            Wait         = $true
            PassThru     = $true
            NoNewWindow  = $true
        }
        $setgrpProcess = Start-Process @startProcessParams

        if ( $setgrpProcess.ExitCode -ne 0 ) {
            Write-Warning "amagent --setgrp returned exit code: $( $setgrpProcess.ExitCode )"
            Write-Error "Group move command failed. The specified group path may not exist: $fullGroupPath"
            return $false
        }

        Write-Verbose "Group assignment command completed successfully"

        # Deregister to apply the new group
        Write-Verbose "Executing: $AgentPath --deregister"
        $startProcessParams.ArgumentList = "--deregister"
        $deregProcess = Start-Process @startProcessParams

        if ( $deregProcess.ExitCode -ne 0 ) {
            Write-Warning "amagent --deregister returned exit code: $( $deregProcess.ExitCode )"
        }

        # Set the access key
        Write-Verbose "Executing: $AgentPath --setkey [REDACTED]"
        $startProcessParams.ArgumentList = "--setkey $AccessKey"
        $setkeyProcess = Start-Process @startProcessParams

        if ( $setkeyProcess.ExitCode -ne 0 ) {
            Write-Warning "amagent --setkey returned exit code: $( $setkeyProcess.ExitCode )"
        }

        Write-Verbose "Waiting $script:SERVICE_RESTART_DELAY_SECONDS seconds for agent to process changes..."
        Start-Sleep -Seconds $script:SERVICE_RESTART_DELAY_SECONDS

        # Restart the agent service to complete registration with group config
        Write-Verbose "Restarting amagent service..."
        Stop-Service -Name "amagent" -Force -ErrorAction Stop
        Start-Sleep -Seconds $script:SERVICE_RESTART_DELAY_SECONDS
        Start-Service -Name "amagent" -ErrorAction Stop

        Write-Verbose "Group move completed successfully"
        return $true
    } catch {
        Write-Error "Error during group move operation: $( $_.Exception.Message )"
        return $false
    }
}

function cleanUpAxAgent {
    <#
        .SYNOPSIS
        Uninstalls the Automox agent (used for rollback on group move failure).

        .DESCRIPTION
        Performs a complete cleanup of the Automox agent including MSI uninstall,
        service removal, process termination, and file cleanup.

        .OUTPUTS
        System.Boolean. Returns $true on success, $false on failure.
    #>

    Write-Verbose "Initiating Automox agent rollback/uninstall..."

    try {
        # Determine install path based on OS architecture
        if ( [ Environment ]::Is64BitProcess ) {
            $rollbackInstallPath = "${env:ProgramFiles(x86)}\Automox"
        } else {
            $rollbackInstallPath = "${env:ProgramFiles}\Automox"
        }
        $logPath = Join-Path -Path $env:ProgramData -ChildPath "amagent"

        # Step 1: Uninstall via MSI using registry lookup (preferred method)
        $uninstReg = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        )
        $appName = 'Automox Agent'
        $installed = @( Get-ChildItem $uninstReg -ErrorAction SilentlyContinue |
            Get-ItemProperty |
            Where-Object { $_.DisplayName -match $appName } )

        if ( $installed ) {
            Write-Verbose "ROLLBACK: Found Automox Agent installation. Uninstalling via MSI..."
            $startProcessParams = @{
                FilePath     = 'msiexec.exe'
                ArgumentList = "/x $( $installed.PSChildName ) /qn REBOOT=ReallySuppress"
                Wait         = $true
                PassThru     = $true
            }
            $process = Start-Process @startProcessParams
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
        $svcExists = Get-CimInstance -ClassName Win32_Service -Filter "Name='amagent'" -ErrorAction SilentlyContinue
        if ( $null -ne $svcExists ) {
            Write-Verbose "ROLLBACK: Removing Automox agent service"
            $svcExists | Remove-CimInstance
        }

        # Step 4: Stop remotecontrold process if running
        $rcProcess = Get-Process remotecontrold -ErrorAction SilentlyContinue
        if ( $null -ne $rcProcess ) {
            Write-Verbose "ROLLBACK: Stopping remote control process"
            Stop-Process $rcProcess -Force -ErrorAction SilentlyContinue
        }

        # Step 5: Remove remotecontrold service
        $rcSvcExists = Get-CimInstance -ClassName Win32_Service -Filter "Name='remotecontrold'" -ErrorAction SilentlyContinue
        if ( $null -ne $rcSvcExists ) {
            Write-Verbose "ROLLBACK: Removing Automox remote control service"
            $rcSvcExists | Remove-CimInstance
        }

        # Step 6: Stop amagent-watchdog process if running (introduced in agent 2.3.34)
        $watchdogProcess = Get-Process amagent-watchdog -ErrorAction SilentlyContinue
        if ( $null -ne $watchdogProcess ) {
            Write-Verbose "ROLLBACK: Stopping Automox Agent Watchdog process"
            Stop-Process $watchdogProcess -Force -ErrorAction SilentlyContinue
        }

        # Step 7: Remove watchdog service (guard on binary path to avoid removing non-Automox services)
        $watchdogSvc = Get-CimInstance -ClassName Win32_Service -Filter "Name='watchdog'" -ErrorAction SilentlyContinue |
            Where-Object { $_.PathName -match 'amagent-watchdog' }
        if ( $null -ne $watchdogSvc ) {
            Write-Verbose "ROLLBACK: Removing Automox Agent Watchdog service"
            $watchdogSvc | Remove-CimInstance
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
                Where-Object { $_.PSIsContainer -eq $true -and $null -eq ( Get-ChildItem -Path $_.FullName ) } |
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

        .DESCRIPTION
        Displays a formatted summary of the installation and group move operations.

        .PARAMETER AgentSuccess
        Whether the agent installation succeeded.

        .PARAMETER GroupMoveAttempted
        Whether a group move was attempted.

        .PARAMETER GroupMoveSuccess
        Whether the group move succeeded.
    #>
    param (
        [ Parameter( Mandatory = $true ) ]
        [ Bool ]$AgentSuccess,

        [ Parameter( Mandatory = $true ) ]
        [ Bool ]$GroupMoveAttempted,

        [ Parameter( Mandatory = $true ) ]
        [ Bool ]$GroupMoveSuccess
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

function Remove-InstallerFile {
    <#
        .SYNOPSIS
        Removes the downloaded MSI installer file.

        .DESCRIPTION
        Cleanup function to remove the installer from the temp directory.

        .PARAMETER InstallerPath
        Full path to the installer file.
    #>
    param (
        [ Parameter( Mandatory = $true ) ]
        [ String ]$InstallerPath
    )

    if ( Test-Path $InstallerPath ) {
        try {
            Remove-Item -Path $InstallerPath -Force -ErrorAction Stop
            Write-Verbose "Installer file removed: $InstallerPath"
        } catch {
            Write-Warning "Failed to remove installer file: $( $_.Exception.Message )"
        }
    }
}

#endregion Functions

#region Main Script

# Validate parameter combinations
if ( -not [ String ]::IsNullOrEmpty( $GroupPath ) -and ( -not [ String ]::IsNullOrEmpty( $GroupName ) -or -not [ String ]::IsNullOrEmpty( $ParentGroupName ) ) ) {
    Write-Warning "Both GroupPath and legacy GroupName/ParentGroupName parameters specified. GroupPath will take precedence."
}

# Determine if a group move is requested
$groupMoveRequested = -not [ String ]::IsNullOrEmpty( $GroupPath ) -or -not [ String ]::IsNullOrEmpty( $GroupName )

if ( $VerboseLogging ) {
    Write-Output "Verbose logging enabled"
    if ( $groupMoveRequested ) {
        if ( -not [ String ]::IsNullOrEmpty( $GroupPath ) ) {
            Write-Output "Target group path: $GroupPath"
        } else {
            $targetPath = if ( $ParentGroupName ) { "$ParentGroupName/$GroupName" } else { $GroupName }
            Write-Output "Target group path: $targetPath"
        }
    }
    if ( $RollbackOnFailure ) {
        Write-Output "Rollback on failure: ENABLED"
    }
    if ( $CleanupInstaller ) {
        Write-Output "Cleanup installer: ENABLED"
    }
}

# Check if the Automox Agent is installed
Write-Verbose "Checking if amagent is installed"
$agentInstalled = checkForAxAgent

if ( $agentInstalled ) {
    Write-Output "Automox Agent is already installed."
    Write-InstallationSummary -AgentSuccess $true -GroupMoveAttempted $false -GroupMoveSuccess $false
    Write-Output "Automox Agent is already installed. Device is not applicable for this script run. `nNow exiting..."
    Stop-Transcript
    exit 0
}

# Automox Agent not installed - proceed with installation
Write-Output "Automox Agent is not installed. Proceeding with download and installation..."

# Check if the Automox Console is reachable
Write-Verbose "Checking if Automox Console is reachable"
if ( -not ( checkAutomoxConsole ) ) {
    Write-Error "Automox Console is not reachable. Exiting script without making changes."
    Write-InstallationSummary -AgentSuccess $false -GroupMoveAttempted $false -GroupMoveSuccess $false
    Stop-Transcript
    exit 1
}

# Download the installer
Write-Verbose "Downloading Automox installer from $( $script:INSTALLER_URL )"
$downloadSuccess = downloadFile -Url $script:INSTALLER_URL -Output $installerPath

# Verify download succeeded
if ( -not $downloadSuccess -or -not ( Test-Path $installerPath ) ) {
    Write-Error "Download failed. Installer not found at $installerPath"
    Write-InstallationSummary -AgentSuccess $false -GroupMoveAttempted $false -GroupMoveSuccess $false
    if ( $CleanupInstaller ) { Remove-InstallerFile -InstallerPath $installerPath }
    Stop-Transcript
    exit 1
}

# Validate file size to ensure complete download
$installerFile = Get-Item -Path $installerPath
$installerSizeMB = [ Math ]::Round( $installerFile.Length / 1MB, 2 )
Write-Verbose "Downloaded installer size: $installerSizeMB MB"

if ( $installerFile.Length -lt $script:MINIMUM_INSTALLER_SIZE_BYTES ) {
    Write-Error "Downloaded installer appears incomplete. Expected at least $( [ Math ]::Round( $script:MINIMUM_INSTALLER_SIZE_BYTES / 1MB, 0 ) ) MB, got $installerSizeMB MB"
    Write-InstallationSummary -AgentSuccess $false -GroupMoveAttempted $false -GroupMoveSuccess $false
    if ( $CleanupInstaller ) { Remove-InstallerFile -InstallerPath $installerPath }
    Stop-Transcript
    exit 1
}

Write-Verbose "Download completed successfully"

# Install the agent
$exitCode = installAxAgent -InstallerPath $installerPath -AccessKey $AccessKey
Write-Output "Installation completed with Exit Code $exitCode"

### Evaluate MSI exit code ###
if ( $null -ne $exitCode ) {
    switch ( $exitCode ) {
        { $_ -in $script:MSI_SUCCESS_EXIT_CODES } {
            Write-Output "Download and installation process completed successfully"
            $script:AgentInstallSuccess = $true

            # Verify the amagent service is running
            $service = Get-Service -Name amagent -ErrorAction SilentlyContinue
            if ( $service.Status -ne "Running" ) {
                Write-Verbose "amagent service is not running. Attempting to start..."
                try {
                    Start-Service -Name amagent -ErrorAction Stop
                    Write-Verbose "amagent service started successfully"
                } catch {
                    Write-Error "Failed to start amagent service: $( $_.Exception.Message )"
                    Write-InstallationSummary -AgentSuccess $false -GroupMoveAttempted $false -GroupMoveSuccess $false
                    if ( $CleanupInstaller ) { Remove-InstallerFile -InstallerPath $installerPath }
                    Stop-Transcript
                    exit 1
                }
            }

            # Handle group move if requested
            if ( $groupMoveRequested ) {
                $script:GroupMoveAttempted = $true

                # Common parameters for Set-AxServerGroup
                $setGroupParams = @{
                    AccessKey = $AccessKey
                    AgentPath = $agentPath
                }

                # Determine group path and attempt move
                if ( -not [ String ]::IsNullOrEmpty( $GroupPath ) ) {
                    Write-Output "Moving Device to Group Path: $GroupPath"
                    $setGroupParams.GroupPath = $GroupPath
                    $script:GroupMoveSuccess = Set-AxServerGroup @setGroupParams
                } elseif ( -not [ String ]::IsNullOrEmpty( $ParentGroupName ) -and -not [ String ]::IsNullOrEmpty( $GroupName ) ) {
                    Write-Output "Moving Device to Group: $GroupName under Parent Group: $ParentGroupName"
                    $setGroupParams.GroupName = $GroupName
                    $setGroupParams.ParentGroupName = $ParentGroupName
                    $script:GroupMoveSuccess = Set-AxServerGroup @setGroupParams
                } elseif ( -not [ String ]::IsNullOrEmpty( $GroupName ) ) {
                    Write-Output "Moving Device to Group: $GroupName"
                    $setGroupParams.GroupName = $GroupName
                    $script:GroupMoveSuccess = Set-AxServerGroup @setGroupParams
                }

                # Handle group move failure
                if ( -not $script:GroupMoveSuccess ) {
                    Write-Error "Group move failed. The specified group path may not exist in the Automox Console."

                    if ( $RollbackOnFailure ) {
                        Write-Output "RollbackOnFailure is enabled. Initiating agent uninstall..."
                        $null = cleanUpAxAgent
                        Write-InstallationSummary -AgentSuccess $false -GroupMoveAttempted $true -GroupMoveSuccess $false
                        if ( $CleanupInstaller ) { Remove-InstallerFile -InstallerPath $installerPath }
                        Stop-Transcript
                        exit 1
                    } else {
                        Write-Warning "Automox Agent installed but group move failed. Device may be in Default Group."
                        Write-Warning "Use -RollbackOnFailure to automatically uninstall the agent when group move fails."
                        Write-InstallationSummary -AgentSuccess $true -GroupMoveAttempted $true -GroupMoveSuccess $false
                        if ( $CleanupInstaller ) { Remove-InstallerFile -InstallerPath $installerPath }
                        Stop-Transcript
                        exit 1
                    }
                }

                Write-InstallationSummary -AgentSuccess $true -GroupMoveAttempted $true -GroupMoveSuccess $true
                Write-Output "Installation Script has finished successfully. Exit Code 0"
                if ( $CleanupInstaller ) { Remove-InstallerFile -InstallerPath $installerPath }
                Stop-Transcript
                exit 0
            } else {
                Write-Output "No Group was specified. Device will remain in Default Group"
                Write-InstallationSummary -AgentSuccess $true -GroupMoveAttempted $false -GroupMoveSuccess $false
                Write-Output "Installation Script has finished successfully. Exit Code 0"
                if ( $CleanupInstaller ) { Remove-InstallerFile -InstallerPath $installerPath }
                Stop-Transcript
                exit 0
            }
        }

        default {
            Write-Error "Installation failed with exit code: $exitCode"
            Write-InstallationSummary -AgentSuccess $false -GroupMoveAttempted $false -GroupMoveSuccess $false
            if ( $CleanupInstaller ) { Remove-InstallerFile -InstallerPath $installerPath }
            Stop-Transcript
            exit $exitCode
        }
    }
}

#endregion Main Script