# Runs pi in a vctl container with the current folder mounted at the same path,
# written Unix-style: D:\dev\app is mounted at /d/dev/app. Run with --help for the options.
# There is deliberately no param block: PowerShell would claim pi's flags too, so
# ConvertFrom-LauncherArgs in lib\common.ps1 parses $args instead.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$options = ConvertFrom-LauncherArgs -Arguments $args

if ($options.Command -eq 'help') {
    Write-Host @'
Runs pi in a VMware Workstation vctl container, with the current folder mounted.

Usage:
  pi-vctl [options] [--] [pi arguments...]
  pi-vctl --update [VERSION]
  pi-vctl --rebuild

Options must come before pi's arguments. The first argument that is not one of them,
or "--", starts pi's arguments. Run "pi-vctl -- --help" for pi's own help.
Inside PowerShell, quote it as '--': PowerShell drops a bare -- before scripts see it.

Options (each overrides its environment variable):
  --memory <size>      Memory limit, such as 2g. The VM gets 512 MB on top.  PI_VCTL_MEMORY (2g)
  --cpus <n>           CPU cores.                                            PI_VCTL_CPUS (4)
  --workspace <dir>    Folder to mount read-write.                           PI_VCTL_WORKSPACE (current folder)
  --mount-ro <dir>     Also mount a folder read-only. Repeatable.            PI_VCTL_MOUNT_RO (dirs separated by ;)
  --env <NAME>         Pass a host variable in. Repeatable.                  PI_VCTL_ENV (names separated by ;)
  -h, --help           Show this help.

Commands:
  --update [VERSION]   Rebuild the image with pi VERSION, default the latest on npm.
  --rebuild            Rebuild the image with the Dockerfile's pi version.

Examples:
  pi-vctl -p "list the failing tests"
  pi-vctl --memory 4g --mount-ro D:\docs --env GITHUB_TOKEN --continue
  pi-vctl -- --memory          # sends --memory to pi
'@
    exit 0
}

if ($options.Command -eq 'rebuild') {
    & (Join-Path $PSScriptRoot 'setup.ps1') -Rebuild
    exit 0
}

if ($options.Command -eq 'update') {
    $version = $options.Version
    if (-not $version) {
        # setup.ps1 needs an exact version: a tag such as "latest" would reuse the cached build step.
        try {
            $version = (Invoke-RestMethod 'https://registry.npmjs.org/@earendil-works/pi-coding-agent/latest').version
        } catch {
            throw "Could not look up the latest pi version ($($_.Exception.Message)). Pass one: --update 1.6.0"
        }
    }
    Write-Host "Updating the pi-vctl image to pi $version..."
    & (Join-Path $PSScriptRoot 'setup.ps1') -PiVersion $version
    exit 0
}

# Options win over environment variables, which win over the defaults.
function Get-Setting($Option, $EnvValue, $Default) {
    if ($Option) { return $Option }
    if ($EnvValue) { return $EnvValue }
    return $Default
}
$config = Get-PiVctlConfig
$piArgs = $options.PiArgs
$originalHome = $env:HOME
$memory = Get-Setting $options.Memory $env:PI_VCTL_MEMORY '2g'
$cpus = Get-Setting $options.Cpus $env:PI_VCTL_CPUS '4'
if ($memory -notmatch '^\d+[mMgG]$') { throw "Memory must be a size such as 512m or 2g, not '$memory'." }
if ($cpus -notmatch '^[1-9]\d*$') { throw "CPUs must be a whole number, not '$cpus'." }
$workspaceInput = Get-Setting $options.Workspace $env:PI_VCTL_WORKSPACE (Get-Location).ProviderPath
$workspace = Assert-SafeMount -Config $config -Path $workspaceInput -OriginalHome $originalHome
$containerWorkspace = ConvertTo-ContainerPath $workspace
$readOnlyMounts = @(Get-ReadOnlyMounts -Config $config -List (@($env:PI_VCTL_MOUNT_RO) + $options.MountRo) -Workspace $workspace -OriginalHome $originalHome)
# Read before Invoke-WithVctlEnv changes HOME and TMP.
$envPairs = @(Get-EnvPassthrough -List (@($env:PI_VCTL_ENV) + $options.Env))

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
