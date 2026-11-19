# Windows runtime regression test for structuredquestions.ps1 (SKILLS-210, two phases since SKILLS-213). Works only
# inside the folder it is given (fake .cmd and .ps1 installs are written there and passed with -SearchPath; no PATH,
# environment or profile is touched).
# Run: powershell -NoProfile -File structuredquestions_windows.ps1 -Dir <empty temp folder> -Script <path to structuredquestions.ps1>
# Needs Windows PowerShell 5.1 or PowerShell 7. Prints one JSON line and VERDICT PASS or VERDICT FAIL; the two phase
# outputs are kept in <Dir>\phase1.json and <Dir>\phase2.json for comparison with the POSIX script.
param([Parameter(Mandatory=$true)][string]$Dir, [Parameter(Mandatory=$true)][string]$Script, [int]$Timeout = 3)
$ErrorActionPreference = 'Stop'
$marker = 'ping -n 4321 127.0.0.1'
$second = Join-Path $Dir 'acct2'
New-Item -ItemType Directory -Path $second -Force | Out-Null
function Shim($name, $lines) { Set-Content -LiteralPath (Join-Path $Dir $name) -Value (@('@echo off') + $lines) -Encoding ASCII }
Shim 'claude.cmd' @($marker + ' >nul')   # cmd.exe waits for a hanging child CLI
Shim 'codex.cmd' @('echo usage: codex [--dangerously-bypass-approvals-and-sandbox]')
Shim 'kimi.cmd' @('echo usage: kimi [--yolo-extra] [--auto-approve]')                       # look-alike flags only
Shim 'grok.cmd' @('echo   --approval-mode MODE', 'echo   MODEL   pick a model (always-ask^|yolo)', 'echo   --permission-mode MODE', 'echo   MODEL   bypassPermissions')   # sibling entries, not continuations
Shim 'omp.cmd' @('echo   --approval-mode=^<value^>   Override (always-ask^|always-ask-cached^|write^|yolo)')   # real omp layout
Shim 'muse.cmd' @('echo   --yolo   run without prompts')
# A second Claude install in its own folder, as a PowerShell script: started the way SPAWN starts a .ps1.
Set-Content -LiteralPath (Join-Path $second 'claude.ps1') -Value "Write-Output 'usage: claude [--dangerously-skip-permissions]'" -Encoding ASCII
function Run([string[]]$extra) {
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = (Get-Process -Id $PID).Path
  $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '" -SearchPath "' + $Dir + ';' + $second + '" -Cwd "' + $Dir + '" -TimeoutSeconds ' + $Timeout + ' ' + ($extra -join ' ')
  $info.UseShellExecute = $false; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
  $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $child = [System.Diagnostics.Process]::Start($info)
  $errTask = $child.StandardError.ReadToEndAsync()
  $outTask = $child.StandardOutput.ReadToEndAsync()
  if (-not $child.WaitForExit(90000)) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
  $raw = $null
  if ($outTask.Wait(5000)) { $raw = $outTask.Result }   # an orphan that inherited the pipe keeps it open forever
  return @{ raw = $raw; code = $child.ExitCode; err = $(if ($errTask.Wait(1000)) { $errTask.Result } else { '' }) }
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$p1 = Run @()
$p2 = Run @('--phase', '2', '--accounts', 'claude=Main,acct2')
$ok = Run @('--check-args', 'omp', '--profile', 'work')
$no = Run @('--check-args', 'omp', '--ok', 'a;b')
$sw.Stop()
$left = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and ($_.CommandLine -like '*4321*' -or $_.CommandLine -like ('*' + (Split-Path -Leaf $Dir) + '*claude.cmd*')) -and $_.ProcessId -ne $PID })
$leftCount = $left.Count
$left | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }   # tidy only what this test started
if (-not $p1.raw -or -not $p2.raw) { ('{"json_parsed":false,"why":"stdout never closed or was empty","stderr":' + (($p1.err + $p2.err) | ConvertTo-Json) + ',"survivors_after_timeout":' + $leftCount + '}'); 'VERDICT FAIL'; exit 1 }
[IO.File]::WriteAllText((Join-Path $Dir 'phase1.json'), $p1.raw); [IO.File]::WriteAllText((Join-Path $Dir 'phase2.json'), $p2.raw)
$d1 = $p1.raw | ConvertFrom-Json; $d2 = $p2.raw | ConvertFrom-Json
$q2 = @($d2.prompts | ForEach-Object { $_.questions })
function Yolo($id) { [bool](@($q2 | Where-Object { $_.id -eq "perm-$id" } | ForEach-Object { $_.options } | Where-Object { $_.label -like 'YOLO*' }).Count) }
$dash = [string][char]0x2014
$accounts = @($d2.derived.accounts)
$main = $accounts | Where-Object { $_.id -eq 'claude-main' }; $acct2 = $accounts | Where-Object { $_.id -eq 'claude-acct2' }
$mapping = $q2 | Where-Object { $_.id -eq 'mapping' }
$result = [ordered]@{
  host = $PSVersionTable.PSVersion.ToString(); seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); json_parsed = $true
  phase1_intro = ($d1.intro[0] -eq 'Found on this machine: Claude, Codex, Kimi, Grok, Muse, OMP.')
  phase1_prompts = ((@($d1.prompts | ForEach-Object { $_.id }) -join ',') -eq 'accounts,providers,count,labels')
  phase1_no_paths = (($p1.raw -notlike ('*' + (Split-Path -Leaf $Dir) + '*claude*')) -and ($p1.raw -notlike '*acct2*'))
  two_installs_mapped = ($main.command -eq (Join-Path $Dir 'claude.cmd')) -and ($acct2.command -eq (Join-Path $second 'claude.ps1'))
  one_user_confirm = ($mapping.question -eq "All agents run as $([Environment]::UserName)?")
  utf8_rows = [bool](@($d2.prompts | Where-Object { $_.id -eq 'mapping' } | ForEach-Object { $_.lines } | Where-Object { $_ -like ('*' + $dash + '*acct2*') }).Count)
  hung_install_no_yolo = (-not (Yolo 'claude-main')); ps1_install_yolo = (Yolo 'claude-acct2'); survivors_after_timeout = $leftCount
  codex_yolo = (Yolo 'codex'); lookalike_not_offered = (-not (Yolo 'kimi')); sibling_entry_not_offered = (-not (Yolo 'grok')); omp_listed_value_offered = (Yolo 'omp'); muse_offered = (Yolo 'muse')
  per_agent_permission = [bool]($q2 | Where-Object { $_.id -eq 'perm-claude-acct2' -and $_.when.question -eq 'perm-gate' })
  check_args = ($ok.code -eq 0) -and (($ok.raw | ConvertFrom-Json).arguments -join ' ') -eq '--profile work' -and ($no.code -eq 3) -and (($no.raw | ConvertFrom-Json).why -eq 'Arguments cannot contain a semicolon (;).')
}
$result | ConvertTo-Json -Compress
foreach ($k in $result.Keys) { if ($k -notin @('host', 'seconds', 'survivors_after_timeout') -and -not $result[$k]) { 'VERDICT FAIL'; exit 1 } }
if ($result.survivors_after_timeout -ne 0) { 'VERDICT FAIL'; exit 1 }
'VERDICT PASS'
