# Runs pi in a vctl container with the current folder mounted at the same path,
# written Unix-style: D:\dev\app is mounted at /d/dev/app.
# All arguments go to pi, so there is deliberately no param block: PowerShell would
# otherwise claim flags such as -m. Settings come from environment variables:
#   PI_VCTL_MEMORY     container memory limit, default 2g (vctl's own default is 512m)
#   PI_VCTL_CPUS       CPU cores, default 4
#   PI_VCTL_WORKSPACE  folder to mount, default the current folder
#   PI_VCTL_MOUNT_RO   more folders to mount read-only, separated by semicolons
#   PI_VCTL_ENV        names of host variables to pass in, separated by semicolons
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$config = Get-PiVctlConfig
$piArgs = @($args)
$originalHome = $env:HOME
$workspaceInput = if ($env:PI_VCTL_WORKSPACE) { $env:PI_VCTL_WORKSPACE } else { (Get-Location).ProviderPath }
$workspace = Assert-SafeMount -Config $config -Path $workspaceInput -OriginalHome $originalHome
$containerWorkspace = ConvertTo-ContainerPath $workspace
$readOnlyMounts = @(Get-ReadOnlyMounts -Config $config -List $env:PI_VCTL_MOUNT_RO -Workspace $workspace -OriginalHome $originalHome)
# Read before Invoke-WithVctlEnv changes HOME and TMP.
$envPairs = @(Get-EnvPassthrough -List $env:PI_VCTL_ENV)
$memory = if ($env:PI_VCTL_MEMORY) { $env:PI_VCTL_MEMORY } else { '2g' }
$cpus = if ($env:PI_VCTL_CPUS) { $env:PI_VCTL_CPUS } else { '4' }

if (-not (Test-Path -LiteralPath (Join-Path $config.VctlDir 'bin\crx.vmdk')) -or
    -not (Test-Path -LiteralPath $config.PiAgentDir)) {
    throw "Not set up yet. Run: $(Join-Path $PSScriptRoot 'setup.ps1')"
}
New-Item -ItemType Directory -Force -Path $config.CacheDir | Out-Null

$exitCode = 1
$containerName = "pi-$PID"
# Allocating a terminal only works with a real console.
$interactive = -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
$patchStatusPath = Join-Path $config.TempDir "pi-vctl-$containerName.status"
Invoke-WithVctlEnv -Config $config -Body {
    Start-VctlRuntime -Config $config
    Remove-StaleLaunches -Config $config
    $runArgs = @(
        'run', '--rm', '--name', $containerName,
        '-c', $cpus, '-m', $memory,
        '-v', "${workspace}:$containerWorkspace",
        '-v', "$($config.PiAgentDir):/root/.pi/agent",
        '-v', "$($config.CacheDir):/root/.cache",
        '-w', $containerWorkspace
    )
    foreach ($mount in $readOnlyMounts) { $runArgs += '-v', "${mount}:$(ConvertTo-ContainerPath $mount):ro" }
    foreach ($pair in $envPairs) { $runArgs += '-e', $pair }
    $patcher = $null
    if ($interactive) {
        $runArgs += '-it'
        $patcher = Start-AgentPatch -Config $config -Container $containerName -StatusPath $patchStatusPath
    }
    try {
        & $config.Vctl @runArgs $config.Image @piArgs
        $script:exitCode = $LASTEXITCODE
    } finally {
        if ($patcher -and -not $patcher.HasExited) { try { $patcher.Kill() } catch {} }
        Remove-VctlLeftovers -Config $config -Container $containerName
    }
}
if (Test-Path -LiteralPath $patchStatusPath) {
    $patchStatus = (Get-Content -LiteralPath $patchStatusPath -Raw).Trim()
    Remove-Item -LiteralPath $patchStatusPath -ErrorAction SilentlyContinue
    if ($patchStatus -ne 'patched' -and $patchStatus -ne 'already-patched') {
        Write-Warning "Could not patch the container's guest agent ($patchStatus), so long output could freeze the terminal. See the README."
    }
}
exit $exitCode
