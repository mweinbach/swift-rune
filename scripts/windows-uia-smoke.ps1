# Run from a Windows desktop with a built rune-hello.exe.
param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [ValidateRange(1, 600)][int]$StartupTimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
# Enumerate only this process's top-level windows. A non-activating Rune window may
# never become MainWindowHandle, and console processes may report their console instead.
if (-not ('RuneUiaWindow' -as [type])) {
Add-Type @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
public static class RuneUiaWindow {
    delegate bool Visitor(IntPtr hwnd, IntPtr param);
    [DllImport("user32.dll")] static extern bool EnumThreadWindows(uint tid, Visitor cb, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int size);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] struct Pt { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int left, top, right, bottom; }
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr hwnd, ref Pt pt);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

    public static void Click(IntPtr hwnd, double x, double y) {
        IntPtr prior = SetThreadDpiAwarenessContext((IntPtr)(-4)); // Per-monitor aware v2
        try {
            var point = new Pt { x = (int)x, y = (int)y };
            if (!ScreenToClient(hwnd, ref point)) throw new Exception("ScreenToClient failed");
            IntPtr xy = (IntPtr)((point.x & 0xffff) | (point.y << 16));
            if (!PostMessage(hwnd, 0x0200, IntPtr.Zero, xy) || // move, left down, left up
                !PostMessage(hwnd, 0x0201, (IntPtr)1, xy) || !PostMessage(hwnd, 0x0202, IntPtr.Zero, xy))
                throw new Exception("Posting the click failed");
        } finally { if (prior != IntPtr.Zero) SetThreadDpiAwarenessContext(prior); }
    }

    public static void Grow(IntPtr hwnd) {
        IntPtr prior = SetThreadDpiAwarenessContext((IntPtr)(-4));
        try {
            Rect rect;
            if (!GetWindowRect(hwnd, out rect) || !SetWindowPos(hwnd, IntPtr.Zero, 0, 0,
                rect.right - rect.left + 120, rect.bottom - rect.top + 80, 0x16)) // no move, Z change or activation
                throw new Exception("Resizing the Rune window failed");
        } finally { if (prior != IntPtr.Zero) SetThreadDpiAwarenessContext(prior); }
    }

    public static void Close(IntPtr hwnd) { PostMessage(hwnd, 0x0010, IntPtr.Zero, IntPtr.Zero); }
    public static IntPtr Find(Process process) {
        IntPtr found = IntPtr.Zero;
        foreach (ProcessThread thread in process.Threads) {
            EnumThreadWindows((uint)thread.Id, delegate(IntPtr hwnd, IntPtr unused) {
                var name = new StringBuilder(256);
                GetClassName(hwnd, name, name.Capacity);
                if (name.ToString() != "RuneSwiftOpenGLWindow") return true;
                found = hwnd;
                return false;
            }, IntPtr.Zero);
            if (found != IntPtr.Zero) break;
        }
        return found;
    }
}
'@
}
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = (Resolve-Path $Executable).Path
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.EnvironmentVariables['RUNE_OPEN_INACTIVE'] = '1'
$hwnd = [IntPtr]::Zero
$app = [System.Diagnostics.Process]::Start($startInfo)
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    $id = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'switch'
    )
    do {
        if ($app.HasExited) { throw "Rune exited with code $($app.ExitCode) before publishing its switch." }
        $app.Refresh()
        $hwnd = [RuneUiaWindow]::Find($app)
        if ($hwnd -ne [IntPtr]::Zero) {
            $window = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
            $switch = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $id)
            if ($null -ne $switch) { break }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($null -eq $switch) { throw 'Timed out waiting for the switch in the native UI Automation tree.' }
    $info = $switch.Current
    if ($info.Name -ne 'Lights' -or $info.FrameworkId -ne 'Rune' -or
        $info.ControlType -ne [System.Windows.Automation.ControlType]::CheckBox -or
        -not $info.IsKeyboardFocusable -or -not $info.IsEnabled -or
        $info.BoundingRectangle.Width -le 0 -or $info.BoundingRectangle.Height -le 0) {
        throw "Unexpected switch properties. Name=$($info.Name), framework=$($info.FrameworkId), type=$($info.ControlType), bounds=$($info.BoundingRectangle)"
    }
    $toggle = $switch.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    function Wait-Toggle($pattern, $expected) {
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while ($pattern.Current.ToggleState.ToString() -ne $expected) {
            if ([DateTime]::UtcNow -ge $deadline) { throw "The Rune switch did not reach $expected." }
            Start-Sleep -Milliseconds 25
        }
    }
    Wait-Toggle $toggle 'Off'
    $toggle.Toggle()
    Wait-Toggle $toggle 'On'

    $before = $switch.Current.BoundingRectangle
    [RuneUiaWindow]::Click($hwnd, ($before.X + $before.Width / 2), ($before.Y + $before.Height / 2))
    Wait-Toggle $toggle 'Off'

    [RuneUiaWindow]::Grow($hwnd)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $after = $switch.Current.BoundingRectangle
        if ($after.X -gt $before.X + 25 -and $after.Y -gt $before.Y + 15) { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw "Resize did not move the switch from $before. Last bounds were $after." }
        Start-Sleep -Milliseconds 25
    } while ($true)
    [RuneUiaWindow]::Click($hwnd, ($after.X + $after.Width / 2), ($after.Y + $after.Height / 2))
    Wait-Toggle $toggle 'On'
    $toggle.Toggle()
    Wait-Toggle $toggle 'Off'
    Write-Output "Lights responded to native clicks and UI Automation Toggle before and after resize ($before -> $after)."
} finally {
    if (-not $app.HasExited) {
        if ($hwnd -ne [IntPtr]::Zero) { [RuneUiaWindow]::Close($hwnd) }
        if (-not $app.WaitForExit(3000)) { $app.Kill() }
    }
    $app.Dispose()
}
