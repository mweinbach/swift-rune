# Run in a Visual Studio developer PowerShell on a Windows desktop with Swift installed.
# Prebuilt executables may also be supplied, including native ARM64 builds.
# -Selection runs the selection, scroll-item, and native callback fixture.
param([string]$Executable, [string]$Client, [switch]$Selection)
$ErrorActionPreference = 'Stop'

if (-not $Executable) {
    & swift build --package-path $PSScriptRoot --product RuneTextFixture
    if ($LASTEXITCODE -ne 0) { throw 'Swift fixture build failed.' }
    $bin = & swift build --package-path $PSScriptRoot --show-bin-path
    if ($LASTEXITCODE -ne 0) { throw 'Could not locate Swift build output.' }
    $Executable = Join-Path $bin 'RuneTextFixture.exe'
}

$clientBuild = $null
$app = $null
$probe = $null
try {
    if (-not $Client) {
        $clientBuild = Join-Path ([IO.Path]::GetTempPath()) ("RuneTextClient-" + [guid]::NewGuid())
        New-Item -ItemType Directory $clientBuild | Out-Null
        $Client = Join-Path $clientBuild 'TextClient.exe'
        $object = Join-Path $clientBuild 'TextClient.obj'
        & cl.exe /nologo /utf-8 /std:c++17 /EHsc /MT (Join-Path $PSScriptRoot 'TextClient.cpp') `
            "/Fo$object" "/Fe$Client" /link UIAutomationCore.lib Ole32.lib OleAut32.lib User32.lib Uuid.lib
        if ($LASTEXITCODE -ne 0) { throw 'Native UI Automation client build failed.' }
    }

    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = (Resolve-Path $Executable).Path
    Write-Output ("Rune text fixture SHA256 " + (Get-FileHash -LiteralPath $start.FileName -Algorithm SHA256).Hash)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['RUNE_OPEN_INACTIVE'] = '1'
    if ($Selection) { $start.EnvironmentVariables['RUNE_SELECTION_FIXTURE'] = '1' }
    $app = [System.Diagnostics.Process]::Start($start)
    $appErrors = $app.StandardError.ReadToEndAsync()

    $clientStart = New-Object System.Diagnostics.ProcessStartInfo
    $clientStart.FileName = (Resolve-Path $Client).Path
    $clientStart.Arguments = $app.Id.ToString()
    $clientStart.UseShellExecute = $false
    $clientStart.CreateNoWindow = $true
    $clientStart.RedirectStandardOutput = $true
    $clientStart.RedirectStandardError = $true
    if ($Selection) { $clientStart.EnvironmentVariables['RUNE_SELECTION_FIXTURE'] = '1' }
    $probe = [System.Diagnostics.Process]::Start($clientStart)
    $output = $probe.StandardOutput.ReadToEndAsync()
    $errors = $probe.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    while (-not $probe.WaitForExit(1000)) {
        if ($app.HasExited) { throw "Rune exited with code $($app.ExitCode) while the UI Automation client was running." }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'UI Automation probe timed out.' }
    }
    if ($probe.ExitCode -ne 0) { throw "UI Automation probe failed with exit code $($probe.ExitCode)." }
    Write-Output $output.Result.Trim()
} finally {
    if ($probe) {
        if (-not $probe.HasExited) { $probe.Kill(); $probe.WaitForExit() }
        if ($errors -and $errors.Result) { Write-Output $errors.Result.Trim() }
        $probe.Dispose()
    }
    if ($app) {
        if (-not $app.HasExited) {
            $null = $app.CloseMainWindow()
            if (-not $app.WaitForExit(1500)) {
                try { $app.Kill() } catch [System.InvalidOperationException] { if (-not $app.HasExited) { throw } }
                $app.WaitForExit()
            }
        }
        if ($appErrors -and $appErrors.Result) { Write-Output $appErrors.Result.Trim() }
        $app.Dispose()
    }
    if ($clientBuild) { Remove-Item -Recurse -Force $clientBuild }
}
