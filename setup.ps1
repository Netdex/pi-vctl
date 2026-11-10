# Prepares the vctl runtime and the pi image. Safe to re-run.
#   .\setup.ps1              first-time setup
#   .\setup.ps1 -Rebuild     rebuild the image, for example after editing image\Dockerfile
param(
    [switch] $Rebuild
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$config = Get-PiVctlConfig

Invoke-WithVctlEnv -Config $config -Body {
    Write-Host 'Starting the vctl runtime...'
    Start-VctlRuntime -Config $config

    # vctl only checks that this file exists. Containers boot from the kernel and
    # initrd in Workstation's vkd folder, and the file's download host no longer exists.
    $disk = Join-Path $config.VctlDir 'bin\crx.vmdk'
    if (-not (Test-Path -LiteralPath $disk)) {
        New-Item -ItemType Directory -Force -Path (Split-Path $disk) | Out-Null
        & $config.VDiskManager -c -s 1GB -a lsilogic -t 0 $disk | Out-Null
        if (-not (Test-Path -LiteralPath $disk)) { throw "Could not create $disk" }
        Write-Host "Created blank $disk"
    }

    $images = & $config.Vctl images 2>&1 | Out-String
    $hasImage = $images.Contains($config.Image)
    if ($Rebuild -or -not $hasImage) {
        # vctl build refuses to overwrite a tag, so build under another one and only
        # replace the working image once the build has succeeded.
        $building = $config.Image -replace ':.*$', ':building'
        # vctl cannot replace an image that any container, running or stopped, still uses.
        $users = @(& $config.Vctl ps -a 2>&1 | Out-String -Stream |
            Where-Object { $_ -match "^\S+\s+$([regex]::Escape($config.Image))\s" } | ForEach-Object { ($_ -split '\s+')[0] })
        if ($hasImage -and $users.Count) {
            throw "These containers still use $($config.Image): $($users -join ', '). Exit pi or run 'vctl rm -f <name>', then run setup again."
        }
        if ($images.Contains($building)) { & $config.Vctl rmi $building }
        Write-Host "Building $($config.Image)..."
        & $config.Vctl build -t $building (Join-Path $PSScriptRoot 'image')
        if ($LASTEXITCODE -ne 0) { throw "vctl build failed with exit code $LASTEXITCODE. Run setup again; a retry can succeed." }
        if ($hasImage) {
            # rmi exits 0 even when it skips the image, so read its result instead.
            $removed = & $config.Vctl rmi $config.Image 2>&1 | Out-String
            if ($removed -notmatch 'REMOVED') { throw "Could not replace $($config.Image): $($removed.Trim())" }
        }
        & $config.Vctl tag $building $config.Image
        if ($LASTEXITCODE -ne 0) { throw "Could not tag $building as $($config.Image)" }
        & $config.Vctl rmi $building

        # vctl build leaves the runtime hung: later runs print nothing and never start.
        # Restarting it fixes that, but would also stop running containers.
        $running = Get-VctlRunningContainers -Config $config
        if ($running.Count) {
            Write-Warning "Not restarting the vctl runtime while containers are running: $($running -join ', '). If pi then fails to start, run 'vctl system stop' once they have exited."
        } else {
            Write-Host 'Restarting the vctl runtime...'
            & $config.Vctl system stop | Out-Null
            Start-VctlRuntime -Config $config
            # The first run after a restart unpacks the image, which takes about a minute.
            Write-Host 'Preparing the image...'
            try {
                & $config.Vctl run --rm --name "pi-setup-$PID" --entrypoint /bin/true $config.Image | Out-Null
            } finally {
                Remove-VctlLeftovers -Config $config -Container "pi-setup-$PID"
            }
        }
    } else {
        Write-Host "Image $($config.Image) already exists. Use -Rebuild to replace it."
    }
}
Write-Host 'Setup complete. Run pi-vctl.ps1 from a project folder.'
