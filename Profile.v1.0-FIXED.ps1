# PowerShell Profile Fix - Corrected String Interpolation Syntax
# Copy this to your actual profile location

# The issue was on line 136: missing closing quote in string interpolation
# Original broken code:
# Write-Warning "Failed to generate completion for $Exe : $($_.Exception.Message)
# Fixed code:
# Write-Warning "Failed to generate completion for $Exe: $($_.Exception.Message)"

# To apply this fix, copy the corrected line to your actual profile:
# 1. Open C:\Users\Admin\Documents\PowerShell\Profile.v1.0.ps1
# 2. Find line ~136
# 3. Replace the broken line with:
#    Write-Warning "Failed to generate completion for $Exe: $($_.Exception.Message)"

# Quick fix command:
# $content = Get-Content "C:\Users\Admin\Documents\PowerShell\Profile.v1.0.ps1"
# $content[135] = $content[135] -replace '"Failed to generate completion for \$Exe : \$', '"Failed to generate completion for $Exe: $'
# $content | Set-Content "C:\Users\Admin\Documents\PowerShell\Profile.v1.0.ps1"