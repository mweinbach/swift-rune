# Run from a Windows SDK developer shell for the architecture to exercise.
$ErrorActionPreference = "Stop"
$work = Join-Path ([IO.Path]::GetTempPath()) ("rune-gpu-selection-" + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($work)
Push-Location $work
try {
    & cl.exe /nologo /W4 /std:c++14 /EHsc /DNOMINMAX "$PSScriptRoot/Windows.cpp" /Fe:Adapter.exe /link dxgi.lib d3d11.lib user32.lib
    if ($LASTEXITCODE -ne 0) { throw "Adapter fixture compilation failed ($LASTEXITCODE)" }
    & .\Adapter.exe
    if ($LASTEXITCODE -ne 0) { throw "DXGI adapter fixture failed ($LASTEXITCODE)" }
} finally {
    Pop-Location
    Remove-Item -LiteralPath $work -Recurse -Force
}
