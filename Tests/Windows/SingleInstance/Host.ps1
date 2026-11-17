param([Parameter(Mandatory)][string]$Executable)
$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path $Executable).Path
$folder = Join-Path ([IO.Path]::GetTempPath()) ('rune-host-' + [guid]::NewGuid().ToString('N'))
$id = 'org.rune.' + [guid]::NewGuid().ToString('N')
$env:RUNE_HANDOFF_TEST_ID = $id
$env:RUNE_HANDOFF_TEST_DIR = $folder
New-Item -ItemType Directory $folder | Out-Null
$log = Join-Path $folder 'host.events'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RuneHandoffWindow {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr FindWindow(string name, string title);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);
}
'@
function Wait-Until([scriptblock]$test, [string]$what) {
    $deadline = [DateTime]::UtcNow.AddSeconds(40)
    while (-not (& $test)) {
        if ($owner.HasExited -or [DateTime]::UtcNow -gt $deadline) {
            if (Test-Path $log) { Get-Content $log | Write-Host }
            throw "Owner exited or timed out waiting for $what"
        }
        Start-Sleep -Milliseconds 20
    }
}
function Has-Event([string]$event) {
    return (Test-Path $log) -and ((Get-Content $log) -contains $event)
}
function Launch([string[]]$launchArgs) {
    & $exe send @launchArgs
    if ($LASTEXITCODE -ne 0) { throw "Second process exited $LASTEXITCODE" }
}
$owner = $null
try {
    $owner = Start-Process -FilePath $exe -ArgumentList @('owner','rune-check://cold1','rune-check://cold2') -PassThru
    Wait-Until { Has-Event 'claimed' } 'claim'
    Launch @('rune-check://before-window')
    New-Item -ItemType File (Join-Path $folder 'host.start') | Out-Null
    Wait-Until { (Has-Event 'ready') -and (Has-Event 'rune-check://before-window') } 'cold links and first frame'
    $window = [RuneHandoffWindow]::FindWindow($null, "Rune single-instance $id")
    if ($window -eq 0) { throw 'Owner window has no HWND' }
    Launch @('rune-check://forwarded')
    Wait-Until { Has-Event 'rune-check://forwarded' } 'forwarded URL'
    Launch @()
    Wait-Until { Has-Event 'reopen true' } 'visible reopen hook'
    Launch @('rune-check://hide')
    Wait-Until { -not [RuneHandoffWindow]::IsWindowVisible($window) } 'hidden window'
    Launch @()
    Wait-Until { (Has-Event 'reopen false') -and [RuneHandoffWindow]::IsWindowVisible($window) } 'reopened hidden HWND'
    Launch @('rune-check://quit')
    if (-not $owner.WaitForExit(20000) -or $owner.ExitCode -ne 0) { throw 'Owner failed to finish' }
    $expected = @('claimed','rune-check://cold1','rune-check://cold2','rune-check://before-window',
                  'rune-check://forwarded','reopen true','rune-check://hide','reopen false','rune-check://quit','ended')
    $actual = @((Get-Content $log) | Where-Object { $_ -ne 'ready' })
    if (($actual -join '|') -ne ($expected -join '|')) { throw "Unexpected owner events: $actual" }
    Write-Host "Owner HWND $window served: $actual"
    foreach ($mode in @('relaunch-tx', 'relaunch-handle')) {
        $owner = Start-Process -FilePath $exe -ArgumentList $mode -PassThru
        if (-not $owner.WaitForExit(25000) -or $owner.ExitCode -ne 0) { throw "$mode failed to exit" }
        $file = Join-Path $folder "$mode.successor"
        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        while (-not (Test-Path $file) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
        $proof = (Get-Content -Raw $file) -split ' '
        if ($proof.Count -ne 3 -or [int]$proof[0] -eq $owner.Id -or [int]$proof[1] -ne $owner.Id -or $proof[2] -ne 'false') {
            throw "$mode successor did not open after its predecessor exited: $proof"
        }
        Write-Host "$mode opened a successor: $proof"
    }
} finally {
    if ($owner -and -not $owner.HasExited) { $owner.Kill(); $owner.WaitForExit() }
    Remove-Item Env:RUNE_HANDOFF_TEST_ID,Env:RUNE_HANDOFF_TEST_DIR
    Remove-Item $folder -Recurse -Force
}
