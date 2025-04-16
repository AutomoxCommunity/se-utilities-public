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

  Creation Date: March, 2025
  Updated by: Automox Professional Services Team
  Version: 2.0.0
  Changes:
    - Added functionality to restart the amagent service if it is not running
    - Before installing the agent, we will check if console.automox.com can be reached
    - Added functionality to rotate the log file if it exceeds 1MB

.EXAMPLE
  Run this script file with at least an AccessKey specified
    Install-AxAgentMsi.ps1 -AccessKey xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

  Optionally include a Group and Parent Group Name as needed
    Install-AxAgentMsi.ps1 -AccessKey xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx -GroupName "My Group Name" -ParentGroupName "My Parent Group Name"

.LINK
https://www.automox.com
#>

param (
    [Parameter(Mandatory = $true)][String]$AccessKey,
    [Parameter(Mandatory = $false)][String]$GroupName,
    [Parameter(Mandatory = $false)][String]$ParentGroupName
)

# Validate that only one ParentGroupName and one GroupName are provided
if ($GroupName -is [Array] -or $ParentGroupName -is [Array]) {
    Write-Host "Error: Only one parent group and one child group can be provided." -ForegroundColor Red
    Exit 1
}

#################### Region start: Setup Variables #################

$installerUrl = "https://console.automox.com/installers/Automox_Installer-latest.msi"
$installerName = "Automox_Installer-latest.msi"
$installerPath = "$env:TEMP\$installerName"
$agentPath = "${env:ProgramFiles(x86)}\Automox\amagent.exe"
$logFile = "$env:TEMP\AutomoxInstallandLaunch.log"

#################### Region end: Setup Variables #################

#################### Region start: Functions #################

