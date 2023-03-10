#This script is designed to deploy the Automox Agent to Windows Devices. You will need to add your Automox Agent Access Key to the $key variable in line 4.

#####################USER INPUT#####################
$key="your_access_key"
####################################################

# Check if already installed
$unkeys = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
foreach ($key in Get-ChildItem $unkeys -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { ($_.DisplayName -like "*Automox*" -and $_.DisplayVersion) })
{
        Write-Output "Automox Agent is already installed"
        exit 0
}
$un64keys = "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
foreach ($key in Get-ChildItem $un64keys -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { ($_.DisplayName -like "*Automox*" -and $_.DisplayVersion) })
{
        Write-Output "Automox Agent is already installed"
        exit 0
}
# Install
$source = 'https://console.automox.com/installers/Automox_Installer-latest.msi'
$destination = 'C:\Automox_Installer-latest.msi'
$client = (New-Object Net.WebClient)
$client.Headers["User-Agent"] = 'ax:ax-agent-deployer/S1 0.1.2 (Windows)'
$client.DownloadFile($source, $destination)
Start-Process msiexec.exe -ArgumentList "/i ${destination} /qn /norestart ACCESSKEY=$key" -Wait
del $destination
Write-Output "Successfully installed the Automox Agent"
