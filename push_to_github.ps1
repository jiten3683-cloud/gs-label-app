# Navigate to the directory where the script is located
Set-Location $PSScriptRoot

# Standard Git workflow
git add .
git commit -m "Automated push via PowerShell"
git push origin main

Write-Host "Push complete! Press any key to exit..."
Pause