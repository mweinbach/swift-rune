# Run from a Visual Studio developer PowerShell with clang-cl and the Windows SDK.
$ErrorActionPreference = 'Stop'
$bridge = Join-Path $PSScriptRoot '../../../Sources/CRuneWin32'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('RuneRedraw-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($scratch)
Push-Location $scratch
try {
    $sources = @('Win32.c', 'LazyGL.c', 'CpuDib.c', 'WGLWorker.c', 'LazyGL.c', 'CustomFrame.c', 'WindowLifecycle.c', 'GroupWake.c', 'Occlusion.c', 'OverlayPointer.c') |
        ForEach-Object { Join-Path $bridge $_ }
    $gpu = @('WGLHandover.cpp', 'PresentDXGI.cpp', 'PresentQueue.cpp', 'PresentInterop.cpp', 'SharedTexture.cpp') |
        ForEach-Object { Join-Path $bridge $_ }
    & clang-cl.exe /nologo /c /O2 /Gy /EHsc /std:c++17 /DNOMINMAX "/I$bridge/include" @gpu
    if ($LASTEXITCODE -ne 0) { throw "Windows GPU compilation failed with exit code $LASTEXITCODE" }
    $objects = Get-ChildItem -Filter '*.obj' | ForEach-Object { $_.FullName }
    & clang-cl.exe /nologo /O2 /Gy /std:c11 "/I$bridge/include" "/I$bridge" @sources "$PSScriptRoot/probe.c" @objects /Fe:Probe.exe /link /OPT:REF user32.lib gdi32.lib dwmapi.lib comctl32.lib imm32.lib opengl32.lib dcomp.lib shell32.lib d3d11.lib d3d12.lib dxgi.lib dxguid.lib ole32.lib uuid.lib
    if ($LASTEXITCODE -ne 0) { throw "Redraw probe build failed with exit code $LASTEXITCODE" }
    & ./Probe.exe
    if ($LASTEXITCODE -ne 0) { throw "Redraw probe failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
