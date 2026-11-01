# Define directory and file paths
$dir = "C:\script"
$url = "https://raw.githubusercontent.com/massgravel/Microsoft-Activation-Scripts/master/MAS/Separate-Files-Version/Activators/TSforge_Activation.cmd"
$outputFile = "$dir\script.cmd"

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
}
