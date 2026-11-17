# English-first interactive checkpoint reader. Blastworks.ai, COMMANDER-993.
$reader = Join-Path $PSScriptRoot 'todo.py'
$probe = "import sys;print('TODO_PYTHON_3={}.{}'.format(*sys.version_info[:2]));sys.exit(sys.version_info.major != 3)"
$candidates = @(
    [pscustomobject]@{ Path = 'py'; Prefix = @('-3') },
    [pscustomobject]@{ Path = 'python'; Prefix = @() },
    [pscustomobject]@{ Path = 'python3'; Prefix = @() }
)
foreach ($candidate in $candidates) {
    $prefix = $candidate.Prefix
    try { $version = & $candidate.Path @prefix -I -c $probe 2>$null } catch { $version = @() }
    if ($LASTEXITCODE -eq 0 -and @($version).Count -eq 1 -and @($version)[0] -match '^TODO_PYTHON_3=3\.\d+$') {
        & $candidate.Path @prefix -I $reader @args
        if ($LASTEXITCODE -eq 2) { exit 1 }
        exit $LASTEXITCODE
    }
}
Write-Error 'Python 3 is required. Tried py -3, python and python3; Microsoft Store aliases are not Python installations.'
exit 1
