# Run in a Visual Studio developer PowerShell with the Windows SDK.
$ErrorActionPreference = 'Stop'
$bridge = Join-Path $PSScriptRoot '../../../Sources/CRuneWin32'
$scratch = Join-Path $env:TEMP ('rune-video-planes-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory $scratch
Push-Location $scratch
try {
    & cl.exe /nologo /O2 /EHsc /std:c++17 /DNOMINMAX "/I$bridge" "/I$bridge/include" "$bridge/LazyGL.c" "$bridge/DecodedPlanes.cpp" "$bridge/SharedTexture.cpp" "$PSScriptRoot/Probe.cpp" /Fe:PlaneProbe.exe /link d3d11.lib dxgi.lib dxguid.lib gdi32.lib user32.lib opengl32.lib
    if ($LASTEXITCODE) { throw "Compilation failed with exit $LASTEXITCODE" }
    & .\PlaneProbe.exe
    if ($LASTEXITCODE) { throw "Plane transfer fixture exited $LASTEXITCODE" }
} finally {
    Pop-Location
    Remove-Item -Recurse -Force -LiteralPath $scratch
}
