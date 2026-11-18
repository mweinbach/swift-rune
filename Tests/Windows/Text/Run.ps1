# Run in a Visual Studio developer PowerShell with the Windows SDK installed.
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '../../..')
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('RuneConfiguredLines-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($scratch)
Push-Location $scratch
try {
    & clang-cl.exe /nologo /O2 /EHsc /std:c++17 /utf-8 "/I$root/Sources/CRuneDesktopText/include" "$root/Sources/CRuneDesktopText/WindowsText.cpp" "$PSScriptRoot/ConfiguredLines.cpp" /Fe:ConfiguredLines.exe /link dwrite.lib d2d1.lib user32.lib ole32.lib uuid.lib
    if ($LASTEXITCODE -ne 0) { throw "Probe build failed with exit code $LASTEXITCODE" }
    & ./ConfiguredLines.exe "$root/Sources/Rune/Resources/Fonts/IBMPlexMono-Regular.ttf"
    if ($LASTEXITCODE -ne 0) { throw "DirectWrite configured-line comparison failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