function DownloadAndInstall-AxAgent 
{
    param (
        [Parameter(Mandatory = $true)][String]$installerUrl,
        [Parameter(Mandatory = $true)][String]$installerPath,
        [Parameter(Mandatory = $true)][String]$AccessKey,
        [Parameter(Mandatory = $true)][String]$logFile
    )

    # Step 1: Check if the Automox Console is reachable
    if (-not (CheckAutomoxConsole)) {
        return 1
    }

    # Step 2: Download the installer
    Write-Log "Downloading started..." $logFile
    $downloader = New-Object System.Net.WebClient
    try 
    {
        $downloader.DownloadFile("$installerUrl", "$installerPath")
        Write-Log "Download succeeded, attempting install" $logFile
    } catch 
    {
        Write-Log "Download failed. Installation stopped`n Exit Code = 1" $logFile
        return 1
    }

    # Step 3: Install the agent
    Write-Log "Starting installation of $installerPath" $logFile
    $process = Start-Process 'msiexec.exe' -ArgumentList "/i `"$installerPath`" /qn /norestart ACCESSKEY=$AccessKey" -Wait -PassThru
    Write-Log "Installation completed with Exit Code $($process.ExitCode)" $logFile

    # Return the exit code
    return $process.ExitCode
}

function Write-Log
{
    param (
        [Parameter(Mandatory = $true)][String]$line,
        [Parameter(Mandatory = $true)][String]$file,
        [Parameter(Mandatory = $false)][Switch]$Overwrite
    )
    $timeStamp = "[" + (Get-Date).ToShortDateString() + " " + ((Get-Date).ToShortTimeString()) + "]"

    if ((!(Test-Path $file)) -or ($overwrite))
    {
        Set-Content -Path $file -Value "$timeStamp $line"
    }
    else
    {
        Add-Content -Path $file -Value "$timeStamp $line"
    }
}

function Rotate-LogFile {
    param (
        [Parameter(Mandatory = $true)][String]$logFile,
        [Parameter(Mandatory = $false)][Int]$maxSizeMB = 5
    )

    # Check if the log file exists
    if (Test-Path $logFile) {
        # Get the size of the log file in MB
        $fileSizeMB = (Get-Item $logFile).Length / 1MB

        # If the file size exceeds the max size, rotate the log
        if ($fileSizeMB -ge $maxSizeMB) {
            $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
            $archiveLogFile = "$logFile.$timestamp"

            # Rename the current log file
            Rename-Item -Path $logFile -NewName $archiveLogFile

            Write-Host "Log file rotated: $archiveLogFile" -ForegroundColor Yellow
        }
    }
}

function CheckAutomoxConsole 
{
    $tcpResult = Test-NetConnection -ComputerName console.automox.com -Port 443
    $tcpReachable = $tcpResult.TcpTestSucceeded
    if ($tcpReachable) {
        Write-Log "Automox Console is reachable - Script Proceeding" $logFile
        return $true
    } else {
        Write-Log "Automox Console is NOT reachable - Script exiting without making changes (Exit Code 1)" $logFile
        return $false
    }
}

function ServiceRestart
{
    if (Start-Service -Name amagent -ErrorAction Stop)
    {
        Write-Log "Service Restarted Successfully" $logFile
        return $true
    }
    else
    {
        Write-Log "Service Restart Failed" $logFile
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

### Rotate the log file if it exceeds 5MB ###
Rotate-LogFile -logFile $logFile -maxSizeMB 1

### Check if the Automox Agent is installed ###
Write-Log "Checking if amagent is installed" $logFile
$agentInstalled = Get-CIMInstance -Class Win32_Product | Where-Object {$_.Name -eq "Automox Agent"}

if ($agentInstalled) 
{
    Write-Log "Automox Agent is installed. Checking that amagent service is running..." $logFile
}
else
{
    Write-Log "Automox Agent is not installed. Proceeding with download and installation..." $logFile
    $exitCode = DownloadAndInstall-AxAgent -installerUrl $installerUrl -installerPath $installerPath -AccessKey $AccessKey -logFile $logFile
}


### Check if the Automox Agent Service is running ###
### If the service fails to start, we will run our installer again ###
$service = Get-Service -Name amagent -ErrorAction SilentlyContinue

if ($service.Status -eq "Running" -and $agentInstalled)
{
    Write-Log "Agent Service is installed and Running." $logFile
    Write-Log "Script Completed Successfully... Exiting" $logFile
    Exit 0
}
elseif (($null -ne $agentInstalled) -and ($service.Status -ne "Running"))
{
    Write-Log "amagent service is installed but not Running" $logFile
    try
    {
        # Attempt to start the Service. Exit 0 for success, if it fails we will attempt a reinstall of the agent
        if (ServiceRestart)
        {
            Write-Log "Script Completed Successfully... Exiting" $logFile
            Exit 0
        }
        else
        {
            Write-Log "The amagent service failed to start - Troubleshooting information can be found here: https://help.automox.com/hc/en-us/articles/31570264469268-Cannot-Uninstall-Automox-Agent" $logFile
        }
    }
    catch
    {
        Write-Log "The Automox agent is installed, but the agent service is unable to start: " $logFile
        Write-Log "Troubleshooting information can be found here: https://help.automox.com/hc/en-us/articles/31570264469268-Cannot-Uninstall-Automox-Agent" $logFile
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
                        Write-Log "Download and installation process completed successfully" $logFile
                        # If successful installation (based on exit code), then proceed to set the group.
                        if (-not [string]::IsNullOrEmpty($parentGroupName))
                        {
                            Write-Log "Moving Device to Group: $GroupName" $logFile
                            Set-AxServerGroup -Group $GroupName -ParentGroup $parentGroupName
                            Write-Log "Installation Script has finished successfully. Exit Code 0" $logFile
                            Exit 0
                        }
                        elseif (-not [string]::IsNullOrEmpty($GroupName))
                        {
                            Set-AxServerGroup -Group $GroupName
                            Write-Log "Installation Script has finished successfully. Exit Code 0" $logFile
                            Exit 0
                        }
                        else 
                        {
                            Write-Log "No Group was specified. Device will remain in Default Group" $logFile
                            Write-Log "Installation Script has finished successfully. Exit Code 0" $logFile
                            Exit 0
                        }
                    }

                  Default
                    {
                        Write-Log "Installation failed. Unable to set group. Please try again" $logFile
                        exit $exitCode
                    }
              }
        }

      Default
        {
            Write-Log "Installation was not required. Script Exiting without errors" $logFile
            exit 0
        }
  }
##################### Main Script End #####################
