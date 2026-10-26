param([Parameter(Mandatory = $true)][string]$StatePath)
# pi-phone fork: a WPF window with a user name box and a focused password box, for
# windows-password-smoke.ps1. Its state file reports both values so the smoke can
# check that nothing was typed into the password box.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework
$window = New-Object System.Windows.Window
$window.Title = "OCU Windows Password Fixture"
$window.ShowInTaskbar = $true
$window.Left = 80
$window.Top = 80
$window.Width = 600
$window.Height = 280
$panel = New-Object System.Windows.Controls.StackPanel
$panel.Margin = New-Object System.Windows.Thickness(20)
$userBox = New-Object System.Windows.Controls.TextBox
[System.Windows.Automation.AutomationProperties]::SetName($userBox, "User name")
$userBox.Height = 30
$userBox.Margin = New-Object System.Windows.Thickness(0, 0, 0, 12)
$passwordBox = New-Object System.Windows.Controls.PasswordBox
[System.Windows.Automation.AutomationProperties]::SetName($passwordBox, "Password")
$passwordBox.Height = 30
$passwordBox.Password = "fixture-secret"
[void]$panel.Children.Add($userBox)
[void]$panel.Children.Add($passwordBox)
$window.Content = $panel
$window.Add_ContentRendered({
    [void]$window.Activate()
    [void]$passwordBox.Focus()
    [void][System.Windows.Input.Keyboard]::Focus($passwordBox)
})
$state = @{ user = ""; password = ""; passwordFocused = $false }
$stateEncoding = New-Object System.Text.UTF8Encoding($false)
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(50)
$timer.Add_Tick({
    $state.user = $userBox.Text
    $state.password = $passwordBox.Password
    $state.passwordFocused = $passwordBox.IsKeyboardFocused
    $temporary = $StatePath + ".tmp"
    [System.IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json -Compress), $stateEncoding)
    try {
        if (Test-Path -LiteralPath $StatePath) { [System.IO.File]::Replace($temporary, $StatePath, ($StatePath + ".bak")) }
        else { [System.IO.File]::Move($temporary, $StatePath) }
    } catch [System.IO.IOException] { }
})
$timer.Start()
$window.Add_Closed({ $timer.Stop() })
$application = New-Object System.Windows.Application
$application.ShutdownMode = "OnMainWindowClose"
[void]$application.Run($window)
