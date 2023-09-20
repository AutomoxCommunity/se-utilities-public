## Automox Evaluation script
# Using scriptblock to relaunch in native environment for 64bit detection.
$scriptBlock = {

    ######## Make changes within the block ########
    # Add Application name exactly as it appears in Add/Remove Programs, Programs and Features, or Apps and Features between single quotes.
    $appName = 'Rapid7 Insight Agent'
    ###############################################

    # Define registry location for uninstall keys
    $uninstReg = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall')

    # Get all entries that match our criteria. DisplayName matches $appName (using -like to support special characters)
    $installed = @(Get-ChildItem $uninstReg -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object {($_.DisplayName -like $appName)})

    # If any matches were found, $installed will return a "1" and pass it to $exitCode flagging the device for remediation.
    if ($installed)
    {
        return 0
    }
    else
    {
        return 1
    }
}

# Execution of $scriptBlock
$exitCode = & "$env:SystemRoot\sysnative\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -NonInteractive -Command $scriptblock

# Exit with value provided by $installed
Exit $exitCode





## Automox Remediation script
# user input
$CustomToken = "your_custom_token_here"

msiexec /i agentInstaller-x86_64.msi /l*v insight_agent_install_log.log /quiet CUSTOMTOKEN=$CustomToken

Start-Sleep -Seconds 30

# Using scriptblock to relaunch in native environment for 64bit detection.
$scriptBlock = {

    ######## Make changes within the block ########
    # Add Application name exactly as it appears in Add/Remove Programs, Programs and Features, or Apps and Features between single quotes.
    $appName = 'Rapid7 Insight Agent'
    ###############################################

    # Define registry location for uninstall keys
    $uninstReg = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall')

    # Get all entries that match our criteria. DisplayName matches $appName (using -like to support special characters)
    $installed = @(Get-ChildItem $uninstReg -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object {($_.DisplayName -like $appName)})

    # If any matches were found, $installed will return a "1" and pass it to $exitCode flagging the device for remediation.
    if ($installed)
    {
        write-output "Rapid7 Insight Agent was installed successfully"
    }
    else
    {
        write-output "Failed to install Rapid7 Insight Agent" 
    }
}

# Execution of $scriptBlock
$exitCode = & "$env:SystemRoot\sysnative\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -NonInteractive -Command $scriptblock

# Exit with value provided by $installed
write-output $exitCode
