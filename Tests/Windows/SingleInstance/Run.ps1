# Run in Windows PowerShell with Swift installed, or supply a built HandoffClient.exe.
param([string]$Executable)
$ErrorActionPreference = 'Stop'
if (!$Executable) {
    & swift build --package-path $PSScriptRoot --product HandoffClient
    if ($LASTEXITCODE -ne 0) { throw 'Failed to build HandoffClient' }
    $bin = & swift build --package-path $PSScriptRoot --show-bin-path
    $Executable = Join-Path $bin 'HandoffClient.exe'
}
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$working = Join-Path ([IO.Path]::GetTempPath()) ('RuneHandoff-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($working)
$children = [Collections.Generic.List[Diagnostics.Process]]::new()
$oldID = $env:RUNE_HANDOFF_TEST_ID
$oldDirectory = $env:RUNE_HANDOFF_TEST_DIR
function Set-Scenario($name) {
    $env:RUNE_HANDOFF_TEST_ID = 'RuneFixture.' + [guid]::NewGuid().ToString('N')
    $env:RUNE_HANDOFF_TEST_DIR = Join-Path $working $name
    [void][IO.Directory]::CreateDirectory($env:RUNE_HANDOFF_TEST_DIR)
}
function File-Path($name) { Join-Path $env:RUNE_HANDOFF_TEST_DIR $name }
function Touch($name) { [IO.File]::WriteAllText((File-Path $name), '') }
function Check-Exit($process) {
    if (!$process.WaitForExit(30000)) { throw "Process $($process.Id) timed out" }
    if ($process.ExitCode -ne 0) {
        $log = $process.StartInfo.Arguments
        throw "Process $($process.Id) ($log) exited $($process.ExitCode)"
    }
}
function Wait-Marker($name, $process) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (!(Test-Path -LiteralPath (File-Path $name))) {
        if ($process.HasExited) { throw "$name was not produced; process exited $($process.ExitCode)" }
        if ($timer.Elapsed.TotalSeconds -gt 30) { throw "Timed out waiting for $name" }
        Start-Sleep -Milliseconds 15
    }
}
function Launch([string[]]$values) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    # Each test token is a flag or URL without spaces or quotes.
    $start.Arguments = $values -join ' '
    $start.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($start)
    $children.Add($process)
    return $process
}
function PipeName {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $bytes = New-Object byte[] $sid.BinaryLength
    $sid.GetBinaryForm($bytes, 0)
    $hex = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
    return "rune-instance-$([Diagnostics.Process]::GetCurrentProcess().SessionId)-$hex-$env:RUNE_HANDOFF_TEST_ID"
}
function Send-Wire([byte[]]$frame, [bool]$readAnswer) {
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', (PipeName), [IO.Pipes.PipeDirection]::InOut,
                                                  [IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $pipe.Connect(2000)
        $pipe.Write($frame, 0, $frame.Length)
        $pipe.Flush()
        if ($readAnswer) {
            $answer = New-Object byte[] 1
            $read = $pipe.ReadAsync($answer, 0, 1)
            if (!$read.Wait(3000) -or $read.Result -ne 1) { throw 'Missing handoff answer' }
            return [char]$answer[0]
        }
    } finally { $pipe.Dispose() }
}
function Frame([byte[]]$body) {
    return [byte[]]([Text.Encoding]::ASCII.GetBytes("rune-instance 2`0") +
                    [BitConverter]::GetBytes([uint32]$body.Length) + $body)
}
function Verify-Events($mode, [string[]]$expected) {
    [string[]]$seen = ConvertFrom-Json (Get-Content -Raw -Encoding UTF8 -LiteralPath (File-Path "$mode.json"))
    if ($seen.Count -ne $expected.Count -or ($seen -join '|') -cne ($expected -join '|')) {
        throw "Unexpected $mode events: $($seen -join ', ')"
    }
}
try {
    Set-Scenario 'transfer'
    $owner = Launch @('owner')
    Wait-Marker 'owner.ready' $owner
    [byte[]]$legacy = [Text.Encoding]::UTF8.GetBytes("rune-instance 1`0rune://legacy/first")
    Send-Wire $legacy $false
    # Invalid UTF-8 must never produce an empty relaunch or a partial URL.
    Send-Wire (Frame ([byte[]]@(0xc3, 0x28))) $false
    $unicodeURL = 'rune://project/' + [char]0xe9
    Check-Exit (Launch @('send', '--ignored', $unicodeURL, 'https://rune.example/second'))
    Check-Exit (Launch @('send', '--reopen'))
    Wait-Marker 'owner.reopened' $owner
    Touch 'owner.listen'
    Wait-Marker 'owner.received' $owner
    Touch 'owner.begin-quit'
    Wait-Marker 'owner.quitting' $owner
    $answer = Send-Wire (Frame ([Text.Encoding]::UTF8.GetBytes('rune://must-not-be-delivered'))) $true
    if ($answer -cne 'Q') { throw "Expected a quitting acknowledgement, got $answer" }
    $successor = Launch @('successor')
    Wait-Marker 'successor.started' $successor
    Start-Sleep -Milliseconds 200
    if ($successor.HasExited -or (Test-Path (File-Path 'successor.ready'))) {
        throw 'Successor failed to wait for the quitting owner'
    }
    Touch 'owner.release'
    Wait-Marker 'successor.ready' $successor
    Wait-Marker 'owner.released' $owner
    if ($owner.HasExited) { throw 'The original process should remain alive after releasing its name' }
    Check-Exit (Launch @('send', 'rune://successor/awake'))
    Wait-Marker 'successor.received' $successor
    $partial = [IO.Pipes.NamedPipeClientStream]::new('.', (PipeName), [IO.Pipes.PipeDirection]::InOut)
    try {
        $partial.Connect(2000)
        $prefix = [Text.Encoding]::ASCII.GetBytes('rune-inst')
        $partial.Write($prefix, 0, $prefix.Length)
        $partial.Flush()
        Touch 'successor.release'
        Wait-Marker 'successor.released' $successor
    } finally { $partial.Dispose() }
    Verify-Events 'owner' @('reopen', 'rune://legacy/first', $unicodeURL, 'https://rune.example/second')
    Verify-Events 'successor' @('rune://successor/awake')
    Touch 'owner.finish'
    Touch 'successor.finish'
    Check-Exit $owner
    Check-Exit $successor
    'PASS interoperable v1 + ordered buffered Unicode URLs + reopen + invalid UTF-8 rejection'
    'PASS quitting Q + claim after release with both primary processes still alive + secondary forwards to successor'
    'PASS release finishes with an incomplete launch on an open client pipe'

    Set-Scenario 'unresponsive'
    # Hold generation zero without reading. Swift's fallback owner must receive another launch
    # on a later generation while the original named pipe is still present.
    $stalled = [IO.Pipes.NamedPipeServerStream]::new((PipeName), [IO.Pipes.PipeDirection]::InOut, 1)
    try {
        $owner = Launch @('successor')
        Wait-Marker 'successor.ready' $owner
        Check-Exit (Launch @('send', 'rune://fallback/generation'))
        Wait-Marker 'successor.received' $owner
        Touch 'successor.release'
        Wait-Marker 'successor.released' $owner
        Verify-Events 'successor' @('rune://fallback/generation')
        Touch 'successor.finish'
        Check-Exit $owner
        'PASS unresponsive pipe skips to a serving owner on the next generation'
    } finally { $stalled.Dispose() }
} finally {
    foreach ($process in $children) {
        if (!$process.HasExited) { $process.Kill(); [void]$process.WaitForExit(2000) }
        $process.Dispose()
    }
    $env:RUNE_HANDOFF_TEST_DIR = $oldDirectory
    $env:RUNE_HANDOFF_TEST_ID = $oldID
    Remove-Item -LiteralPath $working -Recurse -Force
}
