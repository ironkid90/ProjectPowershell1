# Minimal loader profile for PowerShell 5.1
# This file should be placed in: $HOME\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1

$main = Join-Path $HOME "Documents\PowerShell\Profile.v1.0-improved.ps1"
try {
    if (Test-Path $main) { 
        . $main 
    } else { 
        Write-Warning "Profile loader: missing $main" 
    }
} catch {
    Write-Warning "Profile loader failed: $($_.Exception.Message)"
}