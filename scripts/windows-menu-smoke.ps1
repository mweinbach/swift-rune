# Run on a Windows desktop with a built rune-menu-probe.exe and its Swift runtime.
param([Parameter(Mandatory=$true)][string]$Executable)
$ErrorActionPreference = 'Stop'
if (-not ('RuneMenuSmoke' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public class RuneMenuSmoke : IDisposable {
    public readonly Process App = new Process();
    public readonly ConcurrentQueue<string> Output = new ConcurrentQueue<string>();
    public readonly ConcurrentQueue<string> Errors = new ConcurrentQueue<string>();
    public RuneMenuSmoke(string path) {
        App.StartInfo = new ProcessStartInfo(path) {
            WorkingDirectory = Path.GetDirectoryName(path), UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        App.StartInfo.EnvironmentVariables["RUNE_OPEN_INACTIVE"] = "1";
        App.StartInfo.EnvironmentVariables["RUNE_PLAYGROUND"] = "0";
        App.OutputDataReceived += (s, e) => { if (e.Data != null) Output.Enqueue(e.Data); };
        App.ErrorDataReceived += (s, e) => { if (e.Data != null) Errors.Enqueue(e.Data); };
        App.Start();
        App.BeginOutputReadLine();
        App.BeginErrorReadLine();
    }
    public void Dispose() {
        if (!App.HasExited) App.Kill();
        App.Dispose();
    }
    public bool WaitLine(string value, int seconds) {
        var timer = Stopwatch.StartNew();
        do {
            foreach (var line in Output.ToArray()) if (String.Equals(line, value, StringComparison.Ordinal)) return true;
            if (App.HasExited) break;
            System.Threading.Thread.Sleep(40);
        } while (timer.Elapsed.TotalSeconds < seconds);
        return false;
    }
    delegate bool EnumWindow(IntPtr hwnd, IntPtr data);
    [DllImport("user32")] static extern bool EnumWindows(EnumWindow proc, IntPtr data);
    [DllImport("user32", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int capacity);
    [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32")] public static extern IntPtr GetMenu(IntPtr hwnd);
    [DllImport("user32")] public static extern IntPtr GetSubMenu(IntPtr menu, int index);
    [DllImport("user32")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32")] static extern uint GetMenuState(IntPtr menu, uint index, uint flags);
    [DllImport("user32", CharSet=CharSet.Unicode)] static extern int GetMenuString(IntPtr menu, uint item, StringBuilder label, int capacity, uint flags);
    [DllImport("user32", SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint msg, UIntPtr wp, IntPtr lp, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32", SetLastError=true)] static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("user32")] static extern bool GetKeyboardState([Out] byte[] keys);
    [DllImport("user32")] static extern bool SetKeyboardState(byte[] keys);
    [DllImport("user32")] static extern uint MapVirtualKeyW(uint vk, uint kind);
    [DllImport("kernel32")] static extern uint GetCurrentThreadId();
    [StructLayout(LayoutKind.Sequential)] struct Message { public IntPtr hwnd; public uint msg; public UIntPtr wp; public IntPtr lp; public uint time; public int x, y; public uint reserved; }
    [DllImport("user32")] static extern bool PeekMessageW(out Message msg, IntPtr hwnd, uint min, uint max, uint flags);
    public IntPtr FindWindow() {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hwnd, IntPtr unused) {
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            if (pid != App.Id) return true;
            var name = new StringBuilder(80);
            GetClassName(hwnd, name, name.Capacity);
            if (name.ToString() != "RuneSwiftOpenGLWindow") return true;
            found = hwnd;
            return false;
        }, IntPtr.Zero);
        return found;
    }
    public static string Label(IntPtr menu, uint item) {
        var label = new StringBuilder(512);
        GetMenuString(menu, item, label, label.Capacity, 0x400);
        return label.ToString();
    }
    public static uint State(IntPtr menu, uint item) {
        uint state = GetMenuState(menu, item, 0x400);
        if (state == UInt32.MaxValue) throw new InvalidOperationException("Invalid native menu or item " + item);
        return state;
    }
    static void Send(IntPtr hwnd, uint msg, uint wp, IntPtr lp) {
        UIntPtr result;
        if (SendMessageTimeoutW(hwnd, msg, (UIntPtr)wp, lp, 2, 3000, out result) == IntPtr.Zero)
            throw new InvalidOperationException("SendMessageTimeoutW failed for " + msg + " (" + Marshal.GetLastWin32Error() + ")");
    }
    // Native MNS_NOTIFYBYPOS selection is scoped to this window and installed submenu.
    public static void Select(IntPtr hwnd, int section, uint item) {
        Send(hwnd, 0x126, item, GetSubMenu(GetMenu(hwnd), section));
    }
    public static void Chord(IntPtr hwnd, char key, bool alt) {
        uint pid, from = GetCurrentThreadId(), to = GetWindowThreadProcessId(hwnd, out pid);
        Message msg;
        PeekMessageW(out msg, IntPtr.Zero, 0, 0, 0);
        if (!AttachThreadInput(from, to, true)) throw new InvalidOperationException("AttachThreadInput failed");
        var saved = new byte[256];
        try {
            if (!GetKeyboardState(saved)) throw new InvalidOperationException("GetKeyboardState failed");
            var keys = new byte[256];
            keys[0x10] = keys[0xa0] = keys[0x11] = keys[0xa2] = 0x80;
            if (alt) keys[0x12] = keys[0xa4] = 0x80;
            if (!SetKeyboardState(keys)) throw new InvalidOperationException("SetKeyboardState failed");
            int scan = (int)(MapVirtualKeyW(key, 0) << 16) | 1;
            Send(hwnd, 0x100, key, (IntPtr)scan);
            Send(hwnd, 0x101, key, (IntPtr)(scan | unchecked((int)0xc0000000)));
        } finally {
            SetKeyboardState(saved);
            AttachThreadInput(from, to, false);
        }
    }
}
'@
}

$probe = New-Object RuneMenuSmoke ((Resolve-Path $Executable).Path)
function Wait-For([string]$description, [scriptblock]$condition) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (!$probe.App.HasExited -and $timer.Elapsed.TotalSeconds -lt 30) {
        if (& $condition) { return }
        Start-Sleep -Milliseconds 35
    }
    throw "Timed out waiting for $description"
}
function Expect-Line([string]$expected) {
    $timeout = if ($expected -ceq 'READY') { 240 } else { 30 }
    if (!$probe.WaitLine($expected, $timeout)) { throw "Missing output line '$expected'" }
}
function Command([string]$value) { $probe.App.StandardInput.WriteLine($value) }
function Assert-Menu([bool]$condition, [string]$message) { if (!$condition) { throw $message } }
function Submenu([int]$index) { [RuneMenuSmoke]::GetSubMenu([RuneMenuSmoke]::GetMenu($window), $index) }
try {
    $startup = [Diagnostics.Stopwatch]::StartNew()
    do {
        $window = $probe.FindWindow()
        if ($window -ne [IntPtr]::Zero -and [RuneMenuSmoke]::GetMenu($window) -ne [IntPtr]::Zero) { break }
        if ($probe.App.HasExited -or $startup.Elapsed.TotalSeconds -gt 240) { throw 'Native menu window did not open' }
        Start-Sleep -Milliseconds 150
    } while ($true)
    $bar = [RuneMenuSmoke]::GetMenu($window)
    $appMenu = Submenu 0
    $tools = Submenu 1
    Assert-Menu ([RuneMenuSmoke]::GetMenuItemCount($bar) -eq 2) 'Expected two native menu sections'
    Assert-Menu ([RuneMenuSmoke]::Label($bar, 0) -eq 'Menu Probe') 'App menu label'
    Assert-Menu ([RuneMenuSmoke]::Label($bar, 1) -eq 'Rune Tools') 'Named menu label'
    Assert-Menu ([RuneMenuSmoke]::GetMenuItemCount($appMenu) -eq 1) 'App item count'
    Assert-Menu ([RuneMenuSmoke]::GetMenuItemCount($tools) -eq 3) 'Named item count'
    Assert-Menu ([RuneMenuSmoke]::Label($appMenu, 0) -like "Open Quick Panel`t*") 'App accelerator column'
    Assert-Menu ([RuneMenuSmoke]::Label($tools, 0) -like "Named Quick Panel`t*") 'Named accelerator column'
    Assert-Menu (([RuneMenuSmoke]::State($tools, 1) -band 0x800) -ne 0) 'Separator flag'
    Assert-Menu (([RuneMenuSmoke]::State($tools, 2) -band 8) -ne 0) 'Checkmark flag'
    Write-Output "Found native menu and flags in $($startup.ElapsedMilliseconds) ms"
    Expect-Line 'READY'
    Write-Output "First frame in $($startup.ElapsedMilliseconds) ms"
    [RuneMenuSmoke]::Chord($window, 'K', $true)
    Expect-Line 'FIRED 1'
    [RuneMenuSmoke]::Chord($window, 'P', $false)
    Expect-Line 'KEY handled named_quick'
    [RuneMenuSmoke]::Chord($window, 'Y', $false)
    Expect-Line 'FIRED 2'
    [RuneMenuSmoke]::Select($window, 0, 0)
    Expect-Line 'FIRED 3'
    Command 'disable'
    Wait-For 'disabled native items' {
        (([RuneMenuSmoke]::State((Submenu 0), 0) -band 3) -ne 0) -and
        (([RuneMenuSmoke]::State((Submenu 1), 2) -band 3) -ne 0)
    }
    [RuneMenuSmoke]::Select($window, 0, 0)
    [RuneMenuSmoke]::Chord($window, 'K', $true)
    Expect-Line 'KEY handled quick'
    Command 'enable'
    Wait-For 're-enabled native items' { ([RuneMenuSmoke]::State((Submenu 0), 0) -band 3) -eq 0 }
    Command 'replace'
    Wait-For 'native replacement' { [RuneMenuSmoke]::Label((Submenu 0), 0) -like "Replacement Panel`t*" }
    [RuneMenuSmoke]::Chord($window, 'K', $true)
    [RuneMenuSmoke]::Chord($window, 'R', $true)
    Expect-Line 'FIRED 4'
    Command 'clear'
    Wait-For 'removed menu' { [RuneMenuSmoke]::GetMenu($window) -eq [IntPtr]::Zero }
    Command 'quit'
    Assert-Menu ($probe.App.WaitForExit(10000)) 'Probe failed to quit'
    $probe.App.WaitForExit()
    Assert-Menu ($probe.App.ExitCode -eq 0) 'Probe exited with failure'
    $events = @($probe.Output.ToArray() | Where-Object { $_ -match '^(FIRED|KEY|REPLACED)' })
    $expected = @('FIRED 1','KEY handled named_quick','KEY declined named_settings','FIRED 2','FIRED 3',
                  'KEY handled quick','KEY handled quick','REPLACED quick','FIRED 4')
    Assert-Menu (($events -join '|') -ceq ($expected -join '|')) "Unexpected ordering: $($events -join ', ')"
    Write-Output "PASS Windows HMENU sections, checked/disabled state, selection, live replacement and removal. $($events -join ' / ')"
}
finally {
    if ($probe.App.HasExited) { Write-Output "Process exit $($probe.App.ExitCode)" }
    else { Write-Output "Process still running (PID $($probe.App.Id))" }
    Write-Output ($probe.Output.ToArray() -join [Environment]::NewLine)
    Write-Output ($probe.Errors.ToArray() -join [Environment]::NewLine)
    $probe.Dispose()
}
