param([Parameter(Mandatory = $true)][string]$RuntimePath)
$ErrorActionPreference = "Stop"
# pi-phone fork (PP-270): run runtime.ps1's own functions for coded errors against instrumented
# doubles. Runs under pwsh on Linux too.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($RuntimePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$names = @("New-OCUError", "Test-EnvFlagEnabled", "Assert-NotPasswordInput", "Test-ElementIsPassword")
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names }, $true)
if ($functions.Count -ne $names.Count) { throw "Production functions missing: $($names | Where-Object { $_ -notin $functions.Name })" }
foreach ($function in $functions) { Invoke-Expression $function.Extent.Text }

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

Write-Output "pi-phone runtime functions: coded errors passed (instrumented doubles)."
