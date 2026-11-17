# Run from a Visual Studio developer PowerShell on a composed Windows desktop.
$ErrorActionPreference = 'Stop'
$bridge = Join-Path $PSScriptRoot '../../../Sources/CRuneWin32'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('RunePresentation-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($scratch)
Push-Location $scratch
try {
    & clang-cl.exe /nologo /O2 /EHsc /std:c++17 /DNOMINMAX "$bridge/PresentQueue.cpp" "$PSScriptRoot/queue_probe.cpp" /Fe:Probe.exe /link user32.lib gdi32.lib dwmapi.lib d3d11.lib dxgi.lib
    if ($LASTEXITCODE -ne 0) { throw "Presentation probe build failed with exit code $LASTEXITCODE" }
    $failed = @()
    foreach ($case in 'composition', 'child') {
        & ./Probe.exe $case
        if ($LASTEXITCODE -ne 0) { $failed += "$case ($LASTEXITCODE)" }
    }
    if ($failed.Count) { throw "Presentation probe failed in $($failed -join ', ')" }
} finally {
    Pop-Location
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
