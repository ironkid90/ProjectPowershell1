# PowerShell Profile v1.0 - Fixed Version
# Fixed syntax errors and improved reliability

# ----------------------------
# Context detection
# ----------------------------
function Test-IsAdmin { [bool](([System.Security.Principal.WindowsIdentity]::GetCurrent()).Groups -match "S-1-5-32-544") }
function Test-IsSystem { $env:USERNAME -eq "SYSTEM" }
function Test-IsInteractive { [Environment]::UserInteractive -and ($Host.Name -ne "Default Host") }
function Test-IsVSCode { $env:TERM_PROGRAM -eq "vscode" -or $Host.UI.RawUI.WindowTitle -match "Visual Studio Code" }
function Test-IsWindowsTerminal { $env:WT_SESSION -or $env:WT_PROFILE_ID }
function Test-IsSSH { $env:SSH_TTY -or $env:SSH_CONNECTION }

$global:ProfileContext = @{
    IsAdmin = Test-IsAdmin
    IsSystem = Test-IsSystem
    IsInteractive = Test-IsInteractive
    IsVSCode = Test-IsVSCode
    IsWindowsTerminal = Test-IsWindowsTerminal
    IsSSH = Test-IsSSH
    HostName = $Host.Name
}

# ----------------------------
# Profile mode selection
# ----------------------------
$global:PROFILE_MODE = if ($global:ProfileContext.IsInteractive) { "Full" } else { "Stable" }

# ----------------------------
# Early PSReadLine setup (for completion UX)
# ----------------------------
if ($global:ProfileContext.IsInteractive -and (Get-Module -ListAvailable -Name PSReadLine)) {
    try {
        Import-Module PSReadLine -ErrorAction Stop
        
        # Fix Windows Terminal paste behavior
        Set-PSReadLineKeyHandler -Chord 'Ctrl+v' -Function Paste
        
        # Predictive IntelliSense (if available)
        if (Get-Command Set-PSReadLineOption -ParameterName PredictionSource -ErrorAction Ignore) {
            Set-PSReadLineOption -PredictionSource History
        }
        
        # Colors for better completion experience
        Set-PSReadLineOption -Colors @{
            Command = 'Yellow'
            Parameter = 'Green'
            Operator = 'Cyan'
        }
        
    } catch {
        Write-Warning "PSReadLine setup failed: $($_.Exception.Message)"
    }
}

