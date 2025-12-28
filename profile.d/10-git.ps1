# Git-related profile components (loaded deferred)

function Get-GitStatusInfo {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $branch = git branch --show-current 2>$null
        $status = git status --porcelain 2>$null
        
        if ($branch) {
            $dirty = if ($status) { "*" } else { "" }
            return "git:($branch$dirty)"
        }
    }
    return $null
}

# Git aliases
Set-Alias -Name g -Value git
Set-Alias -Name gs -Value git status
Set-Alias -Name gco -Value git checkout
Set-Alias -Name gcm -Value git commit
Set-Alias -Name gp -Value git push

function Get-GitPrompt {
    $info = Get-GitStatusInfo
    if ($info) { " $info" } else { "" }
}