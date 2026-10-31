param(
    [Parameter(Mandatory = $true)]
    [string]$OperationPath
)

$ErrorActionPreference = "Stop"
$DefaultTextLimit = 500
$AccessibilityTreeMaxNodeCount = 1200
$AccessibilityTreeMaxDepth = 64
$MinimumScreenshotDimension = 64
$MinimumScreenshotArea = 20000

# Set output encoding to UTF-8 to properly handle non-ASCII characters
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class OCUWin32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out int value, int valueSize);

    [DllImport("user32.dll")]
    public static extern bool ScreenToClient(IntPtr hWnd, ref POINT point);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool PostMessage(IntPtr hWnd, UInt32 msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, UInt32 msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, UInt32 msg, IntPtr wParam, string lParam);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")]
    public static extern IntPtr GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")]
    public static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx, dy;
        public uint mouseData, flags, time;
        public UIntPtr extra;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort key, scan;
        public uint flags, time;
        public UIntPtr extra;
    }
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mouse;
        [FieldOffset(0)] public KEYBDINPUT keyboard;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public INPUTUNION data; }
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, INPUT[] inputs, int size);
    private static void Send(INPUT input) {
        if (SendInput(1, new[] { input }, Marshal.SizeOf(typeof(INPUT))) != 1)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "SendInput failed (possibly blocked by desktop/integrity restrictions)");
    }
    public static void MouseInput(uint flags, int data) {
        INPUT input = new INPUT();
        input.data.mouse.flags = flags;
        input.data.mouse.mouseData = unchecked((uint)data);
        Send(input);
    }
    public static void KeyInput(int key, bool up) {
        INPUT input = new INPUT(); input.type = 1;
        input.data.keyboard.key = (ushort)key;
        input.data.keyboard.flags = (up ? 2u : 0u) | ((key >= 0x21 && key <= 0x2e) ? 1u : 0u);
        Send(input);
    }

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    // pi-phone fork (PP-270): window identity, z-order and what paints above a window.
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")]
    private static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("dwmapi.dll", EntryPoint = "DwmGetWindowAttribute")]
    private static extern int DwmGetWindowRect(IntPtr hWnd, int attribute, out RECT value, int valueSize);

    public static string WindowTitle(IntPtr hWnd) {
        StringBuilder text = new StringBuilder(512);
        GetWindowText(hWnd, text, text.Capacity);
        return text.ToString();
    }

    public static int WindowProcessId(IntPtr hWnd) {
        uint processId;
        GetWindowThreadProcessId(hWnd, out processId);
        return (int)processId;
    }

    // Whether a top-level window paints on the screen: visible, not minimised, not cloaked (another
    // virtual desktop, a suspended app), not a tool window, not a click-through layered overlay.
    public static bool Paints(IntPtr hWnd) {
        if (!IsWindowVisible(hWnd) || IsIconic(hWnd)) return false;
        int extended = GetWindowLong(hWnd, -20);
        if ((extended & 0x80) != 0) return false;
        if ((extended & 0x80000) != 0 && (extended & 0x20) != 0) return false;
        int cloaked;
        if (DwmGetWindowAttribute(hWnd, 14, out cloaked, 4) == 0 && cloaked != 0) return false;
        return true;
    }

    // The window's painted rectangle: DWM's extended frame bounds, without the invisible resize borders.
    public static bool VisibleFrame(IntPtr hWnd, out RECT rect) {
        if (DwmGetWindowRect(hWnd, 9, out rect, Marshal.SizeOf(typeof(RECT))) != 0 && !GetWindowRect(hWnd, out rect)) return false;
        return rect.Right > rect.Left && rect.Bottom > rect.Top;
    }

    // The painted rectangles of the top-level windows above the target, in z-order (EnumWindows goes
    // from the top); null when the target is not a top-level window.
    public static RECT[] WindowRectsAbove(IntPtr target) {
        List<RECT> rects = new List<RECT>();
        bool found = false;
        EnumWindows(delegate (IntPtr hWnd, IntPtr unused) {
            if (hWnd == target) { found = true; return false; }
            RECT rect;
            if (Paints(hWnd) && VisibleFrame(hWnd, out rect)) rects.Add(rect);
            return true;
        }, IntPtr.Zero);
        return found ? rects.ToArray() : null;
    }

    // The painting, titled top-level windows of a process, from the top.
    public static long[] WindowsOfProcess(int processId) {
        List<long> windows = new List<long>();
        EnumWindows(delegate (IntPtr hWnd, IntPtr unused) {
            if (WindowProcessId(hWnd) == processId && Paints(hWnd) && WindowTitle(hWnd).Length > 0) windows.Add(hWnd.ToInt64());
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }
}
"@

$WM_SETTEXT = 0x000C
$WM_MOUSEMOVE = 0x0200
$WM_LBUTTONDOWN = 0x0201
$WM_LBUTTONUP = 0x0202
$WM_RBUTTONDOWN = 0x0204
$WM_RBUTTONUP = 0x0205
$WM_MBUTTONDOWN = 0x0207
$WM_MBUTTONUP = 0x0208
$WM_MOUSEWHEEL = 0x020A
$WM_MOUSEHWHEEL = 0x020E
$WM_KEYDOWN = 0x0100
$WM_KEYUP = 0x0101
$WM_CHAR = 0x0102
$EM_SETSEL = 0x00B1
$EM_REPLACESEL = 0x00C2

# Screenshot coordinates, UIA bounding rectangles and the windowBounds recorded in
# the operation file are physical pixels, while a DPI-unaware PowerShell process
# reports virtualized metrics from GetSystemMetrics/GetWindowRect. That mismatch
# makes the capturable-window checks reject windows sitting outside the
# virtualized screen and shifts every screenshot coordinate, so pin the process to
# the physical coordinate space before any bounds check runs.
$DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = [IntPtr](-4)
try { [void][OCUWin32]::SetProcessDpiAwarenessContext($DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) } catch { }
# The host may already have selected process awareness. A thread override must
# succeed; silently using virtualized coordinates can target another location.
$previousDpi = [OCUWin32]::SetThreadDpiAwarenessContext($DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
if ($previousDpi -eq [IntPtr]::Zero -or
    [OCUWin32]::GetAwarenessFromDpiAwarenessContext([OCUWin32]::GetThreadDpiAwarenessContext()) -ne 2) {
    throw "Cannot establish per-monitor physical coordinates for the Windows bridge."
}

# Real system input is a deliberate opt-in: it moves the user's pointer and can
# change foreground focus, so the default Windows path stays on UIA patterns and
# Win32 window messages.
$MOUSEEVENTF_LEFTDOWN = 0x0002
$MOUSEEVENTF_LEFTUP = 0x0004
$MOUSEEVENTF_RIGHTDOWN = 0x0008
$MOUSEEVENTF_RIGHTUP = 0x0010
$MOUSEEVENTF_MIDDLEDOWN = 0x0020
$MOUSEEVENTF_MIDDLEUP = 0x0040
$MOUSEEVENTF_WHEEL = 0x0800
$MOUSEEVENTF_HWHEEL = 0x1000

function Test-EnvFlagEnabled([string]$name) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }
    $normalized = $value.Trim().ToLowerInvariant()
    return @("1", "true", "yes", "on") -contains $normalized
}

# pi-phone fork: password fields (UI Automation IsPassword) are marked in the
# outline, their value is never read, and input into them is refused unless the
# host opts out with OPEN_COMPUTER_USE_ALLOW_PASSWORD_INPUT=1.
$PasswordMarker = "[password]"

function Test-ElementIsPassword($element) {
    if ($null -eq $element) {
        return $false
    }
    try {
        return [bool]$element.Current.IsPassword
    } catch {
        return $false
    }
}

# pi-phone fork: set for one call when it carries allow_password_input: true (a person
# typing their own password); every other call keeps the guard.
$script:AllowPasswordInputThisCall = $false

# pi-phone fork (PP-270): a refusal with a machine-readable code (stale_ref, ambiguous_target,
# policy_denied, covered, not_found, password_field), raised before anything reaches the app.
function New-OCUError([string]$Code, [string]$Message, [string]$Suggestion = "") {
    $exception = New-Object System.InvalidOperationException $Message
    $exception.Data["ocuCode"] = $Code
    $exception.Data["ocuSuggestion"] = $Suggestion
    return $exception
}

function Assert-NotPasswordInput($element) {
    if ((Test-ElementIsPassword $element) -and -not $script:AllowPasswordInputThisCall -and -not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_ALLOW_PASSWORD_INPUT")) {
        throw (New-OCUError "password_field" "Refused: the target is a password field. Open Computer Use (pi-phone build) does not type into password fields; set OPEN_COMPUTER_USE_ALLOW_PASSWORD_INPUT=1 to allow it.")
    }
}

# pi-phone fork: physical input (SendInput) needs headed: true on the call as well as the
# OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS gate; without it auto fallbacks stay on window messages.
$script:HeadedThisCall = $false

# pi-phone fork: the states an element line may carry, in this order ("States: checked, focused").
$StateOrder = @("checked", "selected", "expanded", "collapsed", "focused", "disabled", "readonly", "secure")

