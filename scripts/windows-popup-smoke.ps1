# Run on an interactive Windows desktop after building rune-popup-menu and rune-rich-clipboard.
# To include spelling, build Tests/Support/PopupSpelling and install the Windows English (US) dictionary.
# .\scripts\windows-popup-smoke.ps1 .\rune-popup-menu.exe .\rune-rich-clipboard.exe .\PopupSpelling.exe
param(
    [string]$Executable,
    [string]$RichClipboardExecutable,
    [string]$SpellingExecutable
)
$ErrorActionPreference = 'Stop'
if (!$Executable -and !$RichClipboardExecutable -and !$SpellingExecutable) {
    throw 'Provide a popup, rich clipboard, or spellcheck fixture executable.'
}
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

if (-not ('RunePopupSmoke' -as [type])) {
    Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class RunePopupSmoke {
    delegate bool Visitor(IntPtr window, IntPtr unused);
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct MenuBarInfo {
        public int Size;
        public Rect Bounds;
        public IntPtr Menu, MenuWindow;
        public uint Flags;
    }

    [DllImport("user32")] static extern bool EnumWindows(Visitor visit, IntPtr unused);
    [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint id);
    [DllImport("user32", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int count);
    [DllImport("user32")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32")] static extern bool GetMenuBarInfo(IntPtr window, int obj, int item, ref MenuBarInfo info);
    [DllImport("user32", CharSet = CharSet.Unicode)] static extern int GetMenuString(IntPtr menu, uint item, StringBuilder text, int count, uint flags);
    [DllImport("user32")] public static extern IntPtr GetSubMenu(IntPtr menu, int index);
    [DllImport("user32")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32")] static extern uint GetMenuState(IntPtr menu, uint item, uint flags);
    [DllImport("user32", SetLastError = true)] static extern bool GetMenuItemRect(IntPtr window, IntPtr menu, uint item, out Rect bounds);
    [StructLayout(LayoutKind.Sequential)] struct Message {
        public IntPtr Window; public uint Id; public UIntPtr WParam; public IntPtr LParam;
        public uint Time; public Point Position; public uint Reserved;
    }
    [DllImport("kernel32")] static extern uint GetCurrentThreadId();
    [DllImport("user32")] static extern bool PeekMessageW(out Message msg, IntPtr window, uint min, uint max, uint remove);
    [DllImport("user32", SetLastError = true)] static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("user32", SetLastError = true)] static extern bool GetKeyboardState([Out] byte[] keys);
    [DllImport("user32", SetLastError = true)] static extern bool SetKeyboardState(byte[] keys);
    [DllImport("user32")] static extern bool IsMenu(IntPtr menu);
    [DllImport("user32")] static extern bool ScreenToClient(IntPtr window, ref Point pt);
    [DllImport("user32")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32")] static extern uint MapVirtualKey(uint key, uint type);
    [DllImport("user32", SetLastError = true)] static extern bool PostMessage(IntPtr window, uint msg, IntPtr wp, IntPtr lp);

    public static IntPtr Find(uint process, string className, string firstMenuLabel) {
        return FindWindowOrMenu(process, className, firstMenuLabel, false);
    }

    public static IntPtr MenuContaining(uint process, string label) {
        return FindWindowOrMenu(process, "#32768", label, true);
    }

    static IntPtr FindWindowOrMenu(uint process, string className, string menuLabel, bool anyRow) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr unused) {
            uint id; GetWindowThreadProcessId(window, out id);
            if (id != process || !IsWindowVisible(window)) return true;
            var name = new StringBuilder(128);
            GetClassName(window, name, name.Capacity);
            if (name.ToString() != className) return true;
            if (String.IsNullOrEmpty(menuLabel)) { found = window; return false; }
            var info = new MenuBarInfo { Size = Marshal.SizeOf(typeof(MenuBarInfo)) };
            if (!GetMenuBarInfo(window, -4, 0, ref info)) return true;
            int count = anyRow ? GetMenuItemCount(info.Menu) : 1;
            for (int row = 0; row < count; ++row) {
                if (Label(info.Menu, (uint)row) != menuLabel) continue;
                found = info.Menu;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static IntPtr WindowForMenu(uint process, IntPtr menu) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr unused) {
            uint id; GetWindowThreadProcessId(window, out id);
            if (id != process || !IsWindowVisible(window)) return true;
            var name = new StringBuilder(80);
            GetClassName(window, name, name.Capacity);
            if (name.ToString() != "#32768") return true;
            var info = new MenuBarInfo { Size = Marshal.SizeOf(typeof(MenuBarInfo)) };
            if (!GetMenuBarInfo(window, -4, 0, ref info) || info.Menu != menu) return true;
            found = window; return false;
        }, IntPtr.Zero);
        return found;
    }

    public static string Label(IntPtr menu, uint index) {
        var text = new StringBuilder(256);
        GetMenuString(menu, index, text, text.Capacity, 0x400);
        return text.ToString().Split('\t')[0];
    }

    public static uint State(IntPtr menu, uint index) {
        uint state = GetMenuState(menu, index, 0x400);
        if (state == UInt32.MaxValue) throw new InvalidOperationException("Invalid menu row " + index);
        return state;
    }

    public static Rect ItemBounds(IntPtr menu, uint index) {
        IntPtr previous = SetThreadDpiAwarenessContext((IntPtr)(-4));
        try {
            Rect bounds;
            if (!GetMenuItemRect(IntPtr.Zero, menu, index, out bounds)) throw new Win32Exception();
            return bounds;
        } finally { if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous); }
    }

    static void Post(IntPtr window, uint msg, IntPtr wp, IntPtr lp) {
        if (!PostMessage(window, msg, wp, lp)) throw new Win32Exception();
    }

    public static void Click(IntPtr window, int screenX, int screenY, bool secondary) {
        IntPtr previous = SetThreadDpiAwarenessContext((IntPtr)(-4));
        try {
            var pt = new Point { X = screenX, Y = screenY };
            if (!ScreenToClient(window, ref pt)) throw new Win32Exception();
            IntPtr coords = (IntPtr)((pt.Y << 16) | (pt.X & 0xffff));
            Post(window, 0x200, IntPtr.Zero, coords);
            Post(window, secondary ? 0x204u : 0x201u, (IntPtr)(secondary ? 2 : 1), coords);
            Post(window, secondary ? 0x205u : 0x202u, IntPtr.Zero, coords);
        } finally { if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous); }
    }

    public static void Key(IntPtr window, uint key) {
        int flags = 1 | (int)(MapVirtualKey(key, 0) << 16);
        Post(window, 0x100, (IntPtr)key, (IntPtr)flags);
        Post(window, 0x101, (IntPtr)key, (IntPtr)(flags | unchecked((int)0xc0000000)));
    }
    public static void ControlC(IntPtr window, IntPtr menu) {
        // Share input state only with this window's thread while its menu consumes the posted key.
        uint process, from = GetCurrentThreadId(), to = GetWindowThreadProcessId(window, out process);
        Message msg;
        PeekMessageW(out msg, IntPtr.Zero, 0, 0, 0);
        if (!AttachThreadInput(from, to, true)) throw new Win32Exception();
        var saved = new byte[256];
        try {
            if (!GetKeyboardState(saved)) throw new Win32Exception();
            var keys = (byte[])saved.Clone();
            keys[0x11] = keys[0xa2] = 0x80;
            if (!SetKeyboardState(keys)) throw new Win32Exception();
            Key(window, 'C');
            var timer = System.Diagnostics.Stopwatch.StartNew();
            while (IsMenu(menu) && timer.ElapsedMilliseconds < 10000) System.Threading.Thread.Sleep(20);
        } finally {
            SetKeyboardState(saved);
            AttachThreadInput(from, to, false);
        }
    }

    public static void Close(IntPtr window) { Post(window, 0x10, IntPtr.Zero, IntPtr.Zero); }
}
'@
}

