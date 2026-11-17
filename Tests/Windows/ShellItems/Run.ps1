# Run in a Visual Studio developer PowerShell with the Windows SDK and Explorer running.
$ErrorActionPreference = 'Stop'
$bridge = Join-Path $PSScriptRoot '../../../Sources/CRuneWin32'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('RuneShellItems-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($scratch)
Push-Location $scratch
try {
    $flags = @('/nologo', '/EHsc', '/std:c++17', '/MT', "/I$bridge/include")
    $libs = @('shell32.lib', 'ole32.lib', 'uuid.lib', 'user32.lib', 'gdi32.lib')
    & cl.exe @flags "$bridge/Tray.cpp" "$bridge/JumpList.cpp" "$PSScriptRoot/Smoke.cpp" /Fe:Smoke.exe /link @libs
    if ($LASTEXITCODE -ne 0) { throw 'Shell integration probe build failed' }
    & cl.exe @flags "$PSScriptRoot/TrayMenu.cpp" "$PSScriptRoot/Links.cpp" /Fe:Model.exe /link @libs
    if ($LASTEXITCODE -ne 0) { throw 'Menu and shell link probe build failed' }
    & ./Model.exe
    if ($LASTEXITCODE -ne 0) { throw 'Menu or shell link check failed' }
    & ./Smoke.exe
    if ($LASTEXITCODE -ne 0) { throw 'Shell integration check failed' }
} finally {
    Pop-Location
    # Explorer may briefly hold the executable while extracting the shell link's icon.
    for ($i = 0; $i -lt 10 -and (Test-Path -LiteralPath $scratch); $i++) {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $scratch) { Start-Sleep -Milliseconds 300 }
    }
    if (Test-Path -LiteralPath $scratch) { throw "Test directory still in use: $scratch" }
}
