# SPAWN Guided setup: the exact structured-question script, Windows twin of structuredquestions.sh (SKILLS-210).
# Read-only. Windows runs agents as the signed-in user only (cross-user workers are unsupported), so the
# only account row is the operator's own. Same JSON, same titles and options, same limits (at most 4
# questions per prompt, at most 4 options per question). Run with PowerShell, never cmd.exe:
#   structuredquestions.ps1 [-GlitchRoot <path>[,<path>]] [-Cwd <path>]
param([string[]]$GlitchRoot = @(), [string]$Cwd = (Get-Location).Path)
$ErrorActionPreference = 'Stop'
# Every external call is bounded (SPAWN_QUESTIONS_TIMEOUT seconds, default 20): WaitForExit(ms), then Kill.
$timeoutMs = 20000
if ($env:SPAWN_QUESTIONS_TIMEOUT -match '^\d+$') { $timeoutMs = [int]$env:SPAWN_QUESTIONS_TIMEOUT * 1000 }
# How to start a discovered program. Get-Command -CommandType Application also returns .cmd/.bat shims (npm
# installs them), which Process.Start with UseShellExecute=$false cannot run: they go through cmd.exe /d /c with
# the path in one pair of quotes, and a path cmd.exe would still interpret inside quotes (quote, %, !, line
# break) is refused. Only .exe/.com start directly. Pure function of the path, so it can be tested from source.
$script:CmdShim = '(?i)\.(cmd|bat)$'
$script:DirectExe = '(?i)\.(exe|com)$'
$script:UnsafeForCmd = '["%!\r\n]'
function Get-LaunchPlan([string]$Path) {
  if ($Path -match $script:CmdShim) {
    if ($Path -match $script:UnsafeForCmd) { return @{ ok = $false; reason = 'its path has characters cmd.exe would interpret' } }
    $shell = $env:ComSpec; if ([string]::IsNullOrWhiteSpace($shell)) { $shell = 'cmd.exe' }
    return @{ ok = $true; file = $shell; arguments = ('/d /c ""' + $Path + '" --help"') }
  }
  if ($Path -match $script:DirectExe) { return @{ ok = $true; file = $Path; arguments = '--help' } }
  return @{ ok = $false; reason = 'it is not a program Windows can start directly' }
}
# A flag counts only as its own token (--yolo-extra is not --yolo); a valued flag also needs its value in that
# flag's own entry (its line plus indented continuation lines).
$script:TokenBefore = '(?<![A-Za-z0-9_-])'
$script:TokenAfter = '(?![A-Za-z0-9_-])'
function Test-Token([string]$Text, [string]$Token) {
  return [regex]::IsMatch($Text, $script:TokenBefore + [regex]::Escape($Token) + $script:TokenAfter)
}
function Test-HelpFlag([string]$Help, [string]$Flag, [string]$Value) {
  $entry = $null
  foreach ($line in ($Help -split "\r?\n")) {
    if ($null -ne $entry -and $line -match '^\s+[^\s-]') { $entry += ' ' + $line; continue }
    if ($null -ne $entry -and ($Value -eq '' -or (Test-Token $entry $Value))) { return $true }
    $entry = $null
    if (Test-Token $line $Flag) { $entry = $line }
  }
  return ($null -ne $entry -and ($Value -eq '' -or (Test-Token $entry $Value)))
}
function Invoke-Bounded([string]$File, [string]$Arguments) {
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = $File; $info.Arguments = $Arguments; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
  $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
  $process = [System.Diagnostics.Process]::Start($info)
  try {
    $process.StandardInput.Close()
    $out = $process.StandardOutput.ReadToEndAsync(); $err = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($timeoutMs)) { try { $process.Kill() } catch { }; [void]$process.WaitForExit(2000); return $null }
    if (-not $out.Wait(2000) -or -not $err.Wait(2000)) { return $null }
    return ($out.Result + $err.Result)
  } finally { $process.Dispose() }
}
# The service named in an OMP account's own config (modelRoles.default is "<service>/<model>"); any service is kept.
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
$providers = @(
  @{ cli = 'claude'; name = 'Claude'; family = 'anthropic' }, @{ cli = 'codex'; name = 'Codex'; family = 'openai' },
  @{ cli = 'kimi'; name = 'Kimi'; family = 'moonshot' }, @{ cli = 'grok'; name = 'Grok'; family = 'xai' },
  @{ cli = 'agy'; name = 'Agy'; family = 'google' }, @{ cli = 'muse'; name = 'Muse'; family = 'meta' },
  @{ cli = 'omp'; name = 'OMP'; family = '' })
