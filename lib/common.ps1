# Shared helpers for pi-vctl. Dot-source this file.

function Get-PiVctlConfig {
    # Asks Windows for the profile path, because HOME and USERPROFILE can be overridden.
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    $key = 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation'
    $installPath = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).InstallPath
    if (-not $installPath) { $installPath = 'C:\Program Files (x86)\VMware\VMware Workstation\' }

    $config = [pscustomobject]@{
        Image       = 'pi-sandbox:latest'
        Profile     = $userProfile
        TempDir     = Join-Path $userProfile 'AppData\Local\Temp'
        VctlDir     = Join-Path $userProfile '.vctl'
        PiDir       = Join-Path $userProfile '.pi'
        Vctl        = Join-Path $installPath 'bin\vctl.exe'
        VDiskManager = Join-Path $installPath 'vmware-vdiskmanager.exe'
    }
    if (-not (Test-Path -LiteralPath $config.Vctl)) {
        throw "vctl not found at $($config.Vctl). It ships with Workstation 17 and was removed in 25H2."
    }
    return $config
}

# vctl keeps its storage under HOME and unpacks images under TMP. Both must be on a
# path where the user can set case-sensitive folders, which C:\msys64 does not allow.
function Invoke-WithVctlEnv {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [scriptblock] $Body
    )
    # Unusual names: Body can see these variables and would get them instead of its own.
    $vctlEnvNames = 'HOME', 'USERPROFILE', 'TMP', 'TEMP'
    $vctlEnvSaved = @{}
    foreach ($vctlEnvName in $vctlEnvNames) { $vctlEnvSaved[$vctlEnvName] = [Environment]::GetEnvironmentVariable($vctlEnvName, 'Process') }
    try {
        $env:HOME = $Config.Profile
        $env:USERPROFILE = $Config.Profile
        $env:TMP = $Config.TempDir
        $env:TEMP = $Config.TempDir
        & $Body
    } finally {
        foreach ($vctlEnvName in $vctlEnvNames) { [Environment]::SetEnvironmentVariable($vctlEnvName, $vctlEnvSaved[$vctlEnvName], 'Process') }
    }
}

# Call inside Invoke-WithVctlEnv.
function Test-VctlRuntime {
    param([Parameter(Mandatory)] $Config)
    return ((& $Config.Vctl system info 2>&1 | Out-String) -match 'runtime is running')
}

# Call inside Invoke-WithVctlEnv.
function Start-VctlRuntime {
    param([Parameter(Mandatory)] $Config)
    if (Test-VctlRuntime -Config $Config) { return }
    # The containerd daemon outlives this call. Going through the shell stops it from
    # inheriting our output handles, which would hang anything piping our output.
    $info = [Diagnostics.ProcessStartInfo]::new($Config.Vctl, 'system start')
    $info.UseShellExecute = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $process = [Diagnostics.Process]::Start($info)
    if (-not $process.WaitForExit(120000)) { throw 'Timed out waiting for vctl system start.' }
    if (-not (Test-VctlRuntime -Config $Config)) { throw 'The vctl runtime did not start. Run: vctl system info' }
}

# Call inside Invoke-WithVctlEnv. Returns the names of running containers.
function Get-VctlRunningContainers {
    param([Parameter(Mandatory)] $Config)
    # vctl ps has no quiet mode: skip its header row and box-drawing separator rows.
    $rows = & $Config.Vctl ps 2>&1 | Out-String -Stream
    $separator = [string][char]0x2500
    return @($rows | Where-Object { $_ -match '^\S' -and -not $_.StartsWith('NAME ') -and -not $_.StartsWith($separator) } |
        ForEach-Object { ($_ -split '\s+')[0] })
}

# Call inside Invoke-WithVctlEnv, after the run. A run that hung or was interrupted can
# leave its container, its VM process and its VM folders behind. A normal run leaves none.
function Remove-VctlLeftovers {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $Container
    )
    $vmDir = Join-Path $Config.VctlDir ".r\vms\$Container"
    if (-not (Test-Path -LiteralPath $vmDir)) { return }
    if ((& $Config.Vctl ps -a 2>&1 | Out-String) -match "(?m)^$([regex]::Escape($Container))\s") {
        & $Config.Vctl rm -f $Container 2>&1 | Out-Null
    }
    # The VM's log starts with its time and process id. Both must match, so that a reused
    # id never stops one of your own VMs.
    $log = Join-Path $vmDir 'vmware.log'
    if ((Test-Path -LiteralPath $log) -and ((Get-Content -LiteralPath $log -TotalCount 1) -match '^(\S+) .*pid=(\d+)')) {
        $logged = [datetime]::Parse($Matches[1]).ToUniversalTime()
        $vm = Get-Process -Id $Matches[2] -ErrorAction SilentlyContinue
        if ($vm -and $vm.ProcessName -eq 'vmware-vmx' -and [Math]::Abs(($vm.StartTime.ToUniversalTime() - $logged).TotalSeconds) -lt 60) {
            Stop-Process -Id $vm.Id -Force
            $vm.WaitForExit(10000) | Out-Null
        }
    }
    foreach ($dir in $vmDir, (Join-Path $Config.VctlDir ".r\sandboxes\$Container")) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Call inside Invoke-WithVctlEnv. Cleans up after launchers that were killed, for example by
