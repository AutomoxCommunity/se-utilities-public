function CleanUp-AxAgent
{

<#
.SYNOPSIS
   Comprehensive removal of any remnants of the Automox Agent left behind from a broken state.
   Use this if reinstallation fails.
.DESCRIPTION
.NOTES
   This fix only applies to the local device
   Version 1.2
   Released: 2026-06-30
   Author: Automox Support
   Changelog:
     1.2 - Also stop the Automox Agent Watchdog process (amagent-watchdog.exe) and
           remove the 'watchdog' service. The watchdog was introduced in agent 2.3.34
           and was not handled before, so it kept the install folder locked (causing
           "Was not able to remove") and was left behind as an orphaned service.
.EXAMPLE
   CleanUp-AxAgent
.LINK
   http://www.automox.com
#>

   #region uninstall
   # Uninstall with MSI method if found present
   # Define Values
   $OS64Arch = [Environment]::Is64BitProcess
   # Set agent path accordingly to OS Architectire
   if ($true -eq $OS64Arch)
   {
       $installPath = "${env:ProgramFiles(x86)}\Automox"
   }
   else
   {
       $installPath = "${env:ProgramFiles}\Automox"
   }
   $uninstReg = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
   $appName = 'Automox Agent'
   $logPath = "C:\ProgramData\amagent"
   #Get all entries that match our criteria. DisplayName matches $appname
   $installed = @(Get-ChildItem $uninstReg -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { ($_.DisplayName -match $appName) })
   if ($installed)
   {
       Write-Output "Agent still installed`nRemoving...`n"
       $process = Start-Process msiexec.exe -ArgumentList "/x $( $installed.PSChildName ) /qn REBOOT=ReallySuppress" -Wait -PassThru
       Write-Output "Uninstall Completed with Exit Code: $( $process.ExitCode )`n`nProceeding with additional cleanup steps"
   }
   else
   {
       Write-Warning "Proceeding with Automox cleanup steps"
   }
   #endregion
   
   #region cleanup
   # Determine if the Automox Agent process is currently running
   $agentProcess = Get-Process amagent -ErrorAction SilentlyContinue
   # If Agent is running, force it to stop
   if ($null -ne $agentProcess)
   {
       Try
       {
           Write-Output "Stopping Automox agent process"
           Stop-Process $agentProcess -Force -ErrorAction Stop
       }
       Catch
       {
           Write-Error "Unable to stop Automox Agent process.`nFiles may be left behind in C:\ProgramData\amagent\ folder";
       }
   }
   $svcExists = Get-WmiObject -Class Win32_Service -Filter "Name='amagent'"
   if ($null -ne $svcExists)
   {
       Write-Output "Removing Automox agent service"
       $svcExists | Remove-WmiObject
   
       # Test for successful removal of Automox agent
       $svcExists = Get-WmiObject -Class Win32_Service -Filter "Name='amagent'"
       if ($null -ne $svcExists)
       {
           Write-Output "Automox agent service was not able to be removed. Try rebooting and re-run script."
       }
   }
   # Determine if the Automox Remote Control process is currently running
   $agentProcess = Get-Process remotecontrold -ErrorAction SilentlyContinue
   # If Agent is running, force it to stop
   if ($null -ne $agentProcess)
   {
       Try
       {
           Write-Output "Stopping remote control process"
           Stop-Process $agentProcess -Force -ErrorAction Stop
       }
       Catch
       {
           Write-Error "Unable to stop Automox remote control process.`nFiles may be left behind in $installPath folder";
       }
   }
   $svcExists = Get-WmiObject -Class Win32_Service -Filter "Name='remotecontrold'"
   if ($null -ne $svcExists)
   {
       Write-Output "Removing Automox remote control service"
       $svcExists | Remove-WmiObject
           
       # Test for successful removal of Automox remote control service
       $svcExists = Get-WmiObject -Class Win32_Service -Filter "Name='remotecontrold'"
       if ($null -ne $svcExists)
       {
           Write-Output "Automox agent service was not able to be removed. Try rebooting and re-run script."
       }
   }

   # Determine if the Automox Agent Watchdog process is currently running
   # (introduced in agent 2.3.34; runs from $installPath and holds it locked)
   $agentProcess = Get-Process amagent-watchdog -ErrorAction SilentlyContinue
   # If the watchdog is running, force it to stop
   if ($null -ne $agentProcess)
   {
       Try
       {
           Write-Output "Stopping Automox Agent Watchdog process"
           Stop-Process $agentProcess -Force -ErrorAction Stop
       }
       Catch
       {
           Write-Error "Unable to stop Automox Agent Watchdog process.`nFiles may be left behind in $installPath folder";
       }
   }
   
   # Remove the watchdog service. Guard on the binary path so we never remove a
   # non-Automox service that happens to be named 'watchdog'.
   $svcExists = Get-WmiObject -Class Win32_Service -Filter "Name='watchdog'" | Where-Object { $_.PathName -match 'amagent-watchdog' }
   if ($null -ne $svcExists)
   {
       Write-Output "Removing Automox Agent Watchdog service"
       $svcExists | Remove-WmiObject
       # Test for successful removal of the watchdog service
       $svcExists = Get-WmiObject -Class Win32_Service -Filter "Name='watchdog'" | Where-Object { $_.PathName -match 'amagent-watchdog' }
       if ($null -ne $svcExists)
       {
           Write-Output "Automox Agent Watchdog service was not able to be removed. Try rebooting and re-run script."
       }
   }

   # Make sure no msiexec processes are lingering from our uninstall attempt
   # then remove C:\ProgramData\amagent\ directory
   Get-Process msiexe[c] | Stop-Process -Force
   if (Test-Path $logPath)
   {
       $logPath | Remove-Item -Recurse -Force
   }

   if (Test-Path $installPath)
   {
       # Account for removal of exec#### folders that may give access to path denied errors
       Get-ChildItem -Path $installPath -recurse |
           Where-Object {$_.PSIsContainer -eq $true -and (Get-ChildItem -Path $_.FullName) -eq $null} | Remove-Item
       
       # Remove Automox folder
       $installPath | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
       if (Test-Path $installPath)
       {
           Write-Output "Was not able to remove $installPath"
       }
   }
   
   # CleanUp registry settings that could potentially be left behind.
   New-PSDrive -PSProvider Registry -Name HKCR -Root HKEY_CLASSES_ROOT -ErrorAction SilentlyContinue | Out-Null
   $rootKey = (Get-ChildItem "HKCR:\Installer\Products\" -Recurse -ErrorAction SilentlyContinue) | Get-ItemProperty | Where-Object { $_.ProductName -match "Automox Agent" }
   $hklmKey = (Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\" -Recurse -ErrorAction SilentlyContinue) | Get-ItemProperty | Where-Object { $_.DisplayName -match "Automox Agent" }
   $otherKeys = @("HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\amagent", "SYSTEM\CurrentControlSet\Services\EventLog\Application\amagent_uninstall")
   if ($null -ne $rootKey)
   {
       $rootKey | Remove-Item -Recurse -Force
   }
   if ($null -ne $hklmKey)
   {
       $hklmKey | Remove-Item -Recurse -Force
   }
   foreach ($key in $otherKeys)
   {
       if (Test-Path $key)
       {
           $key | Remove-Item -Recurse -Force
       }
   }
   #endregion
}

CleanUp-AxAgent