param([Parameter(Mandatory = $true)][string]$NativePath)
# pi-phone fork: real WPF + native MCP check that a PasswordBox is marked
# "[password]" in the outline, its value is never shown, and set_value,
# type_text and character keys into it are refused, while the user name box
# still takes text and command keys still work.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "windows-fixture-state.ps1")
if ($env:OS -ne "Windows_NT") { throw "Windows desktop required" }
$NativePath = (Resolve-Path -LiteralPath $NativePath).Path
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ("ocu-password-" + [Guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $directory)
$stateFile = Join-Path $directory "state.json"
$fixture = $null
$native = $null
$requestId = 0

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
function Index-Of($result, $pattern) {
    $found = [regex]::Matches((Text $result), "(?m)^\s*(\d+)\s+$pattern")
    Assert ($found.Count -eq 1) ("No single line matches '$pattern':`n" + (Text $result))
    $found[0].Groups[1].Value
}
try {
    $fixtureSource = Join-Path $PSScriptRoot "fixtures/WindowsPasswordFixture.ps1"
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
    $null = Send-Request "initialize" @{ protocolVersion = "2025-03-26"; capabilities = @{}; clientInfo = @{ name = "windows-password-smoke"; version = "1" } }

    $state = Call-Tool "get_app_state" @{ include_screenshot = $false }
    Assert (-not $state.isError) (Text $state)
    $passwordIndex = Index-Of $state 'edit Password \[password\](?:\s|$)'
    $userIndex = Index-Of $state 'edit User name(?:\s|$)'
    Assert ((Text $state) -notmatch "fixture-secret") "The password's value is in the outline"
    Write-Output "PasswordBox marked [password]; its value is not shown."

    $refused = Call-Tool "set_value" @{ element_index = $passwordIndex; value = "typed-by-agent" }
    Assert ($refused.isError -and (Text $refused) -match "password field") ("set_value into the password box was not refused: " + (Text $refused))
    Assert ((Read-State).password -eq "fixture-secret") "The password box changed"
    Write-Output "set_value into the password box refused."

    $state = Call-Tool "get_app_state" @{ include_screenshot = $false }
    $userIndex = Index-Of $state 'edit User name(?:\s|$)'
    $allowed = Call-Tool "set_value" @{ element_index = $userIndex; value = "pi" }
    Assert (-not $allowed.isError) (Text $allowed)
    Wait-For { (Read-State).user -eq "pi" } "user name update"
    Write-Output "set_value into the user name box still works."

    $focused = $true
    try { Wait-For { (Read-State).passwordFocused } "password box keyboard focus" } catch { $focused = $false }
    if ($focused) {
        $state = Call-Tool "get_app_state" @{ include_screenshot = $false }
        Assert ((Text $state) -match "focused UI element is .*\[password\]") ("Focused password box not marked:`n" + (Text $state))
        foreach ($call in @(@("type_text", @{ text = "typed-by-agent" }), @("press_key", @{ key = "a" }), @("press_key", @{ key = "shift+b" }))) {
            $result = Call-Tool $call[0] $call[1]
            Assert ($result.isError -and (Text $result) -match "password field") ("$($call[0]) into the focused password box was not refused: " + (Text $result))
        }
        Assert ((Read-State).password -eq "fixture-secret") "The password box changed after typing"
        Write-Output "type_text and character keys into the focused password box refused."
    } else {
        Write-Warning "The password box did not get keyboard focus on this desktop; focused-typing checks skipped."
    }

    # A call with allow_password_input: true (the person typing their own password) goes in; the next call without it
    # is refused again.
    $state = Call-Tool "get_app_state" @{ include_screenshot = $false }
    $passwordIndex = Index-Of $state 'edit Password \[password\](?:\s|$)'
    $allowedSet = Call-Tool "set_value" @{ element_index = $passwordIndex; value = "typed-by-person"; allow_password_input = $true }
    Assert (-not $allowedSet.isError) ("set_value with allow_password_input was refused: " + (Text $allowedSet))
    Wait-For { (Read-State).password -eq "typed-by-person" } "password box update with allow_password_input"
    Assert ((Text $allowedSet) -notmatch "typed-by-person") "The password's value is in the result"
    $state = Call-Tool "get_app_state" @{ include_screenshot = $false }
    $passwordIndex = Index-Of $state 'edit Password \[password\](?:\s|$)'
    $again = Call-Tool "set_value" @{ element_index = $passwordIndex; value = "typed-by-agent" }
    Assert ($again.isError -and (Text $again) -match "password field") ("The next set_value without the flag was not refused: " + (Text $again))
    Assert ((Read-State).password -eq "typed-by-person") "The password box changed without the flag"
    Write-Output "set_value with allow_password_input goes in; the next call without it is refused."
    Write-Output "Windows password-field guard passed."
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
