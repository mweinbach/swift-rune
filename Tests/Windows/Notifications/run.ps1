# Run in an interactive Windows user session with notifications enabled.
# Pass the path to RuneNotificationProbe.exe to use an existing build.
param([string]$Executable, [string]$ActivationClient)
$ErrorActionPreference = 'Stop'
if (!$Executable) {
    Push-Location $PSScriptRoot
    try {
        & swift build --product RuneNotificationProbe
        if ($LASTEXITCODE) { throw 'Could not build the Swift notification probe' }
        $Executable = Join-Path ((& swift build --show-bin-path).Trim()) 'RuneNotificationProbe.exe'
    } finally { Pop-Location }
}
$nonce = [guid]::NewGuid().ToString('N')
$appId = 'Rune.Test.' + $nonce
$scheme = 'rune-test-' + $nonce
$identityKey = "HKCU:\Software\Classes\AppUserModelId\$appId"
$protocolKey = "HKCU:\Software\Classes\$scheme"
if ((Test-Path $identityKey) -or (Test-Path $protocolKey)) { throw 'Fixture identity collision' }
[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime] > $null
$history = [Windows.UI.Notifications.ToastNotificationManager]::History
function Wait-History([int]$count, [string]$title) {
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $toasts = @($history.GetHistory($appId) | Where-Object { $_.Group -eq 'rune' })
        if ($toasts.Count -eq $count) {
            if (!$count) { return }
            $xml = [xml]$toasts[0].Content.GetXml()
            if ($xml.toast.visual.binding.text[0] -eq $title -and $xml.toast.actions.input.id -eq 'reply') { return }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Unexpected notification history for $count / '$title'. Found $($toasts.Count)."
}
try {
    & $Executable first $appId $scheme
    if ($LASTEXITCODE) { throw 'Swift registration or initial post failed' }
    if ((Get-ItemProperty $identityKey).DisplayName -ne 'Rune Toast Test') { throw 'Registration missing' }
    $command = (Get-Item "$protocolKey\shell\open\command").GetValue('')
    if (!$command.Contains('"%1"') -or !$command.Contains((Get-Item $Executable).FullName)) { throw 'Activation command mismatch' }
    Wait-History 1 First
    & $Executable replace $appId $scheme
    if ($LASTEXITCODE) { throw 'Swift replacement failed' }
    Wait-History 1 Updated
    & $Executable remove $appId $scheme
    if ($LASTEXITCODE) { throw 'Swift removal failed' }
    Wait-History 0 ''
    Write-Output 'Windows toast registration, protocol URI, history replacement, reply XML and removal passed.'
} finally {
    try { $history.Clear($appId) } finally {
        if (Test-Path $protocolKey) { Remove-Item -LiteralPath $protocolKey -Recurse -Force }
        if (Test-Path $identityKey) { Remove-Item -LiteralPath $identityKey -Recurse -Force }
    }
}

# The optional native client is Probe.cpp under ../NotificationActivation.
if ($ActivationClient) {
    foreach ($mode in 'serve', 'wait') {
        $clsid = [guid]::NewGuid().ToString('B')
        $ready = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.ready')
        $proc = Start-Process -FilePath $Executable -ArgumentList "$mode $clsid `"$ready`"" -PassThru -WindowStyle Hidden
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            while (!(Test-Path $ready) -and !$proc.HasExited -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 50
            }
            if (!(Test-Path $ready)) { throw "Swift activator failed to start in $mode mode" }
            & $ActivationClient client $clsid
            if ($LASTEXITCODE -ne 0 -or !$proc.WaitForExit(20000) -or $proc.ExitCode -ne 0) {
                throw "Swift $mode failed to receive the Unicode COM reply"
            }
            Write-Output "Swift $mode received Unicode reply from independent COM client."
        } finally {
            if (!$proc.HasExited) { $proc.Kill(); $proc.WaitForExit() }
            $proc.Dispose()
            if (Test-Path $ready) { Remove-Item -LiteralPath $ready -Force }
        }
    }
}