function ConvertTo-StateNames($Toggle, $Selected, $Expansion, [bool]$Focused, [bool]$Enabled, [bool]$Password, $ReadOnly) {
    $found = @{}
    if ([string]$Toggle -eq "On") { $found["checked"] = $true }
    if ($Selected -eq $true) { $found["selected"] = $true }
    if ([string]$Expansion -in @("Expanded", "PartiallyExpanded")) { $found["expanded"] = $true }
    elseif ([string]$Expansion -eq "Collapsed") { $found["collapsed"] = $true }
    if ($Focused) { $found["focused"] = $true }
    if (-not $Enabled) { $found["disabled"] = $true }
    if ($ReadOnly -eq $true) { $found["readonly"] = $true }
    if ($Password) { $found["secure"] = $true }
    return @($StateOrder | Where-Object { $found.ContainsKey($_) })
}

# UI Automation: TogglePattern, SelectionItemPattern, ExpandCollapsePattern, IsEnabled,
# HasKeyboardFocus, IsPassword and ValuePattern.IsReadOnly.
function Get-ElementStates($element, [bool]$isPassword) {
    $toggle = $null; $selected = $null; $expansion = $null; $readOnly = $null
    $focused = $false; $enabled = $true
    try { $focused = [bool]$element.Current.HasKeyboardFocus } catch {}
    try { $enabled = [bool]$element.Current.IsEnabled } catch {}
    foreach ($pattern in @(try { $element.GetSupportedPatterns() } catch { @() })) {
        try {
            switch -Wildcard ($pattern.ProgrammaticName) {
                "TogglePatternIdentifiers.Pattern" { $toggle = $element.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState }
                "SelectionItemPatternIdentifiers.Pattern" { $selected = $element.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected }
                "ExpandCollapsePatternIdentifiers.Pattern" { $expansion = $element.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState }
                "ValuePatternIdentifiers.Pattern" { $readOnly = $element.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.IsReadOnly }
            }
        } catch {}
    }
    return ConvertTo-StateNames $toggle $selected $expansion $focused $enabled $isPassword $readOnly
}

# A name as the snapshot recorded it (perhaps cut to text_limit, ending in ...) against the live one.
function Test-NamesMatch([string]$Recorded, [string]$Live) {
    if ($Recorded -ceq $Live) { return $true }
    return ($Recorded.EndsWith("...") -and $Live.Length -gt ($Recorded.Length - 3) -and $Live.StartsWith($Recorded.Substring(0, $Recorded.Length - 3), [System.StringComparison]::Ordinal))
}

# Expand and Collapse follow the element's state; either way it is the same ExpandCollapse element.
function ConvertTo-ComparableActions($actions) {
    return (@($actions | ForEach-Object { if ($_ -in @("Expand", "Collapse")) { "ExpandCollapse" } else { [string]$_ } } | Select-Object -Unique) -join ",")
}

# pi-phone fork: whether a live element is the one the snapshot saw (role, name, actions).
function Test-RecordMatches($Live, $Record) {
    if ([string]$Live.controlType -ne [string]$Record.controlType) { return $false }
    if (-not (Test-NamesMatch ([string]$Record.name) ([string]$Live.name))) { return $false }
    return (ConvertTo-ComparableActions $Live.actions) -eq (ConvertTo-ComparableActions $Record.actions)
}

function Get-LiveIdentity($element) {
    [pscustomobject]@{
        controlType = Get-ElementControlTypeName $element
        name = Get-ElementString $element "Name"
        actions = @(Get-PatternNames $element)
    }
}

function New-StaleElementError($record, [string]$why) {
    $role = if ([string]::IsNullOrWhiteSpace($record.controlType)) { "element" } else { [string]$record.controlType }
    return (New-OCUError "stale_ref" ("[{0}] is no longer the {1} '{2}' that the snapshot saw ({3})." -f $record.index, $role, $record.name, $why))
}

# The area the rectangles cover together, counting overlaps once.
function Get-UnionArea($rects) {
    $rects = @($rects)
    if ($rects.Count -eq 0) { return 0 }
    $xs = @($rects | ForEach-Object { [double]$_.x; [double]$_.x + [double]$_.width } | Sort-Object -Unique)
    $ys = @($rects | ForEach-Object { [double]$_.y; [double]$_.y + [double]$_.height } | Sort-Object -Unique)
    $area = 0.0
    for ($i = 0; $i -lt $xs.Count - 1; $i++) {
        for ($j = 0; $j -lt $ys.Count - 1; $j++) {
            $cx = ($xs[$i] + $xs[$i + 1]) / 2; $cy = ($ys[$j] + $ys[$j + 1]) / 2
            foreach ($rect in $rects) {
                if ($cx -ge $rect.x -and $cx -lt ($rect.x + $rect.width) -and $cy -ge $rect.y -and $cy -lt ($rect.y + $rect.height)) {
                    $area += ($xs[$i + 1] - $xs[$i]) * ($ys[$j + 1] - $ys[$j])
                    break
                }
            }
        }
    }
    return $area
}

function Get-Overlap($a, $b) {
    $left = [math]::Max([double]$a.x, [double]$b.x)
    $top = [math]::Max([double]$a.y, [double]$b.y)
    $right = [math]::Min([double]$a.x + [double]$a.width, [double]$b.x + [double]$b.width)
    $bottom = [math]::Min([double]$a.y + [double]$a.height, [double]$b.y + [double]$b.height)
    if ($right -le $left -or $bottom -le $top) { return $null }
    return New-Frame $left $top ($right - $left) ($bottom - $top)
}

# pi-phone fork (PP-271): the parts of the window (bounds, screen pixels) that windows above it
# cover, in window coordinates; full when they cover all of its painted frame (visible, screen pixels).
function Get-CoveredRegions($Bounds, $Above, $Visible) {
    if ($null -eq $Above) { return [pscustomobject]@{ state = "unknown"; covered = @() } }
    if ($null -eq $Visible) { $Visible = $Bounds }
    $covered = New-Object System.Collections.Generic.List[object]
    foreach ($rect in @($Above)) {
        $overlap = Get-Overlap $rect $Bounds
        if ($null -eq $overlap) { continue }
        $local = New-Frame ([math]::Round($overlap.x - $Bounds.x)) ([math]::Round($overlap.y - $Bounds.y)) ([math]::Round($overlap.width)) ([math]::Round($overlap.height))
        if (-not ($covered | Where-Object { $_.x -eq $local.x -and $_.y -eq $local.y -and $_.width -eq $local.width -and $_.height -eq $local.height })) {
            $covered.Add($local)
        }
    }
    if ($covered.Count -eq 0) { return [pscustomobject]@{ state = "clear"; covered = @() } }
    $paintedLocal = New-Frame ($Visible.x - $Bounds.x) ($Visible.y - $Bounds.y) $Visible.width $Visible.height
    $inPainted = @($covered | ForEach-Object { Get-Overlap $_ $paintedLocal } | Where-Object { $null -ne $_ })
    $state = "partial"
    if ((Get-UnionArea $inPainted) -ge ($paintedLocal.width * $paintedLocal.height)) { $state = "full" }
    return [pscustomobject]@{ state = $state; covered = $covered.ToArray() }
}

function ConvertFrom-Rect($rect) {
    return New-Frame $rect.Left $rect.Top ($rect.Right - $rect.Left) ($rect.Bottom - $rect.Top)
}

# What covers a top-level window now: minimized, or Get-CoveredRegions from the z-order above it.
function Get-WindowCover([IntPtr]$hwnd, $bounds) {
    if ([OCUWin32]::IsIconic($hwnd)) { return [pscustomobject]@{ state = "minimized"; covered = @(); visible = $null } }
    if ($null -eq $bounds) { return [pscustomobject]@{ state = ""; covered = @(); visible = $null } }
    try {
        $visible = $null
        $rect = New-Object OCUWin32+RECT
        if ([OCUWin32]::VisibleFrame($hwnd, [ref]$rect)) { $visible = ConvertFrom-Rect $rect }
        $above = [OCUWin32]::WindowRectsAbove($hwnd)
        $rects = $null
        if ($null -ne $above) { $rects = @($above | ForEach-Object { ConvertFrom-Rect $_ }) }
        $cover = Get-CoveredRegions $bounds $rects $visible
        return [pscustomobject]@{ state = $cover.state; covered = @($cover.covered); visible = $visible }
    } catch {
        return [pscustomobject]@{ state = "unknown"; covered = @(); visible = $null }
    }
}

# pi-phone fork: the window a call reads or acts in. An action's snapshot window must still exist and
# belong to the snapshot's process (stale_ref); a get_app_state window_id must belong to an app the
# query matches (not_found).
function Resolve-TargetWindow($operation, [bool]$IsAction) {
    $handle = [long]$operation.windowHandle
    if ($handle -le 0) { return $null }
    $hwnd = [IntPtr]$handle
    $owner = if ([OCUWin32]::IsWindow($hwnd)) { [OCUWin32]::WindowProcessId($hwnd) } else { 0 }
    if ($IsAction) {
        if ($owner -eq 0 -or ($operation.expected_pid -gt 0 -and $owner -ne $operation.expected_pid)) {
            throw (New-OCUError "stale_ref" "The window $handle that the snapshot read is gone or was replaced.")
        }
    } else {
        $matching = @(Get-MatchingProcesses $operation.app | ForEach-Object { $_.Id })
        $title = if ($owner -ne 0) { [OCUWin32]::WindowTitle($hwnd) } else { "" }
        if ($owner -eq 0 -or -not ($matching -contains $owner -or ($title -ne "" -and $title -ilike "*$($operation.app.Trim())*"))) {
            throw (New-OCUError "not_found" "No window $handle of an app matching '$($operation.app)'.")
        }
    }
    return [pscustomobject]@{ hwnd = $hwnd; process = (Get-Process -Id $owner) }
}

