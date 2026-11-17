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
function Send-Wire([byte[]]$frame, [bool]$readAnswer, [int]$generation = 0) {
    $name = PipeName
    if ($generation) { $name += "-$generation" }
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $name, [IO.Pipes.PipeDirection]::InOut,
                                                  [IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $pipe.Connect(2000)
        $pipe.Write($frame, 0, $frame.Length)
        $pipe.Flush()
        if ($readAnswer) {
            # The server keeps its reply available while the connected sender is descheduled.
            Start-Sleep -Milliseconds 200
            $answer = New-Object byte[] 1
            $read = $pipe.ReadAsync($answer, 0, 1)
            if (!$read.Wait(3000)) { throw 'Timed out reading the reply from a connected handoff owner' }
            if ($read.Result -ne 1) { throw 'The owner disconnected before its handoff reply was read' }
            return [char]$answer[0]
        }
    } finally { $pipe.Dispose() }
}
function Frame([byte[]]$body) {
    return [byte[]]([Text.Encoding]::ASCII.GetBytes("rune-instance 2`0") +
                    [BitConverter]::GetBytes([uint32]$body.Length) + $body)
}
function Wait-UnreadReply($pipe) {
    if (!('RuneHandoffPipeProbe' -as [type])) {
        Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RuneHandoffPipeProbe {
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool PeekNamedPipe(SafePipeHandle handle, IntPtr buffer, uint size,
        IntPtr read, out uint available, IntPtr remaining);
    public static uint Available(SafePipeHandle handle) {
        uint available;
        if (!PeekNamedPipe(handle, IntPtr.Zero, 0, IntPtr.Zero, out available, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return available;
    }
}
'@
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ([RuneHandoffPipeProbe]::Available($pipe.SafePipeHandle) -eq 0) {
        if ($timer.Elapsed.TotalSeconds -gt 3) { throw 'Owner never queued a reply for the open client' }
        Start-Sleep -Milliseconds 5
    }
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

    Set-Scenario 'release-with-unread-reply'
    $owner = Launch @('successor')
    Wait-Marker 'successor.ready' $owner
    Check-Exit (Launch @('send', 'rune://before-release'))
    Wait-Marker 'successor.received' $owner
    $unread = [IO.Pipes.NamedPipeClientStream]::new('.', (PipeName), [IO.Pipes.PipeDirection]::InOut)
    try {
        $unread.Connect(2000)
        [byte[]]$next = Frame ([Text.Encoding]::UTF8.GetBytes('rune://unread-reply'))
        $unread.Write($next, 0, $next.Length)
        $unread.Flush()
        Wait-UnreadReply $unread
        Touch 'successor.release'
        Wait-Marker 'successor.released' $owner
        Touch 'successor.finish'
        Check-Exit $owner
        'PASS release finishes with a queued acknowledgement that the open client has not read'
    } finally { $unread.Dispose() }

    Set-Scenario 'unresponsive'
    $firstDirectory = $env:RUNE_HANDOFF_TEST_DIR
    $first = Launch @('successor')
    Wait-Marker 'successor.ready' $first
    Check-Exit (Launch @('send', 'rune://first-generation/awake'))
    Wait-Marker 'successor.received' $first
    # Keep the actual Rune owner busy reading an incomplete launch on generation zero.
    $stalled = [IO.Pipes.NamedPipeClientStream]::new('.', (PipeName), [IO.Pipes.PipeDirection]::InOut)
    try {
        $stalled.Connect(2000)
        $stalled.WriteByte(0x72)
        $stalled.Flush()
        $env:RUNE_HANDOFF_TEST_DIR = Join-Path $firstDirectory 'fallback'
        [void][IO.Directory]::CreateDirectory($env:RUNE_HANDOFF_TEST_DIR)
        $owner = Launch @('fallback')
        Wait-Marker 'fallback.ready' $owner
        $answer = Send-Wire (Frame ([Text.Encoding]::UTF8.GetBytes('rune://generation-one/direct'))) $true 1
        if ($answer -cne 'A') { throw "Generation one did not serve the probe. Reply was $answer" }
        Check-Exit (Launch @('send', 'rune://fallback/generation'))
        Wait-Marker 'fallback.received' $owner
        Touch 'fallback.release'
        Wait-Marker 'fallback.released' $owner
        Verify-Events 'fallback' @('rune://generation-one/direct', 'rune://fallback/generation')
        Touch 'fallback.finish'
        Check-Exit $owner
        $env:RUNE_HANDOFF_TEST_DIR = $firstDirectory
        Touch 'successor.release'
        Wait-Marker 'successor.released' $first
        Verify-Events 'successor' @('rune://first-generation/awake')
        Touch 'successor.finish'
        Check-Exit $first
        'PASS a stalled Rune owner keeps generation zero while a new owner serves later launches'
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
