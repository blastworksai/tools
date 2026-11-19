# SPAWN Guided setup: the exact structured-question script, Windows twin of structuredquestions.sh (SKILLS-210,
# redesigned for the common case in SKILLS-213). Read-only. Windows runs agents as the signed-in user only
# (cross-user workers are unsupported), so every install is one of the operator's own. Same two phases, same JSON,
# same wording, same limits (at most 4 questions per prompt, at most 4 options per question), and the same answer
# arguments as the POSIX script, so the helper builds one argv on every OS. Run with PowerShell, never cmd.exe:
#   structuredquestions.ps1 [-GlitchRoot <path>] [-Cwd <path>]                                         phase 1
#   structuredquestions.ps1 [-GlitchRoot <path>] [-Cwd <path>] --phase 2 [--accounts <cli>=<label>,<label>]...
#                           [--map <id>=<key|path>]... [--skip <id>]...                               phase 2
#   structuredquestions.ps1 --check-args <cli> <word>...                                               Custom check
# --glitch-root and --cwd are accepted too. -SearchPath and -TimeoutSeconds exist for tests: the first limits each
# CLI's lookup to those folders, the second sets the per-call bound without touching the environment.
[CmdletBinding(PositionalBinding = $false)]
param([string[]]$GlitchRoot = @(), [string]$Cwd = (Get-Location).Path, [string[]]$SearchPath = @(), [int]$TimeoutSeconds = 0,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @())
$ErrorActionPreference = 'Stop'
function Write-Json($value) {
  # UTF-8 bytes straight to stdout: Windows PowerShell 5.1 would otherwise encode the dash and dot in the console's
  # OEM code page, and the helper reads UTF-8.
  $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(($value | ConvertTo-Json -Depth 12 -Compress) + "`n")
  $stdout = [Console]::OpenStandardOutput(); $stdout.Write($bytes, 0, $bytes.Length); $stdout.Flush()
}
function Refuse([string]$Why) { Write-Json ([ordered]@{ ok = $false; why = $Why }); exit 3 }
$Rest = @($Rest | Where-Object { $null -ne $_ })
# -File passes one string per parameter: test folders may be joined with ';'.
$SearchPath = @($SearchPath | ForEach-Object { $_ -split ';' } | Where-Object { $_ })

# One Custom permission answer: the words the helper split from the typed text, checked as argv data. The words are
# stored as a list and never pass through a shell, so the check refuses only what could be mistaken for shell text.
if ($Rest.Count -gt 0 -and $Rest[0] -eq '--check-args') {
  $bad = [ordered]@{ "'" = "a single quote (')"; '"' = 'a double quote (")'; '\' = 'a backslash (\)'; '`' = 'a backtick (`)'; '$' = 'a dollar sign ($)'
    ';' = 'a semicolon (;)'; '&' = 'an ampersand (&)'; '|' = 'a vertical bar (|)'; '<' = 'a less-than sign (<)'; '>' = 'a greater-than sign (>)'
    '(' = 'a parenthesis (()'; ')' = 'a parenthesis ())'; '{' = 'a brace ({)'; '}' = 'a brace (})'; '*' = 'an asterisk (*)'; '?' = 'a question mark (?)'
    '!' = 'an exclamation mark (!)'; '#' = 'a hash sign (#)'; '~' = 'a tilde (~)' }
  if ($Rest.Count -lt 2 -or $Rest[1] -cnotmatch '^(claude|codex|kimi|grok|agy|muse|omp)$') { Refuse 'SPAWN knows no such CLI.' }
  $words = @($Rest | Select-Object -Skip 2)
  if ($words.Count -lt 1) { Refuse 'Type at least one argument.' }
  if ($words.Count -gt 256) { Refuse 'At most 256 arguments.' }
  foreach ($w in $words) {
    if ($w -eq '') { Refuse 'An argument is empty.' }
    if ($w.Length -gt 4096) { Refuse 'An argument is longer than 4096 characters.' }
    if ($w.StartsWith('=')) { Refuse 'An argument cannot start with =.' }
    foreach ($c in $w.ToCharArray()) {
      if ([int]$c -lt 32 -or [int]$c -eq 127) { Refuse 'Arguments cannot contain control characters, such as a tab or a line break.' }
      if ($bad.Contains([string]$c)) { Refuse ('Arguments cannot contain ' + $bad[[string]$c] + '.') }
    }
  }
  Write-Json ([ordered]@{ ok = $true; arguments = $words }); exit 0
}