# pi-phone fork: the other windows the query matches, so a caller can read one by window_id.
function Get-OtherWindows([string]$query, [long]$chosen, [int]$limit = 8) {
    $others = New-Object System.Collections.Generic.List[object]
    foreach ($process in @(Get-MatchingProcesses $query)) {
        foreach ($handle in [OCUWin32]::WindowsOfProcess($process.Id)) {
            if ($handle -ne $chosen -and $others.Count -lt $limit) {
                $others.Add([pscustomobject]@{ id = [string]$handle; title = (Limit-Text ([OCUWin32]::WindowTitle([IntPtr]$handle)) 80); app = $process.ProcessName })
            }
        }
    }
    return $others.ToArray()
}

# Physical input needs the environment gate and this call's headed: true.
function Assert-Headed([string]$what) {
    if (-not $script:HeadedThisCall) {
        throw (New-OCUError "policy_denied" "Refused: $what is physical input and needs headed: true on the call.")
    }
}

function Get-FocusedElementOf($process) {
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $focused -and $focused.Current.ProcessId -eq $process.Id) {
            return $focused
        }
    } catch {
    }
    return $null
}

# Whether a press_key chord types a character (a, shift+a, space), not a command (ctrl+a, Return).
function Test-KeyTypesCharacter([string]$key) {
    $parts = @(([string]$key).Split("+") | Where-Object { $_ -ne "" })
    if ($parts.Count -eq 0) {
        return $false
    }
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        if ($parts[$i].ToLowerInvariant() -ne "shift") {
            return $false
        }
    }
    $main = $parts[$parts.Count - 1]
    return ($main.Length -eq 1 -or $main.ToLowerInvariant() -eq "space" -or ($main.StartsWith("KP_") -and $main.Length -eq 4))
}

function New-Frame($x, $y, $width, $height) {
    if ($width -lt 0 -or $height -lt 0) {
        return $null
    }
    [pscustomobject]@{
        x = [double]$x
        y = [double]$y
        width = [double]$width
        height = [double]$height
    }
}

function ConvertTo-LParam([int]$x, [int]$y) {
    $packed = (($y -band 0xffff) -shl 16) -bor ($x -band 0xffff)
    [IntPtr]$packed
}

function ConvertTo-WheelWParam([int]$delta) {
    $packed = (($delta -band 0xffff) -shl 16)
    [IntPtr]$packed
}

function Get-WindowRectFrame([IntPtr]$hwnd) {
    $rect = New-Object OCUWin32+RECT
    if ([OCUWin32]::GetWindowRect($hwnd, [ref]$rect)) {
        return New-Frame $rect.Left $rect.Top ($rect.Right - $rect.Left) ($rect.Bottom - $rect.Top)
    }
    return $null
}

function Get-VirtualScreenFrame {
    $x = [OCUWin32]::GetSystemMetrics(76)
    $y = [OCUWin32]::GetSystemMetrics(77)
    $width = [OCUWin32]::GetSystemMetrics(78)
    $height = [OCUWin32]::GetSystemMetrics(79)
    if ($width -le 0 -or $height -le 0) {
        return $null
    }
    return New-Frame $x $y $width $height
}

function Test-FrameIntersectsVirtualScreen($frame) {
    if ($null -eq $frame) {
        return $false
    }
    $virtualScreen = Get-VirtualScreenFrame
    if ($null -eq $virtualScreen) {
        return $false
    }
    return (
        $frame.x -lt ($virtualScreen.x + $virtualScreen.width) -and
        ($frame.x + $frame.width) -gt $virtualScreen.x -and
        $frame.y -lt ($virtualScreen.y + $virtualScreen.height) -and
        ($frame.y + $frame.height) -gt $virtualScreen.y
    )
}

function Test-CapturableFrame($frame) {
    if ($null -eq $frame) {
        return $false
    }
    if ($frame.width -lt $MinimumScreenshotDimension -or $frame.height -lt $MinimumScreenshotDimension) {
        return $false
    }
    if (($frame.width * $frame.height) -lt $MinimumScreenshotArea) {
        return $false
    }
    return Test-FrameIntersectsVirtualScreen $frame
}

function Get-CapturableWindowFrame([IntPtr]$hwnd) {
    if ($hwnd -eq [IntPtr]::Zero) {
        return $null
    }
    if (-not [OCUWin32]::IsWindowVisible($hwnd) -or [OCUWin32]::IsIconic($hwnd)) {
        return $null
    }
    try {
        [int]$cloaked = 0
        $result = [OCUWin32]::DwmGetWindowAttribute($hwnd, 14, [ref]$cloaked, 4)
        if ($result -ne 0 -or $cloaked -ne 0) {
            return $null
        }
    } catch {
        # An unknown DWM visibility state is not a trustworthy screenshot
        # source. Keep the accessibility tree, but fail closed for the image.
        return $null
    }
    $frame = Get-WindowRectFrame $hwnd
    if (-not (Test-CapturableFrame $frame)) {
        return $null
    }
    return $frame
}

function Get-ElementFrame($element, $windowBounds) {
    try {
        $rect = $element.Current.BoundingRectangle
        if ($rect.IsEmpty -or $rect.Width -le 0 -or $rect.Height -le 0) {
            return $null
        }
        if ($null -ne $windowBounds) {
            return New-Frame ($rect.X - $windowBounds.x) ($rect.Y - $windowBounds.y) $rect.Width $rect.Height
        }
        return New-Frame $rect.X $rect.Y $rect.Width $rect.Height
    } catch {
        return $null
    }
}

function Get-ScreenPoint($localFrame, $windowBounds) {
    Assert-UsableWindowBounds $windowBounds
    if ($null -eq $localFrame) {
        throw "No usable element frame is available for screenshot-coordinate input."
    }
    [pscustomobject]@{
        x = [int][math]::Round($windowBounds.x + $localFrame.x + ($localFrame.width / 2))
        y = [int][math]::Round($windowBounds.y + $localFrame.y + ($localFrame.height / 2))
    }
}

function Assert-UsableWindowBounds($windowBounds) {
    if (-not (Test-CapturableFrame $windowBounds)) {
        throw "No usable screenshot coordinates are available. Restore a visible, non-minimized, on-screen window and run get_app_state again."
    }
}

function Test-GlobalPointerFallbackEnabled {
    # pi-phone fork: and only on a call with headed: true.
    return ((Test-EnvFlagEnabled "OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS") -and $script:HeadedThisCall)
}

function Assert-GlobalInputTarget([IntPtr]$hwnd, [bool]$AllowActivation = $true) {
    if (-not (Test-GlobalPointerFallbackEnabled)) { throw (New-OCUError "policy_denied" "Global input requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 and headed: true on the call") }
    if ($null -eq (Get-CapturableWindowFrame $hwnd)) { throw "Global input requires a visible, usable target window. Run get_app_state again." }
    if ([OCUWin32]::GetForegroundWindow() -ne $hwnd -and $AllowActivation) {
        [void][OCUWin32]::SetForegroundWindow($hwnd)
        Start-Sleep -Milliseconds 100
    }
    if ([OCUWin32]::GetForegroundWindow() -ne $hwnd) {
        throw "Global input refused: target window is not foreground. Activate the target and observe it again."
    }
}

function Assert-CurrentWindowBounds([IntPtr]$hwnd, $expected) {
    Assert-UsableWindowBounds $expected
    $current = Get-CapturableWindowFrame $hwnd
    foreach ($field in @("x", "y", "width", "height")) {
        if ($null -eq $current -or [double]$current.$field -ne [double]$expected.$field) {
            throw "Window geometry changed; run get_app_state before coordinate input."
        }
    }
}

function Assert-GlobalPointerTarget([IntPtr]$hwnd, [int]$x, [int]$y, $bounds, [bool]$AllowActivation = $true) {
    Assert-CurrentWindowBounds $hwnd $bounds
    if ($x -lt $bounds.x -or $y -lt $bounds.y -or $x -ge ($bounds.x + $bounds.width) -or $y -ge ($bounds.y + $bounds.height)) {
        throw "Global input point is outside the observed target window."
    }
    Assert-GlobalInputTarget $hwnd $AllowActivation
    $point = New-Object OCUWin32+POINT
    $point.X = $x; $point.Y = $y
    $hit = [OCUWin32]::WindowFromPoint($point)
    if ($hit -eq [IntPtr]::Zero -or [OCUWin32]::GetAncestor($hit, 2) -ne $hwnd) {
        throw (New-OCUError "covered" "Global input refused: point is covered by another window.")
    }
}

function Resolve-GlobalElementPoint($element, $record, $bounds) {
    if ($null -eq $element -or @($record.runtimeId).Count -eq 0 -or
        -not (Same-RuntimeId @($element.GetRuntimeId()) @($record.runtimeId))) {
        throw "Observed element is no longer available; run get_app_state before physical input."
    }
    $current = Get-ElementFrame $element $bounds
    foreach ($field in @("x", "y", "width", "height")) {
        if ($null -eq $current -or $null -eq $record.frame -or
            [math]::Abs([double]$current.$field - [double]$record.frame.$field) -gt 1) {
            throw "Element geometry changed; run get_app_state before physical input."
        }
    }
    return Get-ScreenPoint $current $bounds
}

function Send-GlobalMouseMove([IntPtr]$hwnd, [int]$x, [int]$y, $bounds, [bool]$AllowActivation = $true) {
    Assert-GlobalPointerTarget $hwnd $x $y $bounds $AllowActivation
    if (-not [OCUWin32]::SetCursorPos($x, $y)) { throw "SetCursorPos failed" }
    Assert-GlobalPointerTarget $hwnd $x $y $bounds $false
}

