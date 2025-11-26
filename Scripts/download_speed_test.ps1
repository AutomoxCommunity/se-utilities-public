# ---Ensure TLS 1.2 is used (Required for Server 2016) ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Load the required .NET Assembly first ---
Add-Type -AssemblyName System.Net.Http

# --- Interactive Menu ---
Clear-Host
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "    Network Download Speed Test Tool      " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Select a payload size to test:"
Write-Host "  [1] Test with ~100 MB Payload"
Write-Host "  [2] Test with ~500 MB Payload)"
Write-Host ""

$selection = Read-Host "Enter Option (1 or 2)"

switch ($selection) {
    '1' {
        $Url = "https://catalog.s.download.windowsupdate.com/d/msdownload/update/software/updt/2025/05/kb5055461_adminconsole_amd64_bc69be5ce05d3e8a4bc398a02f9f38ea69556a72.cab"
        $TestName = "100MB Payload"
    }
    '2' {
        $Url = "https://catalog.s.download.windowsupdate.com/d/msdownload/update/software/updt/2015/08/dataprotectionmanager2012r2-kb3065246_0ade14e6326e183e5724cdc423a871210be40b89.exe"
        $TestName = "500MB Payload"
    }
    Default {
        Write-Warning "Invalid selection. Defaulting to Option 1 (~100 MB)."
        $Url = "https://catalog.s.download.windowsupdate.com/d/msdownload/update/software/updt/2025/05/kb5055461_adminconsole_amd64_bc69be5ce05d3e8a4bc398a02f9f38ea69556a72.cab"
        $TestName = "100 MB Test"
    }
}

$DestinationPath = "$env:USERPROFILE\Downloads\speedtest_payload.cab"

# --- Connection & Link Validation ---
Write-Host "`n1. Testing connection for [$TestName]..." -ForegroundColor Cyan

try {
    # Check if URL is valid URI format before attempting request
    if (!($Url -match "^https?://")) {
        throw "The URL provided for this option is not a valid web address (missing http/https). Please edit the script to include the full path."
    }

    # Added -UseBasicParsing for better compatibility with older PowerShell versions
    $checkRequest = Invoke-WebRequest -Uri $Url -Method Head -ErrorAction Stop -UseBasicParsing
    
    if ($checkRequest.StatusCode -eq 200) {
        Write-Host "   [OK] Connection Established." -ForegroundColor Green
        $totalBytes = $checkRequest.Headers["Content-Length"]
        
        if ($null -eq $totalBytes) { $totalBytes = 0 }
        else { 
            $sizeMB = [Math]::Round($totalBytes / 1MB, 2) 
            Write-Host "   File Size: $sizeMB MB" -ForegroundColor Gray
        }
    }
    else {
        Write-Error "   Server returned status: $($checkRequest.StatusCode)"
        exit
    }
}
catch {
    Write-Error "   [Failed] Connection Error: $($_.Exception.Message)"
    exit
}

# --- Download with Real-Time Monitoring ---
Write-Host "`n2. Starting Download..." -ForegroundColor Cyan
Write-Host "Download in progress. Please wait until testing is completed." -ForegroundColor Gray

# Create HttpClient (Assembly now loaded)
$httpClient = New-Object System.Net.Http.HttpClient
$stopwatch = New-Object System.Diagnostics.Stopwatch
$buffer = New-Object byte[] 81920 # 80KB Buffer

