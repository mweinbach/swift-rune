# Run from a Visual Studio developer PowerShell in an interactive Windows session.
param([string]$VideoFile = "$PSScriptRoot/../../RuneTests/Fixtures/rgbw.mp4")

$ErrorActionPreference = 'Stop'
$bridge = Resolve-Path "$PSScriptRoot/../../../Sources/CRuneWin32"
$clip = (Resolve-Path $VideoFile).Path
$scratch = Join-Path ([IO.Path]::GetTempPath()) ("rune-video-layer-" + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($scratch)
Push-Location $scratch
try {
    & cl.exe /nologo /std:c++17 /EHsc /MD /W4 "/I$bridge/include" "$bridge/VideoLayer.cpp" "$PSScriptRoot/Probe.cpp" /Fe:probe.exe /link d3d11.lib dwmapi.lib user32.lib gdi32.lib
    if ($LASTEXITCODE) { throw 'Video layer fixture build failed' }
    $pixelResult = & .\probe.exe
    $pixelResult | Write-Output
    if ($LASTEXITCODE) { throw "Video layer fixture failed (exit $LASTEXITCODE)" }
    if ($pixelResult -match '^PASS NV12') {
        & swift run --package-path $PSScriptRoot PlayerProbe $clip
        if ($LASTEXITCODE) { throw "Public Player fixture failed (exit $LASTEXITCODE)" }
    }
} finally {
    Pop-Location
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
