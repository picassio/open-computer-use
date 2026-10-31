param([Parameter(Mandatory = $true)][string]$RuntimePath)
$ErrorActionPreference = "Stop"
# pi-phone fork (PP-270): run runtime.ps1's own functions for coded errors, stale refs and covered
# regions against instrumented doubles. Runs under pwsh on Linux too; the
# real UI Automation and z-order paths are covered by windows-pi-phone-smoke.ps1 on a Windows desktop.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($RuntimePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$names = @("New-OCUError", "New-Frame", "Limit-Text", "Test-NamesMatch", "ConvertTo-ComparableActions",
    "Test-RecordMatches", "New-StaleElementError", "Get-UnionArea", "Get-Overlap", "Get-CoveredRegions", "Get-BlackoutRects",
    "Get-ElementTitle", "Format-ElementLine", "Find-Element", "Same-RuntimeId", "Resolve-TargetWindow",
    "Test-EnvFlagEnabled", "Assert-NotPasswordInput", "Test-ElementIsPassword")
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names }, $true)
if ($functions.Count -ne $names.Count) { throw "Production functions missing: $($names | Where-Object { $_ -notin $functions.Name })" }
foreach ($function in $functions) { Invoke-Expression $function.Extent.Text }
$PasswordMarker = "[password]"
$DefaultTextLimit = 500

function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Code($call) {
    try { & $call; return "none" } catch { return [string]$_.Exception.Data["ocuCode"] }
}

# Coded errors keep their code and message through throw/catch.
$caught = $null
try { throw (New-OCUError "stale_ref" "[3] is no longer the button") } catch { $caught = $_ }
Assert ($caught.Exception.Message -eq "[3] is no longer the button" -and $caught.Exception.Data["ocuCode"] -eq "stale_ref") "Coded error lost its code"
$script:AllowPasswordInputThisCall = $false
$secret = [pscustomobject]@{ Current = [pscustomobject]@{ IsPassword = $true } }
Assert ((Code { Assert-NotPasswordInput $secret }) -eq "password_field") "Password refusal is not coded"

# The outline line keeps its form.
$record = [pscustomobject]@{ index = 4; localizedControlType = "check box"; controlType = "ControlType.CheckBox"; name = "Shout"; automationId = "";
    value = ""; isPassword = $false; actions = @("Toggle"); frame = [pscustomobject]@{ x = 20; y = 30; width = 80; height = 20 } }
Assert ((Format-ElementLine $record 0) -eq "`t4 check box Shout Secondary Actions: Toggle Frame: {x: 20, y: 30, width: 80, height: 20}") "Line changed"
$password = [pscustomobject]@{ index = 2; localizedControlType = "edit"; name = "Password"; automationId = ""; value = ""; isPassword = $true; actions = @("SetValue"); frame = $null }
Assert ((Format-ElementLine $password 0) -eq "`t2 edit Password [password] Secondary Actions: SetValue") "Password line"

# Stale refs: the element with the recorded RuntimeId must still be what the snapshot saw.
function New-Fake([int[]]$runtimeId, [string]$name, [string]$type = "ControlType.Button", [string[]]$actions = @("Invoke")) {
    $fake = [pscustomobject]@{ name = $name; controlType = $type; actions = $actions; Current = [pscustomobject]@{ Name = $name; AutomationId = ""; ControlType = [pscustomobject]@{ ProgrammaticName = $type } } }
    $fake | Add-Member -MemberType NoteProperty -Name Id -Value $runtimeId
    $fake | Add-Member -MemberType ScriptMethod -Name GetRuntimeId -Value { $this.Id }
    return $fake
}
function Get-MainElement($process) { "root" }
function Get-AllElements($root) { $script:elements }
function Get-LiveIdentity($element) { [pscustomobject]@{ controlType = $element.controlType; name = $element.name; actions = $element.actions } }
$script:elements = @((New-Fake @(7, 1, 6) "Item 6"), (New-Fake @(7, 1, 5) "Item 5"), (New-Fake @(7, 1, 4) "Item 4"), (New-Fake @(7, 1, 3) "Item 3"))
$item3 = [pscustomobject]@{ index = 6; runtimeId = @(7, 1, 3); name = "Item 3"; controlType = "ControlType.Button"; actions = @("Invoke"); automationId = "" }
Assert ((Find-Element $null $item3).name -eq "Item 3") "A moved element with the same RuntimeId was not found"
$rebuilt = $item3.PSObject.Copy(); $rebuilt.runtimeId = @(7, 1, 99)
Assert ((Code { Find-Element $null $rebuilt }) -eq "stale_ref") "A rebuilt element was not stale"
$renamed = $item3.PSObject.Copy(); $renamed.name = "Item 9"
Assert ((Code { Find-Element $null $renamed }) -eq "stale_ref") "A renamed element was not stale"
Assert ((Test-RecordMatches ([pscustomobject]@{ controlType = "ControlType.TreeItem"; name = "Docs"; actions = @("Expand") }) ([pscustomobject]@{ controlType = "ControlType.TreeItem"; name = "Docs"; actions = @("Collapse") }))) "Expand/Collapse flip was stale"
Assert (-not (Test-RecordMatches ([pscustomobject]@{ controlType = "ControlType.Button"; name = "Docs"; actions = @("Invoke") }) ([pscustomobject]@{ controlType = "ControlType.Button"; name = "Docs"; actions = @("Toggle") }))) "Changed actions matched"
Assert (Test-NamesMatch "Item ..." "Item 3") "A cut name did not match"
Assert (-not (Test-NamesMatch "Item 3" "item 3")) "Names are compared exactly"
$script:elements = @((New-Fake @() "Twin"), (New-Fake @() "Twin"))
$twin = [pscustomobject]@{ index = 2; runtimeId = @(); name = "Twin"; controlType = "ControlType.Button"; actions = @("Invoke"); automationId = "" }
Assert ((Code { Find-Element $null $twin }) -eq "ambiguous_target") "Twins without RuntimeIds were not ambiguous"