try {
    $responseTask = $httpClient.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
    $responseTask.Wait()
    $response = $responseTask.Result
    
    $contentStream = $response.Content.ReadAsStreamAsync().Result
    $fileStream = [System.IO.File]::Create($DestinationPath)
    
    $totalDownloaded = 0
    $stopwatch.Start()
    
    # Tracking for Real-time speed
    $lastUpdate = $stopwatch.Elapsed.TotalSeconds
    $bytesSinceLastUpdate = 0
    
    do {
        $bytesRead = $contentStream.Read($buffer, 0, $buffer.Length)
        if ($bytesRead -gt 0) {
            $fileStream.Write($buffer, 0, $bytesRead)
            $totalDownloaded += $bytesRead
            $bytesSinceLastUpdate += $bytesRead
            
            $currentTime = $stopwatch.Elapsed.TotalSeconds
            
            # Update UI every 0.5 seconds
            if (($currentTime - $lastUpdate) -ge 0.5) {
                $timeDelta = $currentTime - $lastUpdate
                $bitsRead = $bytesSinceLastUpdate * 8
                $currentMbps = [Math]::Round(($bitsRead / 1000000) / $timeDelta, 2)
                $downloadedMB = [Math]::Round($totalDownloaded / 1MB, 2)
                
                if ($totalBytes -gt 0) {
                    $percent = [Math]::Min(100, [Math]::Round(($totalDownloaded / $totalBytes) * 100))
                    Write-Progress -Activity "Downloading Payload" -Status "$downloadedMB MB / $sizeMB MB @ $currentMbps Mbps" -PercentComplete $percent
                } else {
                    Write-Progress -Activity "Downloading Payload" -Status "$downloadedMB MB @ $currentMbps Mbps"
                }
                
                $lastUpdate = $currentTime
                $bytesSinceLastUpdate = 0
            }
        }
    } while ($bytesRead -gt 0)
    
    $stopwatch.Stop()
    Write-Progress -Activity "Downloading Payload" -Completed

    # --- Final Analysis & Extrapolation ---
    Write-Host "`n3. Download Summary" -ForegroundColor Cyan
    Write-Host "------------------------------------------------"
    
    $totalSeconds = $stopwatch.Elapsed.TotalSeconds
    $totalMegabits = ($totalDownloaded * 8) / 1000000
    
    # Prevent division by zero if download was instant
    if ($totalSeconds -gt 0) {
        $averageMbps = [Math]::Round($totalMegabits / $totalSeconds, 2)
    } else {
        $averageMbps = 0
    }
    
    Write-Host "   Total Time    : $([Math]::Round($totalSeconds, 2)) seconds"
    Write-Host "   Total Size    : $([Math]::Round($totalDownloaded / 1MB, 2)) MB"
    Write-Host "   Average Speed : $averageMbps Mbps" -ForegroundColor Yellow
    Write-Host "------------------------------------------------"

    Write-Host "`n4. Bandwidth Extrapolation (Concurrent Endpoints)" -ForegroundColor Cyan
    Write-Host "   Estimated aggregate bandwidth required if multiple clients"
    Write-Host "   download this payload simultaneously at the average speed above:"
    Write-Host ""
    
    $concurrencyLevels = @(5, 10, 30, 50)
    $report = @()

    foreach ($level in $concurrencyLevels) {
        $reqBandwidth = $averageMbps * $level
        
        # Format for readability
        if ($reqBandwidth -gt 1000) {
            $displayBandwidth = "$([Math]::Round($reqBandwidth / 1000, 2)) Gbps"
        } else {
            $displayBandwidth = "$([Math]::Round($reqBandwidth, 2)) Mbps"
        }

        $report += [PSCustomObject]@{
            "Endpoints" = $level
            "Required Bandwidth" = $displayBandwidth
        }
    }

    $report | Format-Table -AutoSize
    Write-Host "   *Note: Assumes linear scaling (If you want everyone to have full speed)." -ForegroundColor DarkGray

    # --- Time Extrapolation (Shared/Fixed Bandwidth) ---
    Write-Host "`n5. Estimated Duration (Shared/Fixed Bandwidth - Calculated)" -ForegroundColor Cyan
    Write-Host "   If the total network connection is limited to the Average Speed ($averageMbps Mbps),"
    Write-Host "   this is how long it would take if users split that bandwidth:"
    Write-Host ""
    
    $timeReport = @()
    
    foreach ($level in $concurrencyLevels) {
        # If N users share the pipe, it takes N times longer to complete N downloads
        $estSeconds = $totalSeconds * $level
        $timeSpan = New-TimeSpan -Seconds $estSeconds
        
        # Format time string (e.g. 1h 30m 15s)
        $durationStr = "{0}h {1}m {2}s" -f [Math]::Floor($timeSpan.TotalHours), $timeSpan.Minutes, $timeSpan.Seconds

        $timeReport += [PSCustomObject]@{
            "Endpoints" = $level
            "Est. Completion Time" = $durationStr
        }
    }
    
    $timeReport | Format-Table -AutoSize
    Write-Host "   *Note: Assumes the total bandwidth is constant and split evenly." -ForegroundColor DarkGray

    # --- Manual Bandwidth Verification ---
    Write-Host "`n6. Bandwidth Verification" -ForegroundColor Cyan
    $response = Read-Host "   Is the Average Speed calculated above ($averageMbps Mbps) representative of your total site bandwidth? (Y/N)"
    
    if ($response -match "^[Nn]") {
        Write-Host ""
        $manualMbps = Read-Host "   Enter your actual total site bandwidth in Mbps (e.g. 100)"
        
        try {
            $manualMbps = [double]$manualMbps
            
            if ($manualMbps -gt 0) {
                Write-Host "`n   Calculating estimates based on MANUAL bandwidth: $manualMbps Mbps" -ForegroundColor Yellow
                Write-Host "   (Time required if $manualMbps Mbps is split among N concurrent downloads)"
                Write-Host ""
                
                $manualReport = @()
                
                foreach ($level in $concurrencyLevels) {
                    # Total Data to transfer for N users = TotalMegabits * N
                    # Time = Total Data / Bandwidth
                    $totalDataToTransfer = $totalMegabits * $level
                    $estSecondsManual = $totalDataToTransfer / $manualMbps
                    
                    $timeSpan = New-TimeSpan -Seconds $estSecondsManual
                    $durationStr = "{0}h {1}m {2}s" -f [Math]::Floor($timeSpan.TotalHours), $timeSpan.Minutes, $timeSpan.Seconds
                    
                    $manualReport += [PSCustomObject]@{
                        "Endpoints" = $level
                        "Est. Completion Time" = $durationStr
                    }
                }
                
                $manualReport | Format-Table -AutoSize
            } else {
                Write-Warning "   Invalid bandwidth entered (must be > 0). Skipping calculation."
            }
        }
        catch {
             Write-Warning "   Invalid input (not a number). Skipping calculation."
        }
    } else {
        Write-Host "   Using calculated speed as baseline." -ForegroundColor Gray
    }

    # --- Interactive Simulation Loop ---
    do {
        Write-Host ""
        $retryResponse = Read-Host "   Do you want to see the result with a different bandwidth capacity? (Y/N)"
        
        if ($retryResponse -match "^[Yy]") {
            $simulatedMbps = Read-Host "   Enter bandwidth in Mbps to simulate (e.g. 500)"
            
            try {
                $simulatedMbps = [double]$simulatedMbps
                
                if ($simulatedMbps -gt 0) {
                    Write-Host "`n   Calculating estimates for: $simulatedMbps Mbps" -ForegroundColor Yellow
                    Write-Host "   (Time required if $simulatedMbps Mbps is split among N concurrent downloads)"
                    Write-Host ""
                    
                    $simReport = @()
                    
                    foreach ($level in $concurrencyLevels) {
                        # Total Data to transfer for N users = TotalMegabits * N
                        # Time = Total Data / Bandwidth
                        $totalDataToTransfer = $totalMegabits * $level
                        $estSecondsSim = $totalDataToTransfer / $simulatedMbps
                        
                        $timeSpan = New-TimeSpan -Seconds $estSecondsSim
                        $durationStr = "{0}h {1}m {2}s" -f [Math]::Floor($timeSpan.TotalHours), $timeSpan.Minutes, $timeSpan.Seconds
                        
                        $simReport += [PSCustomObject]@{
                            "Endpoints" = $level
                            "Est. Completion Time" = $durationStr
                        }
                    }
                    
                    $simReport | Format-Table -AutoSize
                } else {
                    Write-Warning "   Invalid bandwidth entered (must be > 0)."
                }
            }
            catch {
                 Write-Warning "   Invalid input (not a number)."
            }
        }
    } while ($retryResponse -match "^[Yy]")

    Write-Host "`n   Test Complete. Thank you." -ForegroundColor Green
}
catch {
    Write-Error "   [Error] $($_.Exception.Message)"
}
finally {
    if ($fileStream) { $fileStream.Close(); $fileStream.Dispose() }
    if ($contentStream) { $contentStream.Close(); $contentStream.Dispose() }
    if ($httpClient) { $httpClient.Dispose() }
    
   # Cleanup: Delete the test file
    if (Test-Path $DestinationPath) {
        Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
        Write-Host "   [Cleanup] Downloaded test file has been removed." -ForegroundColor DarkGray
    }
}