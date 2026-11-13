# Checks the launcher's path and setting helpers. Needs no vctl and no network.
# A plain script rather than Pester: Windows ships Pester 3.4, whose syntax Pester 5 dropped.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib\common.ps1')

$script:failures = 0
function Test-Case([string] $Name, [scriptblock] $Body) {
    try { & $Body; Write-Host "PASS $Name" }
    catch { $script:failures++; Write-Host "FAIL ${Name}: $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-Equal($Actual, $Expected) {
    $a = @($Actual) -join '|'
    $e = @($Expected) -join '|'
    if ($a -cne $e) { throw "expected '$e', got '$a'" }
}
function Assert-Throws([scriptblock] $Body, [string] $Pattern) {
    try { & $Body } catch {
        if ($Pattern -and $_.Exception.Message -notmatch $Pattern) { throw "wrong error: $($_.Exception.Message)" }
        return
    }
    throw 'did not throw'
}

# A fake profile in a temp folder, so the tests never depend on the real home folder.
$tmp = Join-Path ([IO.Path]::GetTempPath()) "pi-vctl-unit-$PID"
$homeDir = Join-Path $tmp 'home\me'
$project = Join-Path $tmp 'proj'
$reference = Join-Path $tmp 'ref'
foreach ($dir in $project, $reference, (Join-Path $project 'sub'), (Join-Path $tmp 'a,b'),
                 (Join-Path $homeDir '.ssh\keys'), (Join-Path $homeDir 'AppData\Local'), (Join-Path $homeDir 'code')) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
Set-Content -LiteralPath (Join-Path $project 'file.txt') 'x'
$config = [pscustomobject]@{ Profile = $homeDir }

try {
    Test-Case 'ConvertTo-ContainerPath lowercases the drive and flips slashes' {
        Assert-Equal (ConvertTo-ContainerPath 'D:\dev\app') '/d/dev/app'
        Assert-Equal (ConvertTo-ContainerPath 'C:\a b\C') '/c/a b/C'
    }

    Test-Case 'Test-PathInside matches whole folder names, ignoring case' {
        Assert-Equal (Test-PathInside -Path 'C:\a\b' -Parent 'C:\a') $true
        Assert-Equal (Test-PathInside -Path 'C:\A' -Parent 'c:\a\') $true
        Assert-Equal (Test-PathInside -Path 'C:\ab' -Parent 'C:\a') $false
        Assert-Equal (Test-PathInside -Path 'C:\a' -Parent 'C:\a\b') $false
    }

    Test-Case 'Assert-SafeMount accepts a project and trims the trailing backslash' {
        Assert-Equal (Assert-SafeMount -Config $config -Path "$project\") $project
    }
    Test-Case 'Assert-SafeMount accepts a folder under home that is not sensitive' {
        Assert-Equal (Assert-SafeMount -Config $config -Path (Join-Path $homeDir 'code')) (Join-Path $homeDir 'code')
    }
    Test-Case 'Assert-SafeMount refuses a drive root' {
        Assert-Throws { Assert-SafeMount -Config $config -Path 'C:\' } 'drive root'
    }
    Test-Case 'Assert-SafeMount refuses a UNC path' {
        Assert-Throws { Assert-SafeMount -Config $config -Path '\\localhost\C$\Windows' }
    }
    Test-Case 'Assert-SafeMount refuses a file' {
        Assert-Throws { Assert-SafeMount -Config $config -Path (Join-Path $project 'file.txt') } 'Not a folder'
    }
    Test-Case 'Assert-SafeMount refuses a missing folder' {
        Assert-Throws { Assert-SafeMount -Config $config -Path (Join-Path $tmp 'missing') }
    }
    Test-Case 'Assert-SafeMount refuses a comma' {
        Assert-Throws { Assert-SafeMount -Config $config -Path (Join-Path $tmp 'a,b') } 'comma'
    }
    Test-Case 'Assert-SafeMount refuses home and its parents' {
        Assert-Throws { Assert-SafeMount -Config $config -Path $homeDir } 'home folder'
        Assert-Throws { Assert-SafeMount -Config $config -Path (Join-Path $tmp 'home') } 'home folder'
    }
    Test-Case 'Assert-SafeMount refuses sensitive folders and their subfolders' {
        Assert-Throws { Assert-SafeMount -Config $config -Path (Join-Path $homeDir '.ssh') } 'sensitive'
        Assert-Throws { Assert-SafeMount -Config $config -Path (Join-Path $homeDir '.ssh\keys') } 'sensitive'
        Assert-Throws { Assert-SafeMount -Config $config -Path (Join-Path $homeDir 'AppData\Local') } 'sensitive'
    }
    Test-Case 'Assert-SafeMount also checks the original HOME' {
        $other = [pscustomobject]@{ Profile = 'C:\nobody' }
        Assert-Throws { Assert-SafeMount -Config $other -Path (Join-Path $homeDir '.ssh') -OriginalHome $homeDir } 'sensitive'
    }

    Test-Case 'Get-ReadOnlyMounts returns nothing for an empty list' {
        Assert-Equal @(Get-ReadOnlyMounts -Config $config -List '' -Workspace $project).Count 0
        Assert-Equal @(Get-ReadOnlyMounts -Config $config -List ' ; ' -Workspace $project).Count 0
    }
    Test-Case 'Get-ReadOnlyMounts splits on semicolons and strips quotes' {
        Assert-Equal (Get-ReadOnlyMounts -Config $config -List "`"$reference`"; $homeDir\code" -Workspace $project) @($reference, (Join-Path $homeDir 'code'))
    }
    Test-Case 'Get-ReadOnlyMounts combines several lists, as from the variable and repeated options' {
        Assert-Equal (Get-ReadOnlyMounts -Config $config -List @($null, $reference, "$homeDir\code;") -Workspace $project) @($reference, (Join-Path $homeDir 'code'))
    }
    Test-Case 'Get-ReadOnlyMounts refuses folders that overlap the workspace or each other' {
        Assert-Throws { Get-ReadOnlyMounts -Config $config -List (Join-Path $project 'sub') -Workspace $project } 'overlaps'
        Assert-Throws { Get-ReadOnlyMounts -Config $config -List $project -Workspace (Join-Path $project 'sub') } 'overlaps'
        Assert-Throws { Get-ReadOnlyMounts -Config $config -List "$reference;$reference" -Workspace $project } 'overlaps'
    }
    Test-Case 'Get-ReadOnlyMounts applies the same safety checks' {
        Assert-Throws { Get-ReadOnlyMounts -Config $config -List (Join-Path $homeDir '.ssh') -Workspace $project } 'sensitive'
    }

    Test-Case 'Get-EnvPassthrough passes set variables and skips unset ones' {
        $env:PI_VCTL_UNIT_A = 'a b'
        Remove-Item Env:\PI_VCTL_UNIT_B -ErrorAction SilentlyContinue
        Assert-Equal (Get-EnvPassthrough -List 'PI_VCTL_UNIT_A; PI_VCTL_UNIT_B;' 3>$null) 'PI_VCTL_UNIT_A=a b'
        Assert-Equal @(Get-EnvPassthrough -List '').Count 0
    }
    Test-Case 'Get-EnvPassthrough refuses values vctl would split' {
        $env:PI_VCTL_UNIT_A = 'a,b'
        Assert-Throws { Get-EnvPassthrough -List 'PI_VCTL_UNIT_A' } 'comma'
        $env:PI_VCTL_UNIT_A = 'say "hi"'
        Assert-Throws { Get-EnvPassthrough -List 'PI_VCTL_UNIT_A' } 'quote'
    }
    Test-Case 'Get-EnvPassthrough refuses invalid names' {
        Assert-Throws { Get-EnvPassthrough -List 'BAD-NAME' } 'invalid'
        Assert-Throws { Get-EnvPassthrough -List 'A=B' } 'invalid'
    }

    function Parse { ConvertFrom-LauncherArgs -Arguments $args }
    Test-Case 'ConvertFrom-LauncherArgs passes everything to pi without launcher options' {
        $o = Parse -p 'list the tests' --model x
        Assert-Equal $o.Command 'run'
        Assert-Equal $o.PiArgs @('-p', 'list the tests', '--model', 'x')
        Assert-Equal @((Parse).PiArgs).Count 0
    }
    Test-Case 'ConvertFrom-LauncherArgs reads options in both spellings, then stops at the first pi argument' {
        $o = Parse --memory 4g --cpus=8 --workspace D:\w --mount-ro A --mount-ro=B --env X --env Y -c --memory 1g
        Assert-Equal $o.Memory '4g'
        Assert-Equal $o.Cpus '8'
        Assert-Equal $o.Workspace 'D:\w'
        Assert-Equal $o.MountRo @('A', 'B')
        Assert-Equal $o.Env @('X', 'Y')
        Assert-Equal $o.PiArgs @('-c', '--memory', '1g')
    }
    Test-Case 'ConvertFrom-LauncherArgs drops the first -- and passes the rest to pi' {
        # Quoted, because PowerShell drops a bare -- in calls made inside a session.
        $o = Parse --memory 4g '--' --help '--' x
        Assert-Equal $o.Command 'run'
        Assert-Equal $o.PiArgs @('--help', '--', 'x')
    }
    Test-Case 'ConvertFrom-LauncherArgs leaves pi subcommands and unknown options to pi' {
        Assert-Equal (Parse update self).PiArgs @('update', 'self')
        Assert-Equal (Parse --plan --update).PiArgs @('--plan', '--update')
        Assert-Equal (Parse --MEMORY 4g).PiArgs @('--MEMORY', '4g')
    }
    Test-Case 'ConvertFrom-LauncherArgs parses commands' {
        Assert-Equal (Parse -h).Command 'help'
        Assert-Equal (Parse --help).Command 'help'
        Assert-Equal (Parse --rebuild).Command 'rebuild'
        $o = Parse --update
        Assert-Equal "$($o.Command) [$($o.Version)]" 'update []'
        Assert-Equal (Parse --update 1.6.0).Version '1.6.0'
        Assert-Equal (Parse --update=1.6.0).Version '1.6.0'
    }
    Test-Case 'ConvertFrom-LauncherArgs refuses commands mixed with anything else' {
        Assert-Throws { Parse --update 1.6.0 -p x } 'no other arguments'
        Assert-Throws { Parse --rebuild 1.6.0 } 'no other arguments'
        Assert-Throws { Parse --memory 4g --update } 'cannot be combined'
        Assert-Throws { Parse --update --rebuild } 'cannot be combined'
        Assert-Throws { Parse --rebuild=yes } 'takes no value'
    }
    Test-Case 'ConvertFrom-LauncherArgs refuses an option without its value' {
        Assert-Throws { Parse --memory } 'needs a value'
    }
} finally {
    Remove-Item Env:\PI_VCTL_UNIT_A -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures) { Write-Host "$script:failures failed." -ForegroundColor Red; exit 1 }
Write-Host 'All passed.'
