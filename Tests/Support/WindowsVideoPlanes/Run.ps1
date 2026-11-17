# Run in a Visual Studio developer PowerShell. Use -RequireInterop to check a WGL_NV_DX_interop2 adapter.
param([switch]$RequireInterop)
$ErrorActionPreference = 'Stop'
$bridge = Join-Path $PSScriptRoot '../../../Sources/CRuneWin32'
$gl = Join-Path $PSScriptRoot '../../../Sources/CRuneGL'
$shaders = Join-Path $PSScriptRoot '../../../Sources/Rune/Resources/GL'
$glSources = (Get-ChildItem "$gl/*.c").FullName
$scratch = Join-Path $env:TEMP ('rune-video-planes-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory $scratch
Push-Location $scratch
try {
    & cl.exe /nologo /O2 /EHsc /std:c++17 /DNOMINMAX "/I$bridge" "/I$bridge/include" "/I$gl/include" @glSources "$bridge/LazyGL.c" "$bridge/DecodedPlanes.cpp" "$bridge/SharedTexture.cpp" "$PSScriptRoot/Probe.cpp" /Fe:PlaneProbe.exe /link d3d11.lib dxgi.lib dxguid.lib gdi32.lib user32.lib opengl32.lib
    if ($LASTEXITCODE) { throw "Compilation failed with exit $LASTEXITCODE" }
    $results = & .\PlaneProbe.exe $shaders
    $results | Write-Output
    if ($LASTEXITCODE) { throw "Plane transfer fixture exited $LASTEXITCODE" }
    if ($RequireInterop) {
        $gpuCopies = @($results | Where-Object { $_ -match '^driver=1, .*direct-WGL=3/3' })
        if ($gpuCopies.Count -ne 2) { throw 'Both hardware-backed frame sizes must use WGL GPU transfer for all three revisions.' }
    }
} finally {
    Pop-Location
    Remove-Item -Recurse -Force -LiteralPath $scratch
}
