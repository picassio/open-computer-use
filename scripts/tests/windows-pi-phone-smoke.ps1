param([Parameter(Mandatory = $true)][string]$NativePath)
# pi-phone fork (PP-270): real WPF + native MCP checks on a Windows desktop.
# - Each read has "Snapshot:" and "Window id:".
# - An element rebuilt after the read is refused with stale_ref (never acts on another one); an old
#   snapshot id and a replaced window are refused with stale_ref.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "windows-fixture-state.ps1")
if ($env:OS -ne "Windows_NT") { throw "Windows desktop required" }
$NativePath = (Resolve-Path -LiteralPath $NativePath).Path
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ("ocu-pi-phone-" + [Guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $directory)
$stateFile = Join-Path $directory "state.json"
$fixtureSource = Join-Path $PSScriptRoot "fixtures/WindowsPiPhoneFixture.ps1"
$fixture = $null
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

    # Snapshot and window ids.
    $state = Call-Tool "get_app_state" @{}
    Assert (-not $state.isError) (Text $state)
    $null = Snapshot-Of $state
    Assert ((Text $state) -match "(?m)^Window id: \d+$") ("No Window id: line:`n" + (Text $state))
    Write-Output "Reads carry Snapshot: and Window id:."

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
    if ($null -ne $fixture -and -not $fixture.HasExited) { $fixture.Kill(); $fixture.WaitForExit() }
    $fixtureError = Join-Path $directory "fixture.err"
    if (Test-Path -LiteralPath $fixtureError) { Get-Content -LiteralPath $fixtureError | Write-Output }
    Remove-Item -LiteralPath $directory -Recurse -Force
}
