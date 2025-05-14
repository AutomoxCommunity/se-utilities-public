<#
.SYNOPSIS
  Checks if Automox is installed and the agent is running.
  if the Automox agent is not installed, this script downloads and installs the latest Automox Agent MSI.
  Your organization access key is required to install the agent.
  Additionally, you can optionally set a group and parent group for the agent to be moved to upon installation.

  Please note that only one parent group and one child group can be specified.

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

.PARAMETER GroupName
  Specifies the Automox Server Group to move the device to upon
  joining your Organization. Note that if this isn't a top-level
  Group, then you will also need to specify the ParentGroupName
  as well

  -GroupName "My Group Name"

  NOTE: By default this script will only support 1 parent group and 1 child group.

.PARAMETER ParentGroupName
  Specifies the Parent Group of the Server Group specified
  previously.

  -ParentGroupName "My Parent Group Name"

  NOTE: By default this script will only support 1 parent group and 1 child group.

.NOTES
  If you prefer not to specify parameters to this script file,
  you may enter the values manually in the param section in the
  Setup region below.

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

  Optionally include a Group and Parent Group Name as needed
    Install-AxAgentMsi.ps1 -AccessKey xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx -GroupName "My Group Name" -ParentGroupName "My Parent Group Name"

.LINK
https://www.automox.com
#>

param (
    [Parameter(Mandatory = $true)][ValidateNotNullorEmpty()][String]$AccessKey,
    [Parameter(Mandatory = $false)][String]$GroupName,
    [Parameter(Mandatory = $false)][String]$ParentGroupName
)

#################### Region start: Setup Variables #################

$installerUrl = "https://console.automox.com/installers/Automox_Installer-latest.msi"
$installerName = "Automox_Installer-latest.msi"
$installerPath = "${env:TEMP}\${installerName}"
$agentPath = "${env:ProgramFiles(x86)}\Automox\amagent.exe"
$logFile = "${env:TEMP}\AutomoxInstallandLaunch.log"
$VerbosePreference = "Continue"

#################### Region end: Setup Variables #################

# Start the transcript
Start-Transcript -Path $logFile -Append

# Write a start time to the transcript
$Date = Get-Date
Write-Verbose "Automox Installation Transcript begin: $Date"

#################### Region start: Functions #################

function CheckForAgent
{

    $agentInstalled = $false

    if([System.Environment]::Is64BitOperatingSystem)
    {
        $hklm64 = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
        $skey64 = $hklm64.OpenSubKey("Software\Microsoft\Windows\CurrentVersion\Uninstall")
        $unkeys64 = $skey64.GetSubKeyNames()
        foreach($key in $unkeys64)
        {
            if($skey64.OpenSubKey($key).getvalue('DisplayName') -like "*Automox Agent*" -and !($skey64.OpenSubKey($key).getvalue("SystemComponent")))
            {
                $agentInstalled = $true
            }
        }
    }

    # Check 32bit hive on 32/64 bit devices
    $skey32 = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    foreach($key in Get-ChildItem $skey32 -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object {($_.DisplayName -like "*Automox Agent*" -and !($_.SystemComponent))})
    {
        $agentInstalled = $true
    }

    return $agentInstalled

}

