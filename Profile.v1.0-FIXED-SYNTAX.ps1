# PowerShell Profile v1.0 (Fixed Syntax)
# Based on expert analysis feedback
# Goals: Fast startup, predictable behavior, agent-friendly, completion preservation

# ----------------------------
# Context detection
# ----------------------------
function Test-IsAdmin {
    try {
        return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Test-IsSystem {
    try { return [System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem }
    catch { return $false }
}

function Test-IsInteractive { return -not [Console]::IsInputRedirected }

function Get-ProfileContext {
    [pscustomobject]@{
        IsAdmin           = Test-IsAdmin
        IsSystem          = Test-IsSystem
        IsInteractive     = Test-IsInteractive
        IsVSCode          = [bool]$env:VSCODE_PID
        IsWindowsTerminal = [bool]$env:WT_SESSION
        IsSSH             = [bool]$env:SSH_CLIENT -or [bool]$env:SSH_CONNECTION
        HostName          = $Host.Name
        PSVersion         = $PSVersionTable.PSVersion.ToString()
    }
}

$global:ProfileContext = Get-ProfileContext

# ----------------------------
# Mode selection (WT=Full, VSCode=Stable)
# ----------------------------
if ($env:PROFILE_MODE) {
    $global:PROFILE_MODE = $env:PROFILE_MODE
} else {
    if (-not $global:ProfileContext.IsInteractive) { $global:PROFILE_MODE = "Stable" }
    elseif ($global:ProfileContext.IsSystem)        { $global:PROFILE_MODE = "Stable" }
    elseif ($global:ProfileContext.IsVSCode)        { $global:PROFILE_MODE = "Stable" }
    elseif ($global:ProfileContext.IsWindowsTerminal) { $global:PROFILE_MODE = "Full" }
    else                                             { $global:PROFILE_MODE = "Full" }
}

# ----------------------------
# Paths + caches
# ----------------------------
$global:ProfileRoot = Join-Path $HOME "Documents\PowerShell"
$global:CacheRoot   = Join-Path $env:LOCALAPPDATA "PSProfileCache"
$global:CompletionCache = Join-Path $global:CacheRoot "completions"

foreach ($p in @($global:ProfileRoot, $global:CacheRoot, $global:CompletionCache)) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

# Machine-wide tool locations (optional)
$MachineToolsBin = "C:\ProgramData\Tools\bin"
if (Test-Path $MachineToolsBin) {
    if ($env:Path -notlike "*$MachineToolsBin*") { $env:Path = "$MachineToolsBin;$env:Path" }
}

function Test-CommandExists { param([string]$Name) return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue) }

# ----------------------------
# Early: encoding + title + basic prompt
# ----------------------------
try {
    [Console]::InputEncoding  = [Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
} catch {}

try {
    $adminTag = if ($global:ProfileContext.IsAdmin) { " [ADMIN]" } else { "" }
    $sysTag   = if ($global:ProfileContext.IsSystem) { " [SYSTEM]" } else { "" }
    $Host.UI.RawUI.WindowTitle = "pwsh $($global:ProfileContext.PSVersion)$adminTag$sysTag"
} catch {}

function global:prompt {
    $loc = Get-Location
    if ($global:ProfileContext.IsAdmin) { "[$loc] # " } else { "[$loc] $ " }
}

# ----------------------------
# PSReadLine early (completion UX)
# ----------------------------
if ($global:ProfileContext.IsInteractive -and (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue)) {
    try {
        Set-PSReadLineOption -EditMode Windows `
            -HistoryNoDuplicates `
            -HistorySearchCursorMovesToEnd `
            -PredictionSource History `
            -PredictionViewStyle ListView `
            -BellStyle None

        Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
        Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
        Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete
        
        # Fix Windows Terminal paste behavior - use chord binding
        Set-PSReadLineKeyHandler -Chord 'Ctrl+v' -Function Paste
    } catch {
        Write-Warning "PSReadLine configuration failed: $($_.Exception.Message)"
    }
}

# ----------------------------
# Completion caching for CLIs (Helm)
# ----------------------------
function Enable-CliCompletionFromCommand {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Args,
        [int]$MaxAgeDays = 14
    )
    
    if (-not (Test-CommandExists $Exe)) { return }

    $safeName  = ($Exe + "_" + ($Args -join "_")).Replace(":", "").Replace("\\", "_").Replace("/", "_")
    $cacheFile = Join-Path $global:CompletionCache "$safeName.ps1"

    $needsRefresh = $true
    if (Test-Path $cacheFile) {
        $ageDays = ((Get-Date) - (Get-Item $cacheFile).LastWriteTime).TotalDays
        if ($ageDays -lt $MaxAgeDays) { $needsRefresh = $false }
    }

    if ($needsRefresh) {
        try {
            $script = & $Exe @Args | Out-String
            if ($script -and $script.Length -gt 200) {
                Set-Content -Path $cacheFile -Value $script -Encoding UTF8
            }
        } catch {
            Write-Warning "Failed to generate completion for $Exe : $($_.Exception.Message)"
        }
    }

    if (Test-Path $cacheFile) {
        try { . $cacheFile } catch {
            Write-Warning "Failed to load completion cache for $Exe : $($_.Exception.Message)"
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
        
        # Create machine-wide tools directory
        if (-not (Test-Path "C:\ProgramData\Tools\bin")) {
            New-Item -ItemType Directory -Path "C:\ProgramData\Tools\bin" -Force | Out-Null
        }
        
        Write-Host "Machine-wide tools directory ready: C:\ProgramData\Tools\bin" -ForegroundColor Green
    }
    
    Write-Host "Bootstrap complete. Recommended tools:" -ForegroundColor Green
    Write-Host "- gsudo: Admin elevation" -ForegroundColor Gray
    Write-Host "- oh-my-posh: Prompt theming" -ForegroundColor Gray
    Write-Host "- zoxide: Directory jumping" -ForegroundColor Gray
    Write-Host "- Helm: Kubernetes package manager" -ForegroundColor Gray
}

# ----------------------------
# Activate based on mode
# ----------------------------
if ($global:PROFILE_MODE -eq "Full") {
    # Start deferred loading for interactive sessions
    Import-ProfileDeferred -Deferred $DeferredContent
} else {
    # Stable mode: load essentials only
    Enable-HelmCompletion
}

# ----------------------------
# Final initialization message
# ----------------------------
if ($global:ProfileContext.IsInteractive) {
    Write-Host "PowerShell profile loaded ($($global:PROFILE_MODE) mode)" -ForegroundColor Green
    Write-Host "Use 'Show-ProfileStatus' for details, 'Invoke-ProfileHealthCheck' for tool status" -ForegroundColor Gray
}