function Await-Result([string]$label, [scriptblock]$read, [int]$seconds = 20) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($app.HasExited) { throw "App exited with $($app.ExitCode) while waiting for $label" }
        $value = & $read
        if ($value -is [IntPtr]) {
            if ($value -ne [IntPtr]::Zero) { return $value }
        } elseif ($value) { return $value }
        Start-Sleep -Milliseconds 45
    } while ($watch.Elapsed.TotalSeconds -lt $seconds)
    throw "Timed out waiting for $label"
}

function Get-Node([string]$key) {
    $condition = New-Object Windows.Automation.PropertyCondition(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, $key)
    $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
}

function Wait-Status([string]$last) {
    $null = Await-Result "app state '$last'" {
        $nodes = $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
        foreach ($node in $nodes) { if ($node.Current.Name.Contains("Last: $last ")) { return $true } }
    }
}

function Popup-Window([IntPtr]$menu) {
    Await-Result 'native popup HWND' { [RunePopupSmoke]::WindowForMenu($app.Id, $menu) }
}

function Activate-Row([IntPtr]$menu, [string]$title, [switch]$Expand) {
    $target = Popup-Window $menu
    $menuRoot = [Windows.Automation.AutomationElement]::FromHandle($target)
    $name = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, $title)
    $item = $menuRoot.FindFirst([Windows.Automation.TreeScope]::Descendants, $name)
    if (!$item) {
        $labels = ($menuRoot.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name }) -join ', '
        throw "Native popup UIA item '$title' missing. Descendants: $labels"
    }
    $pattern = $null
    if ($Expand -and $item.TryGetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) {
        $pattern.Expand()
        Write-Output "Expanded native '$title' with UIA."
    } elseif ($item.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        $pattern.Invoke()
        Write-Output "Invoked native '$title' with UIA."
    } else {
        $legacy = $item.GetCurrentPattern([Windows.Automation.LegacyIAccessiblePattern]::Pattern)
        $legacy.DoDefaultAction()
        Write-Output "Performed the native default action on '$title' with UIA."
    }
}

