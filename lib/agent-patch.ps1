# Turns off the terminal log in one container's guest agent. See image\agent-patch.sh.
# pi-vctl.ps1 starts this hidden, in its own console, while pi runs: vctl execvm panics
# unless one of its standard handles is a console, and must not draw on pi's.
# Writes the outcome to StatusPath: patched, already-patched, error <reason>, or timeout.
# Writes nothing if the launcher has exited.
param(
    [Parameter(Mandatory)] [string] $Vctl,
    [Parameter(Mandatory)] [string] $Container,
    [Parameter(Mandatory)] [int] $ParentId,
    [Parameter(Mandatory)] [string] $StatusPath
)
$ErrorActionPreference = 'Stop'
# execvm runs this in the VM. No double quotes: it goes inside a quoted argument.
$find = 'for p in /proc/[0-9]*; do if [ -e $p/root/opt/pi-vctl/agent-patch.sh ]; then exec /bin/sh $p/root/opt/pi-vctl/agent-patch.sh; fi; done; echo RESULT not-ready'
$deadline = [DateTime]::UtcNow.AddMinutes(3)
$status = 'timeout'

while ([DateTime]::UtcNow -lt $deadline) {
    # Nobody would read the status.
    if (-not (Get-Process -Id $ParentId -ErrorAction SilentlyContinue)) { exit }
    # execvm while vctl run is still unpacking a new image makes the run hang.
    if (-not ((& $Vctl ps 2>&1 | Out-String) -match "(?m)^$([regex]::Escape($Container))\s")) {
        Start-Sleep -Milliseconds 500
        continue
    }
    # execvm's exit code is always 0, so read its output.
    $info = [Diagnostics.ProcessStartInfo]::new($Vctl, "execvm -c $Container /bin/sh -c `"$find`"")
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(60000)) { try { $process.Kill() } catch {} }
    # execvm adds terminal escape codes, such as a window title.
    $text = ($stdout.Result + "`n" + $stderr.Result) -replace '\x1b(\][^\x07\x1b]*(\x07|\x1b\\)|\[[0-9;?]*[ -/]*[@-~])', ''
    $results = [regex]::Matches($text, 'RESULT ([^\r\n]*)')
    if ($results.Count) {
        $last = $results[$results.Count - 1].Groups[1].Value.Trim()
        if ($last -match '^(patched|already-patched|error)\b') { $status = $last; break }
    }
    Start-Sleep -Milliseconds 500
}
Set-Content -LiteralPath $StatusPath -Value $status -Encoding ascii