$phase = 1; $answers = @(); $maps = @(); $skips = @(); $rerun = @('--phase', '2')
for ($i = 0; $i -lt $Rest.Count; $i += 2) {
  if ($i + 1 -ge $Rest.Count) { [Console]::Error.WriteLine('usage: structuredquestions.ps1 [--phase 1|2] [--accounts <cli>=<labels>]... [--map <id>=<key|path>]... [--skip <id>]...'); exit 2 }
  $name = $Rest[$i]; $value = $Rest[$i + 1]
  switch -CaseSensitive ($name) {
    '--phase' { if ($value -notin @('1', '2')) { exit 2 }; $phase = [int]$value }
    '--accounts' { $phase = 2; $answers += , $value; $rerun += @($name, $value) }
    '--map' { $phase = 2; $maps += , $value; $rerun += @($name, $value) }
    '--skip' { $phase = 2; $skips += , $value; $rerun += @($name, $value) }
    '--glitch-root' { $GlitchRoot += , $value }
    '--cwd' { $Cwd = $value }
    default { [Console]::Error.WriteLine('usage: structuredquestions.ps1 [--phase 1|2] [--accounts <cli>=<labels>]... [--map <id>=<key|path>]... [--skip <id>]...'); exit 2 }
  }
}

# Every external call is bounded (SPAWN_QUESTIONS_TIMEOUT seconds, default 20): WaitForExit(ms), then Kill.
$timeoutMs = 20000
if ($TimeoutSeconds -gt 0) { $timeoutMs = $TimeoutSeconds * 1000 }
elseif ($env:SPAWN_QUESTIONS_TIMEOUT -match '^\d+$') { $timeoutMs = [int]$env:SPAWN_QUESTIONS_TIMEOUT * 1000 }
# How to start a discovered program. .cmd/.bat shims (npm installs them) go through cmd.exe /d /c with the path in
# one pair of quotes, and a path cmd.exe would still interpret inside quotes (quote, %, !, line break) is refused.
# .exe/.com start directly. A .ps1 install runs the way SPAWN launches it (PowerShell -File, backend.luau), and a
# path with a quote or a line break is refused. Pure function of the path, so it can be tested from source.
$script:CmdShim = '(?i)\.(cmd|bat)$'
$script:DirectExe = '(?i)\.(exe|com)$'
$script:PsScript = '(?i)\.ps1$'
$script:UnsafeForCmd = '["%!\r\n]'
$script:UnsafeForPs = '["\r\n]'
function Get-LaunchPlan([string]$Path) {
  if ($Path -match $script:CmdShim) {
    if ($Path -match $script:UnsafeForCmd) { return @{ ok = $false; reason = 'its path has characters cmd.exe would interpret' } }
    $shell = $env:ComSpec; if ([string]::IsNullOrWhiteSpace($shell)) { $shell = 'cmd.exe' }
    return @{ ok = $true; file = $shell; arguments = ('/d /c ""' + $Path + '" --help"') }
  }
  if ($Path -match $script:DirectExe) { return @{ ok = $true; file = $Path; arguments = '--help' } }
  if ($Path -match $script:PsScript) {
    if ($Path -match $script:UnsafeForPs) { return @{ ok = $false; reason = 'its path has a quote or a line break' } }
    $engine = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
    return @{ ok = $true; file = [IO.Path]::Combine($PSHOME, $engine); arguments = ('-NoLogo -NoProfile -File "' + $Path + '" --help') }
  }
  return @{ ok = $false; reason = 'it is not a program Windows can start directly' }
}
# A flag counts only as its own token (--yolo-extra is not --yolo); a valued flag also needs its value in that
# flag's own entry (its line plus indented continuation lines).
$script:TokenBefore = '(?<![A-Za-z0-9_-])'
$script:TokenAfter = '(?![A-Za-z0-9_-])'
function Test-Token([string]$Text, [string]$Token) {
  return [regex]::IsMatch($Text, $script:TokenBefore + [regex]::Escape($Token) + $script:TokenAfter)
}
function Get-Indent([string]$Line) { return $Line.Length - $Line.TrimStart().Length }
function Test-HelpFlag([string]$Help, [string]$Flag, [string]$Value) {
  $entry = $null; $indent = 0
  foreach ($line in ($Help -split "\r?\n")) {
    # A continuation is indented deeper than the entry holding the flag; a sibling entry, a positional or
    # environment name at the same or a shallower indent, or a line starting with a dash ends the entry.
    if ($null -ne $entry -and $line -match '^\s+[^\s-]' -and (Get-Indent $line) -gt $indent) { $entry += ' ' + $line; continue }
    if ($null -ne $entry -and ($Value -eq '' -or (Test-Token $entry $Value))) { return $true }
    $entry = $null
    if (Test-Token $line $Flag) { $entry = $line; $indent = Get-Indent $line }
  }
  return ($null -ne $entry -and ($Value -eq '' -or (Test-Token $entry $Value)))
}
# Ends a launched program AND everything it started (a .cmd shim's cmd.exe leaves its child CLI running when only
# it is killed). Works on Windows PowerShell 5.1 and PowerShell 7 alike: the descendants are found through
# Win32_Process parent links (valid while the parent is gone too, as long as the child started after the parent),
# then stopped deepest first, then the root. Process.Kill($true) is .NET Core only, so it is not relied on.
function Stop-ProcessTree([int]$RootId, [datetime]$Since) {
  try {
    $table = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Select-Object ProcessId, ParentProcessId, CreationDate)
    $order = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue; $queue.Enqueue($RootId)
    while ($queue.Count -gt 0) {
      $parentId = $queue.Dequeue()
      foreach ($row in $table) {
        if ($row.ParentProcessId -eq $parentId -and $row.ProcessId -ne $RootId -and $row.CreationDate -ge $Since.AddSeconds(-2) -and -not $order.Contains([int]$row.ProcessId)) { [void]$order.Add([int]$row.ProcessId); $queue.Enqueue([int]$row.ProcessId) }
      }
    }
    for ($i = $order.Count - 1; $i -ge 0; $i--) { Stop-Process -Id $order[$i] -Force -ErrorAction SilentlyContinue }
  } catch { }
  Stop-Process -Id $RootId -Force -ErrorAction SilentlyContinue
}
function Invoke-Bounded([string]$File, [string]$Arguments) {
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = $File; $info.Arguments = $Arguments; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
  $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
  $process = [System.Diagnostics.Process]::Start($info)
  $id = $process.Id
  try { $since = $process.StartTime } catch { $since = (Get-Date).AddSeconds(-5) }
  $text = $null
  try {
    $process.StandardInput.Close()
    $out = $process.StandardOutput.ReadToEndAsync(); $err = $process.StandardError.ReadToEndAsync()
    if ($process.WaitForExit($timeoutMs) -and $out.Wait(2000) -and $err.Wait(2000)) { $text = $out.Result + $err.Result }
  } finally {
    # On time-out, on an output drain that never ends and after a normal exit alike: nothing it started stays.
    Stop-ProcessTree $id $since
    $process.Dispose()
  }
  return $text
}
# The service named in an OMP install's own config (modelRoles.default is "<service>/<model>"); any service is kept.
function Get-OmpFamily([string]$ConfigPath) {
  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return '' }
  $inRoles = $false
  foreach ($line in (Get-Content -LiteralPath $ConfigPath -TotalCount 400)) {
    if ($line -match '^modelRoles:') { $inRoles = $true; continue }
    if ($inRoles -and $line -match '^\S') { $inRoles = $false }
    if ($inRoles -and $line -match '^\s+default:\s*["'']?([a-z0-9._-]+)/') { return $Matches[1] }
  }
  return ''
}
$operator = [Environment]::UserName
$userHome = $env:USERPROFILE
$clis = @('claude', 'codex', 'kimi', 'grok', 'agy', 'muse', 'omp')
$pname = @{ claude = 'Claude'; codex = 'Codex'; kimi = 'Kimi'; grok = 'Grok'; agy = 'Agy'; muse = 'Muse'; omp = 'OMP' }
$pfam = @{ claude = 'anthropic'; codex = 'openai'; kimi = 'moonshot'; grok = 'xai'; agy = 'google'; muse = 'meta'; omp = '' }
# The YOLO choice per provider: the flag its installed --help must show, its value (or empty), argv, consequence.
$yolo = @{
  claude = @('--dangerously-skip-permissions', '', '--dangerously-skip-permissions', 'Claude acts without asking first.')
  agy = @('--dangerously-skip-permissions', '', '--dangerously-skip-permissions', 'Agy acts without asking first.')
  codex = @('--dangerously-bypass-approvals-and-sandbox', '', '--dangerously-bypass-approvals-and-sandbox', 'Codex runs with no approvals and no sandbox.')
  kimi = @('--auto', '', '--auto', 'Kimi never asks for approval.')
  grok = @('--permission-mode', 'bypassPermissions', '--permission-mode bypassPermissions', 'Grok skips its permission checks.')
  muse = @('--yolo', '', '--yolo', 'Muse runs without approval prompts.')
  omp = @('--approval-mode', 'yolo', '--approval-mode yolo', 'OMP runs tools without approval.')
}
$dash = [string][char]0x2014
function Opt($label, $desc, $pre, $extra) {
  $o = [ordered]@{ label = $label; description = $desc; preselected = [bool]$pre }
  if ($extra) { foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] } }
  $o
}
function Ask($id, $q, $header, $multi, $opts, $extra) {
  $item = [ordered]@{ id = $id; question = $q; header = $header; multiSelect = [bool]$multi; options = @($opts) }
  if ($extra) { foreach ($k in $extra.Keys) { $item[$k] = $extra[$k] } }
  $item
}
function When($qid, $label) { [ordered]@{ question = $qid; is = $label } }
$script:prompts = @()
# Prompts of at most 4 questions: a section longer than that continues in the next prompt. Lines are printed
# verbatim before the prompt (only before its first part).
function Section($id, $title, $qs, $lines, $note) {
  $qs = @($qs); if ($qs.Count -eq 0) { return }
  $total = [int][Math]::Ceiling($qs.Count / 4)
  for ($k = 1; $k -le $total; $k++) {
    $chunk = @($qs[(($k - 1) * 4)..([Math]::Min($qs.Count, $k * 4) - 1)])
    $p = [ordered]@{ id = $(if ($total -eq 1) { $id } else { "$id-$k" }); title = $(if ($total -eq 1) { $title } else { "$title ($k of $total)" }) }
    if ($k -eq 1 -and @($lines).Count -gt 0) { $p['lines'] = @($lines) }
    if ($note) { $p['show_first'] = $note }
    $p['questions'] = $chunk
    $script:prompts += , $p
  }
}
# Options split evenly into questions of at most 4 (ids qid-1, qid-2; one question keeps qid).
function Chunked($qid, $text, $header, $multi, $opts, $extra) {
  $opts = @($opts); $chunks = [int][Math]::Ceiling($opts.Count / 4); $base = [int][Math]::Floor($opts.Count / $chunks); $more = $opts.Count % $chunks
  $pos = 0; $out = @(); $ids = @()
  for ($c = 1; $c -le $chunks; $c++) {
    $size = $base + $(if ($c -le $more) { 1 } else { 0 })
    $id = if ($chunks -gt 1) { "$qid-$c" } else { $qid }
    $out += , (Ask $id $(if ($chunks -gt 1) { "$text ($c of $chunks)" } else { $text }) $(if ($chunks -gt 1) { "$header $c" } else { $header }) $multi @($opts[$pos..($pos + $size - 1)]) $extra)
    $ids += $id; $pos += $size
  }
  return @{ questions = $out; ids = $ids }
}
function Cut([string]$s, [int]$m) { if ($s.Length -le $m) { $s } else { $s.Substring(0, $m) } }
function Get-Reduced([string]$s) { $s.ToLowerInvariant() -creplace '[^a-z0-9]', '' }
function Get-Slug([string]$s) { (($s.ToLowerInvariant() -creplace '[^a-z0-9]+', '-') -creplace '^-+', '') -creplace '-+$', '' }
function Get-Display($cli, [string]$label) { if ($label.StartsWith($pname[$cli], [StringComparison]::OrdinalIgnoreCase)) { $label } else { $pname[$cli] + ' ' + $label } }
function Get-Ordinal([int]$n) { $w = @{ 2 = 'second'; 3 = 'third'; 4 = 'fourth'; 5 = 'fifth'; 6 = 'sixth'; 7 = 'seventh'; 8 = 'eighth'; 9 = 'ninth' }[$n]; if ($w) { $w } else { "$($n)th" } }
function Test-Printable([string]$s) { foreach ($c in $s.ToCharArray()) { if ([int]$c -lt 32 -or [int]$c -eq 127) { return $false } }; return $true }

