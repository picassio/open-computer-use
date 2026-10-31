param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [switch]$Cover,
    [int]$Left = 80,
    [int]$Top = 80,
    [int]$Width = 600,
    [int]$Height = 460
)
# pi-phone fork (PP-270): WPF windows for windows-pi-phone-smoke.ps1.
# Without -Cover: "OCU pi-phone Fixture", a Shout check box and six item buttons. Its state file reports
# the check box and the last button clicked; commands in "$StatePath.command" (JSON {sequence, kind})
# reorder the same buttons (reverse), replace them with new ones in reverse order (rebuild), or close
# the window and open a new one with the same title (reopen).
# With -Cover: "OCU Cover Fixture", a plain red topmost window at Left/Top/Width/Height, to cover it.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework
$stateEncoding = New-Object System.Text.UTF8Encoding($false)
function Write-State($state) {
    $temporary = $StatePath + ".tmp"
    [System.IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json -Compress), $stateEncoding)
    try {
        if (Test-Path -LiteralPath $StatePath) { [System.IO.File]::Replace($temporary, $StatePath, ($StatePath + ".bak")) }
        else { [System.IO.File]::Move($temporary, $StatePath) }
    } catch [System.IO.IOException] { }
}

$application = New-Object System.Windows.Application
if ($Cover) {
    $window = New-Object System.Windows.Window
    $window.Title = "OCU Cover Fixture"
    $window.WindowStartupLocation = "Manual"
    $window.Left = $Left; $window.Top = $Top; $window.Width = $Width; $window.Height = $Height
    $window.Topmost = $true
    $window.Background = [System.Windows.Media.Brushes]::Red
    $window.Add_ContentRendered({ Write-State @{ ready = $true } })
    $application.ShutdownMode = "OnMainWindowClose"
    [void]$application.Run($window)
    return
}

$state = @{ sequence = 0; checked = $false; clicked = ""; windows = 0 }
$ui = @{ window = $null; items = $null; check = $null; buttons = @() }
function Add-Buttons([string[]]$names) {
    foreach ($button in $ui.buttons) { $ui.items.Children.Remove($button) }
    $ui.buttons = @()
    foreach ($name in $names) {
        $button = New-Object System.Windows.Controls.Button
        $button.Content = $name
        $button.Height = 30
        $button.Margin = New-Object System.Windows.Thickness(0, 2, 0, 2)
        $button.Add_Click({ param($sender, $eventArgs) $state.clicked = [string]$sender.Content })
        [void]$ui.items.Children.Add($button)
        $ui.buttons += $button
    }
}
function New-MainWindow {
    $window = New-Object System.Windows.Window
    $window.Title = "OCU pi-phone Fixture"
    $window.WindowStartupLocation = "Manual"
    $window.Left = $Left; $window.Top = $Top; $window.Width = $Width; $window.Height = $Height
    $window.ShowInTaskbar = $true
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = New-Object System.Windows.Thickness(20)
    $check = New-Object System.Windows.Controls.CheckBox
    $check.Content = "Shout"
    [System.Windows.Automation.AutomationProperties]::SetName($check, "Shout")
    $items = New-Object System.Windows.Controls.StackPanel
    [void]$panel.Children.Add($check)
    [void]$panel.Children.Add($items)
    $window.Content = $panel
    $ui.window = $window; $ui.items = $items; $ui.check = $check; $ui.buttons = @()
    Add-Buttons @(1..6 | ForEach-Object { "Item $_" })
    $state.windows += 1
    $window.Show()
    [void]$window.Activate()
}

$commandPath = $StatePath + ".command"
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(50)
$timer.Add_Tick({
    if (Test-Path -LiteralPath $commandPath) {
        try {
            $command = [System.IO.File]::ReadAllText($commandPath) | ConvertFrom-Json
            if ($command.sequence -gt $state.sequence) {
                switch ($command.kind) {
                    "reverse" {
                        $buttons = @($ui.buttons)
                        [array]::Reverse($buttons)
                        foreach ($button in $buttons) { $ui.items.Children.Remove($button) }
                        foreach ($button in $buttons) { [void]$ui.items.Children.Add($button) }
                        $ui.buttons = $buttons
                    }
                    "rebuild" {
                        $names = @($ui.buttons | ForEach-Object { [string]$_.Content })
                        [array]::Reverse($names)
                        Add-Buttons $names
                    }
                    "reopen" {
                        $old = $ui.window
                        New-MainWindow
                        $old.Close()
                    }
                }
                $state.sequence = $command.sequence
            }
        } catch [System.IO.IOException] { }
    }
    $state.checked = [bool]$ui.check.IsChecked
    Write-State $state
})
$application.ShutdownMode = "OnExplicitShutdown"
New-MainWindow
$timer.Start()
[void]$application.Run()
