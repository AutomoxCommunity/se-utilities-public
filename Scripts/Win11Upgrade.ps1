###Evaluation###

$Version = (Get-CimInstance Win32_OperatingSystem).Version

if ($Version -ge '10.0.22000')
{
  Write-Output "Device is already on Windows 11 - Build 22000"
  Write-Output "Now exiting!"
  Exit 0
}

else
{
  Write-Output "The device is not on Windows 11."
  Write-Output "Running Feature Build Upgrade."
  Exit 1
}


###Remediation###

$dir = 'C:\_Windows11_Upgrade\packages'
Write-Output "Staging temp directory for the Windows Installation Assistant files."
New-Item -ItemType Directory -Path $dir -Force
Write-Output "Directory created. Now downloading the Windows 11 Installation Media."
$webClient = New-Object System.Net.WebClient
$url = 'https://go.microsoft.com/fwlink/?linkid=2171764'
$file = "$($dir)\Win11Upgrade.exe"
$webClient.DownloadFile($url,$file)
Write-Output "Download Completed!"
Write-Output "Running the Windows 11 installation..."
Start-Process -FilePath $file -ArgumentList '/quietinstall /skipeula /auto upgrade /copylogs $dir'