# Every install of each CLI the operator can start, in PATH order: .exe, .com, .cmd, .bat and .ps1 named exactly the
# CLI. One that cannot be started safely is said plainly and is not a candidate.
$cands = @(); $unavailable = @(); $found = @{}
foreach ($cli in $clis) {
  $paths = @()
  if ($SearchPath.Count -gt 0) {
    foreach ($dir in $SearchPath) { foreach ($ext in '.exe', '.com', '.cmd', '.bat', '.ps1') { $candidate = Join-Path $dir ($cli + $ext); if (Test-Path -LiteralPath $candidate -PathType Leaf) { $paths += $candidate } } }
  } else { $paths = @(Get-Command -All -Name $cli -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | ForEach-Object { $_.Source }) }
  $seen = @{}; $n = 0
  foreach ($path in $paths) {
    if (-not $path -or $seen.ContainsKey($path.ToLowerInvariant())) { continue }
    if ([IO.Path]::GetFileNameWithoutExtension($path) -ne $cli -or [IO.Path]::GetExtension($path) -notmatch '(?i)^\.(exe|com|cmd|bat|ps1)$') { continue }
    $seen[$path.ToLowerInvariant()] = $true
    $plan = Get-LaunchPlan $path
    if (-not $plan.ok) { $unavailable += "Unavailable: $path ($($plan.reason))."; continue }
    $n++; $found[$cli] = $true
    $cands += , [ordered]@{ cli = $cli; key = "$operator#$n"; n = $n; path = $path; plan = $plan; used_by = '' }
  }
}
$glitch = @()
$roots = @($GlitchRoot) + @("$userHome\Glitch")
$walk = $Cwd
for ($i = 0; $i -lt 32 -and $walk; $i++) { $roots += $walk; $next = Split-Path -Parent $walk; if (-not $next -or $next -eq $walk) { break }; $walk = $next }
foreach ($root in $roots) {
  if (-not $root) { continue }
  if ((Test-Path -LiteralPath "$root\.claude\scripts\workspaces.py" -PathType Leaf) -and (Test-Path -LiteralPath "$root\.claude\scripts\plan_check.py" -PathType Leaf) -and ($glitch -notcontains $root)) { $glitch += $root }
}
$providersOut = @($clis | ForEach-Object { [ordered]@{ name = $pname[$_]; cli = $_; found = [bool]$found[$_] } })
$limits = [ordered]@{ questions_per_prompt = 4; options_per_question = 4; header_characters = 12 }