# closing their window: their finally blocks never ran, so their containers may still run.
# A launcher's container is named pi-<its process id>.
function Remove-StaleLaunches {
    param([Parameter(Mandatory)] $Config)
    $names = @(& $Config.Vctl ps -a 2>&1 | Out-String -Stream | ForEach-Object { if ($_ -match '^(pi-\d+)\s') { $Matches[1] } })
    $names += @(Get-ChildItem (Join-Path $Config.VctlDir '.r\vms') -Directory -ErrorAction SilentlyContinue |
        Where-Object Name -match '^pi-\d+$' | ForEach-Object Name)
    foreach ($staleName in ($names | Sort-Object -Unique)) {
        $launcher = Get-Process -Id ([int]($staleName -replace '^pi-')) -ErrorAction SilentlyContinue
        if ($launcher -and $launcher.ProcessName -in 'pwsh', 'powershell') { continue }
        & $Config.Vctl rm -f $staleName 2>&1 | Out-Null
        Remove-VctlLeftovers -Config $Config -Container $staleName
    }
    Get-ChildItem $Config.TempDir -Filter 'pi-vctl-pi-*.status' -ErrorAction SilentlyContinue |
        Where-Object { -not (Get-Process -Id ([int]($_.BaseName -replace '^pi-vctl-pi-')) -ErrorAction SilentlyContinue) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# Call inside Invoke-WithVctlEnv, so the helper gets the same HOME. Starts lib\agent-patch.ps1
# hidden, in a console of its own, and returns its process.
function Start-AgentPatch {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $Container,
        [Parameter(Mandatory)] [string] $StatusPath
    )
    Remove-Item -LiteralPath $StatusPath -ErrorAction SilentlyContinue
    $shell = (Get-Process -Id $PID).Path
    $helperScript = Join-Path $PSScriptRoot 'agent-patch.ps1'
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$helperScript`" -Vctl `"$($Config.Vctl)`" -Container $Container -ParentId $PID -StatusPath `"$StatusPath`""
    $info = [Diagnostics.ProcessStartInfo]::new($shell, $arguments)
    $info.UseShellExecute = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    return [Diagnostics.Process]::Start($info)
}

function Test-PathInside {
    param([string] $Path, [string] $Parent)
    $p = $Path.TrimEnd('\')
    $q = $Parent.TrimEnd('\')
    return ($p -ieq $q) -or $p.StartsWith("$q\", [StringComparison]::OrdinalIgnoreCase)
}

# Refuses folders that would hand the agent credentials or code the host runs.
function Assert-SafeWorkspace {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $Workspace,
        [string] $OriginalHome
    )
    $path = (Resolve-Path -LiteralPath $Workspace).ProviderPath.TrimEnd('\')
    if ($path -notmatch '^[A-Za-z]:\\') { throw "Workspace must be on a local drive: $path" }
    if ($path -match '^[A-Za-z]:$') { throw "Refusing to mount a drive root: $path" }
    # vctl parses --volume as CSV.
    if ($path.Contains(',')) { throw "vctl cannot mount a path containing a comma: $path" }

    $homes = @($Config.Profile)
    if ($OriginalHome) { $homes += $OriginalHome }
    foreach ($h in $homes) {
        # A home folder, or anything above one, exposes dotfiles and credentials.
        if (Test-PathInside -Path $h -Parent $path) { throw "Refusing to mount a home folder or its parent: $path" }
        foreach ($sensitive in '.pi', '.vctl', '.ssh', '.aws', '.config', '.claude', 'AppData') {
            if (Test-PathInside -Path $path -Parent (Join-Path $h $sensitive)) { throw "Refusing to mount a sensitive folder: $path" }
        }
    }
    return $path
}