# A replaced window is stale for an action and not found for a read.
Add-Type -TypeDefinition @"
using System;
public static class OCUWin32 {
    public static bool alive = true; public static int owner = 42; public static string title = "Fixture";
    public static bool IsWindow(IntPtr h) { return alive; }
    public static int WindowProcessId(IntPtr h) { return owner; }
    public static string WindowTitle(IntPtr h) { return title; }
}
"@
function Get-Process { param([int]$Id) [pscustomobject]@{ Id = $Id; ProcessName = "fixture" } }
function Get-MatchingProcesses($query) { @([pscustomobject]@{ Id = 42; ProcessName = "fixture" }) }
$action = [pscustomobject]@{ windowHandle = 1234; expected_pid = 42; app = "fixture" }
Assert ((Resolve-TargetWindow $action $true).process.Id -eq 42) "The snapshot's window was not used"
[OCUWin32]::alive = $false
Assert ((Code { Resolve-TargetWindow $action $true }) -eq "stale_ref") "A closed window was not stale"
[OCUWin32]::alive = $true; [OCUWin32]::owner = 77
Assert ((Code { Resolve-TargetWindow $action $true }) -eq "stale_ref") "A window of another process was not stale"
[OCUWin32]::title = "Something else"
Assert ((Code { Resolve-TargetWindow ([pscustomobject]@{ windowHandle = 1234; app = "fixture" }) $false }) -eq "not_found") "A window of another app was read"
Assert ($null -eq (Resolve-TargetWindow ([pscustomobject]@{ windowHandle = 0; app = "fixture" }) $true)) "No window id must keep the main window"

# Covered regions in window coordinates; full when they cover the painted frame.
$bounds = New-Frame 100 100 400 300
$cover = Get-CoveredRegions $bounds @((New-Frame 400 50 300 200), (New-Frame 0 0 50 50)) $bounds
Assert ($cover.state -eq "partial" -and @($cover.covered).Count -eq 1 -and $cover.covered[0].x -eq 300 -and $cover.covered[0].height -eq 150) "Partial cover: $($cover | ConvertTo-Json -Depth 4)"
Assert ((Get-CoveredRegions $bounds @() $bounds).state -eq "clear") "Clear"
Assert ((Get-CoveredRegions $bounds $null $bounds).state -eq "unknown") "Unknown z-order"
$full = Get-CoveredRegions $bounds @((New-Frame 0 0 300 800), (New-Frame 250 0 800 800)) $bounds
Assert ($full.state -eq "full") "Full cover by two windows"
# The invisible resize borders (outside the painted frame) need no cover for the window to be fully covered.
$painted = New-Frame 107 100 386 293
Assert ((Get-CoveredRegions $bounds @((New-Frame 107 100 386 293)) $painted).state -eq "full") "Full cover of the painted frame"
Assert ((Get-UnionArea @((New-Frame 0 0 10 10), (New-Frame 5 5 10 10))) -eq 175) "Union area"
$strips = @(Get-BlackoutRects $bounds @((New-Frame 300 0 100 150)) $painted)
Assert ($strips.Count -eq 4 -and $strips[0].x -eq 300) "Blackout keeps the covered part first: $($strips | ConvertTo-Json -Depth 3)"
Assert (($strips | Where-Object { $_.x -eq 0 -and $_.width -eq 7 }) -and ($strips | Where-Object { $_.x -eq 393 -and $_.width -eq 7 }) -and ($strips | Where-Object { $_.y -eq 293 -and $_.height -eq 7 })) "Invisible borders not blacked out"

Write-Output "pi-phone runtime functions: coded errors, stale refs, window replacement and covered regions passed (instrumented doubles)."
