param([Parameter(Mandatory)][string]$Executable, [switch]$CheckForeground)
$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path $Executable).Path
$parent = if ($env:RUNE_TEST_DIR) { $env:RUNE_TEST_DIR } else { [IO.Path]::GetTempPath() }
$folder = Join-Path $parent ('rune-host-' + [guid]::NewGuid().ToString('N'))
$id = 'org.rune.' + [guid]::NewGuid().ToString('N')
$env:RUNE_HANDOFF_TEST_ID = $id
$env:RUNE_HANDOFF_TEST_DIR = $folder
New-Item -ItemType Directory $folder | Out-Null
$stdout = Join-Path $folder 'owner.stdout'
$stderr = Join-Path $folder 'owner.stderr'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RuneHandoffWindow {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr FindWindow(IntPtr name, string title);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr window);
    [DllImport("kernel32.dll")]
    public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")]
    public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")]
    public static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr handle);
}
'@
function Wait-Until([scriptblock]$test, [string]$what) {
    $deadline = [DateTime]::UtcNow.AddSeconds(40)
    while (-not (& $test)) {
        if ($owner.HasExited -or [DateTime]::UtcNow -gt $deadline) {
            throw "Owner exited or timed out waiting for $what"
        }
        Start-Sleep -Milliseconds 20
    }
}
function Read-Events {
    Get-ChildItem $folder -Filter 'host-*.event' | Sort-Object Name | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }
}
function Has-Event([string]$event) {
    return (Read-Events) -contains $event
}
function Launch([string[]]$launchArgs) {
    & $exe send @launchArgs
    if ($LASTEXITCODE -ne 0) { throw "Second process exited $LASTEXITCODE" }
}
function Hold-Owner([int]$processId) {
    # SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, retained across process exit.
    $handle = [RuneHandoffWindow]::OpenProcess(0x101000, $false, $processId)
    if ($handle -eq [IntPtr]::Zero) { throw "Could not open PID $processId" }
    return $handle
}
function Wait-ForCleanExit([IntPtr]$handle) {
    if ([RuneHandoffWindow]::WaitForSingleObject($handle, 25000) -ne 0) { throw 'Owner did not exit in time' }
    [uint32]$code = 0
    if (-not [RuneHandoffWindow]::GetExitCodeProcess($handle, [ref]$code) -or $code -ne 0) {
        throw "Owner exit code $code"
    }
}
$owner = $null
$processHandle = [IntPtr]::Zero
try {
    $owner = Start-Process -FilePath $exe -ArgumentList @('owner','rune-check://cold1','rune-check://cold2') -PassThru -RedirectStandardError $stderr -RedirectStandardOutput $stdout
    $processHandle = Hold-Owner $owner.Id
    Wait-Until { Has-Event 'claimed' } 'claim'
    Write-Host "Claimed $id by PID $($owner.Id)"
    Launch @('rune-check://before-window')
    New-Item -ItemType File (Join-Path $folder 'host.start') | Out-Null
    Wait-Until { (Has-Event 'ready') -and (Has-Event 'rune-check://before-window') } 'cold links and first frame'
    $window = [RuneHandoffWindow]::FindWindow([IntPtr]::Zero, "Rune single-instance $id")
    if ($window -eq [IntPtr]::Zero) { throw 'Owner window has no HWND' }
    Launch @('rune-check://forwarded')
    Wait-Until { Has-Event 'rune-check://forwarded' } 'forwarded URL'
    Launch @()
    Wait-Until { Has-Event 'reopen true' } 'visible reopen hook'
    Launch @('rune-check://hide')
    Wait-Until { -not [RuneHandoffWindow]::IsWindowVisible($window) } 'hidden window'
    $before = [RuneHandoffWindow]::GetForegroundWindow()
    Launch @()
    Wait-Until { (Has-Event 'reopen false') -and [RuneHandoffWindow]::IsWindowVisible($window) } 'reopened hidden HWND'
    if ($CheckForeground) {
        if ($before -eq $window) { throw 'The hidden window still held the foreground' }
        Wait-Until { [RuneHandoffWindow]::GetForegroundWindow() -eq $window } 'restored foreground HWND'
    }
    Write-Host "Foreground HWND before reopening $before; after reopening $([RuneHandoffWindow]::GetForegroundWindow()); owner $window"
    Launch @('rune-check://quit')
    Wait-ForCleanExit $processHandle
    $expected = @('claimed','rune-check://cold1','rune-check://cold2','rune-check://before-window',
                  'rune-check://forwarded','reopen true','rune-check://hide','reopen false','rune-check://quit','ended')
    $actual = @((Read-Events) | Where-Object { $_ -ne 'ready' -and $_ -ne 'created' })
    if (($actual -join '|') -ne ($expected -join '|')) { throw "Unexpected owner events: $actual" }
    Write-Host "Owner HWND $window served: $actual"
    foreach ($mode in @('relaunch-tx', 'relaunch-handle')) {
        [void][RuneHandoffWindow]::CloseHandle($processHandle)
        $processHandle = [IntPtr]::Zero
        $owner.Dispose()
        $owner = Start-Process -FilePath $exe -ArgumentList $mode -PassThru
        $processHandle = Hold-Owner $owner.Id
        Wait-ForCleanExit $processHandle
        $file = Join-Path $folder "$mode.successor"
        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        while (-not (Test-Path $file) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
        $proof = (Get-Content -Raw $file) -split ' '
        if ($proof.Count -ne 3 -or [int]$proof[0] -eq $owner.Id -or [int]$proof[1] -ne $owner.Id -or $proof[2] -ne 'false') {
            throw "$mode successor did not open after its predecessor exited: $proof"
        }
        $successor = [RuneHandoffWindow]::OpenProcess(0x101000, $false, [uint32]$proof[0])
        if ($successor -ne [IntPtr]::Zero) {
            try { Wait-ForCleanExit $successor } finally { [void][RuneHandoffWindow]::CloseHandle($successor) }
        }
        Write-Host "$mode opened a successor: $proof"
    }
} catch {
    Read-Events | Write-Host
    if ($owner) {
        $owner.Refresh()
        Write-Host "owner pid=$($owner.Id) exited=$($owner.HasExited) exitCode=$($owner.ExitCode)"
        $hwnd = [RuneHandoffWindow]::FindWindow([IntPtr]::Zero, "Rune single-instance $id")
        Write-Host "hwnd=$hwnd visible=$([RuneHandoffWindow]::IsWindowVisible($hwnd)) minimized=$([RuneHandoffWindow]::IsIconic($hwnd))"
    }
    foreach ($file in @($stdout, $stderr)) {
        if (Test-Path $file) { Get-Content $file -Tail 80 | Write-Host }
    }
    throw
} finally {
    if ($processHandle -ne [IntPtr]::Zero) { [void][RuneHandoffWindow]::CloseHandle($processHandle) }
    if ($owner -and -not $owner.HasExited) { $owner.Kill(); $owner.WaitForExit() }
    if ($owner) { $owner.Dispose() }
    Remove-Item Env:RUNE_HANDOFF_TEST_ID,Env:RUNE_HANDOFF_TEST_DIR
    # Process redirection can keep its file open briefly after the kernel signals exit.
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        try { Remove-Item $folder -Recurse -Force; break } catch {
            if ($attempt -eq 39) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
}