$perm = @{
  claude = @(@('Normal (asks before actions)', '', '', 'Claude asks before it edits files or runs commands.'), @('Skip permission prompts (--dangerously-skip-permissions)', '--dangerously-skip-permissions', '--dangerously-skip-permissions', 'Claude acts without asking first.'))
  codex = @(@('Normal', '', '', 'Codex keeps its approvals and its sandbox.'), @('YOLO, no sandbox (--dangerously-bypass-approvals-and-sandbox)', '--dangerously-bypass-approvals-and-sandbox', '--dangerously-bypass-approvals-and-sandbox', 'Codex runs with no approvals and no sandbox.'))
  kimi = @(@('Normal', '', '', 'Kimi uses its default mode.'), @('Ask when needed (--yolo)', '--yolo', '--yolo', 'Kimi asks only when it needs to.'), @('Never ask (--auto)', '--auto', '--auto', 'Kimi never asks for approval.'))
  grok = @(@('Normal', '', '', 'Grok uses its default permission mode.'), @('Bypass permissions (--permission-mode bypassPermissions)', '--permission-mode', '--permission-mode bypassPermissions', 'Grok skips its permission checks.'))
  agy = @(@('Normal', '', '', 'Agy asks before actions.'), @('Skip permission prompts (--dangerously-skip-permissions)', '--dangerously-skip-permissions', '--dangerously-skip-permissions', 'Agy acts without asking first.'))
  muse = @(@('Normal', '', '', 'Muse asks before actions.'), @('No approval prompts (--yolo)', '--yolo', '--yolo', 'Muse runs without approval prompts.'))
  omp = @(@('Normal', '', '', 'OMP asks before tool actions.'), @('YOLO (--approval-mode yolo)', '--approval-mode', '--approval-mode yolo', 'OMP runs tools without approval.'))
}
function Opt($label, $desc, $pre) { [ordered]@{ label = $label; description = $desc; preselected = [bool]$pre } }
function Ask($q, $header, $multi, $opts, $when) {
  $item = [ordered]@{ question = $q; header = $header; multiSelect = [bool]$multi; options = @($opts) }
  if ($when) { $item['when'] = $when }
  $item
}
$script:prompts = @()
function Section($id, $title, $qs, $note) {
  $qs = @($qs); if ($qs.Count -eq 0) { return }
  $total = [int][Math]::Ceiling($qs.Count / 4)
  for ($k = 1; $k -le $total; $k++) {
    $chunk = @($qs[(($k - 1) * 4)..([Math]::Min($qs.Count, $k * 4) - 1)])
    $p = [ordered]@{ id = $(if ($total -eq 1) { $id } else { "$id-$k" }); title = $(if ($total -eq 1) { $title } else { "$title ($k of $total)" }) }
    if ($note) { $p['ask_only_for'] = $note }
    $p['questions'] = $chunk
    $script:prompts += , $p
  }
}
$dash = [string][char]0x2014
$arrow = [string][char]0x2192
$dot = [string][char]0x00B7
$found = @(); $missing = @(); $accounts = @(); $used = @{}; $permOut = [ordered]@{}; $noflag = @(); $unavailable = @()
foreach ($p in $providers) {
  $cmd = Get-Command $p.cli -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) { $missing += $p.name; continue }
  # One provider that cannot be started is reported and skipped; discovery of the others goes on.
  $plan = Get-LaunchPlan $cmd.Source
  if (-not $plan.ok) { $unavailable += "Unavailable: $($p.name) ($($plan.reason))."; continue }
  try { $help = Invoke-Bounded $plan.file $plan.arguments } catch { $unavailable += "Unavailable: $($p.name) (it could not be started: $($_.Exception.Message))."; continue }
  if ($null -eq $help) { $help = '' }
  $found += "$($p.name) you"
  $family = $p.family
  if ($p.cli -eq 'omp') { $family = Get-OmpFamily (Join-Path $userHome '.omp\agent\config.yml') }
  $id = "$($p.cli)-$($operator.ToLower())"
  $accounts += [ordered]@{ id = $id; provider = $p.name; provider_family = $family; account_label = $operator.ToUpper(); account = $operator; operator = $true; command = $cmd.Source; home = $userHome; option = "$operator (you) $dash $($cmd.Source)"; row = "$operator $arrow ID $id, label $($operator.ToUpper())" }
  $list = @()
  foreach ($choice in $perm[$p.cli]) {
    if ($choice[1] -eq '' -or (Test-HelpFlag $help $choice[1] ($choice[2] -split ' ' | Select-Object -Skip 1 | Select-Object -First 1))) { $list += , [ordered]@{ label = $choice[0]; arguments = @($choice[2] -split ' ' | Where-Object { $_ }) } }
    else { $noflag += "$($p.name) offers Normal only for flags its --help does not show ($($choice[1]))." }
  }
  $permOut[$p.name] = $list
}
$glitch = @()
$candidates = @($GlitchRoot) + @("$userHome\Glitch")
$walk = $Cwd
for ($i = 0; $i -lt 32 -and $walk; $i++) { $candidates += $walk; $next = Split-Path -Parent $walk; if (-not $next -or $next -eq $walk) { break }; $walk = $next }
foreach ($root in $candidates) {
  if (-not $root) { continue }
  if ((Test-Path -LiteralPath "$root\.claude\scripts\workspaces.py" -PathType Leaf) -and (Test-Path -LiteralPath "$root\.claude\scripts\plan_check.py" -PathType Leaf) -and ($glitch -notcontains $root)) { $glitch += $root }
}
$intro = @("Found on this machine: $(if ($found) { $found -join " $dot " } else { 'nothing' }).")
if ($missing) { $intro += "Not found: $($missing -join ', ')." }
if ($glitch.Count -eq 1) { $intro += "Glitch folder detected: $($glitch[0])." }
elseif ($glitch.Count -gt 1) { $intro += "Glitch folders detected: $($glitch -join ', ')." }
if ($glitch.Count -gt 3) { $intro += "More Glitch folders found, not listed as choices (pick Other and type one): $(($glitch | Select-Object -Skip 3) -join ', ')." }
if ($glitch.Count -eq 0) { $intro += "Glitch folder: not found in $userHome\Glitch, the launch folder and its parents." }
$intro += $unavailable
$intro += $noflag
# Prompt 1: one multi-select per provider (a lone operator row gets a Skip row: every question needs 2 options).
$qs = @()
foreach ($p in $providers) {
  $mine = @($accounts | Where-Object { $_.provider -eq $p.name }); if ($mine.Count -eq 0) { continue }
  $opts = @($mine | ForEach-Object { Opt $_.option "Your own login on this machine. ID $($_.id), label $($_.account_label)." $false })
  $opts += , (Opt "Skip $($p.name)" "Run no $($p.name) agents." $false)
  $qs += , (Ask "$($p.name): which accounts should SPAWN run?" $p.name $true $opts $null)
}
Section 'accounts' 'Accounts' $qs $null
Section 'ids' 'IDs and labels' @((Ask 'Use these IDs and labels?' 'IDs' $false @((Opt 'Use these (Recommended)' 'Use the IDs and labels in the table above.' $true), (Opt 'Change some' 'Say which IDs or labels to change.' $false)) $null)) $null
$fo = @(); foreach ($g in ($glitch | Select-Object -First 3)) { $fo += , (Opt "Glitch folder: $g$(if ($glitch.Count -eq 1) { ' (Recommended)' })" 'Every agent starts in this Glitch installation.' ($glitch.Count -eq 1)) }
$fo += , (Opt "Each account's own home folder" "Each agent starts in its own account's home folder." ($glitch.Count -eq 0))
if ($glitch.Count -eq 0) { $fo += , (Opt "This launch folder: $Cwd" 'Every agent starts in the folder this setup was launched from.' $false) }
Section 'folder' 'Folder' @((Ask 'Which folder should every agent start in?' 'Folder' $false $fo $null)) $null
$qs = @()
foreach ($p in $providers) {
  if (-not $permOut.Contains($p.name) -or $permOut[$p.name].Count -lt 2) { continue }
  $po = @(); $i = 0
  foreach ($choice in $perm[$p.cli]) { if ($permOut[$p.name] | Where-Object { $_.label -eq $choice[0] }) { $po += , (Opt $choice[0] $choice[3] ($choice[1] -eq '')) } }
  $qs += , (Ask "$($p.name): which permission mode?" $p.name $false $po ([ordered]@{ provider = $p.name }))
}
Section 'permissions' 'Permissions' $qs 'providers with a chosen account'
$qs = @()
foreach ($a in ($accounts | Where-Object { $_.provider -eq 'OMP' })) {
  $oo = @(); $alt = @('openai', 'google', 'anthropic') | Where-Object { $_ -ne $a.provider_family }
  if ($a.provider_family) { $oo += , (Opt "$($a.provider_family) (from its config) (Recommended)" "The service named in this account's own OMP configuration." $true); $alt = $alt | Select-Object -First 2 }
  foreach ($s in $alt) { $oo += , (Opt $s "Run this account's OMP model through $s." $false) }
  $qs += , (Ask "Which service runs $($a.id)'s model?" 'OMP service' $false $oo ([ordered]@{ account_id = $a.id }))
}
Section 'omp' 'OMP service' $qs 'chosen OMP accounts'
Section 'review' 'Review' @((Ask 'Save these {N} agents?' 'Save' $false @((Opt 'Save and set up (Recommended)' 'Save the roster and let SPAWN prepare it.' $true), (Opt 'Change something' 'Go back and change a choice.' $false)) $null)) $null
$prompts = @($script:prompts | ForEach-Object { if ($_.id -eq 'ids') { $_['show_first'] = 'derived.accounts[].row for the chosen accounts, one per line' } elseif ($_.id -eq 'review') { $_['show_first'] = 'derived.review table for the chosen accounts; {N} is their count' }; $_ })
$result = [ordered]@{
  intro = $intro; prompts = $prompts
  derived = [ordered]@{
    operator = $operator; launch_folder = $Cwd
    providers = @($providers | ForEach-Object { $n = $_.name; [ordered]@{ name = $n; cli = $_.cli; seats = 0; operator = [bool]($accounts | Where-Object { $_.provider -eq $n }) } })
    accounts = $accounts; permissions = $permOut; glitch_folders = $glitch
    omp_prompt = 'Follow the explicitly assigned task. Role text is guidance, not identity isolation.'
    review = [ordered]@{ columns = @('ID', 'account', 'CLI', 'permission flags', 'folder', 'paid check'); paid_check_native = 'one harmless paid model message'; paid_check_terminal = 'offline checks only' }
  }
  limits = [ordered]@{ questions_per_prompt = 4; options_per_question = 4; header_characters = 12 }
}
[Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 12 -Compress))
