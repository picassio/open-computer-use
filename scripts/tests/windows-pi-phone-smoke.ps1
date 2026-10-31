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
$NativePath = (Resolve-Path -LiteralPath $NativePath).Path
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ("ocu-pi-phone-" + [Guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $directory)
$stateFile = Join-Path $directory "state.json"
$fixtureSource = Join-Path $PSScriptRoot "fixtures/WindowsPiPhoneFixture.ps1"
$fixture = $null
$cover = $null
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
    $coverState = Join-Path $directory ("cover-" + [Guid]::NewGuid() + ".json")
    $script:cover = Start-Process powershell.exe -ArgumentList @("-NoProfile", "-STA", "-File", "`"$fixtureSource`"", "-StatePath", "`"$coverState`"", "-Cover",
        "-Left", $left, "-Top", $top, "-Width", $width, "-Height", $height) -PassThru
    Wait-For { Test-Path -LiteralPath $coverState } "cover window"
    Start-Sleep -Milliseconds 500
}
function Get-Pixels($result) {
    $image = Image $result
    Assert ($null -ne $image) ("No screenshot:`n" + (Text $result))
    $stream = New-Object System.IO.MemoryStream (, [Convert]::FromBase64String($image.data))
    return New-Object System.Drawing.Bitmap $stream
}
try {
    $fixture = Start-Process powershell.exe -ArgumentList @("-NoProfile", "-STA", "-File", "`"$fixtureSource`"", "-StatePath", "`"$stateFile`"") -PassThru -RedirectStandardOutput (Join-Path $directory "fixture.out") -RedirectStandardError (Join-Path $directory "fixture.err")
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
    $covered = Call-Tool "get_app_state" @{}
    Assert (-not $covered.isError) (Text $covered)
    $match = [regex]::Match((Text $covered), "(?m)^Covered: \[\{x: (\d+), y: (\d+), width: (\d+), height: (\d+)\}")
    Assert $match.Success ("No Covered: line with the cover window over the fixture:`n" + (Text $covered))
    $x, $y, $width, $height = 1..4 | ForEach-Object { [int]$match.Groups[$_].Value }
    $bitmap = Get-Pixels $covered
    try {
        $inside = $bitmap.GetPixel($x + [int]($width / 2), $y + [int]($height / 2))
        Assert ($inside.R -eq 0 -and $inside.G -eq 0 -and $inside.B -eq 0) "The covered part is not black: $inside"
        $red = 0
        for ($py = 0; $py -lt $bitmap.Height; $py += 4) {
            for ($px = 0; $px -lt $bitmap.Width; $px += 4) {
                $pixel = $bitmap.GetPixel($px, $py)
                if ($pixel.R -gt 200 -and $pixel.G -lt 60 -and $pixel.B -lt 60) { $red += 1 }
            }
        }
        Assert ($red -eq 0) "The cover window's red shows in the fixture's screenshot ($red samples)"
        $outside = $bitmap.GetPixel([math]::Max(30, $x - 60), [math]::Min($bitmap.Height - 20, $y + 20))
        Assert (-not ($outside.R -eq 0 -and $outside.G -eq 0 -and $outside.B -eq 0)) "The uncovered part is black too"
    } finally { $bitmap.Dispose() }
    Write-Output "Covered part $x,$y ${width}x$height is reported and black; no cover pixels in the screenshot."
    Assert-Code (Call-Tool "get_app_state" @{ refuse_if_covered = $true }) "covered" "refuse_if_covered"
    Assert-Code (Call-Tool "click" @{ x = ($x + 10); y = ($y + 10); headed = $true }) "covered" "A click in the covered part"
    Write-Output "refuse_if_covered and a click in the covered part are refused with covered."

    # A window over all of it.
    Start-Cover 40 40 800 620
    $hidden = Call-Tool "get_app_state" @{}
    Assert (-not $hidden.isError -and $null -eq (Image $hidden)) ("A fully covered fixture returned a screenshot:`n" + (Text $hidden))
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
