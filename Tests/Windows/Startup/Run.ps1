# Run in a Windows Swift/Visual Studio developer PowerShell.
$ErrorActionPreference = 'Stop'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('RuneStartup-' + [Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($scratch)
Push-Location $scratch
try {
    $bridge = Join-Path $PSScriptRoot '../../../Sources/CRuneWin32'
    $gpu = @('WGLHandover.cpp', 'PresentDXGI.cpp', 'PresentQueue.cpp', 'PresentInterop.cpp', 'SharedTexture.cpp') |
        ForEach-Object { Join-Path $bridge $_ }
    & clang-cl /nologo /O2 /Gy /EHsc /std:c++17 /DNOMINMAX "/I$bridge/include" /c @gpu
    if ($LASTEXITCODE -ne 0) { throw "Windows GPU bridge compilation failed with $LASTEXITCODE" }
    $objects = Get-ChildItem -Filter '*.obj' | ForEach-Object { $_.FullName }
    $hostSources = @('CpuDib.c', 'WGLWorker.c', 'LazyGL.c', 'WindowLifecycle.c', 'Occlusion.c', 'CustomFrame.c', 'GroupWake.c', 'OverlayPointer.c') |
        ForEach-Object { Join-Path $bridge $_ }
    & clang-cl /nologo /O2 /Gy /std:c11 "/I$bridge/include" "$PSScriptRoot/flash.c" @hostSources @objects /Fe:FlashProbe.exe /link /OPT:REF user32.lib gdi32.lib dwmapi.lib comctl32.lib imm32.lib opengl32.lib shell32.lib d3d11.lib d3d12.lib dxgi.lib dxguid.lib ole32.lib uuid.lib
    if ($LASTEXITCODE -ne 0) { throw "Taskbar probe compilation failed with $LASTEXITCODE" }
    & ./FlashProbe.exe
    if ($LASTEXITCODE -ne 0) { throw "Taskbar probe failed with $LASTEXITCODE" }
    & clang-cl /nologo /O2 /std:c11 "/I$bridge/include" "$PSScriptRoot/menu_theme.c" "$bridge/MenuTheme.c" /Fe:MenuThemeProbe.exe
    if ($LASTEXITCODE -ne 0) { throw "Menu theme probe compilation failed with $LASTEXITCODE" }
    & ./MenuThemeProbe.exe
    if ($LASTEXITCODE -ne 0) { throw "Menu theme probe failed with $LASTEXITCODE" }
    & swift run --package-path $PSScriptRoot StartupProbe
    if ($LASTEXITCODE -ne 0) { throw "First-paint probe failed with $LASTEXITCODE" }
} finally {
    Pop-Location
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
