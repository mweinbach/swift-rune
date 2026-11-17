# Run in a Visual Studio Developer PowerShell from a Windows desktop.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/../../..").Path
$media = Join-Path $repo 'Sources/CRuneMedia'
$fixture = (Resolve-Path "$repo/Tests/RuneTests/Fixtures/rgbw.mp4").Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('RuneVideoPicture-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($work)
Push-Location $work
try {
    $sources = @("$PSScriptRoot/Picture.cpp", "$media/WindowsMedia.cpp", "$media/WindowsVideoGPU.cpp", "$media/WindowsVideoClock.cpp")
    $libraries = @('mfuuid.lib','mfplat.lib','mfreadwrite.lib','mfplay.lib','ole32.lib','runtimeobject.lib','d3d11.lib','dxgi.lib','dxguid.lib','propsys.lib','user32.lib','uuid.lib','dwmapi.lib')
    & cl.exe /nologo /std:c++17 /EHsc /W4 "/I$media/include" @sources /Fe:Picture.exe /link @libraries
    if ($LASTEXITCODE) { throw "Picture fixture failed to compile ($LASTEXITCODE)" }
    & .\Picture.exe ([Uri]$fixture).AbsoluteUri
    if ($LASTEXITCODE) { throw "Decoded video check failed ($LASTEXITCODE)" }
    & swift run --package-path $PSScriptRoot WindowsVideoConsumption $fixture "$PSScriptRoot/rgbw-audio.mp4"
    if ($LASTEXITCODE) { throw "Video consumption check failed ($LASTEXITCODE)" }
} finally {
    Pop-Location
    Remove-Item -LiteralPath $work -Recurse -Force
}