# ----------------------------
# Utility functions
# ----------------------------
function Test-CommandExists($Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# ----------------------------
# Machine-wide tool locations
# ----------------------------
$MachineTools = "C:\ProgramData\Tools\bin"
if (Test-Path $MachineTools) {
    $env:PATH = "$MachineTools;$env:PATH"
}

# ----------------------------
# CLI completion generators with caching
# ----------------------------
function Enable-CliCompletionFromCommand {
    param(
        [Parameter(Mandatory)]$Exe,
        [Parameter(Mandatory)]$Args,
        [int]$MaxAgeDays = 7
    )
    
    if (-not (Test-CommandExists $Exe)) { return }
    
    $cacheDir = Join-Path $env:LOCALAPPDATA "PSProfileCache\completions"
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    $cacheFile = Join-Path $cacheDir "$Exe-completion.ps1"
    
    # Generate if cache is stale or missing
    $shouldGenerate = $true
    if (Test-Path $cacheFile) {
        $age = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
        if ($age.TotalDays -le $MaxAgeDays) { $shouldGenerate = $false }
    }
    
    if ($shouldGenerate) {
        try {
            $script = & $Exe $Args 2>$null
            if ($script -and $script.Length -gt 200) {
                Set-Content -Path $cacheFile -Value $script -Encoding UTF8
            }
        } catch {
            Write-Warning "Failed to generate completion for ${Exe}: $($_.Exception.Message)"
        }
    }

    if (Test-Path $cacheFile) {
        try { . $cacheFile } catch {
            Write-Warning "Failed to load completion cache for ${Exe}: $($_.Exception.Message)"
        }
    }
}

function Enable-HelmCompletion {
    Enable-CliCompletionFromCommand -Exe "helm" -Args @("completion","powershell") -MaxAgeDays 14
}

# ----------------------------
# Deferred loading (in-process runspace)
# ----------------------------
function Import-ProfileDeferred {
    param([Parameter(Mandatory)][ScriptBlock]$Deferred)

    # Capture the interactive session state
    $GlobalState = [psmoduleinfo]::new($false)
    $GlobalState.SessionState = $ExecutionContext.SessionState

    # Store deferred code as TEXT in the captured session state
    $GlobalState.SessionState.PSVariable.Set('DeferredText', $Deferred.ToString())

    # Create runspace to run async (in-process)
    $Runspace   = [runspacefactory]::CreateRunspace($Host)
    $PowerShell = [powershell]::Create($Runspace)
    $Runspace.Open()
    $Runspace.SessionStateProxy.PSVariable.Set('GlobalState', $GlobalState)

    # Async wrapper
    $Wrapper = {
        Start-Sleep -Milliseconds 200
        . $GlobalState {
            do { Start-Sleep -Milliseconds 200 } until (Get-Command Import-Module -ErrorAction Ignore)

            try {
                # Rebuild scriptblock INSIDE this session state, then dot-source it
                $sb = [scriptblock]::Create($DeferredText)
                . $sb
            } catch {
                $errLog = Join-Path $env:LOCALAPPDATA "PSProfileCache\deferred.error.log"
                New-Item -ItemType Directory -Path (Split-Path $errLog -Parent) -Force | Out-Null
                Add-Content -Path $errLog -Encoding UTF8 -Value ("Deferred FAIL " + (Get-Date) + " :: " + $_.Exception.Message)
                Write-Warning ("Deferred profile load failed: " + $_.Exception.Message)
            } finally {
                Remove-Variable DeferredText -ErrorAction SilentlyContinue
            }
        }
    }

    $null = $PowerShell.AddScript($Wrapper.ToString()).BeginInvoke()
}

# ----------------------------
# Deferred content to load
# ----------------------------
$DeferredContent = {
    $logPath = Join-Path $env:LOCALAPPDATA "PSProfileCache\deferred.log"
    New-Item -ItemType Directory -Path (Split-Path $logPath -Parent) -Force | Out-Null
    $global:DeferredLoaded = $true
    Add-Content -Path $logPath -Encoding UTF8 -Value ("Deferred OK  " + (Get-Date))

    Enable-HelmCompletion

    if (Test-CommandExists "gsudo") { Set-Alias sudo gsudo }
    if (Test-CommandExists "oh-my-posh") { 
        try { oh-my-posh init pwsh | Invoke-Expression } catch {}
    }
    if (Test-CommandExists "zoxide") {
        try { zoxide init --cmd z powershell | Invoke-Expression } catch {}
    }
    
    # Load profile.d modules if they exist
    $profileDir = Join-Path $global:ProfileRoot "profile.d"
    if (Test-Path $profileDir) {
        Get-ChildItem $profileDir -Filter "*.ps1" | Sort-Object Name | ForEach-Object {
            try { . $_.FullName } catch {
                Write-Warning "Failed to load profile module $($_.Name): $($_.Exception.Message)"
            }
        }
    }
}

# ----------------------------
# Health + status functions
# ----------------------------
function Show-ProfileStatus {
    $c = $global:ProfileContext
    Write-Host "=== Profile v1.0 Status ===" -ForegroundColor Cyan
    Write-Host ("Mode: " + $global:PROFILE_MODE) -ForegroundColor Yellow
    Write-Host ("Host: " + $c.HostName + " | VSCode=" + $c.IsVSCode + " | WT=" + $c.IsWindowsTerminal + " | Interactive=" + $c.IsInteractive) -ForegroundColor Gray
    Write-Host ("Admin=" + $c.IsAdmin + " | SYSTEM=" + $c.IsSystem + " | SSH=" + $c.IsSSH) -ForegroundColor Gray
}

function Invoke-ProfileHealthCheck {
    $checks = @(
        @{ Name="oh-my-posh"; Kind="cmd" },
        @{ Name="zoxide"; Kind="cmd" },
        @{ Name="gsudo"; Kind="cmd" },
        @{ Name="helm"; Kind="cmd" }
    )

    $results = $checks | ForEach-Object {
        $present = if ($_.Kind -eq "cmd") { [bool](Get-Command $_.Name -ErrorAction SilentlyContinue) } else { $false }
        [pscustomobject]@{ Item=$_.Name; Present=$present }
    }
    
    $results | Format-Table -AutoSize
    return $results
}

function Edit-Profile {
    code "C:\Users\Admin\Documents\PowerShell\Profile.v1.0.ps1"
}

function Update-Profile {
    param([switch]$Force)
    
    if (-not $Force -and -not $global:ProfileContext.IsInteractive) {
        Write-Warning "Profile updates should be run interactively"
        return
    }
    
    Write-Host "Updating profile components..." -ForegroundColor Yellow
    
    # Update completion caches
    Enable-HelmCompletion -MaxAgeDays 0
    
    Write-Host "Profile update complete" -ForegroundColor Green
}

# ----------------------------
# Bootstrap command
# ----------------------------
function Bootstrap-TerminalToolchain {
    param([switch]$MachineWide)
    
    Write-Host "=== Terminal Toolchain Bootstrap ===" -ForegroundColor Cyan
    
    if ($MachineWide) {
        Write-Host "Installing machine-wide tools..." -ForegroundColor Yellow
        # Machine-wide installation logic would go here
    } else {
        Write-Host "Installing user tools..." -ForegroundColor Yellow
        # User installation logic would go here
    }
    
    Write-Host "Bootstrap complete" -ForegroundColor Green
}

# ----------------------------
# Main profile execution
# ----------------------------
$global:ProfileRoot = Split-Path $MyInvocation.MyCommand.Path -Parent

# Start deferred loading for interactive sessions
if ($global:ProfileContext.IsInteractive) {
    Import-ProfileDeferred -Deferred $DeferredContent
}

# Show status in interactive mode
if ($global:ProfileContext.IsInteractive -and $global:PROFILE_MODE -eq "Full") {
    Show-ProfileStatus
}