function Wait-Menu([string]$first) {
    Await-Result "visible native menu starting with '$first'" { [RunePopupSmoke]::Find($app.Id, '#32768', $first) }
}

function Assert-True([bool]$condition, [string]$reason) { if (!$condition) { throw $reason } }

function Start-Example([string]$file, [string]$launchArguments = '') {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = (Resolve-Path $file).Path
    $start.WorkingDirectory = [IO.Path]::GetDirectoryName($start.FileName)
    $start.Arguments = $launchArguments
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.EnvironmentVariables['RUNE_OPEN_INACTIVE'] = '1'
    [Diagnostics.Process]::Start($start)
}

function Stop-Example {
    if (!$app.HasExited) {
        if ($window -ne [IntPtr]::Zero) { [RunePopupSmoke]::Close($window) }
        if (!$app.WaitForExit(3000)) { $app.Kill() }
    }
    $app.Dispose()
}

$failures = New-Object 'Collections.Generic.List[string]'
if ($Executable) {
    $app = Start-Example $Executable
    $window = [IntPtr]::Zero
    try {
        $window = Await-Result 'Rune window' { [RunePopupSmoke]::Find($app.Id, 'RuneSwiftOpenGLWindow', '') } 240
        $root = [Windows.Automation.AutomationElement]::FromHandle($window)
        $canvas = Await-Result 'accessible canvas' { Get-Node 'canvas' } 240
        $theme = Await-Result 'accessible theme picker' { Get-Node 'theme' }
        Wait-Status '-'
        Write-Output 'Popup example window and accessibility tree ready.'

        $area = $canvas.Current.BoundingRectangle
        $x = [int]($area.X + $area.Width / 2)
        $y = [int]($area.Y + $area.Height / 2)
        [RunePopupSmoke]::Click($window, $x, $y, $true)
        $context = Wait-Menu 'Copy'
        Assert-True ([RunePopupSmoke]::GetMenuItemCount($context) -eq 4) 'Unexpected context menu structure'
        Assert-True ([RunePopupSmoke]::Label($context, 1) -ceq 'Paste' -and ([RunePopupSmoke]::State($context, 1) -band 3)) 'Paste should be disabled'
        Assert-True (([RunePopupSmoke]::State($context, 2) -band 0x800) -ne 0) 'Missing native separator'
        $share = [RunePopupSmoke]::GetSubMenu($context, 3)
        Assert-True ([RunePopupSmoke]::Label($context, 3) -ceq 'Share' -and [RunePopupSmoke]::Label($share, 1) -ceq 'Messages') 'Missing nested Share commands'
        $first = [RunePopupSmoke]::ItemBounds($context, 0)
        $rowHeight = $first.Bottom - $first.Top
        Assert-True ([Math]::Abs($first.Top - $y) -le $rowHeight -and [Math]::Abs($first.Left - $x) -le $rowHeight) 'Pointer anchor missed the click'
        Activate-Row $context 'Share' -Expand
        $null = Await-Result 'open Share submenu' { [RunePopupSmoke]::WindowForMenu($app.Id, $share) }
        Activate-Row $share 'Messages'
        Wait-Status 'messages'
        Write-Output 'Nested command selected through its native menu.'

        [RunePopupSmoke]::Click($window, $x, $y, $true)
        $context = Wait-Menu 'Copy'
        [RunePopupSmoke]::ControlC((Popup-Window $context), $context)
        Wait-Status 'copy'

        # Focus the authored canvas through normal pointer handling before sending VK_APPS to its window.
        [RunePopupSmoke]::Click($window, $x, $y, $false)
        [RunePopupSmoke]::Key($window, 0x5d) # The Windows application/context-menu key.
        $context = Wait-Menu 'Copy'
        $first = [RunePopupSmoke]::ItemBounds($context, 0)
        $area = $canvas.Current.BoundingRectangle
        Assert-True ([Math]::Abs($first.Left - $area.Left) -le $rowHeight -and [Math]::Abs($first.Top - $area.Bottom) -le $rowHeight) 'Keyboard menu should anchor to the focused control'
        [RunePopupSmoke]::Key((Popup-Window $context), 0x1b)
        Wait-Status '(dismissed)'
        Write-Output 'Keyboard context-menu anchor and Escape dismissal verified.'

        $area = $theme.Current.BoundingRectangle
        [RunePopupSmoke]::Click($window, [int]($area.X + $area.Width / 2), [int]($area.Y + $area.Height / 2), $false)
        $picker = Wait-Menu 'System'
        Assert-True (([RunePopupSmoke]::State($picker, 0) -band 8) -ne 0) 'System should be checked'
        Activate-Row $picker 'Dark'
        $null = Await-Result 'picker closing' { [RunePopupSmoke]::Find($app.Id, '#32768', 'System') -eq [IntPtr]::Zero }
        [RunePopupSmoke]::Click($window, [int]($area.X + $area.Width / 2), [int]($area.Y + $area.Height / 2), $false)
        $picker = Wait-Menu 'System'
        Assert-True (([RunePopupSmoke]::State($picker, 2) -band 8) -ne 0 -and ([RunePopupSmoke]::State($picker, 0) -band 8) -eq 0) 'Dark should be checked after selection'
        [RunePopupSmoke]::Key((Popup-Window $picker), 0x1b)
        Write-Output 'PASS Windows popup menus: pointer and keyboard anchors, Ctrl+C, disabled Paste, separator, Share > Messages, Escape dismissal, and persistent picker selection.'
    } catch {
        Write-Output $_.Exception.Message
        $failures.Add($_.Exception.Message)
    } finally {
        Stop-Example
    }
}