function Send-GlobalMouseClick([IntPtr]$hwnd, [int]$screenX, [int]$screenY, [string]$button, [int]$count, $bounds) {
    if ($button -notin @("left", "right", "middle")) { throw "Unsupported global mouse button: $button" }
    if ($count -lt 1 -or $count -gt 3) { throw "Global click_count must be between 1 and 3." }
    $down = $MOUSEEVENTF_LEFTDOWN; $up = $MOUSEEVENTF_LEFTUP; $virtualKey = 1
    if ($button -eq "right") { $down = $MOUSEEVENTF_RIGHTDOWN; $up = $MOUSEEVENTF_RIGHTUP; $virtualKey = 2 }
    elseif ($button -eq "middle") { $down = $MOUSEEVENTF_MIDDLEDOWN; $up = $MOUSEEVENTF_MIDDLEUP; $virtualKey = 4 }
    if ([OCUWin32]::GetAsyncKeyState($virtualKey) -lt 0) { throw "Mouse button is already held; global input refused." }
    Send-GlobalMouseMove $hwnd $screenX $screenY $bounds
    for ($i = 0; $i -lt [math]::Max(1, $count); $i++) {
        Assert-GlobalPointerTarget $hwnd $screenX $screenY $bounds $false
        try {
            [OCUWin32]::MouseInput($down, 0)
            Start-Sleep -Milliseconds 30
        } finally { [OCUWin32]::MouseInput($up, 0) }
        Start-Sleep -Milliseconds 60
    }
}

function Send-MouseClick([IntPtr]$hwnd, [int]$screenX, [int]$screenY, [string]$button, [int]$count) {
    $point = New-Object OCUWin32+POINT
    $point.X = $screenX
    $point.Y = $screenY
    [void][OCUWin32]::ScreenToClient($hwnd, [ref]$point)
    $lParam = ConvertTo-LParam $point.X $point.Y

    $down = $WM_LBUTTONDOWN
    $up = $WM_LBUTTONUP
    $downFlag = 0x0001
    if ($button -eq "right") {
        $down = $WM_RBUTTONDOWN
        $up = $WM_RBUTTONUP
        $downFlag = 0x0002
    } elseif ($button -eq "middle") {
        $down = $WM_MBUTTONDOWN
        $up = $WM_MBUTTONUP
        $downFlag = 0x0010
    }

    $repeat = [math]::Max(1, $count)
    for ($i = 0; $i -lt $repeat; $i++) {
        [void][OCUWin32]::PostMessage($hwnd, $WM_MOUSEMOVE, [IntPtr]::Zero, $lParam)
        [void][OCUWin32]::PostMessage($hwnd, $down, [IntPtr]$downFlag, $lParam)
        Start-Sleep -Milliseconds 35
        [void][OCUWin32]::PostMessage($hwnd, $up, [IntPtr]::Zero, $lParam)
        Start-Sleep -Milliseconds 50
    }
}

function Send-Drag([IntPtr]$hwnd, [int]$fromX, [int]$fromY, [int]$toX, [int]$toY, $bounds) {
    if (Test-GlobalPointerFallbackEnabled) {
        Assert-GlobalPointerTarget $hwnd $toX $toY $bounds
        if ([OCUWin32]::GetAsyncKeyState(1) -lt 0) { throw "Mouse button is already held; global input refused." }
        Send-GlobalMouseMove $hwnd $fromX $fromY $bounds
        try {
            [OCUWin32]::MouseInput($MOUSEEVENTF_LEFTDOWN, 0)
            for ($i = 1; $i -le 12; $i++) {
                $x = [int][math]::Round($fromX + (($toX - $fromX) * $i / 12))
                $y = [int][math]::Round($fromY + (($toY - $fromY) * $i / 12))
                Send-GlobalMouseMove $hwnd $x $y $bounds $false
                Start-Sleep -Milliseconds 20
            }
        } finally { [OCUWin32]::MouseInput($MOUSEEVENTF_LEFTUP, 0) }
        return
    }
    $start = New-Object OCUWin32+POINT
    $start.X = $fromX
    $start.Y = $fromY
    [void][OCUWin32]::ScreenToClient($hwnd, [ref]$start)
    $end = New-Object OCUWin32+POINT
    $end.X = $toX
    $end.Y = $toY
    [void][OCUWin32]::ScreenToClient($hwnd, [ref]$end)

    $steps = 12
    $startParam = ConvertTo-LParam $start.X $start.Y
    [void][OCUWin32]::PostMessage($hwnd, $WM_MOUSEMOVE, [IntPtr]::Zero, $startParam)
    [void][OCUWin32]::PostMessage($hwnd, $WM_LBUTTONDOWN, [IntPtr]1, $startParam)
    for ($i = 1; $i -le $steps; $i++) {
        $x = [int][math]::Round($start.X + (($end.X - $start.X) * $i / $steps))
        $y = [int][math]::Round($start.Y + (($end.Y - $start.Y) * $i / $steps))
        [void][OCUWin32]::PostMessage($hwnd, $WM_MOUSEMOVE, [IntPtr]1, (ConvertTo-LParam $x $y))
        Start-Sleep -Milliseconds 20
    }
    [void][OCUWin32]::PostMessage($hwnd, $WM_LBUTTONUP, [IntPtr]::Zero, (ConvertTo-LParam $end.X $end.Y))
}

function Send-Scroll([IntPtr]$hwnd, [int]$screenX, [int]$screenY, [string]$direction, [double]$pages, $bounds) {
    if (Test-GlobalPointerFallbackEnabled) {
        Send-GlobalMouseMove $hwnd $screenX $screenY $bounds
        $delta = [int][math]::Round(120 * $pages)
        if ($direction -eq "down" -or $direction -eq "left") { $delta = -1 * $delta }
        $message = $MOUSEEVENTF_WHEEL
        if ($direction -eq "left" -or $direction -eq "right") { $message = $MOUSEEVENTF_HWHEEL }
        Assert-GlobalPointerTarget $hwnd $screenX $screenY $bounds $false
        [OCUWin32]::MouseInput($message, $delta)
        Start-Sleep -Milliseconds 120
        return
    }
    # WM_MOUSEWHEEL / WM_MOUSEHWHEEL carry screen coordinates, unlike clicks.
    $lParam = ConvertTo-LParam $screenX $screenY
    $delta = [int][math]::Round(120 * $pages)
    $message = $WM_MOUSEWHEEL
    if ($direction -eq "down" -or $direction -eq "left") {
        $delta = -1 * $delta
    }
    if ($direction -eq "left" -or $direction -eq "right") {
        $message = $WM_MOUSEHWHEEL
    }
    if (-not [OCUWin32]::PostMessage($hwnd, $message, (ConvertTo-WheelWParam $delta), $lParam)) {
        throw "PostMessage wheel delivery failed."
    }
}