# ---- phase 1: the intro and the accounts questions; nothing discovered about accounts is named ----
if ($phase -eq 1) {
  $have = @($clis | Where-Object { $found[$_] }); $missing = @($clis | Where-Object { -not $found[$_] } | ForEach-Object { $pname[$_] })
  $intro = @("Found on this machine: $(if ($have.Count) { ($have | ForEach-Object { $pname[$_] }) -join ', ' } else { 'nothing' }).")
  if ($missing.Count) { $intro += "Not found: $($missing -join ', ')." }
  if ($glitch.Count -eq 1) { $intro += "Glitch folder detected: $($glitch[0])." }
  elseif ($glitch.Count -gt 1) { $intro += "Glitch folders detected: $($glitch -join ', ')." }
  if ($glitch.Count -gt 3) { $intro += "More Glitch folders found, not listed as choices (pick Other and type one): $(($glitch | Select-Object -Skip 3) -join ', ')." }
  if ($glitch.Count -eq 0) { $intro += "Glitch folder: not found in $userHome\Glitch, the launch folder and its parents." }
  $intro += $unavailable
  $result = [ordered]@{ phase = 1; intro = @($intro); prompts = @() }
  if ($have.Count -gt 0) {
    Section 'accounts' 'Accounts' @((Ask 'multi' 'Are there any providers for which you have more than one account?' 'Accounts' $false @((Opt 'No' 'One account for each provider found.' $true $null), (Opt 'Yes' 'Say which providers, how many accounts and their labels.' $false $null)) $null)) @() $null
    if ($have.Count -ge 2) {
      $picked = Chunked 'providers' 'Which providers have more than one account?' 'Providers' $true @($have | ForEach-Object { Opt $pname[$_] "More than one $($pname[$_]) account." $false ([ordered]@{ value = $_ }) }) ([ordered]@{ when = (When 'multi' 'Yes') })
      Section 'providers' 'Providers' $picked.questions @() $null
      $each = [ordered]@{ questions = @($picked.ids) }
    } else { $each = [ordered]@{ items = @([ordered]@{ label = $pname[$have[0]]; value = $have[0] }) } }
    Section 'count' 'Number of accounts' @((Ask 'count' 'How many {provider} accounts?' '{provider}' $false @((Opt '2' 'Two {provider} accounts.' $true $null), (Opt '3' 'Three {provider} accounts.' $false $null), (Opt '4' 'Four {provider} accounts.' $false $null)) ([ordered]@{ when = (When 'multi' 'Yes'); for_each = $each; other = [ordered]@{ whole_number = @(2, 16) } }))) @() $null
    Section 'labels' 'Labels' @((Ask 'labels' 'Labels for your {N} {provider} accounts?' '{provider}' $false @((Opt 'Number them ({provider} 1, {provider} 2)' 'The labels are {provider} 1 to {provider} {N}.' $true ([ordered]@{ value = 'numbered' })), (Opt 'Type my own labels' 'Type {N} labels, separated by commas: at most 32 characters each.' $false ([ordered]@{ value = 'typed'; type = $true }))) ([ordered]@{ when = (When 'multi' 'Yes'); for_each = $each; for_each_count = [ordered]@{ question = 'count' } }))) @() $null
    $result.prompts = @($script:prompts)
    $result['next'] = [ordered]@{ argv = @('--phase', '2'); per_answer = [ordered]@{ question = 'labels'; argv = @('--accounts', '{cli}={labels}') }; numbered = '{provider} 1,{provider} 2,...,{provider} {N}' }
  }
  $result['derived'] = [ordered]@{ providers = $providersOut; glitch_folders = @($glitch) }
  $result['limits'] = $limits
  Write-Json $result; exit 0
}

