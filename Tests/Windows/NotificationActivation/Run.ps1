# Run from a Visual Studio developer PowerShell with the Windows 10+ SDK.
$ErrorActionPreference = 'Stop'
$bridge = Join-Path $PSScriptRoot '../../../Sources/CRuneNotify'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('RuneNotify-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($scratch)
Push-Location $scratch
try {
    & cl.exe /nologo /EHsc /MT /W4 "/I$bridge/include" "$bridge/WindowsNotificationActivator.cpp" "$PSScriptRoot/Probe.cpp" /Fe:Probe.exe /link ole32.lib uuid.lib
    if ($LASTEXITCODE -ne 0) { throw "Probe build failed with exit code $LASTEXITCODE" }
    & ./Probe.exe
    if ($LASTEXITCODE -ne 0) { throw "Probe failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