function Send-Text([IntPtr]$hwnd, [string]$text) {
    foreach ($char in $text.ToCharArray()) {
        [void][OCUWin32]::PostMessage($hwnd, $WM_CHAR, [IntPtr][int][char]$char, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 8
    }
}

function Send-TextToEditHandle([IntPtr]$hwnd, [string]$text, $element) {
    if ($hwnd -eq [IntPtr]::Zero) {
        return $false
    }

    try {
        [void][OCUWin32]::SendMessage($hwnd, $EM_SETSEL, [IntPtr](-1), [IntPtr](-1))
        [void][OCUWin32]::SendMessage($hwnd, $EM_REPLACESEL, [IntPtr]1, $text)
        return $true
    } catch {
    }

    try {
        $current = ""
        if ($null -ne $element) {
            $current = Get-ElementValue $element
        }
        [void][OCUWin32]::SendMessage($hwnd, $WM_SETTEXT, [IntPtr]::Zero, ($current + $text))
        return $true
    } catch {
        return $false
    }
}

function Get-VirtualKey([string]$key) {
    $normalized = $key.ToLowerInvariant()
    $map = @{
        "return" = 0x0D; "enter" = 0x0D; "tab" = 0x09; "escape" = 0x1B; "esc" = 0x1B
        "backspace" = 0x08; "back_space" = 0x08; "delete" = 0x2E; "space" = 0x20
        "left" = 0x25; "up" = 0x26; "right" = 0x27; "down" = 0x28
        "home" = 0x24; "end" = 0x23; "page_up" = 0x21; "prior" = 0x21; "page_down" = 0x22; "next" = 0x22
    }
    if ($map.ContainsKey($normalized)) {
        return $map[$normalized]
    }
    if ($normalized -match "^f([1-9]|1[0-2])$") {
        return 0x70 + [int]$Matches[1] - 1
    }
    if ($normalized -match "^kp_([0-9])$") {
        return 0x60 + [int]$Matches[1]
    }
    if ($normalized.Length -eq 1) {
        $code = [int][char]$normalized.ToUpperInvariant()[0]
        if (($code -ge 0x30 -and $code -le 0x39) -or ($code -ge 0x41 -and $code -le 0x5A)) {
            return $code
        }
    }
    throw "Unsupported key: $key"
}

function Send-Key([IntPtr]$hwnd, [string]$key, [string]$method = "auto") {
    if ($method -eq "global") {
        $parts = $key -split "\+"
        # Resolve and validate the entire chord before any key goes down.
        $vk = Get-VirtualKey $parts[-1]
        $modifiers = New-Object System.Collections.Generic.List[int]
        foreach ($part in $parts[0..([math]::Max(0, $parts.Length - 2))]) {
            if ($parts.Length -eq 1) { break }
            $modifier = switch ($part.ToLowerInvariant()) {
                "ctrl" { 0x11 }; "control" { 0x11 }; "shift" { 0x10 }; "alt" { 0x12 }
                "super" { 0x5B }; "win" { 0x5B }; "cmd" { 0x5B }
                default { throw "Unsupported key modifier: $part" }
            }
            if (-not $modifiers.Contains($modifier)) { $modifiers.Add($modifier) }
        }
        $keys = @($modifiers.ToArray()) + @($vk)
        foreach ($item in $keys) {
            if ([OCUWin32]::GetAsyncKeyState($item) -lt 0) { throw "Requested key is already held; global input refused." }
        }
        Assert-GlobalInputTarget $hwnd
        $pressed = New-Object System.Collections.Generic.List[int]
        try {
            foreach ($item in $keys) {
                Assert-GlobalInputTarget $hwnd $false
                $pressed.Add($item)
                [OCUWin32]::KeyInput($item, $false)
            }
            Start-Sleep -Milliseconds 30
        } finally {
            $cleanupErrors = @()
            for ($i = $pressed.Count - 1; $i -ge 0; $i--) {
                try { [OCUWin32]::KeyInput($pressed[$i], $true) } catch { $cleanupErrors += $_ }
            }
            if ($cleanupErrors.Count -gt 0) { throw "Global key release failed: $($cleanupErrors -join '; ')" }
        }
        return
    }
    $parts = $key -split "\+"
    $main = $parts[$parts.Length - 1]
    $modifiers = @()
    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
        switch ($parts[$i].ToLowerInvariant()) {
            "ctrl" { $modifiers += 0x11 }
            "control" { $modifiers += 0x11 }
            "shift" { $modifiers += 0x10 }
            "alt" { $modifiers += 0x12 }
            "super" { $modifiers += 0x5B }
            "win" { $modifiers += 0x5B }
            "cmd" { $modifiers += 0x5B }
        }
    }
    foreach ($modifier in $modifiers) {
        [void][OCUWin32]::PostMessage($hwnd, $WM_KEYDOWN, [IntPtr]$modifier, [IntPtr]::Zero)
    }
    $vk = Get-VirtualKey $main
    [void][OCUWin32]::PostMessage($hwnd, $WM_KEYDOWN, [IntPtr]$vk, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 25
    [void][OCUWin32]::PostMessage($hwnd, $WM_KEYUP, [IntPtr]$vk, [IntPtr]::Zero)
    [array]::Reverse($modifiers)
    foreach ($modifier in $modifiers) {
        [void][OCUWin32]::PostMessage($hwnd, $WM_KEYUP, [IntPtr]$modifier, [IntPtr]::Zero)
    }
}

# Every process with a main window that the query names (pid, process name or window title), in the
# order Resolve-App picks from. pi-phone fork: also lists the other windows a query matches.
function Get-MatchingProcesses([string]$query) {
    $normalized = $query.Trim()
    $processQuery = $normalized
    if ($processQuery.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) {
        $processQuery = $processQuery.Substring(0, $processQuery.Length - 4)
    }
    $processes = @(Get-Process | Where-Object { $_.MainWindowHandle -ne 0 })
    $pidValue = 0
    if ([int]::TryParse($normalized, [ref]$pidValue)) {
        $match = @($processes | Where-Object { $_.Id -eq $pidValue })
        if ($match.Count -gt 0) {
            return $match
        }
    }
    return @($processes | Where-Object {
        $_.ProcessName -ieq $processQuery -or
        "$($_.ProcessName).exe" -ieq $normalized -or
        $_.MainWindowTitle -ieq $normalized -or
        $_.MainWindowTitle -ilike "*$normalized*"
    })
}

function Resolve-App([string]$query) {
    $normalized = $query.Trim()
    $match = @(Get-MatchingProcesses $query) | Select-Object -First 1
    if ($null -ne $match) {
        return $match
    }

    if (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH") {
        try {
            $started = Start-Process -FilePath $normalized -PassThru
            for ($i = 0; $i -lt 20; $i++) {
                Start-Sleep -Milliseconds 250
                $candidate = Get-Process -Id $started.Id -ErrorAction SilentlyContinue
                if ($null -ne $candidate -and $candidate.MainWindowHandle -ne 0) {
                    return $candidate
                }
            }
        } catch {
        }
    }

    throw (New-OCUError "not_found" "appNotFound(`"$query`")")
}

# pi-phone fork: the window this call reads or acts in, when it is not the process's main window.
$script:TargetWindow = [IntPtr]::Zero
$script:TargetProcess = $null

function Get-TargetHandle($process) {
    if ($script:TargetWindow -ne [IntPtr]::Zero) { return $script:TargetWindow }
    return [IntPtr]$process.MainWindowHandle
}

function Get-MainElement($process) {
    if ($script:TargetWindow -ne [IntPtr]::Zero) {
        return [Windows.Automation.AutomationElement]::FromHandle($script:TargetWindow)
    }
    if ($process.MainWindowHandle -ne 0) {
        return [Windows.Automation.AutomationElement]::FromHandle([IntPtr]$process.MainWindowHandle)
    }
    $condition = New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::ProcessIdProperty), $process.Id
    $children = [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $condition)
    if ($children.Count -gt 0) {
        return $children.Item(0)
    }
    throw "No top-level UI Automation window is available for $($process.ProcessName). Run the Windows runtime in the signed-in desktop session."
}

function Get-WindowBounds($process, $element) {
    $hwnd = Get-TargetHandle $process
    return Get-CapturableWindowFrame $hwnd
}

function Get-PatternNames($element) {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $element.GetSupportedPatterns()) {
        $programmatic = $pattern.ProgrammaticName
        if ($programmatic -like "InvokePatternIdentifiers.Pattern") { $names.Add("Invoke") }
        elseif ($programmatic -like "TogglePatternIdentifiers.Pattern") { $names.Add("Toggle") }
        elseif ($programmatic -like "SelectionItemPatternIdentifiers.Pattern") { $names.Add("Select") }
        elseif ($programmatic -like "ExpandCollapsePatternIdentifiers.Pattern") {
            try {
                $state = $element.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState
                if ($state -eq [Windows.Automation.ExpandCollapseState]::Collapsed) { $names.Add("Expand") }
                elseif ($state -eq [Windows.Automation.ExpandCollapseState]::Expanded) { $names.Add("Collapse") }
            } catch {
                $names.Add("Expand")
                $names.Add("Collapse")
            }
        }
        elseif ($programmatic -like "ScrollItemPatternIdentifiers.Pattern") { $names.Add("ScrollIntoView") }
        elseif ($programmatic -like "ScrollPatternIdentifiers.Pattern") { $names.Add("Scroll") }
        elseif ($programmatic -like "ValuePatternIdentifiers.Pattern") { $names.Add("SetValue") }
    }
    if ($names.Count -gt 0) {
        return @($names | Select-Object -Unique)
    }
    return @()
}

function Get-ElementString($element, [string]$propertyName) {
    try {
        $value = $element.Current.$propertyName
        if ($null -eq $value) {
            return ""
        }
        return [string]$value
    } catch {
        return ""
    }
}

function Get-ElementInt64($element, [string]$propertyName) {
    try {
        return [int64]$element.Current.$propertyName
    } catch {
        return 0
    }
}

function Get-ElementControlTypeName($element) {
    try {
        $controlType = $element.Current.ControlType
        if ($null -eq $controlType) {
            return ""
        }
        return [string]$controlType.ProgrammaticName
    } catch {
        return ""
    }
}

function Resolve-TextLimit($Value) {
    if ($null -eq $Value) {
        return $script:DefaultTextLimit
    }
    if ($Value -is [string] -and $Value.Trim().ToLowerInvariant() -eq "max") {
        return $null
    }
    if ($Value -is [bool]) {
        return $script:DefaultTextLimit
    }
    try {
        $integer = [int]$Value
        if ($integer -gt 0) {
            return $integer
        }
    } catch {
    }
    return $script:DefaultTextLimit
}

function Limit-Text([string]$Text, $TextLimit = $script:DefaultTextLimit) {
    if ($null -eq $Text) {
        return ""
    }
    if ($null -eq $TextLimit) {
        return $Text
    }
    $effectiveTextLimit = [int]$TextLimit
    if ($Text.Length -gt $effectiveTextLimit) {
        return $Text.Substring(0, $effectiveTextLimit) + "..."
    }
    return $Text
}

function Get-ElementValue($element, $TextLimit = $script:DefaultTextLimit) {
    try {
        $valuePattern = $element.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
        $value = $valuePattern.Current.Value
        if ($null -eq $value) {
            return ""
        }
        $text = [string]$value
        return Limit-Text $text $TextLimit
    } catch {
        return ""
    }
}

function Get-ElementRecord($element, [int]$index, $windowBounds, $TextLimit = $script:DefaultTextLimit) {
    $frame = Get-ElementFrame $element $windowBounds
    $runtimeId = @()
    try { $runtimeId = @($element.GetRuntimeId()) } catch {}
    $isPassword = Test-ElementIsPassword $element
    $value = ""
    if (-not $isPassword) { $value = Get-ElementValue $element $TextLimit }
    [pscustomobject]@{
        index = $index
        runtimeId = $runtimeId
        automationId = Get-ElementString $element "AutomationId"
        name = Limit-Text (Get-ElementString $element "Name") $TextLimit
        controlType = Get-ElementControlTypeName $element
        localizedControlType = Get-ElementString $element "LocalizedControlType"
        className = Get-ElementString $element "ClassName"
        value = $value
        nativeWindowHandle = Get-ElementInt64 $element "NativeWindowHandle"
        frame = $frame
        actions = @(Get-PatternNames $element)
        isPassword = $isPassword
        states = @(Get-ElementStates $element $isPassword)
    }
}

# One outline line: "<index> <role> <name>[ [password]][ Value: …][ Secondary Actions: …][ States: …][ Frame: {…}]".
function Format-ElementLine($record, [int]$depth) {
    $role = $record.localizedControlType
    if ([string]::IsNullOrWhiteSpace($role)) {
        $role = $record.controlType
    }
    $title = Get-ElementTitle $record
    if ($record.isPassword) {
        $title = ("$title " + $PasswordMarker).Trim()
    }
    $actionsSegment = ""
    if (@($record.actions).Count -gt 0) {
        $actionsSegment = " Secondary Actions: " + (@($record.actions) -join ", ")
    }
    # pi-phone fork: the element's states.
    if (@($record.states).Count -gt 0) {
        $actionsSegment += " States: " + (@($record.states) -join ", ")
    }
    $valueSegment = ""
    if (-not [string]::IsNullOrWhiteSpace($record.value) -and $record.value -ne $title) {
        $safeValue = (($record.value -replace "`r", "\\r") -replace "`n", "\\n")
        $valueSegment = " Value: $safeValue"
    }
    $frameSegment = ""
    if ($null -ne $record.frame) {
        $frameSegment = " Frame: {{x: {0}, y: {1}, width: {2}, height: {3}}}" -f [int][math]::Round($record.frame.x), [int][math]::Round($record.frame.y), [int][math]::Round($record.frame.width), [int][math]::Round($record.frame.height)
    }
    return ("`t" * ($depth + 1)) + "$($record.index) $role $title$valueSegment$actionsSegment$frameSegment"
}

function Get-ElementTitle($record) {
    if (-not [string]::IsNullOrWhiteSpace($record.name)) {
        return $record.name
    }
    if (-not [string]::IsNullOrWhiteSpace($record.automationId)) {
        return "ID: $($record.automationId)"
    }
    return ""
}

function Render-Tree($element, $windowBounds, $TextLimit = $script:DefaultTextLimit, [int]$MaxTreeNodes = $script:AccessibilityTreeMaxNodeCount, [int]$MaxTreeDepth = $script:AccessibilityTreeMaxDepth) {
    $records = New-Object System.Collections.Generic.List[object]
    $lines = New-Object System.Collections.Generic.List[string]
    $visited = New-Object System.Collections.Generic.HashSet[string]
    $nextIndex = 0
    $effectiveMaxTreeNodes = if ($MaxTreeNodes -gt 0) { $MaxTreeNodes } else { $script:AccessibilityTreeMaxNodeCount }
    $effectiveMaxTreeDepth = if ($MaxTreeDepth -gt 0) { $MaxTreeDepth } else { $script:AccessibilityTreeMaxDepth }

    function Visit($node, [int]$depth) {
        if ($script:nextIndex -ge $script:MaxTreeNodes -or $depth -gt $script:MaxTreeDepth) {
            return
        }
        $runtime = ""
        try { $runtime = (@($node.GetRuntimeId()) -join ".") } catch { $runtime = [guid]::NewGuid().ToString() }
        if (-not $script:visited.Add($runtime)) {
            return
        }

        $index = $script:nextIndex
        $script:nextIndex++
        $record = Get-ElementRecord $node $index $script:windowBounds $TextLimit
        $script:records.Add($record)
        $script:lines.Add((Format-ElementLine $record $depth))

        try {
            $children = $node.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition)
            for ($i = 0; $i -lt $children.Count; $i++) {
                Visit $children.Item($i) ($depth + 1)
            }
        } catch {
        }
    }

    $script:records = $records
    $script:lines = $lines
    $script:visited = $visited
    $script:nextIndex = $nextIndex
    $script:windowBounds = $windowBounds
    $script:MaxTreeNodes = $effectiveMaxTreeNodes
    $script:MaxTreeDepth = $effectiveMaxTreeDepth
    Visit $element 0

    [pscustomobject]@{
        records = $records.ToArray()
        lines = $lines.ToArray()
    }
}

# pi-phone fork (PP-271): a screen copy of the window's rectangle shows whatever paints there, so the
# parts other windows cover, and the invisible resize borders outside its painted frame, are blacked out.
function Get-BlackoutRects($bounds, $covered, $visible) {
    $rects = New-Object System.Collections.Generic.List[object]
    foreach ($rect in @($covered)) { if ($null -ne $rect) { $rects.Add($rect) } }
    if ($null -ne $visible) {
        $left = [math]::Max(0, [double]$visible.x - [double]$bounds.x)
        $top = [math]::Max(0, [double]$visible.y - [double]$bounds.y)
        $right = [math]::Min([double]$bounds.width, [double]$visible.x + [double]$visible.width - [double]$bounds.x)
        $bottom = [math]::Min([double]$bounds.height, [double]$visible.y + [double]$visible.height - [double]$bounds.y)
        foreach ($strip in @(
            (New-Frame 0 0 $bounds.width $top),
            (New-Frame 0 $bottom $bounds.width ($bounds.height - $bottom)),
            (New-Frame 0 $top $left ($bottom - $top)),
            (New-Frame $right $top ($bounds.width - $right) ($bottom - $top))
        )) {
            if ($null -ne $strip -and $strip.width -gt 0 -and $strip.height -gt 0) { $rects.Add($strip) }
        }
    }
    return $rects.ToArray()
}

function Capture-WindowPngBase64($bounds, $covered = @(), $visible = $null) {
    if (-not (Test-CapturableFrame $bounds)) {
        return $null
    }
    $bitmap = $null
    $graphics = $null
    $stream = $null
    try {
        $bitmap = New-Object System.Drawing.Bitmap ([int][math]::Round($bounds.width)), ([int][math]::Round($bounds.height))
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen([int][math]::Round($bounds.x), [int][math]::Round($bounds.y), 0, 0, $bitmap.Size)
        foreach ($rect in (Get-BlackoutRects $bounds $covered $visible)) {
            $graphics.FillRectangle([System.Drawing.Brushes]::Black, [float]$rect.x, [float]$rect.y, [float]$rect.width, [float]$rect.height)
        }
        $stream = New-Object System.IO.MemoryStream
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $stream.ToArray()
        return [Convert]::ToBase64String($bytes)
    } catch {
        return $null
    } finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-FocusedSummary($processId, $TextLimit = $script:DefaultTextLimit) {
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $focused -and $focused.Current.ProcessId -eq $processId) {
            $role = $focused.Current.LocalizedControlType
            $name = Limit-Text $focused.Current.Name $TextLimit
            $summary = "$role $name".Trim()
            if (Test-ElementIsPassword $focused) {
                $summary = "$summary $PasswordMarker"
            }
            return $summary
        }
    } catch {
    }
    return $null
}