# ---- phase 2: answers -> agents, then mapping, permissions, folder, OMP service, review ----
$labelsOf = [ordered]@{}
foreach ($v in $answers) {
  if (-not $v.Contains('=')) { Refuse 'An --accounts answer needs the form <cli>=<label>,<label>.' }
  $cli = $v.Substring(0, $v.IndexOf('=')); $lab = $v.Substring($v.IndexOf('=') + 1)
  if ($cli -cnotmatch '^(claude|codex|kimi|grok|agy|muse|omp)$') { Refuse 'SPAWN knows no CLI with that name.' }
  if (-not $found[$cli]) { Refuse "No $($pname[$cli]) was found on this machine, so it cannot have accounts." }
  if ($labelsOf.Contains($cli)) { Refuse "$($pname[$cli]) accounts were given twice." }
  $parts = @($lab -split ',', 0)
  if ($lab -eq '') { $parts = @() }
  if ($parts.Count -gt 16) { Refuse "At most 16 $($pname[$cli]) accounts." }
  if ($parts.Count -eq 0) { Refuse "A $($pname[$cli]) label is empty." }
  $seenLab = @{}; $list = @()
  foreach ($part in $parts) {
    $l = $part.Trim(' ')
    if ($l -eq '') { Refuse "A $($pname[$cli]) label is empty." }
    if (-not (Test-Printable $l)) { Refuse "A $($pname[$cli]) label has a control character, such as a tab or a line break." }
    if ($l.Length -gt 32) { Refuse "The $($pname[$cli]) label `"$l`" is longer than 32 characters." }
    if ($seenLab.ContainsKey($l.ToLowerInvariant())) { Refuse "Two $($pname[$cli]) accounts have the label `"$l`"." }
    $seenLab[$l.ToLowerInvariant()] = $true; $list += $l
  }
  $labelsOf[$cli] = $list
}
$agentsAll = @(); $usedId = @{}
foreach ($cli in $clis) {
  if (-not $found[$cli]) { continue }
  if ($labelsOf.Contains($cli)) {
    $k = 0
    foreach ($l in $labelsOf[$cli]) {
      $k++; $base = Get-Slug $l
      if ($base.StartsWith("$cli-")) { $base = $base.Substring($cli.Length + 1) } elseif ($base -eq $cli) { $base = '' }
      if ($base -eq '') { $base = "$k" }
      $id = "$cli-$base"; $sfx = 1
      while ($usedId.ContainsKey($id)) { $sfx++; $id = "$cli-$base-$sfx" }
      $usedId[$id] = $true
      $agentsAll += , [ordered]@{ id = $id; cli = $cli; label = $l; pos = $k; single = $false; cand = $null; typed = $null }
    }
  } else { $usedId[$cli] = $true; $agentsAll += , [ordered]@{ id = $cli; cli = $cli; label = $pname[$cli]; pos = 1; single = $true; cand = $null; typed = $null } }
}
$byId = @{}; foreach ($a in $agentsAll) { $byId[$a.id] = $a }
foreach ($s in $skips) { if (-not $byId.ContainsKey($s)) { Refuse "No agent has the ID `"$s`"." } }
function Take($a, $c) { $a.cand = $c; $c.used_by = $a.id }
# Overrides first: an install key, or a typed absolute path.
foreach ($v in $maps) {
  if (-not $v.Contains('=')) { Refuse 'A --map answer needs the form <id>=<install key or absolute path>.' }
  $id = $v.Substring(0, $v.IndexOf('=')); $pth = $v.Substring($v.IndexOf('=') + 1)
  if (-not $byId.ContainsKey($id)) { Refuse "No agent has the ID `"$id`"." }
  $a = $byId[$id]
  if ($skips -contains $id) { continue }
  if ($pth -match '^([A-Za-z]:[\\/]|\\\\)') {
    if (-not (Test-Printable $pth)) { Refuse 'A typed path has a control character.' }
    $hit = $cands | Where-Object { $_.cli -eq $a.cli -and $_.path -eq $pth } | Select-Object -First 1
    if ($hit -and $hit.used_by) { Refuse "Two agents cannot use the same install: $($hit.key)." }
    if ($hit) { Take $a $hit } else { $a.typed = $pth }
  } else {
    $hit = $cands | Where-Object { $_.cli -eq $a.cli -and $_.key -eq $pth } | Select-Object -First 1
    if (-not $hit) { Refuse "`"$pth`" is not a $($pname[$a.cli]) install found on this machine." }
    if ($hit.used_by) { Refuse "Two agents cannot use the same install: $pth." }
    Take $a $hit
  }
}
foreach ($cli in $clis) {
  $mine = @($cands | Where-Object { $_.cli -eq $cli })
  # Pass 1: a label that names the folder holding an install. Pass 2: the rest in PATH order.
  foreach ($a in @($agentsAll | Where-Object { $_.cli -eq $cli -and -not $_.single -and -not $_.cand -and -not $_.typed -and $skips -notcontains $_.id })) {
    $r = Get-Reduced $a.label; if ($r -eq '') { continue }
    foreach ($c in $mine) { if (-not $c.used_by -and (Get-Reduced (Split-Path -Leaf (Split-Path -Parent $c.path))) -eq $r) { Take $a $c; break } }
  }
  foreach ($a in @($agentsAll | Where-Object { $_.cli -eq $cli -and -not $_.cand -and -not $_.typed -and $skips -notcontains $_.id })) {
    foreach ($c in $mine) { if (-not $c.used_by) { Take $a $c; break } }
  }
}
$runs = @{}
foreach ($a in @($agentsAll | Where-Object { ($_.cand -or $_.typed) -and $skips -notcontains $_.id })) {
  $pth = if ($a.typed) { $a.typed } else { $a.cand.path }
  if ($runs.ContainsKey($pth.ToLowerInvariant())) { Refuse "$($runs[$pth.ToLowerInvariant()]) and $($a.id) would run the same install as the same account, so they would share one login." }
  $runs[$pth.ToLowerInvariant()] = $a.id
}
$agents = @(); $missingAg = @()
foreach ($a in $agentsAll) {
  if ($skips -contains $a.id) { continue }
  if ($a.typed) {
    $plan = Get-LaunchPlan $a.typed
    if (-not (Test-Path -LiteralPath $a.typed -PathType Leaf) -or -not $plan.ok) { Refuse "$operator cannot run $($a.typed), so it cannot be $($a.id)." }
    $a['path'] = $a.typed; $a['key'] = ''; $a['plan'] = $plan; $a['n'] = 0
  } elseif ($a.cand) { $a['path'] = $a.cand.path; $a['key'] = $a.cand.key; $a['plan'] = $a.cand.plan; $a['n'] = $a.cand.n }
  else { $missingAg += , $a; continue }
  try { $help = Invoke-Bounded $a.plan.file $a.plan.arguments } catch { $help = $null }
  $y = $yolo[$a.cli]
  $a['sup'] = ($null -ne $help) -and (Test-HelpFlag $help $y[0] $y[1])
  $a['family'] = if ($a.cli -eq 'omp') { Get-OmpFamily (Join-Path $userHome '.omp\agent\config.yml') } else { $pfam[$a.cli] }
  $a['display'] = Get-Display $a.cli $a.label
  $a['row'] = "$($a.display) $dash $operator (you) $dash $($a.path)"
  $agents += , $a
}
# Mapping. Every agent runs as the operator, so the question is the one-OS-user confirm; the table is shown when it
# carries news: a second install in use, a typed path, or an account left without one.
$show = ($missingAg.Count -gt 0) -or [bool]($agents | Where-Object { $_.typed -or $_.n -gt 1 })
$lines = @()
if ($show) {
  foreach ($a in $agents) { $lines += $a.row }
  foreach ($cli in $clis) {
    if (-not ($agentsAll | Where-Object { $_.cli -eq $cli -and $skips -notcontains $_.id })) { continue }
    $unused = @($cands | Where-Object { $_.cli -eq $cli -and -not $_.used_by })
    if ($unused.Count -eq 0) { continue }
    $text = (@($unused | Select-Object -First 3) | ForEach-Object { "$operator (you) $dash $($_.path)" }) -join ', '
    if ($unused.Count -gt 3) { $text += ", and $($unused.Count - 3) more" }
    $lines += "Not used for $($pname[$cli]): $text."
  }
}
$agyWarn = $false
foreach ($m in $missingAg) {
  $d = Get-Display $m.cli $m.label
  $lines += "$($d): no $(if ($m.pos -gt 1) { (Get-Ordinal $m.pos) + ' ' })install or OS user found. Each $($pname[$m.cli]) account needs its own install with its own login. Type its path, or skip it."
  if ($m.cli -eq 'agy') { $agyWarn = $true }
}
if (@($agents | Where-Object { $_.cli -eq 'agy' }).Count -gt 1 -or ($agents | Where-Object { $_.cli -eq 'agy' -and $_.typed })) { $agyWarn = $true }
if ($agyWarn) { $lines += "Agy keeps its login per OS user; a second install may share the first one's login." }
$qs = @()
if ($agents.Count -gt 0) { $qs += , (Ask 'mapping' "All agents run as $($operator)?" 'Accounts' $false @((Opt 'Yes (Recommended)' "Every agent runs as $operator." $true $null), (Opt 'Change some' 'Pick another install, type a path or skip an agent.' $false $null)) $null) }
foreach ($m in $missingAg) {
  $d = Get-Display $m.cli $m.label
  $qs += , (Ask "missing-$($m.id)" "$($d): type its path, or skip it?" (Cut $d 12) $false @((Opt 'Skip it (Recommended)' "Save no agent for $d." $true $null), (Opt 'Type its path' "Type the absolute path of the $($pname[$m.cli]) install that has this account's login." $false ([ordered]@{ type = $true }))) ([ordered]@{ agent_id = $m.id }))
}
Section 'mapping' 'Accounts' $qs $lines $null
if ($agents.Count -gt 0) {
  Section 'permissions' 'Permissions' @((Ask 'perm-gate' 'Do you want to set special permission modes to start some of these agents with?' 'Permissions' $false @((Opt 'No, all Default (Recommended)' 'Every agent starts with no extra arguments.' $true $null), (Opt 'Yes' 'Choose Default, YOLO or Custom for each agent.' $false $null)) $null)) @() $null
  $qs = @(); $lines = @()
  foreach ($a in $agents) {
    $y = $yolo[$a.cli]
    $ol = @(Opt 'Default (no arguments)' "$($pname[$a.cli]) starts with no extra arguments." $true $null)
    if ($a.sup) { $ol += , (Opt "YOLO ($($y[2]))" $y[3] $false $null) }
    else { $lines += "YOLO is not offered for $($a.display): its --help does not show $($y[0])$(if ($y[1]) { ' ' + $y[1] })." }
    $ol += , (Opt 'Custom (type the arguments)' 'Type the arguments; SPAWN checks them before they are saved.' $false ([ordered]@{ type = $true }))
    $qs += , (Ask "perm-$($a.id)" "$($a.display): which permission mode?" (Cut $a.display 12) $false $ol ([ordered]@{ when = (When 'perm-gate' 'Yes'); agent_id = $a.id }))
  }
  Section 'permission-modes' 'Permission modes' $qs $lines $null
  # Folder: only when Glitch was found; every agent not started in Glitch starts in its own home folder.
  if ($glitch.Count -gt 0) {
    $qs = @()
    if ($glitch.Count -gt 1) {
      $qs += , (Ask 'glitch-root' 'Which Glitch folder?' 'Glitch' $false @($glitch | Select-Object -First 3 | ForEach-Object { Opt $_ "The Glitch installation at $_." $false ([ordered]@{ value = $_ }) }) $null)
      $qt = 'Would you like to start all these agents within Glitch?'
    } else { $qt = "I detected Glitch at $($glitch[0]). Would you like to start all these agents within Glitch?" }
    $fo = @(Opt 'All (Recommended)' 'Every agent starts in Glitch.' $true $null)
    if ($agents.Count -gt 1) { $fo += , (Opt 'Choose per agent' 'Pick the agents that start in Glitch; the rest start in their own home folder.' $false $null) }
    $fo += , (Opt 'None' 'Every agent starts in its own home folder.' $false $null)
    $qs += , (Ask 'folder' $qt 'Folder' $false $fo $null)
    $more = @(); if ($glitch.Count -gt 3) { $more = @("More Glitch folders found, not listed as choices (pick Other and type one): $(($glitch | Select-Object -Skip 3) -join ', ').") }
    Section 'folder' 'Folder' $qs $more $null
    if ($agents.Count -gt 1) {
      $picked = Chunked 'folder-agents' 'Which agents start in Glitch?' 'Glitch' $true @($agents | ForEach-Object { Opt $_.display 'Starts in Glitch.' $false ([ordered]@{ value = $_.id }) }) ([ordered]@{ when = (When 'folder' 'Choose per agent') })
      Section 'folder-agents' 'Agents in Glitch' $picked.questions @() $null
    }
  }
  # The OMP service per OMP agent. No startup-prompt or model question exists.
  $qs = @()
  foreach ($a in @($agents | Where-Object { $_.cli -eq 'omp' })) {
    $oo = @(); $alt = @('openai', 'google', 'anthropic' | Where-Object { $_ -ne $a.family })
    if ($a.family) { $oo += , (Opt "$($a.family) (from its config) (Recommended)" "The service named in this agent's own OMP configuration." $true $null); $alt = @($alt | Select-Object -First 2) }
    foreach ($s in $alt) { $oo += , (Opt $s "Run this agent's OMP model through $s." $false $null) }
    $qs += , (Ask "omp-$($a.id)" "Which service runs $($a.id)'s model?" 'OMP service' $false $oo ([ordered]@{ agent_id = $a.id }))
  }
  Section 'omp' 'OMP service' $qs @() $null
  Section 'review' 'Review' @((Ask 'review' 'Save these {N} agents?' 'Save' $false @((Opt 'Save and set up (Recommended)' 'Save the roster and let SPAWN prepare it.' $true $null), (Opt 'Change something' 'Go back and change a choice.' $false $null)) $null)) @() 'derived.review table for the agents; {N} is their count'
}
$perms = [ordered]@{}
foreach ($a in $agents) {
  $y = $yolo[$a.cli]; $list = @([ordered]@{ label = 'Default (no arguments)'; arguments = @() })
  if ($a.sup) { $list += , [ordered]@{ label = "YOLO ($($y[2]))"; arguments = @($y[2] -split ' ') } }
  $perms[$a.id] = $list
}
$result = [ordered]@{
  phase = 2; intro = @(); prompts = @($script:prompts)
  derived = [ordered]@{
    operator = $operator; launch_folder = $Cwd; providers = $providersOut
    accounts = @($agents | ForEach-Object { [ordered]@{ id = $_.id; provider = $pname[$_.cli]; provider_family = $_.family; account_label = $_.label; display = $_.display; account = $operator; operator = $true; command = $_.path; home = $userHome; install = $_.key; row = $_.row } })
    missing = @($missingAg | ForEach-Object { [ordered]@{ id = $_.id; provider = $pname[$_.cli]; account_label = $_.label; display = (Get-Display $_.cli $_.label) } })
    candidates = @($cands | ForEach-Object { [ordered]@{ key = $_.key; provider = $pname[$_.cli]; account = $operator; operator = $true; command = $_.path; option = "$operator (you) $dash $($_.path)"; used_by = $_.used_by } })
    permissions = $perms
    custom_arguments = [ordered]@{ label = 'Custom (type the arguments)'; check = @('--check-args', '{cli}', '{words}') }
    glitch_folders = @($glitch)
    rerun = [ordered]@{ argv = @($rerun); map = @('--map', '{id}={install key or absolute path}'); skip = @('--skip', '{id}') }
    omp_prompt = 'Follow the explicitly assigned task. Role text is guidance, not identity isolation.'
    review = [ordered]@{ columns = @('ID', 'account', 'CLI', 'permission flags', 'folder', 'paid check'); paid_check_native = 'one harmless paid model message'; paid_check_terminal = 'offline checks only' }
  }
  limits = $limits
}
Write-Json $result
