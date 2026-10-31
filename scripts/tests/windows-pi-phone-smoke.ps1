param([Parameter(Mandatory = $true)][string]$NativePath)
# pi-phone fork (PP-270): real WPF + native MCP checks on a Windows desktop.
# - Each read has "Snapshot:" and "Window id:"; a check box shows "States: checked" once ticked.
# - An element rebuilt after the read is refused with stale_ref (never acts on another one); an old
#   snapshot id and a replaced window are refused with stale_ref.
# - A second, topmost window over part of the fixture: its part is reported ("Covered: [...]") and black
#   in the screenshot (no red pixels of the cover); refuse_if_covered refuses; a click there is refused.
#   Over the whole fixture: no screenshot, and the reason.
# - drag, coordinate clicks and key_method global without headed: true are refused (policy_denied).
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "windows-fixture-state.ps1")
if ($env:OS -ne "Windows_NT") { throw "Windows desktop required" }
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class PiPhoneSmokeWin32 {
    delegate bool EnumProc(IntPtr hWnd, IntPtr unused);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr unused);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    // The visible top-level windows above a window, from the top: what may cover it.
    public static string WindowsAbove(long handle) {
        List<string> above = new List<string>();
        EnumWindows(delegate (IntPtr hWnd, IntPtr unused) {
            if (hWnd.ToInt64() == handle) return false;
            if (!IsWindowVisible(hWnd)) return true;
            StringBuilder title = new StringBuilder(256), name = new StringBuilder(256);
            GetWindowText(hWnd, title, title.Capacity);
            GetClassName(hWnd, name, name.Capacity);
            uint processId;
            GetWindowThreadProcessId(hWnd, out processId);
            int[] frame = Frame(hWnd.ToInt64());
            above.Add(name + " '" + title + "' pid=" + processId + " exstyle=0x" + GetWindowLong(hWnd, -20).ToString("x") +
                (frame == null ? "" : " frame=" + string.Join(",", frame)));
            return true;
        }, IntPtr.Zero);
        return string.Join(" | ", above.ToArray());
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out RECT value, int size);
    // Physical pixels, as ocu's runtime (per-monitor aware) reports them.
    static void Physical() { SetThreadDpiAwarenessContext(new IntPtr(-4)); }
    // The window rectangle (what ocu captures) and DWM's painted frame, as {x, y, width, height} strings.
    public static int[] Rect(long handle) {
        Physical();
        RECT rect;
        if (!GetWindowRect(new IntPtr(handle), out rect)) return null;
        return new int[] { rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top };
    }
    public static int[] Frame(long handle) {
        Physical();
        RECT rect;
        if (DwmGetWindowAttribute(new IntPtr(handle), 9, out rect, Marshal.SizeOf(typeof(RECT))) != 0) return null;
        return new int[] { rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top };
    }
    public static string Describe(long handle) {
        int[] rect = Rect(handle);
        int[] frame = Frame(handle);
        return "window " + handle + " visible=" + IsWindowVisible(new IntPtr(handle)) +
            (rect == null ? " rect=unknown" : " rect=" + string.Join(",", rect)) +
            (frame == null ? " frame=unknown" : " frame=" + string.Join(",", frame));
    }
}
"@
$NativePath = (Resolve-Path -LiteralPath $NativePath).Path
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ("ocu-pi-phone-" + [Guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $directory)
$stateFile = Join-Path $directory "state.json"
$fixtureSource = Join-Path $PSScriptRoot "fixtures/WindowsPiPhoneFixture.ps1"
$fixture = $null
$cover = $null
$coverHandle = 0
$native = $null
$requestId = 0
$sequence = 0

function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Wait-For($test, $description) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        try { if (& $test) { return } } catch { }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timeout: $description"
}
function Read-State { Read-WindowsFixtureState $stateFile }
function Send-Request($method, $parameters) {
    $script:requestId += 1
    $message = @{ jsonrpc = "2.0"; id = $script:requestId; method = $method; params = $parameters }
    $native.StandardInput.WriteLine(($message | ConvertTo-Json -Depth 20 -Compress))
    $native.StandardInput.Flush()
    $read = $native.StandardOutput.ReadLineAsync()
    Assert ($read.Wait(40000)) "MCP timed out"
    Assert (-not [string]::IsNullOrWhiteSpace($read.Result)) "MCP exited"
    $response = $read.Result | ConvertFrom-Json
    Assert ($response.id -eq $script:requestId -and $null -eq $response.error) "Unexpected RPC response"
    return $response.result
}
function Call-Tool($tool, $arguments) {
    if (-not $arguments.ContainsKey("app")) { $arguments.app = [string]$fixture.Id }
    Send-Request "tools/call" @{ name = $tool; arguments = $arguments }
}
function Text($result) { ($result.content | Where-Object type -eq "text" | ForEach-Object text) -join "`n" }
function Image($result) { @($result.content | Where-Object type -eq "image") | Select-Object -First 1 }
function Index-Of($result, $pattern) {
    $found = [regex]::Matches((Text $result), "(?m)^\s*(\d+)\s+$pattern")
    Assert ($found.Count -eq 1) ("No single line matches '$pattern':`n" + (Text $result))
    $found[0].Groups[1].Value
}
function Line-Of($result, $pattern) {
    $found = [regex]::Match((Text $result), "(?m)^\s*\d+\s+$pattern.*$")
    Assert $found.Success ("No line matches '$pattern':`n" + (Text $result))
    $found.Value
}
function Snapshot-Of($result) {
    $found = [regex]::Match((Text $result), "(?m)^Snapshot: ([0-9a-f]{8})$")
    Assert $found.Success ("No Snapshot: line:`n" + (Text $result))
    $found.Groups[1].Value
}
function Assert-Code($result, $code, $what) {
    Assert ($result.isError -and (Text $result) -match "(?m)^Error: $code retry=safe suggestion=.+$") ("$what was not refused with ${code}:`n" + (Text $result))
}
function Change-Window($kind) {
    $script:sequence += 1
    [System.IO.File]::WriteAllText(($stateFile + ".command"), (@{ sequence = $script:sequence; kind = $kind } | ConvertTo-Json -Compress), [System.Text.Encoding]::UTF8)
    Wait-For { (Read-State).sequence -eq $script:sequence } "fixture command $kind"
    Start-Sleep -Milliseconds 300
}
function Start-Cover($left, $top, $width, $height) {
    if ($null -ne $script:cover -and -not $script:cover.HasExited) { $script:cover.Kill(); $script:cover.WaitForExit() }
    $name = "cover-" + [Guid]::NewGuid()
    $coverState = Join-Path $directory "$name.json"
    $coverError = Join-Path $directory "$name.err"
    $script:cover = Start-Process powershell.exe -ArgumentList @("-NoProfile", "-STA", "-File", "`"$fixtureSource`"", "-StatePath", "`"$coverState`"", "-Cover",
        "-Left", $left, "-Top", $top, "-Width", $width, "-Height", $height) -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $directory "$name.out") -RedirectStandardError $coverError
    try {
        Wait-For { $script:cover.HasExited -or ((Test-Path -LiteralPath $coverState) -and (Read-WindowsFixtureState $coverState).ready) } "cover window"
    } catch {
        throw "The cover window did not come up: $($_.Exception.Message). $(Get-Content -Raw -LiteralPath $coverError -ErrorAction SilentlyContinue)"
    }
    if ($script:cover.HasExited) { throw "The cover window exited ($($script:cover.ExitCode)): $(Get-Content -Raw -LiteralPath $coverError -ErrorAction SilentlyContinue)" }
    $script:coverHandle = [long](Read-WindowsFixtureState $coverState).hwnd
    Wait-For { [PiPhoneSmokeWin32]::IsWindowVisible([IntPtr]$script:coverHandle) } "visible cover window"
}
# Read the fixture until the text matches (the window manager and DWM may take a moment after the
# cover window shows); the last read is returned whatever it says, and the caller asserts on it.
function Read-Until($pattern, $arguments = @{}) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $result = Call-Tool "get_app_state" $arguments.Clone()
        if (-not $result.isError -and (Text $result) -match $pattern) { return $result }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    return $result
}
function Describe-Windows {
    "cover " + [PiPhoneSmokeWin32]::Describe($script:coverHandle) + "; fixture " + [PiPhoneSmokeWin32]::Describe([long](Get-Process -Id $fixture.Id).MainWindowHandle)
}
# The rectangles of a read's Covered: line, in window (screenshot) coordinates.
function Covered-Rects($result) {
    $line = [regex]::Match((Text $result), "(?m)^Covered: \[(.*?)\]").Groups[1].Value
    @([regex]::Matches($line, "\{x: (-?\d+), y: (-?\d+), width: (\d+), height: (\d+)\}") | ForEach-Object {
        [pscustomobject]@{ x = [int]$_.Groups[1].Value; y = [int]$_.Groups[2].Value; width = [int]$_.Groups[3].Value; height = [int]$_.Groups[4].Value }
    })
}
function In-Rect($rect, $px, $py, $margin = 0) {
    $px -ge ($rect.x - $margin) -and $px -lt ($rect.x + $rect.width + $margin) -and $py -ge ($rect.y - $margin) -and $py -lt ($rect.y + $rect.height + $margin)
}
function Is-Black($pixel) { $pixel.R -eq 0 -and $pixel.G -eq 0 -and $pixel.B -eq 0 }
function Is-Red($pixel) { $pixel.R -gt 200 -and $pixel.G -lt 60 -and $pixel.B -lt 60 }
# Pixels on a 6-pixel grid: inside the given rectangle, or (rect $null) in the window's painted frame
# but at least 8 pixels away from every covered rectangle.
function Sample-Pixels($bitmap, $rect, $covered, $painted) {
    $samples = New-Object System.Collections.Generic.List[object]
    for ($py = 0; $py -lt $bitmap.Height; $py += 6) {
        for ($px = 0; $px -lt $bitmap.Width; $px += 6) {
            if ($null -ne $rect) {
                if (-not (In-Rect $rect $px $py)) { continue }
            } else {
                if (-not (In-Rect $painted $px $py -8)) { continue }
                if (@($covered | Where-Object { In-Rect $_ $px $py 8 }).Count -gt 0) { continue }
            }
            $samples.Add([pscustomobject]@{ x = $px; y = $py; pixel = $bitmap.GetPixel($px, $py) })
        }
    }
    return $samples.ToArray()
}
function Show-Samples($samples, [int]$count = 6) {
    (@($samples | Select-Object -First $count | ForEach-Object { "($($_.x),$($_.y))=#{0:x2}{1:x2}{2:x2}" -f $_.pixel.R, $_.pixel.G, $_.pixel.B }) -join " ")
}
function Get-Pixels($result) {
    $image = Image $result
    Assert ($null -ne $image) ("No screenshot:`n" + (Text $result))
    $stream = New-Object System.IO.MemoryStream (, [Convert]::FromBase64String($image.data))
    return New-Object System.Drawing.Bitmap $stream
}
try {
    # -NoNewWindow: Start-Process otherwise opens a console window for each powershell.exe, on top of
    # the windows already there; the cover fixture's console then covers part of this fixture too.
    $fixture = Start-Process powershell.exe -ArgumentList @("-NoProfile", "-STA", "-File", "`"$fixtureSource`"", "-StatePath", "`"$stateFile`"") -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $directory "fixture.out") -RedirectStandardError (Join-Path $directory "fixture.err")
    Wait-For { Test-Path -LiteralPath $stateFile } "WPF startup"
    Wait-For { (Get-Process -Id $fixture.Id).MainWindowHandle -ne [IntPtr]::Zero } "visible WPF main window"
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $NativePath
    $start.Arguments = "mcp"
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $native = New-Object System.Diagnostics.Process
    $native.StartInfo = $start
    [void]$native.Start()
    $null = Send-Request "initialize" @{ protocolVersion = "2025-03-26"; capabilities = @{}; clientInfo = @{ name = "windows-pi-phone-smoke"; version = "1" } }

    # Snapshot and window ids; the uncovered fixture.
    $state = Call-Tool "get_app_state" @{}
    Assert (-not $state.isError) (Text $state)
    $null = Snapshot-Of $state
    Assert ((Text $state) -match "(?m)^Window id: \d+$") ("No Window id: line:`n" + (Text $state))
    Assert ((Text $state) -notmatch "(?m)^Covered:") ("The uncovered fixture was reported covered:`n" + (Text $state))
    Assert ($null -ne (Image $state)) "No screenshot of the uncovered fixture"
    $fixtureHandle = [long](Get-Process -Id $fixture.Id).MainWindowHandle
    $bitmap = Get-Pixels $state
    try {
        $all = @(Sample-Pixels $bitmap ([pscustomobject]@{ x = 0; y = 0; width = $bitmap.Width; height = $bitmap.Height }) @() $null)
        $black = @($all | Where-Object { Is-Black $_.pixel }).Count
        Write-Output ("Uncovered screenshot {0}x{1} of fixture {2}: {3} of {4} samples pure black; {5}" -f $bitmap.Width, $bitmap.Height, [PiPhoneSmokeWin32]::Describe($fixtureHandle), $black, $all.Count, (Show-Samples ($all | Select-Object -Skip ([int]($all.Count / 2)))))
        Write-Output ("Visible windows above the fixture: " + [PiPhoneSmokeWin32]::WindowsAbove($fixtureHandle))
        # A capture that is mostly black is no picture of the window at all (a locked or disconnected desktop).
        Assert ($black -lt $all.Count / 2) "The uncovered fixture's screenshot is mostly black: the capture itself does not work here"
    } finally { $bitmap.Dispose() }
    Write-Output "Reads carry Snapshot: and Window id:; the uncovered fixture has no Covered: line."

    # Check box state.
    Assert ((Line-Of $state "check box Shout") -notmatch "States:.*checked") "Unticked check box shows checked"
    $ticked = Call-Tool "click" @{ element_index = (Index-Of $state "check box Shout"); snapshot_id = (Snapshot-Of $state) }
    Assert (-not $ticked.isError) (Text $ticked)
    Wait-For { (Read-State).checked } "check box ticked"
    Assert ((Line-Of $ticked "check box Shout") -match "States: (\w+, )*checked") ("Ticked check box line: " + (Line-Of $ticked "check box Shout"))
    Write-Output "Check box: $((Line-Of $ticked 'check box Shout').Trim())"

    # A rebuilt element is stale; it is never another element.
    $state = Call-Tool "get_app_state" @{ include_screenshot = $false }
    $index = Index-Of $state "button Item 3"
    $snapshot = Snapshot-Of $state
    Change-Window "rebuild"
    $stale = Call-Tool "click" @{ element_index = $index; snapshot_id = $snapshot }
    Assert-Code $stale "stale_ref" "A click on a rebuilt button"
    Assert ((Read-State).clicked -eq "") ("A stale click reached a button: " + (Read-State).clicked)
    Write-Output "A rebuilt button is refused with stale_ref; nothing was clicked."

    # The same buttons reordered: the snapshot's Item 3, or stale_ref; never the button now at its number.
    $state = Call-Tool "get_app_state" @{ include_screenshot = $false }
    $index = Index-Of $state "button Item 3"
    $snapshot = Snapshot-Of $state
    Change-Window "reverse"
    $moved = Call-Tool "click" @{ element_index = $index; snapshot_id = $snapshot }
    if ($moved.isError) {
        Assert-Code $moved "stale_ref" "A click on a moved button"
        Assert ((Read-State).clicked -eq "") ("A refused click reached a button: " + (Read-State).clicked)
        Write-Output "A moved button is refused with stale_ref (its RuntimeId changed)."
    } else {
        Wait-For { (Read-State).clicked -ne "" } "button click"
        Assert ((Read-State).clicked -eq "Item 3") ("The click went to " + (Read-State).clicked + " instead of Item 3")
        Write-Output "A moved button is found again by its RuntimeId: Item 3 was clicked."
    }

    # An old snapshot id.
    $first = Call-Tool "get_app_state" @{ include_screenshot = $false }
    $second = Call-Tool "get_app_state" @{ include_screenshot = $false }
    $old = Call-Tool "click" @{ element_index = (Index-Of $first "button Item 1"); snapshot_id = (Snapshot-Of $first) }
    Assert-Code $old "stale_ref" "A click with an old snapshot id"
    Assert ((Text $old) -match "replaced by $(Snapshot-Of $second)") (Text $old)
    Write-Output "An old snapshot id is refused with stale_ref."

    # Physical or coordinate input without headed: true.
    $state = Call-Tool "get_app_state" @{}
    foreach ($call in @(@("drag", @{ from_x = 40; from_y = 60; to_x = 120; to_y = 60 }), @("click", @{ x = 40; y = 60 }), @("press_key", @{ key = "ctrl+a"; key_method = "global" }))) {
        Assert-Code (Call-Tool $call[0] $call[1]) "policy_denied" "$($call[0]) without headed"
    }
    Write-Output "drag, a coordinate click and key_method global without headed are refused with policy_denied."

    # A window over part of the fixture.
    Start-Cover 380 180 250 150
    $covered = Read-Until "(?m)^Covered: \["
    Assert (-not $covered.isError) (Text $covered)
    $rects = @(Covered-Rects $covered)
    Assert ($rects.Count -gt 0) ("No Covered: line with the cover window over the fixture ($(Describe-Windows)):`n" + (Text $covered))
    $fixtureRect = [PiPhoneSmokeWin32]::Rect($fixtureHandle)
    $fixtureFrame = [PiPhoneSmokeWin32]::Frame($fixtureHandle)
    $coverFrame = [PiPhoneSmokeWin32]::Frame($script:coverHandle)
    # Where the cover window paints, in the fixture's screenshot coordinates (its origin is the window rectangle).
    $expected = [pscustomobject]@{ x = $coverFrame[0] - $fixtureRect[0]; y = $coverFrame[1] - $fixtureRect[1]; width = $coverFrame[2]; height = $coverFrame[3] }
    $painted = [pscustomobject]@{ x = $fixtureFrame[0] - $fixtureRect[0]; y = $fixtureFrame[1] - $fixtureRect[1]; width = $fixtureFrame[2]; height = $fixtureFrame[3] }
    $bitmap = Get-Pixels $covered
    try {
        Write-Output ("{0} | image {1}x{2}; {3}; cover expected at {4},{5} {6}x{7}; painted frame at {8},{9} {10}x{11}" -f
            ([regex]::Match((Text $covered), "(?m)^Covered: .*$").Value), $bitmap.Width, $bitmap.Height, (Describe-Windows),
            $expected.x, $expected.y, $expected.width, $expected.height, $painted.x, $painted.y, $painted.width, $painted.height)
        Write-Output ("Visible windows above the fixture: " + [PiPhoneSmokeWin32]::WindowsAbove($fixtureHandle))
        Assert ($bitmap.Width -eq $fixtureRect[2] -and $bitmap.Height -eq $fixtureRect[3]) "The screenshot is not the window rectangle's size"
        # The cover window's part is reported where it really is, and nothing reported spans the whole window.
        $coverPart = @($rects | Where-Object { [math]::Abs($_.x - $expected.x) -le 1 -and [math]::Abs($_.y - $expected.y) -le 1 -and
            ([math]::Abs($_.width - $expected.width) -le 1 -or $_.x + $_.width -ge $bitmap.Width - 1) -and
            ([math]::Abs($_.height - $expected.height) -le 1 -or $_.y + $_.height -ge $bitmap.Height - 1) }) | Select-Object -First 1
        Assert ($null -ne $coverPart) "No reported rectangle is where the cover window paints"
        Assert (@($rects | Where-Object { $_.width -ge $painted.width -and $_.height -ge $painted.height }).Count -eq 0) "A reported rectangle spans the whole window"
        $inside = @(Sample-Pixels $bitmap $coverPart $rects $painted)
        $insideBlack = @($inside | Where-Object { Is-Black $_.pixel }).Count
        $outside = @(Sample-Pixels $bitmap $null $rects $painted)
        $outsideBlack = @($outside | Where-Object { Is-Black $_.pixel }).Count
        $red = @(Sample-Pixels $bitmap ([pscustomobject]@{ x = 0; y = 0; width = $bitmap.Width; height = $bitmap.Height }) @() $null | Where-Object { Is-Red $_.pixel }).Count
        Write-Output ("Inside the cover: {0} of {1} samples pure black ({2}). Outside every covered part: {3} of {4} pure black ({5}). Red samples: {6}." -f
            $insideBlack, $inside.Count, (Show-Samples $inside 3), $outsideBlack, $outside.Count, (Show-Samples ($outside | Select-Object -Skip ([int]($outside.Count / 2)))), $red)
        Assert ($inside.Count -gt 0 -and $insideBlack -eq $inside.Count) "The covered part is not black"
        Assert ($red -eq 0) "The cover window's red shows in the fixture's screenshot ($red samples)"
        # The fixture's uncovered part is its light WPF surface; dark text is a small share of it.
        Assert ($outside.Count -ge 50 -and $outsideBlack -lt $outside.Count / 5) "The uncovered part is black too"
        $x, $y = $coverPart.x, $coverPart.y
    } finally { $bitmap.Dispose() }
    Write-Output "Covered part $($coverPart.x),$($coverPart.y) $($coverPart.width)x$($coverPart.height) is reported and black; the rest is not; no cover pixels in the screenshot."
    Assert-Code (Call-Tool "get_app_state" @{ refuse_if_covered = $true }) "covered" "refuse_if_covered"
    Assert-Code (Call-Tool "click" @{ x = ($x + 10); y = ($y + 10); headed = $true }) "covered" "A click in the covered part"
    Write-Output "refuse_if_covered and a click in the covered part are refused with covered."

    # A window over all of it.
    Start-Cover 40 40 800 620
    $hidden = Read-Until "Screenshot omitted: other windows cover the whole window"
    Assert (-not $hidden.isError -and $null -eq (Image $hidden)) ("A fully covered fixture returned a screenshot ($(Describe-Windows)):`n" + (Text $hidden))
    Assert ((Text $hidden) -match "Screenshot omitted: other windows cover the whole window") (Text $hidden)
    Write-Output "A fully covered window has no screenshot, and says why."
    $cover.Kill(); $cover.WaitForExit(); $cover = $null
    Start-Sleep -Milliseconds 300

    # A replaced window.
    $state = Call-Tool "get_app_state" @{ include_screenshot = $false }
    $snapshot = Snapshot-Of $state
    $item = Index-Of $state "button Item 1"
    Change-Window "reopen"
    Wait-For { (Read-State).windows -eq 2 } "reopened window"
    Assert-Code (Call-Tool "press_key" @{ key = "Return"; snapshot_id = $snapshot }) "stale_ref" "A key into a replaced window"
    Assert-Code (Call-Tool "click" @{ element_index = $item }) "stale_ref" "A click in a replaced window"
    Write-Output "Actions in a replaced window are refused with stale_ref."
    Write-Output "Windows pi-phone smoke passed."
} finally {
    if ($null -ne $native -and -not $native.HasExited) {
        $native.StandardInput.Close()
        if (-not $native.WaitForExit(3000)) { $native.Kill(); $native.WaitForExit() }
    }
    foreach ($process in @($cover, $fixture)) {
        if ($null -ne $process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
    }
    $fixtureError = Join-Path $directory "fixture.err"
    if (Test-Path -LiteralPath $fixtureError) { Get-Content -LiteralPath $fixtureError | Write-Output }
    Remove-Item -LiteralPath $directory -Recurse -Force
}