function Get-SelectedText($processId, $TextLimit = $script:DefaultTextLimit) {
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -eq $focused -or $focused.Current.ProcessId -ne $processId) {
            return $null
        }
        if (Test-ElementIsPassword $focused) {
            return $null
        }
        $textPattern = $focused.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern)
        $selection = $textPattern.GetSelection()
        if ($selection.Count -gt 0) {
            $maxLength = if ($null -eq $TextLimit) { -1 } else { [int]$TextLimit + 1 }
            return Limit-Text ($selection.Item(0).GetText($maxLength)) $TextLimit
        }
    } catch {
    }
    return $null
}

function Resolve-ObservationOptions($operation) {
    $values = @{ include_ax = $true; include_screenshot = $true }
    foreach ($key in @("include_ax", "include_screenshot")) {
        $property = $operation.PSObject.Properties[$key]
        if ($null -ne $property) {
            if ($property.Value -isnot [bool]) { throw "$key must be a boolean" }
            $values[$key] = $property.Value
        }
    }
    if (-not $values.include_ax -and -not $values.include_screenshot) {
        throw "At least one of include_ax or include_screenshot must be true"
    }
    return [pscustomobject]$values
}

function Build-Snapshot([string]$query, $TextLimit = $script:DefaultTextLimit, [int]$MaxTreeNodes = $script:AccessibilityTreeMaxNodeCount, [int]$MaxTreeDepth = $script:AccessibilityTreeMaxDepth, [bool]$IncludeAX = $true, [bool]$IncludeScreenshot = $true) {
    if (-not $IncludeAX -and -not $IncludeScreenshot) {
        throw "At least one of include_ax or include_screenshot must be true"
    }
    # pi-phone fork: a window named by window_id (Resolve-TargetWindow sets TargetWindow and its process).
    if ($null -ne $script:TargetProcess) { $process = $script:TargetProcess } else { $process = Resolve-App $query }
    $element = Get-MainElement $process
    $bounds = Get-WindowBounds $process $element
    $handle = Get-TargetHandle $process
    $rendered = @{ lines = @(); records = @() }
    $focus = $null
    $selection = $null
    $image = $null
    $cover = $null
    if ($IncludeAX) {
        $rendered = Render-Tree $element $bounds $TextLimit $MaxTreeNodes $MaxTreeDepth
        $focus = Get-FocusedSummary $process.Id $TextLimit
        $selection = Get-SelectedText $process.Id $TextLimit
    }
    if ($IncludeScreenshot) {
        $cover = Get-WindowCover $handle $bounds
        if ($cover.state -notin @("full", "minimized")) { $image = Capture-WindowPngBase64 $bounds $cover.covered $cover.visible }
    }
    $title = $process.MainWindowTitle
    if ($handle -ne [IntPtr]$process.MainWindowHandle) { $title = [OCUWin32]::WindowTitle($handle) }
    $coverState = ""
    $covered = @()
    if ($null -ne $cover) { $coverState = $cover.state; $covered = @($cover.covered) }
    [pscustomobject]@{
        app = [pscustomobject]@{
            name = $process.ProcessName
            bundleIdentifier = $process.ProcessName
            pid = [int]$process.Id
        }
        windowHandle = [long]$handle
        otherWindows = @(Get-OtherWindows $query ([long]$handle))
        cover = $coverState
        covered = $covered
        windowTitle = Limit-Text $title $TextLimit
        windowBounds = $bounds
        screenshotPngBase64 = $image
        treeLines = @($rendered.lines)
        focusedSummary = $focus
        selectedText = $selection
        elements = @($rendered.records)
    }
}

