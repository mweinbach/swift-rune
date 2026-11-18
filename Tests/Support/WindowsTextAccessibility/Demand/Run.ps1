param([string]$Executable, [string]$Client, [string]$Provider)
$ErrorActionPreference = 'Stop'
$scratch = $null
$app = $null
try {
    if (-not $Executable) {
        & swift build --package-path $PSScriptRoot -c release --product RuneDemandFixture
        if ($LASTEXITCODE -ne 0) { throw 'RuneDemandFixture build failed.' }
        $bin = & swift build --package-path $PSScriptRoot -c release --show-bin-path
        if ($LASTEXITCODE -ne 0) { throw 'Could not locate RuneDemandFixture.' }
        $Executable = Join-Path $bin 'RuneDemandFixture.exe'
    }
    if (-not $Client -or -not $Provider) {
        $scratch = Join-Path ([IO.Path]::GetTempPath()) ('RuneDemand-' + [guid]::NewGuid())
        $null = New-Item -ItemType Directory $scratch
    }
    if (-not $Provider) {
        $native = (Resolve-Path (Join-Path $PSScriptRoot '../../../../Sources/CRuneWin32')).Path
        $Provider = Join-Path $scratch 'DemandProvider.exe'
        $sources = @('RuneAccessibility.cpp', 'RuneTextProvider.cpp', 'RuneTextRange.cpp') |
            ForEach-Object { Join-Path $native $_ }
        Push-Location $scratch
        try {
            & cl.exe /nologo /MT /EHsc /std:c++17 "/I$(Join-Path $native 'include')" `
                (Join-Path $PSScriptRoot 'DemandProvider.cpp') @sources "/Fe$Provider" /link `
                User32.lib Ole32.lib OleAut32.lib Uuid.lib UIAutomationCore.lib Comctl32.lib
            if ($LASTEXITCODE -ne 0) { throw 'DemandProvider build failed.' }
        } finally { Pop-Location }
    }
    & $Provider
    if ($LASTEXITCODE -ne 0) { throw 'Dormant HWND provider or synchronous activation check failed.' }
    if (-not $Client) {
        $Client = Join-Path $scratch 'DemandClient.exe'
        & cl.exe /nologo /MT /EHsc /std:c++17 (Join-Path $PSScriptRoot 'DemandClient.cpp') `
            "/Fo$(Join-Path $scratch 'DemandClient.obj')" "/Fe$Client" /link `
            UIAutomationCore.lib Ole32.lib OleAut32.lib User32.lib Uuid.lib
        if ($LASTEXITCODE -ne 0) { throw 'DemandClient build failed.' }
    }
    $app = Start-Process -FilePath (Resolve-Path $Executable).Path -PassThru
    & $Client $app.Id
    if ($LASTEXITCODE -ne 0) { throw "First UI Automation traversal failed (exit $LASTEXITCODE)." }
} finally {
    if ($app) {
        if (-not $app.HasExited) {
            $null = $app.CloseMainWindow()
            if (-not $app.WaitForExit(2500)) { $app.Kill(); $app.WaitForExit() }
        }
        $app.Dispose()
    }
    if ($scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
