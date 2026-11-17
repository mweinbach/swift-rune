# Run from a Windows Swift developer PowerShell. Each app uses its own unswitched desktop.
param([ValidateSet('only', 'handoff', 'direct', 'failure')][string[]]$Mode = @('only','handoff','direct','failure'))
$ErrorActionPreference = 'Stop'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('RuneCPUFirst-' + [Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($scratch)
$previous = @{}
foreach ($name in 'RUNE_CPU_FIRST','RUNE_PLAYGROUND','RUNE_GPU_INFO','RUNE_BOOT_PROFILE') {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name)
}
try {
    & swift build --package-path $PSScriptRoot --scratch-path $scratch --product CPUProbe
    if ($LASTEXITCODE -ne 0) { throw 'CPUProbe build failed' }
    $bin = & swift build --package-path $PSScriptRoot --scratch-path $scratch --show-bin-path
    if ($LASTEXITCODE -ne 0) { throw 'Could not locate CPUProbe build products' }
    $app = Join-Path $bin 'CPULaunch.exe'
    $driver = Join-Path $PSScriptRoot 'Sources/CPUProbeDriver'
    Push-Location $scratch
    try {
        & clang-cl /nologo /O2 /std:c11 "/I$driver/include" "$PSScriptRoot/launch.c" "$driver/CPUProbeDriver.c" "/Fe:$app" /link user32.lib gdi32.lib comctl32.lib
        if ($LASTEXITCODE -ne 0) { throw 'Native desktop launcher build failed' }
    } finally { Pop-Location }
    $shaders = @(Get-ChildItem -LiteralPath $bin -Recurse -File -Filter layer.frag | Where-Object { $_.Directory.Name -eq 'GL' })
    if ($shaders.Count -ne 1) { throw 'Expected exactly one GL/layer.frag in the temporary build' }
    $shader = $shaders[0].FullName
    $env:RUNE_PLAYGROUND = '0'
    $env:RUNE_GPU_INFO = '1'
    $env:RUNE_BOOT_PROFILE = '1'
    foreach ($case in $Mode) {
        switch ($case) {
            'only' { $env:RUNE_CPU_FIRST = 'only' }
            'direct' { $env:RUNE_CPU_FIRST = '0' }
            default { Remove-Item Env:RUNE_CPU_FIRST -ErrorAction SilentlyContinue }
        }
        $original = [IO.File]::ReadAllBytes($shader)
        try {
            if ($case -eq 'failure') {
                [IO.File]::WriteAllText($shader, "#error RUNE_QA_EXPECTED_LAYER_COMPILE_FAILURE`n", [Text.Encoding]::ASCII)
            }
            $out = Join-Path $scratch "$case.out"
            $err = Join-Path $scratch "$case.err"
            $process = Start-Process -FilePath $app -ArgumentList $case -WorkingDirectory $bin -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
            $null = $process.Handle
            $limit = if ($case -eq 'failure') {380000} else {290000}
            if (!$process.WaitForExit($limit)) {
                $process.Kill()
                $null = $process.WaitForExit(5000)
                Get-Content -LiteralPath $out
                Get-Content -LiteralPath $err
                throw "$case PID=$($process.Id) exceeded its $limit ms deadline"
            }
            $text = [IO.File]::ReadAllText($err)
            Get-Content -LiteralPath $out
            Write-Output $text
            if ($process.ExitCode -ne 0 -or $text -notmatch "PASS $case ") { throw "$case failed" }
            if ($case -eq 'failure' -and $text -notmatch 'RUNE_QA_EXPECTED_LAYER_COMPILE_FAILURE') {
                throw 'The GPU driver did not report the injected shader compilation error'
            }
        } finally {
            if ($case -eq 'failure') { [IO.File]::WriteAllBytes($shader, $original) }
        }
    }
} finally {
    foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