function List-Apps {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($process in (Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } | Sort-Object ProcessName, Id)) {
        if ($null -eq (Get-CapturableWindowFrame ([IntPtr]$process.MainWindowHandle))) {
            continue
        }
        $title = $process.MainWindowTitle
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = "untitled"
        }
        $lines.Add(("{0} -- {1} [running, pid={2}, window={3}]" -f $process.ProcessName, $process.ProcessName, $process.Id, $title))
    }
    return ($lines -join "`n")
}

function Same-RuntimeId($left, $right) {
    if ($null -eq $left -or $null -eq $right -or $left.Count -ne $right.Count) {
        return $false
    }
    for ($i = 0; $i -lt $left.Count; $i++) {
        if ([int]$left[$i] -ne [int]$right[$i]) {
            return $false
        }
    }
    return $true
}

function Get-AllElements($root) {
    $items = New-Object System.Collections.Generic.List[object]
    $items.Add($root)
    try {
        $descendants = $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
        for ($i = 0; $i -lt $descendants.Count; $i++) {
            $items.Add($descendants.Item($i))
        }
    } catch {
    }
    return $items.ToArray()
}

# pi-phone fork: the live element the snapshot's record names, or a stale_ref refusal. Never acts on
# a re-numbered element: the element with the recorded UIA RuntimeId must still be the one the snapshot
# saw (role, name, actions); without a RuntimeId only one unambiguous match counts.
function Find-Element($process, $record) {
    if ($null -eq $record) {
        return $null
    }
    $root = Get-MainElement $process
    $runtimeId = @($record.runtimeId)
    if ($runtimeId.Count -gt 0) {
        foreach ($element in (Get-AllElements $root)) {
            $same = $false
            try { $same = Same-RuntimeId @($element.GetRuntimeId()) $runtimeId } catch {}
            if ($same) {
                if (Test-RecordMatches (Get-LiveIdentity $element) $record) {
                    return $element
                }
                throw (New-StaleElementError $record "it changed")
            }
        }
        throw (New-StaleElementError $record "it went away")
    }
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($element in (Get-AllElements $root)) {
        try {
            $sameAutomationId = -not [string]::IsNullOrWhiteSpace($record.automationId) -and $element.Current.AutomationId -eq $record.automationId
            $sameName = -not [string]::IsNullOrWhiteSpace($record.name) -and $element.Current.Name -eq $record.name
            $sameType = $element.Current.ControlType.ProgrammaticName -eq $record.controlType
            if (($sameAutomationId -or $sameName) -and $sameType) {
                $candidates.Add($element)
            }
        } catch {
        }
    }
    if ($candidates.Count -eq 1) { return $candidates[0] }
    if ($candidates.Count -gt 1) {
        throw (New-OCUError "ambiguous_target" ("[{0}] matches {1} elements now ({2} '{3}')." -f $record.index, $candidates.Count, $record.controlType, $record.name))
    }
    throw (New-StaleElementError $record "it went away")
}

function Get-CurrentPatternOrNull($element, $pattern) {
    try {
        return $element.GetCurrentPattern($pattern)
    } catch {
        return $null
    }
}

function Invoke-PreferredClick($element) {
    $invoke = Get-CurrentPatternOrNull $element ([Windows.Automation.InvokePattern]::Pattern)
    if ($null -ne $invoke) {
        $invoke.Invoke()
        return $true
    }
    $selection = Get-CurrentPatternOrNull $element ([Windows.Automation.SelectionItemPattern]::Pattern)
    if ($null -ne $selection) {
        $selection.Select()
        return $true
    }
    $toggle = Get-CurrentPatternOrNull $element ([Windows.Automation.TogglePattern]::Pattern)
    if ($null -ne $toggle) {
        $toggle.Toggle()
        return $true
    }
    return $false
}

function Invoke-SecondaryAction($element, [string]$action) {
    switch ($action.ToLowerInvariant()) {
        "invoke" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.InvokePattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Invoke(); return }
        }
        "toggle" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.TogglePattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Toggle(); return }
        }
        "select" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.SelectionItemPattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Select(); return }
        }
        "expand" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ExpandCollapsePattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Expand(); return }
        }
        "collapse" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ExpandCollapsePattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Collapse(); return }
        }
        "scrollintoview" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ScrollItemPattern]::Pattern)
            if ($null -ne $pattern) { $pattern.ScrollIntoView(); return }
        }
        "setfocus" {
            if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS")) {
                throw "SetFocus is disabled by default to avoid stealing user focus; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1 to enable it."
            }
            $element.SetFocus()
            return
        }
    }
    throw "$action is not a valid secondary action for $($operation.element.index)"
}

function Invoke-Scroll($element, [string]$direction, [double]$pages) {
    $scroll = Get-CurrentPatternOrNull $element ([Windows.Automation.ScrollPattern]::Pattern)
    if ($null -eq $scroll) {
        return $false
    }
    $horizontal = [Windows.Automation.ScrollAmount]::NoAmount
    $vertical = [Windows.Automation.ScrollAmount]::NoAmount
    if ($direction -eq "up") { $vertical = [Windows.Automation.ScrollAmount]::LargeDecrement }
    elseif ($direction -eq "down") { $vertical = [Windows.Automation.ScrollAmount]::LargeIncrement }
    elseif ($direction -eq "left") { $horizontal = [Windows.Automation.ScrollAmount]::LargeDecrement }
    elseif ($direction -eq "right") { $horizontal = [Windows.Automation.ScrollAmount]::LargeIncrement }
    $repeat = [math]::Max(1, [int][math]::Ceiling($pages))
    for ($i = 0; $i -lt $repeat; $i++) {
        try {
            $scroll.Scroll($horizontal, $vertical)
        } catch {
            # ScrollPattern can exist while the element still refuses to scroll in
            # its current state, for example a list with two rows. Fall through to
            # the coordinate path instead of failing the whole tool call.
            return $false
        }
        Start-Sleep -Milliseconds 40
    }
    return $true
}

function Find-TextEntryElement($process) {
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $focused -and $focused.Current.ProcessId -eq $process.Id) {
            $focusedValue = Get-CurrentPatternOrNull $focused ([Windows.Automation.ValuePattern]::Pattern)
            if ($null -ne $focusedValue -and -not $focusedValue.Current.IsReadOnly) {
                return $focused
            }
        }
    } catch {
    }

    $root = Get-MainElement $process
    foreach ($element in (Get-AllElements $root)) {
        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -eq $valuePattern -or $valuePattern.Current.IsReadOnly) {
            continue
        }
        $controlType = Get-ElementControlTypeName $element
        if ($controlType -like "*Edit*" -or $controlType -like "*Document*") {
            return $element
        }
    }

    foreach ($element in (Get-AllElements $root)) {
        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -ne $valuePattern -and -not $valuePattern.Current.IsReadOnly) {
            return $element
        }
    }

    return $null
}

function Get-NativeWindowHandle($element) {
    $handle = Get-ElementInt64 $element "NativeWindowHandle"
    if ($handle -le 0) {
        return [IntPtr]::Zero
    }
    return [IntPtr]$handle
}

function Test-TextWindowHandleCandidate($process, $element) {
    if ($null -eq $element) {
        return $false
    }
    $handle = Get-NativeWindowHandle $element
    if ($handle -eq [IntPtr]::Zero -or $handle -eq (Get-TargetHandle $process)) {
        return $false
    }
    $controlType = Get-ElementControlTypeName $element
    $className = Get-ElementString $element "ClassName"
    return (
        $controlType -like "*Edit*" -or
        $controlType -like "*Document*" -or
        $className -like "*Edit*" -or
        $className -like "*Rich*" -or
        $className -like "*Text*"
    )
}

function Find-TextEntryWindowHandle($process, $preferredElement) {
    if (Test-TextWindowHandleCandidate $process $preferredElement) {
        return Get-NativeWindowHandle $preferredElement
    }

    $root = Get-MainElement $process
    foreach ($element in (Get-AllElements $root)) {
        if (-not (Test-TextWindowHandleCandidate $process $element)) {
            continue
        }
        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -ne $valuePattern -and -not $valuePattern.Current.IsReadOnly) {
            return Get-NativeWindowHandle $element
        }
    }

    foreach ($element in (Get-AllElements $root)) {
        if (Test-TextWindowHandleCandidate $process $element) {
            return Get-NativeWindowHandle $element
        }
    }

    return [IntPtr]::Zero
}