if ($RichClipboardExecutable) {
    $app = Start-Example $RichClipboardExecutable
    $window = [IntPtr]::Zero
    try {
        $window = Await-Result 'Rich Clipboard window' { [RunePopupSmoke]::Find($app.Id, 'RuneSwiftOpenGLWindow', '') } 240
        $root = [Windows.Automation.AutomationElement]::FromHandle($window)
        $field = Await-Result 'editable field' { Get-Node 'field' } 240
        $area = $field.Current.BoundingRectangle
        [RunePopupSmoke]::Click($window, [int]($area.X + $area.Width / 2), [int]($area.Y + $area.Height / 2), $false)
        $edit = $field.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
        $edit.SetValue('Popup probe')
        $null = Await-Result 'new field text' { $edit.Current.Value -ceq 'Popup probe' }
        [RunePopupSmoke]::Key($window, 0x5d)
        $fieldMenu = Wait-Menu 'Cut'
        Assert-True ([RunePopupSmoke]::Label($fieldMenu, 3) -ceq 'Select All') 'Missing field Select All command'
        Activate-Row $fieldMenu 'Select All'
        $text = $field.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern)
        $null = Await-Result 'selected field text' { $text.GetSelection()[0].GetText(-1) -ceq 'Popup probe' }
        [RunePopupSmoke]::Key($window, 0x5d)
        $fieldMenu = Wait-Menu 'Cut'
        Assert-True (([RunePopupSmoke]::State($fieldMenu, 0) -band 3) -eq 0) 'Cut should be enabled for the selection'
        [RunePopupSmoke]::Key((Popup-Window $fieldMenu), 0x1b)
        $null = Await-Result 'field menu dismissal' { [RunePopupSmoke]::Find($app.Id, '#32768', 'Cut') -eq [IntPtr]::Zero }
        Assert-True ($edit.Current.Value -ceq 'Popup probe') 'Escape changed the editable value'
        Write-Output 'PASS Windows field popup: keyboard opening, native Select All, UIA Text selection, enabled Cut and Escape.'
    } catch {
        Write-Output $_.Exception.Message
        $failures.Add($_.Exception.Message)
    } finally {
        Stop-Example
    }
}

