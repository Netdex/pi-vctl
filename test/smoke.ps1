# Sends one prompt to the configured model and checks that pi can write through the mount.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib\common.ps1')
$config = Get-PiVctlConfig

# Inside the repo, because the launcher refuses to mount anything under AppData.
$work = Join-Path $PSScriptRoot ".smoke-$PID"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:PI_VCTL_WORKSPACE = $work
try {
    $prompt = 'Use the bash tool to run exactly: echo PI_VCTL_OK > smoke.txt && uname -s > kernel.txt . Then reply with one word: DONE'
    $output = & pwsh -NoProfile -File (Join-Path $root 'pi-vctl.ps1') --no-session -p $prompt 2>&1 | Out-String
    Write-Host $output
    $marker = Join-Path $work 'smoke.txt'
    $kernel = Join-Path $work 'kernel.txt'
    if (-not (Test-Path -LiteralPath $marker)) { throw 'FAILED: smoke.txt did not reach the host.' }
    if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne 'PI_VCTL_OK') { throw 'FAILED: smoke.txt has the wrong contents.' }
    if ((Get-Content -LiteralPath $kernel -Raw).Trim() -ne 'Linux') { throw 'FAILED: the command did not run in Linux.' }
    Write-Host 'PASS: the model ran a tool in Linux, and its file reached the host.'
} finally {
    Remove-Item Env:\PI_VCTL_WORKSPACE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
