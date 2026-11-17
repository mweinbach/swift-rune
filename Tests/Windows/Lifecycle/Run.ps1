# Run from a Visual Studio developer PowerShell with clang-cl and the Windows SDK.
$ErrorActionPreference = 'Stop'
$bridge = Join-Path $PSScriptRoot '../../../Sources/CRuneWin32'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('RuneLifecycle-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($scratch)
Push-Location $scratch
try {
    $cpp = Get-ChildItem -Path $bridge -Filter '*.cpp' | ForEach-Object { $_.FullName }
    $c = Get-ChildItem -Path $bridge -Filter '*.c' | ForEach-Object { $_.FullName }
    & clang-cl.exe /nologo /c /O2 /Gy /EHsc /std:c++17 /DNOMINMAX "/I$bridge/include" @cpp
    if ($LASTEXITCODE -ne 0) { throw "Win32 C++ compilation failed with exit code $LASTEXITCODE" }
    & clang-cl.exe /nologo /c /O2 /Gy /std:c11 "/I$bridge/include" @c
    if ($LASTEXITCODE -ne 0) { throw "Win32 C compilation failed with exit code $LASTEXITCODE" }
    $objects = Get-ChildItem -Filter '*.obj' | ForEach-Object { $_.FullName }
    & lib.exe /nologo /out:RuneWin32.lib @objects
    if ($LASTEXITCODE -ne 0) { throw "Win32 library build failed with exit code $LASTEXITCODE" }
    $libraries = @(
        'user32.lib', 'gdi32.lib', 'dwmapi.lib', 'comctl32.lib', 'imm32.lib', 'opengl32.lib', 'shell32.lib',
        'd3d11.lib', 'd3d12.lib', 'dxgi.lib', 'dxguid.lib', 'ole32.lib', 'uuid.lib'
    )
    & clang-cl.exe /nologo /O2 /std:c11 "/I$bridge/include" "/I$bridge" "$PSScriptRoot/probe.c" RuneWin32.lib /Fe:Probe.exe /link /OPT:REF @libraries
    if ($LASTEXITCODE -ne 0) { throw "Lifecycle probe build failed with exit code $LASTEXITCODE" }
    & ./Probe.exe
    if ($LASTEXITCODE -ne 0) { throw "Lifecycle probe failed with exit code $LASTEXITCODE" }
    & ./Probe.exe fast-exit
    if ($LASTEXITCODE -ne 0) { throw "Fast-exit probe failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
