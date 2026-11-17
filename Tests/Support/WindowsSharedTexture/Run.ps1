$ErrorActionPreference = 'Stop'
& swift build --package-path $PSScriptRoot -j 3
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$bin = & swift build --package-path $PSScriptRoot --show-bin-path
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$original = $env:RUNE_TEST_D3D12_PRODUCER
try {
    foreach ($d3d12 in 0, 1) {
        if ($d3d12) { $env:RUNE_TEST_D3D12_PRODUCER = '1' } else { $env:RUNE_TEST_D3D12_PRODUCER = $null }
        & (Join-Path $bin 'SharedTextureConsumer.exe')
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
} finally {
    $env:RUNE_TEST_D3D12_PRODUCER = $original
}
