# Shows what a container can reach on the network. Sends no credentials.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib\common.ps1')
$config = Get-PiVctlConfig

$nic = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.InterfaceAlias -notmatch 'VMware' } | Select-Object -First 1
$hostIp = $nic.IPv4Address.IPAddress
$gateway = $nic.IPv4DefaultGateway.NextHop
$models = Get-Content -LiteralPath (Join-Path $config.PiDir 'agent\models.json') -Raw | ConvertFrom-Json

$targets = @(
    @{ label = 'host RPC'; host = $hostIp; port = 135 }
    @{ label = 'host SMB'; host = $hostIp; port = 445 }
    @{ label = 'LAN gateway HTTP'; host = $gateway; port = 80 }
    @{ label = 'LAN gateway HTTPS'; host = $gateway; port = 443 }
)
foreach ($provider in $models.providers.PSObject.Properties) {
    $uri = [Uri]$provider.Value.baseUrl
    $targets += @{ label = "model provider $($provider.Name)"; host = $uri.Host; port = $uri.Port }
}
$targets += @{ label = 'npm registry'; host = 'registry.npmjs.org'; port = 443 }

$work = Join-Path $config.TempDir "pi-vctl-netprobe-$PID"
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $work 'targets.json'), (ConvertTo-Json -InputObject $targets -Depth 3))
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'net-probe.js') -Destination $work
    Invoke-WithVctlEnv -Config $config -Body {
        Start-VctlRuntime -Config $config
        try {
            & $config.Vctl run --rm --name "pi-netprobe-$PID" -m 1g -v "${work}:/workspace" --entrypoint node $config.Image /workspace/net-probe.js
        } finally {
            Remove-VctlLeftovers -Config $config -Container "pi-netprobe-$PID"
        }
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