if ($SpellingExecutable) {
    $app = Start-Example $SpellingExecutable 'speling'
    $window = [IntPtr]::Zero
    try {
        $window = Await-Result 'spelling fixture window' { [RunePopupSmoke]::Find($app.Id, 'RuneSwiftOpenGLWindow', '') } 240
        $root = [Windows.Automation.AutomationElement]::FromHandle($window)
        $field = Await-Result 'spellcheck field' { Get-Node 'word' } 240
        $edit = $field.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
        Assert-True ($edit.Current.Value -ceq 'speling') 'Expected authored misspelling'
        $area = $field.Current.BoundingRectangle
        $x = [int]($area.X + $area.Width / 2)
        $y = [int]($area.Y + $area.Height / 2)
        [RunePopupSmoke]::Click($window, $x, $y, $true)
        $menu = Await-Result 'native en-US suggestion spelling' { [RunePopupSmoke]::MenuContaining($app.Id, 'spelling') }
        [RunePopupSmoke]::Key((Popup-Window $menu), 0x1b)
        $null = Await-Result 'spelling menu dismissal' { [RunePopupSmoke]::MenuContaining($app.Id, 'spelling') -eq [IntPtr]::Zero }
        Assert-True ($edit.Current.Value -ceq 'speling') 'Escape changed the misspelled word'
        [RunePopupSmoke]::Click($window, $x, $y, $true)
        $menu = Await-Result 'reopened spelling suggestions' { [RunePopupSmoke]::MenuContaining($app.Id, 'spelling') }
        Activate-Row $menu 'spelling'
        $null = Await-Result 'corrected text via UI Automation' { $edit.Current.Value -ceq 'spelling' }
        Write-Output 'PASS Windows en-US spelling suggestion: Escape preserved speling, and choosing spelling corrected the field value.'
    } catch {
        Write-Output $_.Exception.Message
        $failures.Add($_.Exception.Message)
    } finally {
        Stop-Example
    }
}

if ($failures.Count) { throw ($failures -join [Environment]::NewLine) }