function DownloadAndInstall-AxAgent 
{
    param (
        [Parameter(Mandatory = $false)][String]$installerUrl="https://console.automox.com/installers/Automox_Installer-latest.msi",
        [Parameter(Mandatory = $true)][String]$installerPath="${env:TEMP}\${installerName}",
        [Parameter(Mandatory = $true)][String]$AccessKey
    )

    # Step 1: Download the installer
    Write-Output "Downloading started..."
    $downloader = New-Object System.Net.WebClient
    try 
    {
        $downloader.DownloadFile("$installerUrl", "$installerPath")
        Write-Output "Download succeeded, attempting install"
    } catch 
    {
        Write-Error "Download failed. Installation stopped`n Exit Code = 1"
        Stop-Transcript
        exit 1
    }

    # Step 2: Install the agent
    Write-Output "Starting installation of $installerPath"
    $process = Start-Process 'msiexec.exe' -ArgumentList "/i `"$installerPath`" /qn /norestart ACCESSKEY=$AccessKey" -Wait -PassThru
    Write-Output "Installation completed with Exit Code $($process.ExitCode)"

    # Return the exit code
    return $process.ExitCode
}

function CheckAutomoxConsole 
{
    $tcpResult = Test-NetConnection -ComputerName console.automox.com -Port 443
    $tcpReachable = $tcpResult.TcpTestSucceeded
    if ($tcpReachable) {
        Write-Verbose "Automox Console is reachable - Script Proceeding"
        return $true
    } else {
        Write-Error "Automox Console is NOT reachable - Script exiting without making changes (Exit Code 1)"
        return $false
    }
}

function Set-AxServerGroup
{
    param (
        [Parameter(Mandatory = $true)][String]$GroupName,
        [Parameter(Mandatory = $false)][String]$parentGroupName
    )
    if ($ParentGroupName)
    {
        $argList = "--setgrp `"Default Group/$ParentGroupName/$GroupName`""
    }
    else
    {
        $argList = "--setgrp `"Default Group/$GroupName`""
    }
    Start-Process -FilePath $agentPath -ArgumentList "$argList" -Wait
    Start-Process -FilePath $agentPath -ArgumentList "--deregister"
}

#################### Region End: Functions #################

##################### Main Script Start #####################

### Check if the Automox Agent is installed ###
Write-Verbose "Checking if amagent is installed" 
$agentInstalled = CheckForAgent

if ($agentInstalled) 
{
    Write-Verbose "Automox Agent is installed. Checking that amagent service is running..."
}
else
{
    Write-Output "Automox Agent is not installed. Proceeding with download and installation..."
    # Check if the Automox Console is reachable
    if (-not (CheckAutomoxConsole))
    {
        Write-Error "Automox Console is not reachable. Exiting script without making changes."
        Stop-Transcript
        Exit 1
    }
    $exitCode = DownloadAndInstall-AxAgent -installerUrl $installerUrl -installerPath $installerPath -AccessKey $AccessKey
}


### Check if the Automox Agent Service is running ###
### If the service fails to start, we will run our installer again ###
$service = Get-Service -Name amagent -ErrorAction SilentlyContinue

if ($service.Status -eq "Running" -and $agentInstalled)
{
    Write-Output "Agent Service is installed and Running."
    Write-Output "Script Completed Successfully... Exiting"
    Stop-Transcript
    Exit 0
}
elseif (($null -ne $agentInstalled) -and ($service.Status -ne "Running"))
{
    Write-Output "amagent service is installed but not Running"
        # Attempt to start the Service. Exit 0 for success, if it fails we will attempt a reinstall of the agent
        try
        {
            Write-Verbose "Attempting to start amagent service"
            Start-Service -Name amagent -ErrorAction Stop
        }
        catch
        {
            Write-Error "Service failed to start. Attempting to restart the service"
            Stop-Transcript
            Exit 1
        }
}


### Here is where the exit code for the MSI is evaluated ###
### If an error is encountered, we will exit the script without setting groups ###
Switch (([String]::IsNullOrEmpty($exitCode) -eq $False) -and ([String]::IsNullOrWhiteSpace($exitCode) -eq $False))
{
    {($_ -eq $True)}
    {
        Switch ($exitCode)
        {
            {($_ -in @('0', '1641', '3010'))}
            {
                Write-Output "Download and installation process completed successfully" 
                # If successful installation (based on exit code), then proceed to set the group.
                if (-not [string]::IsNullOrEmpty($ParentGroupName) -and -not [string]::IsNullOrEmpty($GroupName))
                {
                    Write-Output "Moving Device to Group: $GroupName under Parent Group: $ParentGroupName" 
                    Set-AxServerGroup -GroupName $GroupName -ParentGroup $ParentGroupName
                    Write-Output "Installation Script has finished successfully. Exit Code 0" 
                    Stop-Transcript
                    Exit 0
                }
                elseif (-not [string]::IsNullOrEmpty($GroupName))
                {
                    Write-Output "Moving Device to Group: $GroupName" 
                    Set-AxServerGroup -GroupName $GroupName
                    Write-Output "Installation Script has finished successfully. Exit Code 0" 
                    Stop-Transcript
                    Exit 0
                }
                else
                {
                    Write-Output "No Group was specified. Device will remain in Default Group" 
                    Write-Output "Installation Script has finished successfully. Exit Code 0" 
                    Stop-Transcript
                    Exit 0
                }
            }

            Default
            {
                if ([string]::IsNullOrEmpty($GroupName) -and [string]::IsNullOrEmpty($ParentGroupName))
                {
                    Write-Output "No Group or Parent Group specified. Device will remain in Default Group." 
                    Write-Output "Installation Script has finished successfully. Exit Code 0" 
                    Stop-Transcript
                    Exit 0
                }
                else
                {
                    Write-Output "The Automox Agent was installed, but failed to set the desired group."
                    Write-Error "Please check that your specified group or parent group exist in the Automox Console."
                    Stop-Transcript
                    exit $exitCode
                }
            }
        }
    }

    Default
    {
        Write-Output "Installation was not required. Script Exiting without errors"
        Stop-Transcript
        exit 0
    }
}

##################### Main Script End #####################
