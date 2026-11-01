# Define directory and file paths
$dir = "C:\script"
$url = "https://raw.githubusercontent.com/massgravel/Microsoft-Activation-Scripts/master/MAS/Separate-Files-Version/Activators/TSforge_Activation.cmd"
$outputFile = "$dir\script.cmd"
$taskName = "WindowsSystemScriptRunner"

# Create the directory if it doesn't already exist
if (!(Test-Path -Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-Host "Created directory: $dir" -ForegroundColor Cyan
}

# Download the file and save it as script.cmd
try {
    Invoke-WebRequest -Uri $url -OutFile $outputFile
    Write-Host "Successfully downloaded and saved to: $outputFile" -ForegroundColor Green
}
catch {
    Write-Error "Failed to download the file: $_"
    exit 1
}

# Create a scheduled task to run script.cmd at startup silently with administrator/SYSTEM privileges
try {
    $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$outputFile`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
    
    # Register the scheduled task (overwriting if it already exists)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Successfully created background scheduled task: $taskName" -ForegroundColor Green
}
catch {
    Write-Error "Failed to create scheduled task: $_"
}
