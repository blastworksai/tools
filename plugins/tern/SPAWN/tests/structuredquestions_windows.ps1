# Windows runtime regression test for structuredquestions.ps1 (SKILLS-210). Works only inside the folder it is given
# (fake .cmd shims are written there and passed with -SearchPath; no PATH, environment or profile is touched).
# Run: powershell -NoProfile -File structuredquestions_windows.ps1 -Dir <empty temp folder> -Script <path to structuredquestions.ps1>
# Needs Windows PowerShell 5.1 or PowerShell 7. Prints one JSON line and VERDICT PASS or VERDICT FAIL.
param([Parameter(Mandatory=$true)][string]$Dir, [Parameter(Mandatory=$true)][string]$Script, [int]$Timeout = 3)
$ErrorActionPreference = 'Stop'
$marker = 'ping -n 4321 127.0.0.1'
function Shim($name, $lines) { Set-Content -LiteralPath (Join-Path $Dir $name) -Value (@('@echo off') + $lines) -Encoding ASCII }
Shim 'claude.cmd' @($marker + ' >nul')   # cmd.exe waits for a hanging child CLI
Shim 'codex.cmd' @('echo usage: codex [--dangerously-bypass-approvals-and-sandbox]')
Shim 'kimi.cmd' @('echo usage: kimi [--yolo-extra] [--auto-approve]')                       # look-alike flags only
Shim 'grok.cmd' @('echo   --approval-mode MODE', 'echo   MODEL   pick a model (always-ask^|yolo)', 'echo   --permission-mode MODE', 'echo   MODEL   bypassPermissions')   # sibling entries, not continuations
Shim 'omp.cmd' @('echo   --approval-mode=^<value^>   Override (always-ask^|always-ask-cached^|write^|yolo)')   # real omp layout
Shim 'muse.cmd' @('echo   --yolo   run without prompts')
$sw = [Diagnostics.Stopwatch]::StartNew()
$info = New-Object System.Diagnostics.ProcessStartInfo
$info.FileName = (Get-Process -Id $PID).Path
$info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '" -SearchPath "' + $Dir + '" -Cwd "' + $Dir + '" -TimeoutSeconds ' + $Timeout
$info.UseShellExecute = $false; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
$info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
$child = [System.Diagnostics.Process]::Start($info)
$errTask = $child.StandardError.ReadToEndAsync()
$outTask = $child.StandardOutput.ReadToEndAsync()
if (-not $child.WaitForExit(60000)) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
$sw.Stop()
$raw = $null
if ($outTask.Wait(5000)) { $raw = $outTask.Result }   # an orphan that inherited the pipe keeps it open forever
$data = $null
if ($raw) { $data = $raw | ConvertFrom-Json }
$dot = [string][char]0x00B7
$left = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and ($_.CommandLine -like '*4321*' -or $_.CommandLine -like ('*' + (Split-Path -Leaf $Dir) + '*claude.cmd*')) -and $_.ProcessId -ne $PID })
$leftCount = $left.Count
$left | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }   # tidy only what this test started
$asked = @($data.prompts | ForEach-Object { $_.questions } | Where-Object { $_.question -like '*which permission mode?*' } | ForEach-Object { $_.when.provider })
$accounts = @($data.derived.accounts | ForEach-Object { $_.provider })
if ($null -eq $data) { ('{"json_parsed":false,"why":"stdout never closed: a process the script started still holds its pipe","survivors_after_timeout":' + $leftCount + '}'); 'VERDICT FAIL'; exit 1 }
$result = [ordered]@{
  host = $PSVersionTable.PSVersion.ToString(); seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
  json_parsed = ($null -ne $data); utf8_intro = ($data.intro[0] -like ('*' + $dot + '*'));
  hung_provider_unavailable = (@($data.intro) -contains "Unavailable: Claude (its --help did not finish within $Timeout seconds).") -and ($accounts -notcontains 'Claude')
  survivors_after_timeout = $leftCount
  codex_found = ($accounts -contains 'Codex'); lookalike_not_offered = ($asked -notcontains 'Kimi')
  sibling_entry_not_offered = ($asked -notcontains 'Grok'); omp_listed_value_offered = ($asked -contains 'OMP'); muse_offered = ($asked -contains 'Muse')
}
$result | ConvertTo-Json -Compress
if (-not ($result.json_parsed -and $result.utf8_intro -and $result.hung_provider_unavailable -and $result.survivors_after_timeout -eq 0 -and $result.codex_found -and $result.lookalike_not_offered -and $result.sibling_entry_not_offered -and $result.omp_listed_value_offered -and $result.muse_offered)) { 'VERDICT FAIL'; exit 1 }
'VERDICT PASS'