function Invoke-TypeText($process, [string]$text) {
    $element = Find-TextEntryElement $process
    Assert-NotPasswordInput $element
    $targetHwnd = Find-TextEntryWindowHandle $process $element
    if ($targetHwnd -ne [IntPtr]::Zero -and (Send-TextToEditHandle $targetHwnd $text $element)) {
        return $true
    }

    if ($null -ne $element) {
        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -ne $valuePattern -and -not $valuePattern.Current.IsReadOnly) {
            if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK")) {
                throw "UIA ValuePattern text fallback is disabled by default because it may bring the target app to the foreground; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK=1 to enable it."
            }
            $current = ""
            try { $current = [string]$valuePattern.Current.Value } catch {}
            $valuePattern.SetValue($current + $text)
            return $true
        }
    }
    return $false
}

# Read the operation file as UTF-8 explicitly. Windows PowerShell 5.1's
# Get-Content defaults to the system ANSI code page (e.g. GBK on Chinese
# systems) for files without a BOM, which corrupts non-ASCII input such as
# Chinese text passed to set_value/type_text.
$operationJson = [System.IO.File]::ReadAllText($OperationPath, [System.Text.Encoding]::UTF8)
$operation = $operationJson | ConvertFrom-Json

try {
    if ($operation.tool -eq "list_apps") {
        $response = [pscustomobject]@{ ok = $true; text = (List-Apps) }
    } elseif ($operation.tool -eq "get_app_state") {
        $observation = Resolve-ObservationOptions $operation
        $script:TargetProcess = $null
        $target = Resolve-TargetWindow $operation $false
        if ($null -ne $target) { $script:TargetWindow = $target.hwnd; $script:TargetProcess = $target.process }
        $response = [pscustomobject]@{ ok = $true; snapshot = (Build-Snapshot $operation.app (Resolve-TextLimit $operation.text_limit) ([int]$operation.max_tree_nodes) ([int]$operation.max_tree_depth) $observation.include_ax $observation.include_screenshot) }
    } else {
        # pi-phone fork: act in the snapshot's window (stale_ref when it is gone or replaced).
        $target = Resolve-TargetWindow $operation $true
        if ($null -ne $target) {
            $process = $target.process
            $script:TargetWindow = $target.hwnd
        } else {
            $process = Resolve-App $operation.app
            if ($operation.expected_pid -gt 0 -and $process.Id -ne $operation.expected_pid) {
                throw (New-OCUError "stale_ref" "Target process changed; run get_app_state before acting.")
            }
        }
        $hwnd = Get-TargetHandle $process
        $windowBounds = $operation.windowBounds
        $element = Find-Element $process $operation.element
        $script:AllowPasswordInputThisCall = ($operation.allow_password_input -is [bool]) -and $operation.allow_password_input
        $script:HeadedThisCall = ($operation.headed -is [bool]) -and $operation.headed
        if ($operation.tool -eq "drag") { Assert-Headed "drag" }
        if ($operation.tool -eq "click" -and ($null -eq $operation.element -or $operation.click_method -eq "global")) { Assert-Headed "a coordinate or global click" }
        if ($operation.tool -eq "press_key" -and $operation.key_method -eq "global") { Assert-Headed "key_method global" }

        switch ($operation.tool) {
            "click" {
                $clickMethod = [string]$operation.click_method
                if ([string]::IsNullOrWhiteSpace($clickMethod)) { $clickMethod = "auto" }

                if ($clickMethod -eq "accessibility") {
                    if ($null -eq $element) { throw "click_method 'accessibility' requires element_index" }
                    if ($operation.mouse_button -eq "right" -or $operation.mouse_button -eq "middle") {
                        throw "click_method 'accessibility' does not support mouse_button '$($operation.mouse_button)'"
                    }
                    if (-not (Invoke-PreferredClick $element)) {
                        throw "click_method 'accessibility' could not click the requested element"
                    }
                } elseif ($clickMethod -eq "app_post") {
                    Assert-UsableWindowBounds $windowBounds
                    if ($null -ne $operation.element -and $null -ne $operation.element.frame) {
                        $point = Get-ScreenPoint $operation.element.frame $windowBounds
                    } else {
                        $point = [pscustomobject]@{
                            x = [int][math]::Round($windowBounds.x + [double]$operation.x)
                            y = [int][math]::Round($windowBounds.y + [double]$operation.y)
                        }
                    }
                    Send-MouseClick $hwnd $point.x $point.y $operation.mouse_button ([int]$operation.click_count)
                } elseif ($clickMethod -eq "global") {
                    if (-not (Test-GlobalPointerFallbackEnabled)) {
                        throw "click_method 'global' requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 because it may move the system pointer and change foreground focus"
                    }
                    Assert-UsableWindowBounds $windowBounds
                    if ($null -ne $operation.element -and $null -ne $operation.element.frame) {
                        $point = Get-ScreenPoint $operation.element.frame $windowBounds
                    } else {
                        $point = [pscustomobject]@{
                            x = [int][math]::Round($windowBounds.x + [double]$operation.x)
                            y = [int][math]::Round($windowBounds.y + [double]$operation.y)
                        }
                    }
                    if ($null -ne $operation.element) { $point = Resolve-GlobalElementPoint $element $operation.element $windowBounds }
                    Send-GlobalMouseClick $hwnd $point.x $point.y $operation.mouse_button ([int]$operation.click_count) $windowBounds
                } elseif ($clickMethod -eq "sky_click") {
                    throw "click_method 'sky_click' is not supported on Windows"
                } elseif ($clickMethod -eq "auto") {
                    $handled = $false
                    if ($null -ne $element -and $operation.mouse_button -ne "right" -and $operation.mouse_button -ne "middle") {
                        $handled = Invoke-PreferredClick $element
                    }
                    if (-not $handled) {
                        Assert-UsableWindowBounds $windowBounds
                        if ($null -ne $operation.element -and $null -ne $operation.element.frame) {
                            $point = Get-ScreenPoint $operation.element.frame $windowBounds
                        } else {
                            $point = [pscustomobject]@{
                                x = [int][math]::Round($windowBounds.x + [double]$operation.x)
                                y = [int][math]::Round($windowBounds.y + [double]$operation.y)
                            }
                        }
                        if (Test-GlobalPointerFallbackEnabled) {
                            if ($null -ne $operation.element) { $point = Resolve-GlobalElementPoint $element $operation.element $windowBounds }
                            Send-GlobalMouseClick $hwnd $point.x $point.y $operation.mouse_button ([int]$operation.click_count) $windowBounds
                        } else {
                            Send-MouseClick $hwnd $point.x $point.y $operation.mouse_button ([int]$operation.click_count)
                        }
                    }
                } else {
                    throw "Invalid click_method '$clickMethod'"
                }
            }
            "perform_secondary_action" {
                if ($null -eq $element) { throw "unknown element_index '$($operation.element.index)'" }
                Invoke-SecondaryAction $element $operation.action
            }
            "scroll" {
                $handled = $false
                if ($null -ne $element) {
                    $handled = Invoke-Scroll $element $operation.direction ([double]$operation.pages)
                }
                if (-not $handled) {
                    Assert-UsableWindowBounds $windowBounds
                    $point = Get-ScreenPoint $operation.element.frame $windowBounds
                    if (Test-GlobalPointerFallbackEnabled) { $point = Resolve-GlobalElementPoint $element $operation.element $windowBounds }
                    Send-Scroll $hwnd $point.x $point.y $operation.direction ([double]$operation.pages) $windowBounds
                }
            }
            "drag" {
                Assert-UsableWindowBounds $windowBounds
                Send-Drag $hwnd ([int][math]::Round($windowBounds.x + [double]$operation.from_x)) ([int][math]::Round($windowBounds.y + [double]$operation.from_y)) ([int][math]::Round($windowBounds.x + [double]$operation.to_x)) ([int][math]::Round($windowBounds.y + [double]$operation.to_y)) $windowBounds
            }
            "type_text" {
                if (-not (Invoke-TypeText $process $operation.text)) {
                    Assert-NotPasswordInput (Get-FocusedElementOf $process)
                    Send-Text $hwnd $operation.text
                }
            }
            "press_key" {
                if (Test-KeyTypesCharacter $operation.key) {
                    Assert-NotPasswordInput (Get-FocusedElementOf $process)
                }
                Send-Key $hwnd $operation.key $operation.key_method
            }
            "set_value" {
                if ($null -eq $element) { throw "unknown element_index '$($operation.element.index)'" }
                Assert-NotPasswordInput $element
                $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
                if ($null -eq $valuePattern) {
                    throw "Cannot set a value for an element that is not settable"
                }
                $valuePattern.SetValue($operation.value)
            }
            default {
                throw "unsupportedTool(`"$($operation.tool)`")"
            }
        }

        Start-Sleep -Milliseconds 120
        # The read after an action follows the app's main window, as upstream, unless the call named a window.
        $script:TargetProcess = $null
        if (-not ($operation.explicit_window -is [bool] -and $operation.explicit_window)) {
            $script:TargetWindow = [IntPtr]::Zero
        } elseif ($null -ne $target) {
            $script:TargetProcess = $target.process
        }
        $response = [pscustomobject]@{ ok = $true; snapshot = (Build-Snapshot $operation.app) }
    }
} catch {
    $message = $_.Exception.Message
    $code = $_.Exception.Data["ocuCode"]
    if ($null -ne $code) {
        # pi-phone fork: a coded refusal keeps its plain message.
        $response = [pscustomobject]@{ ok = $false; error = $message; code = [string]$code; suggestion = [string]$_.Exception.Data["ocuSuggestion"] }
    } else {
        if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
            $message = "$message at $($_.ScriptStackTrace)"
        }
        $response = [pscustomobject]@{ ok = $false; error = $message }
    }
}

$response | ConvertTo-Json -Depth 50 -Compress
