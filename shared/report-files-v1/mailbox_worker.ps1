# Existing-PowerShell work-tool helper, not a service. Invoke at work checkpoints
# and during wait via -Mode wait. This is transport/journal machinery, not proof
# that a configured CLI actually invokes it. Installation/evidence remains gated.
param([string]$Root,[string]$Handle,[string]$Owner,[ValidateSet('init','report','replay','receipts','consume','wait','claim','resolve','retire-local','retire-authorized','run-checks','checkout')][string]$Mode,[string]$MessageId,[ValidateRange(1000,60000)][int]$PollMs=5000,[ValidateRange(1,30)][int]$WaitSeconds=30,[string]$ReportFloor='-1',[string]$ReplyFloor='-1',[string]$ReceiptChain='',[string]$ExpectedBinding='',[string]$CheckId='',[string]$WithdrawnStarts='')
$ErrorActionPreference='Stop'
$utf8=New-Object Text.UTF8Encoding($false,$true)
function Fail([string]$Code) { throw $Code }
# A schema refusal names the field (At) and the rule it broke on a second line (SKILLS-214),
# in the same words as the jq validator's explain mode.
$script:schemaAt=''
function At([string]$Path) { $script:schemaAt=$Path }
function Refuse([string]$Rule) {
 # One line only: a key or value echoed into the rule may carry control characters.
 $line=$Rule; if ($script:schemaAt.Length -gt 0) { $line=$script:schemaAt+': '+$Rule }
 $line=$line -replace '[\x00-\x1f\x7f]',''; if ($line.Length -gt 300) { $line=$line.Substring(0,300) }
 Fail ("invalid_schema`n"+$line)
}
function Full([string]$Resource,[long]$Current,[long]$Limit) { Fail ("full`n"+$Resource+"`n"+$Current+"`n"+$Limit) }
function Hash([byte[]]$Bytes) { $sha=[Security.Cryptography.SHA256]::Create(); try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() } }
# Recursive RFC8259 reader. Unlike ConvertFrom-Json it preserves duplicate-key,
# null, trailing-content and container-kind evidence before any journal effect.
function Space {
 while ($script:cursor -lt $script:jsonText.Length -and " `t`r`n".Contains([string]$script:jsonText[$script:cursor])) { $script:cursor++ }
}
function JsonString {
 if ($script:cursor -ge $script:jsonText.Length -or $script:jsonText[$script:cursor] -ne '"') { Fail 'invalid_schema' }
 $script:cursor++; $builder=New-Object Text.StringBuilder
 while ($script:cursor -lt $script:jsonText.Length) {
  $c=$script:jsonText[$script:cursor]; $script:cursor++
  if ($c -eq '"') { $text=$builder.ToString(); if ($utf8.GetByteCount($text) -gt $script:stringLimit) { Fail 'oversize' }; return $text }
  if ([int]$c -lt 32) { Fail 'invalid_schema' }
  if ($c -eq '\') {
   if ($script:cursor -ge $script:jsonText.Length) { Fail 'invalid_schema' }
   $escape=$script:jsonText[$script:cursor]; $script:cursor++
   switch -CaseSensitive ($escape) {
    '"' { $c='"' }
    '\' { $c='\' }
    '/' { $c='/' }
    'b' { $c=[char]8 }
    'f' { $c=[char]12 }
    'n' { $c="`n" }
    'r' { $c="`r" }
    't' { $c="`t" }
    'u' {
     if ($script:cursor+4 -gt $script:jsonText.Length) { Fail 'invalid_schema' }
     $hex=$script:jsonText.Substring($script:cursor,4); if ($hex -notmatch '^[0-9a-fA-F]{4}$') { Fail 'invalid_schema' }
     $code=[Convert]::ToInt32($hex,16); $script:cursor+=4
     if ($code -ge 0xD800 -and $code -le 0xDBFF) {
      if ($script:cursor+6 -gt $script:jsonText.Length -or $script:jsonText.Substring($script:cursor,2) -cne '\u') { Fail 'invalid_schema' }
      $hex=$script:jsonText.Substring($script:cursor+2,4); if ($hex -notmatch '^[0-9a-fA-F]{4}$') { Fail 'invalid_schema' }
      $low=[Convert]::ToInt32($hex,16); if ($low -lt 0xDC00 -or $low -gt 0xDFFF) { Fail 'invalid_schema' }
      $script:cursor+=6; $c=[char]::ConvertFromUtf32(65536+($code-0xD800)*1024+$low-0xDC00)
     } elseif ($code -ge 0xDC00 -and $code -le 0xDFFF) { Fail 'invalid_schema' }
     else { $c=[char]$code }
    }
    default { Fail 'invalid_schema' }
   }
  }
  $null=$builder.Append($c)
 }
 Fail 'invalid_schema'
}
function JsonValue([int]$Depth) {
 $script:values++; if ($Depth -gt 12 -or $script:values -gt 16384) { Fail 'oversize' }
 Space; if ($script:cursor -ge $script:jsonText.Length) { Fail 'invalid_schema' }
 $c=$script:jsonText[$script:cursor]
 if ($c -eq '"') { return (JsonString) }
 if ($c -eq '{' -or $c -eq '[') {
  $object=$c -eq '{'; $closer=']'; if ($object) { $closer='}' }
  $map=[Collections.Hashtable]::new([StringComparer]::Ordinal); $list=@(); $count=0
  $script:cursor++; Space
  if ($script:cursor -lt $script:jsonText.Length -and $script:jsonText[$script:cursor] -eq $closer) { $script:cursor++; if ($object) { return $map }; return ,$list }
  while ($true) {
   # Arrays admit 512 entries (CHECKOUT changed_files), matching mailbox_json.awk.
   $count++; $maximum=512; if ($object) { $maximum=64 }; if ($count -gt $maximum) { Fail 'oversize' }
   Space
   if ($object) {
    $key=JsonString; if ($utf8.GetByteCount($key) -gt 64 -or $map.ContainsKey($key)) { Fail 'invalid_schema' }
    Space; if ($script:cursor -ge $script:jsonText.Length -or $script:jsonText[$script:cursor] -ne ':') { Fail 'invalid_schema' }; $script:cursor++
    $map[$key]=JsonValue ($Depth+1)
   } else { $list+=,(JsonValue ($Depth+1)) }
   Space; if ($script:cursor -ge $script:jsonText.Length) { Fail 'invalid_schema' }
   if ($script:jsonText[$script:cursor] -eq $closer) { $script:cursor++; if ($object) { return $map }; return ,$list }
   if ($script:jsonText[$script:cursor] -ne ',') { Fail 'invalid_schema' }; $script:cursor++
  }
 }
 $tail=$script:jsonText.Substring($script:cursor)
 if ($tail.StartsWith('true')) { $script:cursor+=4; return $true }
 if ($tail.StartsWith('false')) { $script:cursor+=5; return $false }
 $match=[regex]::Match($tail,'^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?')
 if (-not $match.Success) { Fail 'invalid_schema' }
 [long]$whole=0
 if ($match.Value -match '^-?[0-9]+$' -and [long]::TryParse($match.Value,[ref]$whole)) { $script:cursor+=$match.Length; return $whole }
 $number=[double]::Parse($match.Value,[Globalization.CultureInfo]::InvariantCulture)
 if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { Fail 'invalid_schema' }
 $script:cursor+=$match.Length; return $number
}
function Decode([byte[]]$Bytes,[int]$Limit=65536) {
 if ($Bytes.Length -eq 0 -or $Bytes.Length -gt $Limit) { Fail 'oversize' }
 $script:jsonText=$utf8.GetString($Bytes); $script:cursor=0; $script:values=0; $script:stringLimit=32768
 if ($Limit -gt 65536) { $script:stringLimit=2097152 }
 $value=JsonValue 1; Space
 if ($script:cursor -ne $script:jsonText.Length -or ($Limit -le 65536 -and $script:values -gt 2048)) { Fail 'invalid_schema' }
 return ,$value
}
function Encode($Value) { return ,$utf8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 12 -Compress)) }
function DirectorySafe([string]$Path) {
 $item=Get-Item -LiteralPath $Path -Force
 while ($null -ne $item) { if ($item -isnot [IO.DirectoryInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Fail 'binding_mismatch' }; $item=$item.Parent }
}
function ReadFile([string]$Path,[int]$Limit) {
 DirectorySafe ([IO.Path]::GetDirectoryName($Path))
 $item=Get-Item -LiteralPath $Path -Force
 if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt $Limit) { Fail 'binding_mismatch' }
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try {
  $bytes=New-Object byte[] ($Limit+1); $length=0
  while ($length -lt $bytes.Length) { $n=$stream.Read($bytes,$length,$bytes.Length-$length); if ($n -eq 0) { break }; $length+=$n }
  if ($length -gt $Limit) { Fail 'oversize' }; $result=New-Object byte[] $length; [Array]::Copy($bytes,$result,$length); return ,$result
 } finally { $stream.Dispose() }
}
# Shared with mailbox_target.ps1 and the POSIX helpers: 4MiB/1024 hard;
# ordinary durable 2MiB/896, settlement 2.25MiB/1008. The remaining
# 1.5MiB journal replacement + 256KiB/16 staging slots are never ordinary space.
$script:capacityDepth=0
# Re-admission inside one invocation (wait polls, post-retirement lock removal) waits out
# a busy gate for at most gateWaitMs: every holder releases it before sleep or stdio.
# This only ever creates the gate; it never takes a held one.
$script:gateWaitMs=0
function EnterCapacity {
 if ($script:capacityDepth -eq 0) {
  DirectorySafe $box
  $gateWatch=[Diagnostics.Stopwatch]::StartNew()
  while ($true) {
   try { $null=New-Item -ItemType Directory -Path (Join-Path $box 'capacity.lock') -ErrorAction Stop; break }
   catch { if ($gateWatch.ElapsedMilliseconds -ge $script:gateWaitMs) { Fail 'capacity_locked' }; Start-Sleep -Milliseconds 100 }
  }
 }
 $script:capacityDepth++
}
function LeaveCapacity {
 $script:capacityDepth--
 if ($script:capacityDepth -eq 0) { [IO.Directory]::Delete((Join-Path $box 'capacity.lock'),$false) }
}
function Capacity([long]$ExtraBytes,[int]$ExtraFiles,[bool]$Drain=$false,[long]$ReplacedBytes=0,[int]$ReplacedFiles=0) {
 if ($script:capacityDepth -lt 1) { Fail 'journal_corrupt' }
 $queue=New-Object 'System.Collections.Generic.Queue[string]'; $queue.Enqueue($box); $files=0; $dirs=0; [long]$size=0
 while ($queue.Count -gt 0) {
  foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($queue.Dequeue())) {
   $item=Get-Item -LiteralPath $path -Force
   if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Fail 'binding_mismatch' }
   if ($item.PSIsContainer) { $dirs++; if ($dirs -gt 1024) { Full 'mailbox_directories' $dirs 1024 }; $queue.Enqueue($path) }
   else { $files++; $size+=$item.Length }
  }
 }
 $byteLimit=2097152; $fileLimit=896
 if ($Drain) { $byteLimit=2359296; $fileLimit=1008 }
 if ($size+$ExtraBytes -gt 4194304) { Full 'mailbox_bytes' ($size+$ExtraBytes) 4194304 }
 if ($files+$ExtraFiles -gt 1024) { Full 'mailbox_files' ($files+$ExtraFiles) 1024 }
 if ($size+$ExtraBytes-$ReplacedBytes -gt $byteLimit) { Full 'mailbox_bytes' ($size+$ExtraBytes-$ReplacedBytes) $byteLimit }
 if ($files+$ExtraFiles-$ReplacedFiles -gt $fileLimit) { Full 'mailbox_files' ($files+$ExtraFiles-$ReplacedFiles) $fileLimit }
}
function WriteTemp([byte[]]$Bytes) {
 # The enclosing transaction admits the complete peak before creating staging.
 if ($script:capacityDepth -lt 1) { Fail 'journal_corrupt' }
 $path=Join-Path $box ('staging/'+[Guid]::NewGuid().ToString('N')+'.tmp')
 $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try { $stream.Write($Bytes,0,$Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
 return $path
}
function Publish([string]$Relative,[byte[]]$Bytes,[bool]$Drain=$false) {
 EnterCapacity
 try {
  $path=Join-Path $box $Relative; $parent=[IO.Path]::GetDirectoryName($path)
  if (Test-Path -LiteralPath $path) { if ([Convert]::ToBase64String((ReadFile $path 4096)) -cne [Convert]::ToBase64String($Bytes)) { Fail 'content_conflict' }; return }
  Capacity $Bytes.Length 1 $Drain
  if (-not (Test-Path -LiteralPath $parent)) { DirectorySafe ([IO.Path]::GetDirectoryName($parent)); $null=New-Item -ItemType Directory -Path $parent }
  DirectorySafe $parent
  $tmp=WriteTemp $Bytes
  try { [IO.File]::Move($tmp,$path) } finally { if (Test-Path -LiteralPath $tmp) { [IO.File]::Delete($tmp) } }
  if ([Convert]::ToBase64String((ReadFile $path 4096)) -cne [Convert]::ToBase64String($Bytes)) { Fail 'content_conflict' }
 } finally { LeaveCapacity }
}
function CompactJournal {
 # Receipt advancement does not discard unclaimed or uncertain execution bytes.
 while ($true) {
  $next=$script:journal.consumed_reply_floor+1
  $fact=@($script:journal.consumed | Where-Object { $_.reply_seq -eq $next -and $_.acknowledged })
  if ($fact.Count -ne 1) { break }
  $script:journal.consumed_reply_floor=$next
 }
 $script:journal.consumed=@($script:journal.consumed | Where-Object { $_.reply_seq -gt $script:journal.consumed_reply_floor -or $_.execution -ne 'resolved' })
}
function JournalBytes {
 CompactJournal
 $retained=0L
 foreach ($fact in $script:journal.consumed) { $retained+=[Convert]::FromBase64String($fact.bytes).Length }
 if ($script:journal.consumed.Count -gt 8) { Full 'retained_executions' $script:journal.consumed.Count 8 }
 if ($retained -gt 524288) { Full 'retained_reply_bytes' $retained 524288 }
 $bytes=Encode $script:journal
 if ($bytes.Length -gt 1572864) { Full 'journal_bytes' $bytes.Length 1572864 }
 return ,$bytes
}
function Save([bool]$Drain=$true) {
 $bytes=JournalBytes
 EnterCapacity
 try {
  $oldBytes=0; $oldFiles=0
  if (Test-Path -LiteralPath $journalPath) { $oldBytes=(ReadFile $journalPath 1572864).Length; $oldFiles=1 }
  Capacity $bytes.Length 1 $Drain $oldBytes $oldFiles
  $tmp=WriteTemp $bytes
  try {
   # Windows PowerShell converts an ordinary $null string argument to ""; the
   # explicit null-string sentinel preserves File.Replace's no-backup contract.
   if ($oldFiles -eq 1) { [IO.File]::Replace($tmp,$journalPath,[NullString]::Value) }
   else { [IO.File]::Move($tmp,$journalPath) }
  } finally { if (Test-Path -LiteralPath $tmp) { [IO.File]::Delete($tmp) } }
 } finally { LeaveCapacity }
}
function MatchBinding($Value,[bool]$Token=$false) {
 foreach ($key in @('logical_session_id','worker_id','worker_generation','launch_request_id','work_id')) { if ($Value[$key] -cne $binding[$key]) { Fail 'binding_mismatch' } }
 if ($Token -and $Value.enrolment_token -cne $binding.enrolment_token) { Fail 'binding_mismatch' }
}
function Fields($Value,[string[]]$Required) { ObjectFields $Value $Required }
function ObjectFields($Value,[string[]]$Required,[string[]]$Optional=@()) {
 if ($Value -isnot [hashtable]) { Refuse 'must be an object' }
 foreach ($key in $Required) { if (-not $Value.ContainsKey($key)) { Refuse ('missing field '+$key) } }
 foreach ($key in $Value.Keys) { if ($key -cnotin $Required -and $key -cnotin $Optional) { Refuse ('unknown field '+$key) } }
}
function ValueType($Value,[string]$Type) {
 $valid=$false
 switch -CaseSensitive ($Type) {
  'id' { $valid=$Value -is [string] -and $Value -cmatch '^[A-Za-z0-9_-]{1,96}\z' }
  'token' { $valid=$Value -is [string] -and $Value -cmatch '^[A-Za-z0-9_-]{16,128}\z' }
  'digest' { $valid=$Value -is [string] -and $Value -cmatch '^[0-9a-f]{64}\z' }
  'revision' { $valid=$Value -is [string] -and $Value -cmatch '^([0-9a-f]{40}|[0-9a-f]{64})\z' }
  'class' { $valid=$Value -is [string] -and $Value -cmatch '^[a-z][a-z0-9-]{0,31}\z' }
  'family' { $valid=$Value -is [string] -and $Value -cmatch '^[a-z][a-z0-9-]{0,23}\z' }
  'exit' { $valid=($Value -is [long] -or $Value -is [int] -or $Value -is [double]) -and $Value -ge -2147483648 -and $Value -le 4294967295 -and $Value%1 -eq 0 }
  'path' { $valid=$Value -is [string] -and $utf8.GetByteCount($Value) -ge 1 -and $utf8.GetByteCount($Value) -le 4096 -and -not $Value.Contains([string][char]0) }
  'absolute' { $valid=$Value -is [string] -and $utf8.GetByteCount($Value) -ge 1 -and $utf8.GetByteCount($Value) -le 4096 -and -not $Value.Contains([string][char]0) -and $Value -cmatch '^(/|[A-Za-z]:[/\\]|\\\\)' }
  'relative' { $valid=$Value -is [string] -and $utf8.GetByteCount($Value) -ge 1 -and $utf8.GetByteCount($Value) -le 256 -and $Value -cnotmatch '[\x00\\]|^/|^[A-Za-z]:|(^|/)\.\.(/|\z)' }
  'branch' { $valid=$Value -is [string] -and $utf8.GetByteCount($Value) -ge 1 -and $utf8.GetByteCount($Value) -le 256 }
  'scope' { $valid=$Value -is [string] -and $utf8.GetByteCount($Value) -ge 1 -and $utf8.GetByteCount($Value) -le 256 }
  'finding' { $valid=$Value -is [string] -and $utf8.GetByteCount($Value) -ge 1 -and $utf8.GetByteCount($Value) -le 400 }
  'positive' { $valid=($Value -is [long] -or $Value -is [int] -or $Value -is [double]) -and $Value -ge 1 -and $Value -le 9007199254740991 -and $Value%1 -eq 0 }
  'nonnegative' { $valid=($Value -is [long] -or $Value -is [int] -or $Value -is [double]) -and $Value -ge 0 -and $Value -le 9007199254740991 -and $Value%1 -eq 0 }
  'percent' { $valid=($Value -is [long] -or $Value -is [int] -or $Value -is [double]) -and $Value -ge 0 -and $Value -le 100 -and $Value%1 -eq 0 }
  'short' { $valid=$Value -is [string] -and $utf8.GetByteCount($Value) -ge 1 -and $utf8.GetByteCount($Value) -le 1024 }
  'long' { $valid=$Value -is [string] -and $utf8.GetByteCount($Value) -ge 1 -and $utf8.GetByteCount($Value) -le 32768 }
  default { Fail 'invalid_schema' }
 }
 if (-not $valid) {
  $rules=@{ id='1-96 of A-Z a-z 0-9 _ -'; token='16-128 of A-Z a-z 0-9 _ -'; digest='64 lowercase hex characters'; revision='40 or 64 lowercase hex characters'
   positive='whole number from 1'; nonnegative='whole number from 0'; percent='whole number from 0 to 100'; short='text of 1 to 1024 bytes'; long='text of 1 to 32768 bytes'
   absolute='an absolute path of at most 4096 bytes'; relative='a relative path'; path='a path of 1 to 4096 bytes' }
  if ($rules.ContainsKey($Type)) { Refuse $rules[$Type] } else { Refuse 'invalid value' }
 }
}
function ContextMeasurement($p) {
 if ($p.ContainsKey('context_used_pct') -and $p.ContainsKey('context_snapshot')) { Fail 'invalid_schema' }
 if ($p.ContainsKey('context_used_pct')) { ValueType $p.context_used_pct 'percent' }
 if ($p.ContainsKey('context_snapshot')) {
  $s=$p.context_snapshot
  ObjectFields $s @('current_tokens','window_tokens','observed_at_ms') @('first_turn_tokens')
  ValueType $s.current_tokens 'nonnegative'; ValueType $s.window_tokens 'positive'; ValueType $s.observed_at_ms 'nonnegative'
  if ($s.current_tokens -gt $s.window_tokens) { Fail 'invalid_schema' }
  if ($s.ContainsKey('first_turn_tokens')) {
   ValueType $s.first_turn_tokens 'nonnegative'
   if ($s.first_turn_tokens -gt $s.window_tokens) { Fail 'invalid_schema' }
  }
 }
}
function Values($Value,[string]$Type,[int]$Minimum=0,[int]$Maximum=256) {
 if ($Value -isnot [array] -or $Value.Count -lt $Minimum -or $Value.Count -gt $Maximum) { Fail 'invalid_schema' }
 foreach ($entry in $Value) { ValueType $entry $Type }
}
function Choice($Value,[string[]]$Allowed) {
 if ($Value -isnot [string] -or $Value -cnotin $Allowed) { Refuse ('must be one of '+($Allowed -join ', ')) }
}
function Unique($Value,[string]$Key='') {
 $seen=[Collections.Hashtable]::new([StringComparer]::Ordinal)
 foreach ($entry in $Value) {
  $item=$entry; if ($Key.Length -gt 0) { $item=$entry[$Key] }
  if ($seen.ContainsKey($item)) { Refuse ($(if ($Key.Length -gt 0) { $Key+' values' } else { 'values' })+' must be unique') }; $seen[$item]=$true
 }
}
function Findings($Value) {
 if ($Value -isnot [array] -or $Value.Count -gt 32) { Fail 'invalid_schema' }
 foreach ($finding in $Value) {
  ObjectFields $finding @('finding_id','path','summary') @('line')
  ValueType $finding.finding_id 'id'; ValueType $finding.path 'short'; ValueType $finding.summary 'finding'
  if ($finding.ContainsKey('line')) { ValueType $finding.line 'positive' }
 }
 Unique $Value 'finding_id'
}
function BoundedText($Value,[int]$Maximum,[bool]$Nonblank=$false) {
 if ($Value -isnot [string] -or $utf8.GetByteCount($Value) -lt 1 -or $utf8.GetByteCount($Value) -gt $Maximum -or $Value.Contains([string][char]0)) { Refuse ('text of 1 to '+$Maximum+' bytes') }
 # Match the canonical Luau ASCII whitespace class, not .NET's Unicode \s.
 if ($Nonblank -and $Value -cnotmatch '[^ \t\r\n\x0b\x0c]') { Refuse 'must not be blank' }
}
function ProposedWork($p) {
 $required=@('owner_id','owner_generation','activation_token','proposal_id','kind')
 $optional=@('orch_project_id','new_project_name')
 if ($p.kind -ceq 'new_work') {
  At 'payload'; ObjectFields $p ($required+@('record_id','record_revision','prompt','scope','checks')) ($optional+@('base_ref','repository_id','target_ref','target_revision'))
  At 'payload.record_id'; ValueType $p.record_id 'short'; At 'payload.record_revision'; ValueType $p.record_revision 'nonnegative'
  At 'payload.prompt'; BoundedText $p.prompt 32768 $true
  At 'payload.scope'; ObjectFields $p.scope @('paths','systems')
  foreach ($key in @('paths','systems')) {
   $maximum=64; $bytes=256; if ($key -ceq 'systems') { $maximum=16; $bytes=80 }
   $items=$p.scope[$key]; At ('payload.scope.'+$key)
   if ($items -isnot [array]) { Refuse 'must be a list' }
   if ($items.Count -gt $maximum) { Refuse ('must hold 0 to '+$maximum+' entries, has '+$items.Count) }
   for ($i=0; $i -lt $items.Count; $i++) { At ('payload.scope.'+$key+'['+$i+']'); BoundedText $items[$i] $bytes }
  }
  At 'payload.checks'
  if ($p.checks -isnot [array]) { Refuse 'must be a list' }
  if ($p.checks.Count -gt 16) { Refuse ('must hold 0 to 16 entries, has '+$p.checks.Count) }
  for ($c=0; $c -lt $p.checks.Count; $c++) {
   $check=$p.checks[$c]; $at='payload.checks['+$c+']'
   At $at; ObjectFields $check @('check_id','argv'); At ($at+'.check_id'); ValueType $check.check_id 'id'
   At ($at+'.argv')
   if ($check.argv -isnot [array]) { Refuse 'must be a list' }
   if ($check.argv.Count -lt 1 -or $check.argv.Count -gt 16) { Refuse ('must hold 1 to 16 entries, has '+$check.argv.Count) }
   for ($i=0; $i -lt $check.argv.Count; $i++) { At ($at+'.argv['+$i+']'); BoundedText $check.argv[$i] 512 }
  }
  At 'payload.checks'; Unique $p.checks 'check_id'
  foreach ($key in @('base_ref','target_ref')) { if ($p.ContainsKey($key)) { At ('payload.'+$key); BoundedText $p[$key] 256 } }
  if ($p.ContainsKey('repository_id')) { At 'payload.repository_id'; ValueType $p.repository_id 'id' }
  if ($p.ContainsKey('target_revision')) { At 'payload.target_revision'; ValueType $p.target_revision 'revision' }
  At 'payload'
  if ($p.ContainsKey('target_ref') -ne $p.ContainsKey('target_revision')) { Refuse 'target_ref and target_revision go together' }
  if ($p.ContainsKey('target_ref') -and -not $p.ContainsKey('repository_id')) { Refuse 'target_ref needs repository_id' }
 } else {
  At 'payload'; ObjectFields $p ($required+@('source')) $optional
  $source=$p.source; At 'payload.source'
  if ($source -isnot [hashtable]) { Refuse 'must be an object' }
  At 'payload.source'
  if ($source.kind -isnot [string] -or $source.kind -cnotin @('plan_file','board','template')) { Refuse 'kind must be plan_file, board or template' }
  if ($source.kind -ceq 'template') {
   ObjectFields $source @('kind','template_id','revision','input') @('custom_fields')
   At 'payload.source.template_id'; ValueType $source.template_id 'id'; At 'payload.source.input'; BoundedText $source.input 32768 $true
   if ($source.ContainsKey('custom_fields')) {
    $custom=$source.custom_fields
    At 'payload.source.custom_fields'
    if ($custom -isnot [hashtable] -or $custom.Count -gt 16) { Refuse 'up to 16 lowercase names other than input, values up to 2048 bytes' }
    foreach ($name in $custom.Keys) {
     if ($name -isnot [string] -or $name.Length -gt 32 -or $name -ceq 'input' -or $name -cnotmatch '^[a-z][a-z0-9-]*$') { Refuse 'up to 16 lowercase names other than input, values up to 2048 bytes' }
     $value=$custom[$name]
     if ($value -isnot [string] -or $utf8.GetByteCount($value) -gt 2048 -or $value.Contains([string][char]0)) { Refuse 'up to 16 lowercase names other than input, values up to 2048 bytes' }
    }
   }
  } else {
   ObjectFields $source @('kind','path','revision'); At 'payload.source.path'; ValueType $source.path 'absolute'
  }
  At 'payload.source.revision'; BoundedText $source.revision 1024 $true
 }
 At 'payload'
 if ($p.ContainsKey('orch_project_id') -eq $p.ContainsKey('new_project_name')) { Refuse 'give exactly one of orch_project_id or new_project_name' }
 if ($p.ContainsKey('orch_project_id')) { At 'payload.orch_project_id'; ValueType $p.orch_project_id 'id' }
 if ($p.ContainsKey('new_project_name')) { At 'payload.new_project_name'; BoundedText $p.new_project_name 160 $true }
}
function ProjectStart($p) {
 ObjectFields $p @('owner_id','owner_generation','activation_token','orch_project_id','project_revision','decision_context')
 ValueType $p.owner_id 'id'; ValueType $p.owner_generation 'positive'; ValueType $p.activation_token 'digest'
 ValueType $p.orch_project_id 'id'; ValueType $p.project_revision 'positive'; ValueType $p.decision_context 'digest'
}
# A rollover successor's provision.json carries the issued handover ID and
# sha256(handover_id:handover_token), never the token. ACCEPTED must match it before any
# sequence is allocated, so a mistyped pair is retried instead of published.
# Messages name the field and never echo either value. Only ACCEPTED reads the provisioned
# handover, so every other mode behaves like the POSIX helper even if it is malformed.
function ProvisionedHandover($Descriptor) {
 if (-not $Descriptor.ContainsKey('handover')) { return $null }
 $issued=$Descriptor.handover
 if ($issued -isnot [hashtable] -or $issued.Count -ne 2 -or $issued.handover_id -isnot [string] -or $issued.handover_id -cnotmatch '^[A-Za-z0-9_-]{1,96}\z' -or $issued.handover_sha256 -isnot [string] -or $issued.handover_sha256 -cnotmatch '^[0-9a-f]{64}\z') { Fail 'binding_mismatch' }
 return $issued
}
function HandoverCheck($Report) {
 $issued=ProvisionedHandover $descriptor
 $supplied=$Report.ContainsKey('handover_id')
 if ($null -eq $issued) {
  if ($supplied) { Fail 'binding_mismatch: handover_id was not issued to this generation; report ACCEPTED without a handover pair' }
  return
 }
 if (-not $supplied) { Fail 'binding_mismatch: handover_id and handover_token are required; copy both verbatim from the launch preface and report ACCEPTED again' }
 if ($Report.handover_id -cne $issued.handover_id) { Fail 'binding_mismatch: handover_id differs from the provisioned handover; copy it verbatim from the launch preface and report ACCEPTED again' }
 if ((Hash ($utf8.GetBytes($Report.handover_id+':'+$Report.handover_token))) -cne $issued.handover_sha256) { Fail 'binding_mismatch: handover_token differs from the provisioned handover digest; copy it verbatim from the launch preface and report ACCEPTED again' }
}
function ReportInput($Report) {
 At ''
 ObjectFields $Report @('kind','payload') @('action_id','action_revision','handover_id','handover_token')
 At 'kind'; Choice $Report.kind @('REGISTER','READY','ACCEPTED','HEARTBEAT','WAITING','BLOCKED','ASK','CHECKPOINT','REVIEW_READY','REVIEW_RESULT','DONE','ROLLOVER_REQUEST','LANDING_REQUEST','LANDING_RESULT','reply_ack','COORDINATOR_RELEASE','COORDINATOR_PROPOSAL','PROJECT_START_CLAIM','CHECK_RESULT','CHECKOUT','LABEL','DEPLOY_RESULT')
 $action=$Report.ContainsKey('action_id'); $handover=$Report.ContainsKey('handover_id')
 $required=$Report.kind -cin @('REVIEW_RESULT','LANDING_RESULT','reply_ack','COORDINATOR_RELEASE','PROJECT_START_CLAIM','LABEL','DEPLOY_RESULT')
 $optional=$Report.kind -cin @('CHECKPOINT','DONE','WAITING','BLOCKED')
 At ''
 if ($action -ne $Report.ContainsKey('action_revision')) { Refuse 'action_id and action_revision go together' }
 if ($required -and -not $action) { Refuse 'this kind needs the issued action_id and action_revision' }
 if ($action -and -not ($required -or $optional)) { Refuse 'this kind takes no action_id or action_revision' }
 if ($handover -ne $Report.ContainsKey('handover_token') -or ($handover -and $Report.kind -cne 'ACCEPTED')) { Refuse 'handover_id and handover_token go together, on ACCEPTED only' }
 if ($action) { At 'action_id'; ValueType $Report.action_id 'id'; At 'action_revision'; ValueType $Report.action_revision 'positive' }
 At ''
 if ($handover) { ValueType $Report.handover_id 'id'; ValueType $Report.handover_token 'token' }
 foreach ($key in @('logical_session_id','worker_id','launch_request_id','work_id','mailbox_handle')) { ValueType $binding[$key] 'id' }
 ValueType $binding.worker_generation 'positive'; ValueType $binding.enrolment_token 'token'
 $p=$Report.payload
 At 'payload'
 switch -CaseSensitive ($Report.kind) {
  'REGISTER' {
   ObjectFields $p @('capabilities')
   Values $p.capabilities 'short' 1 8
   $seen=[Collections.Hashtable]::new([StringComparer]::Ordinal)
   foreach ($cap in $p.capabilities) {
    Choice $cap @('report-files-v1','native-ask-v1','worker-poll-v1','argv-v1','coordinator-control-v1','check-runner-v1','release-manager-v1','project-start-v1')
    if ($seen.ContainsKey($cap)) { Fail 'invalid_schema' }; $seen[$cap]=$true
    if ($binding.ContainsKey('capabilities') -and $cap -cnotin $binding.capabilities) { Fail 'binding_mismatch' }
   }
   if (-not $seen.ContainsKey('report-files-v1')) { Fail 'invalid_schema' }
  }
  'READY' { ObjectFields $p @('state') @('summary','context_used_pct','context_snapshot'); Choice $p.state @('idle'); ContextMeasurement $p }
  'ACCEPTED' {
   ObjectFields $p @('assignment_sha256'); ValueType $p.assignment_sha256 'digest'
   HandoverCheck $Report
  }
  'HEARTBEAT' { ObjectFields $p @('state') @('summary','request_id','context_used_pct','context_snapshot'); Choice $p.state @('working','idle','waiting','blocked'); if ($p.ContainsKey('request_id')) { ValueType $p.request_id 'id' }; ContextMeasurement $p }
  'WAITING' { ObjectFields $p @('reason') @('request_id'); ValueType $p.reason 'short'; if ($p.ContainsKey('request_id')) { ValueType $p.request_id 'id' } }
  'BLOCKED' { ObjectFields $p @('reason') @('evidence'); ValueType $p.reason 'long' }
  'ASK' {
   ObjectFields $p @('question','options') @('evidence'); ValueType $p.question 'long'
   if ($p.options -isnot [array] -or $p.options.Count -lt 1 -or $p.options.Count -gt 16) { Fail 'invalid_schema' }
   $seen=[Collections.Hashtable]::new([StringComparer]::Ordinal)
   foreach ($option in $p.options) {
    ObjectFields $option @('id','label'); ValueType $option.id 'id'; ValueType $option.label 'short'
    if ($seen.ContainsKey($option.id)) { Fail 'invalid_schema' }; $seen[$option.id]=$true
   }
  }
  'CHECKPOINT' {
   ObjectFields $p @('checkpoint_id','task_ref','project_id','worktree_ref','artifact_revision','completed','remaining','holds','checks') @('plan_ref','plan_revision','request_id','context_used_pct','context_snapshot')
   ContextMeasurement $p
   if ($p.ContainsKey('request_id')) { ValueType $p.request_id 'id' }
   foreach ($key in @('checkpoint_id','project_id')) { ValueType $p[$key] 'id' }
   foreach ($key in @('task_ref','worktree_ref','artifact_revision')) { ValueType $p[$key] 'short' }
   foreach ($key in @('completed','remaining','holds')) { Values $p[$key] 'long' }
   if ($p.ContainsKey('plan_ref') -ne $p.ContainsKey('plan_revision')) { Fail 'invalid_schema' }
   if ($p.ContainsKey('plan_ref')) { ValueType $p.plan_ref 'short'; ValueType $p.plan_revision 'short' }
   if ($p.checks -isnot [array] -or $p.checks.Count -gt 256) { Fail 'invalid_schema' }
   foreach ($check in $p.checks) {
    ObjectFields $check @('check_id','artifact_revision','outcome','evidence_ref')
    ValueType $check.check_id 'id'; ValueType $check.artifact_revision 'short'; ValueType $check.evidence_ref 'short'
    Choice $check.outcome @('passed','failed','not_run')
   }
  }
  'REVIEW_READY' { ObjectFields $p @('checkpoint_id','artifact_revision') @('summary'); ValueType $p.checkpoint_id 'id'; ValueType $p.artifact_revision 'short' }
  'REVIEW_RESULT' {
   ObjectFields $p @('review_id','round','artifact_revision','outcome','findings') @('summary')
   ValueType $p.review_id 'id'; ValueType $p.round 'positive'; ValueType $p.artifact_revision 'short'; Choice $p.outcome @('approved','changes_required')
   Findings $p.findings
  }
  'DONE' { ObjectFields $p @('checkpoint_id','artifact_revision','summary') @('output_ref'); ValueType $p.checkpoint_id 'id'; ValueType $p.artifact_revision 'short'; ValueType $p.summary 'long'; if ($p.ContainsKey('output_ref')) { ValueType $p.output_ref 'relative' } }
  'CHECK_RESULT' {
   ObjectFields $p @('check_id','argv_sha256','exit_code','output_sha256','head','ran_at_ms')
   ValueType $p.check_id 'id'; ValueType $p.argv_sha256 'digest'; ValueType $p.exit_code 'exit'; ValueType $p.output_sha256 'digest'; ValueType $p.head 'revision'; ValueType $p.ran_at_ms 'nonnegative'
  }
  'CHECKOUT' {
   ObjectFields $p @('worktree_path','common_dir','branch','head','changed_files','changed_overflow','changed_total','dirty') @('base')
   ValueType $p.worktree_path 'absolute'; ValueType $p.common_dir 'absolute'; ValueType $p.branch 'branch'; ValueType $p.head 'revision'
   if ($p.ContainsKey('base')) { ValueType $p.base 'revision' }
   Values $p.changed_files 'path' 0 512; Unique $p.changed_files
   ValueType $p.changed_total 'nonnegative'
   if ($p.changed_overflow -isnot [bool] -or $p.dirty -isnot [bool]) { Fail 'invalid_schema' }
   # A sorted prefix may be shorter than 512 when the full list would exceed the report bound.
   if ($p.changed_total -lt $p.changed_files.Count -or $p.changed_overflow -ne ($p.changed_total -gt $p.changed_files.Count)) { Fail 'invalid_schema' }
  }
  'LABEL' { ObjectFields $p @('work_ref','class') @('reason'); ValueType $p.work_ref 'short'; ValueType $p.class 'class'; if ($p.ContainsKey('reason')) { ValueType $p.reason 'short' } }
  'DEPLOY_RESULT' {
   ObjectFields $p @('deploy_id','attempt_id','landing_id','outcome','revision','evidence') @('reason')
   foreach ($key in @('deploy_id','attempt_id','landing_id')) { ValueType $p[$key] 'id' }
   Choice $p.outcome @('deployed','held','not_applicable','failed'); ValueType $p.revision 'short'
   Values $p.evidence 'short' 0 16
   if ($p.ContainsKey('reason')) { ValueType $p.reason 'short' }
  }
  'ROLLOVER_REQUEST' { ObjectFields $p @('checkpoint_id','reason'); ValueType $p.checkpoint_id 'id'; ValueType $p.reason 'short' }
  'LANDING_REQUEST' {
   ObjectFields $p @('checkpoint_id','project_id','repo_ref','target_ref','target_revision','source_ref','source_revision') @('summary')
   foreach ($key in @('checkpoint_id','project_id')) { ValueType $p[$key] 'id' }
   foreach ($key in @('repo_ref','target_ref','target_revision','source_ref','source_revision')) { ValueType $p[$key] 'short' }
  }
  'LANDING_RESULT' {
   ObjectFields $p @('landing_id','grant_id','project_id','repo_ref','target_ref','target_revision','source_revision','outcome','evidence') @('result_revision','observed_target_revision','reason','pr_ref','summary')
   foreach ($key in @('landing_id','grant_id','project_id')) { ValueType $p[$key] 'id' }
   foreach ($key in @('repo_ref','target_ref','target_revision','source_revision')) { ValueType $p[$key] 'short' }
   Choice $p.outcome @('landed','rejected','stale_target','uncertain')
   foreach ($key in @('result_revision','observed_target_revision','reason','pr_ref')) { if ($p.ContainsKey($key)) { ValueType $p[$key] 'short' } }
   if (($p.outcome -ceq 'landed') -ne $p.ContainsKey('result_revision')) { Fail 'invalid_schema' }
   if (($p.outcome -ceq 'stale_target') -ne $p.ContainsKey('observed_target_revision')) { Fail 'invalid_schema' }
   if ($p.outcome -ceq 'stale_target' -and $p.observed_target_revision -ceq $p.target_revision) { Fail 'invalid_schema' }
   if ($p.outcome -ceq 'landed' -and $p.ContainsKey('reason')) { Fail 'invalid_schema' }
   if ($p.outcome -cin @('rejected','uncertain') -and -not $p.ContainsKey('reason')) { Fail 'invalid_schema' }
  }
  'COORDINATOR_PROPOSAL' {
   if ($p -isnot [hashtable]) { Refuse 'must be an object' }
   foreach ($key in @('owner_id','proposal_id')) { At ('payload.'+$key); ValueType $p[$key] 'id' }
   At 'payload.owner_generation'; ValueType $p.owner_generation 'positive'; At 'payload.activation_token'; ValueType $p.activation_token 'digest'
   At 'payload'
   if ($p.kind -isnot [string] -or $p.kind -cnotin @('dispatch','report','review','rollover','landing','new_work','add_source')) { Refuse 'kind must be new_work, add_source, dispatch, report, review, rollover or landing' }
   if ($p.kind -cin @('new_work','add_source')) {
    ProposedWork $p
   } else {
    ObjectFields $p @('owner_id','owner_generation','activation_token','proposal_id','kind','work_id','project_id') @('checkpoint_id','record_id','record_revision','prompt')
    foreach ($key in @('work_id','project_id')) { At ('payload.'+$key); ValueType $p[$key] 'id' }
    At 'payload'
   if ($p.kind -ceq 'dispatch') {
    if ($p.ContainsKey('checkpoint_id')) { Refuse 'dispatch takes no checkpoint_id' }
    At 'payload.record_id'; ValueType $p.record_id 'short'; At 'payload.prompt'; ValueType $p.prompt 'long'
    At 'payload.record_revision'; ValueType $p.record_revision 'nonnegative'
   } else {
    foreach ($key in @('record_id','record_revision','prompt')) { if ($p.ContainsKey($key)) { Refuse ($p.kind+' takes no '+$key) } }
    if ($p.kind -ceq 'report') { if ($p.ContainsKey('checkpoint_id')) { Refuse 'report takes no checkpoint_id' } }
    else { At 'payload.checkpoint_id'; ValueType $p.checkpoint_id 'id' }
   }
   }
  }
  'PROJECT_START_CLAIM' { ProjectStart $p }
  'COORDINATOR_RELEASE' {
   ObjectFields $p @('owner_id','owner_generation','activation_token','quiescent')
   ValueType $p.owner_id 'id'; ValueType $p.owner_generation 'positive'; ValueType $p.activation_token 'digest'
   if ($p.quiescent -isnot [bool] -or -not $p.quiescent) { Fail 'invalid_schema' }
  }
  'reply_ack' {
   ObjectFields $p @('message_id','reply_seq','reply_sha256','status')
   ValueType $p.message_id 'id'; ValueType $p.reply_seq 'positive'; ValueType $p.reply_sha256 'digest'; Choice $p.status @('recorded')
  }
 }
 if ($p.ContainsKey('evidence')) { Values $p.evidence 'short' }
 if ($p.ContainsKey('summary') -and $Report.kind -cne 'DONE') { ValueType $p.summary 'short' }
}
function PublishPending($Pending,[bool]$Drain=$false) {
 $bytes=[Convert]::FromBase64String($Pending.bytes); if ((Hash $bytes) -cne $Pending.sha256) { Fail 'journal_corrupt' }
 if ($Pending.kind -ceq 'PROJECT_START_CLAIM' -and (-not (Capable 'coordinator-control-v1') -or -not (Capable 'project-start-v1'))) { Fail 'unsupported_capability' }
 $count=[int][Math]::Ceiling($bytes.Length/2048.0)
 for ($i=1;$i -le $count;$i++) {
  $length=[Math]::Min(2048,$bytes.Length-($i-1)*2048); $part=New-Object byte[] $length; [Array]::Copy($bytes,($i-1)*2048,$part,0,$length)
  $chunk=[ordered]@{transport='report-files-v1';version=1;type='chunk';mailbox_handle=$Handle;direction='report';slot=$Pending.seq;message_id=$Pending.event_id;message_sha256=$Pending.sha256;index=$i;count=$count;data_b64=[Convert]::ToBase64String($part)}
  Publish ('reports/'+$Pending.seq+'/chunk-'+$i+'.json') (Encode $chunk) $Drain
 }
 $manifest=[ordered]@{transport='report-files-v1';version=1;type='manifest';mailbox_handle=$Handle;direction='report';slot=$Pending.seq;message_id=$Pending.event_id;message_sha256=$Pending.sha256;message_bytes=$bytes.Length;count=$count}
 Publish ('reports/'+$Pending.seq+'/manifest.json') (Encode $manifest) $Drain
}
function Allocate($InputReport,$Consumption=$null) {
 # Closed payload/envelope validation precedes reading or advancing next_seq.
 ReportInput $InputReport
 if ($InputReport.kind -ceq 'PROJECT_START_CLAIM' -and (-not (Capable 'coordinator-control-v1') -or -not (Capable 'project-start-v1'))) { Fail 'unsupported_capability' }
 $control=$InputReport.kind -eq 'reply_ack'; $count=0; [long]$total=0
 foreach ($p in $script:journal.pending) { if (($p.kind -eq 'reply_ack') -eq $control) { $count++; $total+=$p.length } }
 if ($count -ge 8) { $resource='pending_reports'; if ($control) { $resource='pending_reply_ack' }; Full $resource ($count+1) 8 }
 [long]$seq=$script:journal.next_seq; if ($seq -lt 1 -or $seq -ge 9007199254740991) { Fail 'journal_corrupt' }
 $event=Hash ($utf8.GetBytes($Handle+':report:'+$seq))
 $report=@{version=3;event_id=$event;seq=$seq}
 foreach ($key in @('logical_session_id','worker_id','worker_generation','launch_request_id','work_id','enrolment_token')) { $report[$key]=$binding[$key] }
 foreach ($key in $InputReport.Keys) { $report[$key]=$InputReport[$key] }
 $bytes=Encode $report; $limit=65536; if ($control) { $limit=2048 }
 if ($bytes.Length -gt $limit) { Fail 'oversize' }
 $null=Decode $bytes $limit
 if (-not $control -and $total+$bytes.Length -gt 524288) { Full 'pending_report_bytes' ($total+$bytes.Length) 524288 }
 $pending=@{seq=$seq;event_id=$event;kind=$report.kind;bytes=[Convert]::ToBase64String($bytes);sha256=(Hash $bytes);length=$bytes.Length}
 $script:journal.pending+=,$pending; $script:journal.next_seq=$seq+1
 if ($null -ne $Consumption) { $Consumption.ack_seq=$seq }
 # Admit journal replacement and the entire publication under one shared lock.
 # No target allocation can consume that space between admission and commit.
 EnterCapacity
 try {
  $nextBytes=JournalBytes; $oldBytes=(ReadFile $journalPath 1572864).Length
  $chunks=[int][Math]::Ceiling($bytes.Length/2048.0)
  Capacity ($nextBytes.Length+4096*$chunks+2048) ($chunks+2) $control $oldBytes 1
  Save $control
  PublishPending $pending $control
 } finally { LeaveCapacity }
 return $pending
}
function CollectReceipts {
 while ($true) {
  [long]$next=$script:journal.receipt_seq+1; $path=Join-Path $box ('acks/'+$next+'.json')
  if (-not (Test-Path -LiteralPath $path)) { break }
  $pending=@($script:journal.pending | Where-Object { $_.seq -eq $next })
  if ($pending.Count -ne 1) { Fail 'journal_corrupt' }
  $p=$pending[0]; $ack=Decode (ReadFile $path 2048) 2048
  Fields $ack @('version','logical_session_id','worker_id','worker_generation','launch_request_id','work_id','event_id','seq','event_sha256','committed_revision','disposition','receipt_chain_sha256')
  MatchBinding $ack
  if ($ack.version -ne 1 -or $ack.seq -ne $next -or $ack.event_id -cne $p.event_id -or $ack.event_sha256 -cne $p.sha256 -or $ack.disposition -cne 'accepted' -or $ack.committed_revision -lt 1 -or $ack.committed_revision -gt 9007199254740991 -or $ack.committed_revision%1 -ne 0) { Fail 'binding_mismatch' }
  $previous=New-Object byte[] 32; for ($i=0;$i -lt 32;$i++) { $previous[$i]=[Convert]::ToByte($script:journal.receipt_chain.Substring($i*2,2),16) }
  $suffix=$utf8.GetBytes([string]$next+"`n"+$p.event_id+"`n"+$p.sha256+"`n"+$ack.committed_revision+"`n")
  $chain=Hash ([byte[]]($previous+$suffix)); if ($chain -cne $ack.receipt_chain_sha256) { Fail 'content_conflict' }
  $script:journal.receipt_seq=$next; $script:journal.receipt_chain=$chain
  $script:journal.pending=@($script:journal.pending | Where-Object { $_.seq -ne $next })
  foreach ($c in $script:journal.consumed) { if ($c.ack_seq -eq $next) { $c.acknowledged=$true } }
  # Save cumulative receipts before publishing proof or discarding saved bytes.
  Save
 }
 if ($script:journal.receipt_seq -gt 0) {
  $watermarks=@(); foreach ($path in [IO.Directory]::EnumerateFileSystemEntries((Join-Path $box 'watermarks'))) { $item=Get-Item -LiteralPath $path; if ($item.Name -notmatch '^([1-9][0-9]*)\.json$') { Fail 'journal_corrupt' }; $null=ReadFile $path 2048; $watermarks+=,@{seq=[long]$Matches[1];path=$path}; if ($watermarks.Count -gt 3) { Full 'watermark_files' $watermarks.Count 3 } }
  $watermarks=@($watermarks | Sort-Object -Property seq -Descending)
  # Latest cumulative proof must be present before removing surplus older files.
  if ($watermarks.Count -ge 2) {
   $latest=Decode (ReadFile $watermarks[0].path 2048) 2048; MatchBinding $latest $true
   if ($latest.through_seq -gt $script:journal.receipt_seq -or $latest.mailbox_handle -cne $Handle) { Fail 'journal_corrupt' }
   for ($i=2;$i -lt $watermarks.Count;$i++) { [IO.File]::Delete($watermarks[$i].path) }
  }
  $wm=[ordered]@{version=1;type='receipt_watermark';mailbox_handle=$Handle;through_seq=$script:journal.receipt_seq;receipt_chain_sha256=$script:journal.receipt_chain}
  foreach ($key in @('logical_session_id','worker_id','worker_generation','launch_request_id','work_id','enrolment_token')) { $wm[$key]=$binding[$key] }
  Publish ('watermarks/'+$script:journal.receipt_seq+'.json') (Encode $wm) $true
 }
}
function Receipts {
 EnterCapacity
 try { CollectReceipts } finally { LeaveCapacity }
}
function Receive {
 At '' # a refusal in this receive never inherits an earlier call's field path (SKILLS-214)
 # Receipt cursors may already have advanced and remote files may be compacted.
 # Only an explicitly unclaimed retained fact is deliverable; a claim is never
 # permission to execute again, even when its caller lost the claim response.
 $unclaimed=@($script:journal.consumed | Where-Object { $_.execution -ceq 'unclaimed' } | Sort-Object { $_.reply_seq })
 if ($unclaimed.Count -gt 0) {
  $fact=$unclaimed[0]; $saved=[Convert]::FromBase64String($fact.bytes)
  if ($saved.Length -gt 65536 -or (Hash $saved) -cne $fact.sha256) { Fail 'journal_corrupt' }
  $savedReply=Decode $saved
  if ($savedReply.kind -ceq 'record_ruling' -and -not (Capable 'coordinator-control-v1')) { Fail 'unsupported_capability' }
  if ($savedReply.kind -ceq 'project_start' -and (-not (Capable 'coordinator-control-v1') -or -not (Capable 'project-start-v1'))) { Fail 'unsupported_capability' }
  if ($fact.ack_seq -eq 0) {
   $null=Allocate @{kind='reply_ack';action_id=$fact.action_id;action_revision=$fact.action_revision;payload=@{message_id=$fact.message_id;reply_seq=$fact.reply_seq;reply_sha256=$fact.sha256;status='recorded'}} $fact
  } elseif (-not $fact.acknowledged) {
   $pending=@($script:journal.pending | Where-Object { $_.seq -eq $fact.ack_seq })
   if ($pending.Count -ne 1) { Fail 'journal_corrupt' }
   PublishPending $pending[0] $true
  }
  return ,$saved
 }
 [long]$seq=$script:journal.reply_next
 $existing=@($script:journal.consumed | Where-Object { $_.reply_seq -eq $seq })
 if ($existing.Count -gt 0) { Fail 'journal_corrupt' }
 $path=Join-Path $box ('replies/'+$seq+'/manifest.json'); if (-not (Test-Path -LiteralPath $path)) { return $null }
 $manifest=Decode (ReadFile $path 2048) 2048
 Fields $manifest @('transport','version','type','mailbox_handle','direction','slot','message_id','message_sha256','message_bytes','count')
 if ($manifest.transport -cne 'report-files-v1' -or $manifest.version -ne 1 -or $manifest.type -cne 'manifest' -or $manifest.direction -cne 'reply' -or $manifest.mailbox_handle -cne $Handle -or $manifest.slot -ne $seq -or $manifest.message_bytes -lt 1 -or $manifest.message_bytes -gt 65536 -or $manifest.count -ne [Math]::Ceiling($manifest.message_bytes/2048.0)) { Fail 'binding_mismatch' }
 $memory=New-Object IO.MemoryStream
 try {
  for ($i=1;$i -le $manifest.count;$i++) {
   $chunk=Decode (ReadFile (Join-Path $box ('replies/'+$seq+'/chunk-'+$i+'.json')) 4096) 4096
   Fields $chunk @('transport','version','type','mailbox_handle','direction','slot','message_id','message_sha256','index','count','data_b64')
   foreach ($key in @('transport','version','mailbox_handle','direction','slot','message_id','message_sha256','count')) { if ($chunk[$key] -cne $manifest[$key]) { Fail 'content_conflict' } }
   if ($chunk.type -cne 'chunk' -or $chunk.index -ne $i -or $chunk.data_b64 -isnot [string] -or $chunk.data_b64.Length -eq 0 -or $chunk.data_b64.Length -gt 2732 -or $chunk.data_b64.Length%4 -ne 0 -or $chunk.data_b64 -notmatch '^[A-Za-z0-9+/]*={0,2}$') { Fail 'invalid_schema' }
   try { $part=[Convert]::FromBase64String($chunk.data_b64) } catch { Fail 'invalid_schema' }
   if ($part.Length -lt 1 -or $part.Length -gt 2048 -or [Convert]::ToBase64String($part) -cne $chunk.data_b64) { Fail 'invalid_schema' }
   $length=[Math]::Min(2048,$manifest.message_bytes-($i-1)*2048)
   if ($part.Length -ne $length) { Fail 'incomplete' }; $memory.Write($part,0,$part.Length)
  }
  $bytes=$memory.ToArray()
 } finally { $memory.Dispose() }
 if ($bytes.Length -ne $manifest.message_bytes -or (Hash $bytes) -cne $manifest.message_sha256) { Fail 'content_conflict' }
 At ''; $reply=Decode $bytes; MatchBinding $reply
 if ($reply.version -ne 1 -or $reply.reply_seq -ne $seq -or $reply.message_id -cne $manifest.message_id -or $reply.action_id -notmatch '^[A-Za-z0-9_-]{1,96}$' -or $reply.action_revision -lt 1 -or $reply.action_revision%1 -ne 0 -or $reply.action_revision -gt 9007199254740991 -or $reply.kind -cnotin @('assignment','report_request','owner_decision','landing_grant','landing_refresh','coordinator_activation','coordinator_retirement','project_start','review_request','rework','deploy_grant','label_request','record_ruling')) { Fail 'binding_mismatch' }
 $fields=@('version','logical_session_id','worker_id','worker_generation','launch_request_id','work_id','message_id','reply_seq','action_id','action_revision','kind','payload')
 if ($reply.kind -cin @('owner_decision','record_ruling')) { $fields+=@('gate_id','gate_revision') }
 Fields $reply $fields
 if ($reply.message_id -notmatch '^[A-Za-z0-9_-]{1,96}$') { Fail 'invalid_schema' }
 $p=$reply.payload
 switch ($reply.kind) {
  'assignment' {
   Fields $p @('assignment_ref','assignment_sha256','instructions')
   if ($p.assignment_sha256 -notmatch '^[0-9a-f]{64}$' -or $p.assignment_ref -isnot [string] -or $utf8.GetByteCount($p.assignment_ref) -lt 1 -or $utf8.GetByteCount($p.assignment_ref) -gt 1024 -or $p.instructions -isnot [string] -or $utf8.GetByteCount($p.instructions) -lt 1) { Fail 'invalid_schema' }
   ValueType $p.instructions 'long'
  }
  'report_request' {
   Fields $p @('request_id','requested_kind','reason')
   if ($p.request_id -notmatch '^[A-Za-z0-9_-]{1,96}$' -or $p.requested_kind -cnotin @('HEARTBEAT','CHECKPOINT') -or $p.reason -isnot [string] -or $utf8.GetByteCount($p.reason) -lt 1 -or $utf8.GetByteCount($p.reason) -gt 1024) { Fail 'invalid_schema' }
  }
  'owner_decision' {
   Fields $p @('choice_id','answer')
   if ($reply.gate_id -notmatch '^[A-Za-z0-9_-]{1,96}$' -or $reply.gate_revision -lt 1 -or $reply.gate_revision -gt 9007199254740991 -or $reply.gate_revision%1 -ne 0 -or $p.choice_id -notmatch '^[A-Za-z0-9_-]{1,96}$' -or $p.answer -isnot [string] -or $utf8.GetByteCount($p.answer) -lt 1) { Fail 'invalid_schema' }
   ValueType $p.answer 'long'
  }
  'record_ruling' {
   ObjectFields $p @('path','marker','entry','expected_document_sha256','expected_non_rulings_sha256')
   ValueType $reply.gate_id 'id'; ValueType $reply.gate_revision 'positive'
   ValueType $reply.action_id 'id'; ValueType $reply.action_revision 'positive'
   ValueType $p.path 'absolute'
   ValueType $p.expected_document_sha256 'digest'; ValueType $p.expected_non_rulings_sha256 'digest'
   if ($p.marker -isnot [string] -or $utf8.GetByteCount($p.marker) -gt 256 -or $p.marker -cnotmatch '^orchplus-ruling:[A-Za-z0-9_-]+:[A-Za-z0-9_-]+\z' -or ($p.marker.Split(':')[-1] -cne $reply.gate_id)) { Fail 'invalid_schema' }
   if ($p.entry -isnot [string] -or $utf8.GetByteCount($p.entry) -lt 1 -or $utf8.GetByteCount($p.entry) -gt 8192 -or $p.entry -cmatch '[\x00\r]' -or $p.entry.EndsWith("`n")) { Fail 'invalid_schema' }
   foreach ($line in $p.entry.Split([char]10)) {
    if (-not $line.StartsWith('> ') -or $line.Substring(2) -cmatch '[<>`]') { Fail 'invalid_schema' }
   }
  }
  'landing_grant' {
   ObjectFields $p @('landing_id','grant_id','project_id','checkpoint_id','repo_ref','target_ref','target_revision','source_ref','source_revision','builder_work_id','proof') @('review_id','reviewer_family')
   foreach ($key in @('landing_id','grant_id','project_id','checkpoint_id','builder_work_id')) { ValueType $p[$key] 'id' }
   foreach ($key in @('repo_ref','target_ref','target_revision','source_ref','source_revision')) { ValueType $p[$key] 'short' }
   ObjectFields $p.proof @('mode','artifact_revision','check_refs') @('review_id')
   Choice $p.proof.mode @('cross_family_review','helper_checks','review_disabled'); ValueType $p.proof.artifact_revision 'short'
   Values $p.proof.check_refs 'short' 0 16
   if ($p.proof.mode -ceq 'review_disabled') {
    if ($p.ContainsKey('review_id') -or $p.ContainsKey('reviewer_family') -or $p.proof.ContainsKey('review_id')) { Fail 'invalid_schema' }
   } else {
    ValueType $p.review_id 'id'; ValueType $p.reviewer_family 'family'; ValueType $p.proof.review_id 'id'
    if ($p.proof.review_id -cne $p.review_id) { Fail 'invalid_schema' }
   }
  }
  'review_request' {
   ObjectFields $p @('review_id','round','question_id','builder_work_id','task_ref','source_ref','artifact_revision','scope_paths','findings_prev') @('plan_ref','plan_revision')
   foreach ($key in @('review_id','builder_work_id')) { ValueType $p[$key] 'id' }
   ValueType $p.round 'positive'; Choice $p.question_id @('implements_task_v1')
   foreach ($key in @('task_ref','source_ref','artifact_revision')) { ValueType $p[$key] 'short' }
   Values $p.scope_paths 'scope' 0 64; Findings $p.findings_prev
   if ($p.ContainsKey('plan_ref') -ne $p.ContainsKey('plan_revision')) { Fail 'invalid_schema' }
   if ($p.ContainsKey('plan_ref')) { ValueType $p.plan_ref 'short'; ValueType $p.plan_revision 'short' }
  }
  'rework' {
   ObjectFields $p @('round','artifact_revision','failed_checks','findings') @('review_id')
   if ($p.ContainsKey('review_id')) { ValueType $p.review_id 'id' }
   ValueType $p.round 'positive'; ValueType $p.artifact_revision 'short'
   if ($p.failed_checks -isnot [array] -or $p.failed_checks.Count -gt 16) { Fail 'invalid_schema' }
   foreach ($failed in $p.failed_checks) { Fields $failed @('check_id','exit_code'); ValueType $failed.check_id 'id'; ValueType $failed.exit_code 'exit' }
   Findings $p.findings
  }
  'deploy_grant' {
   Fields $p @('deploy_id','attempt_id','landing_id','revision','target_ref')
   foreach ($key in @('deploy_id','attempt_id','landing_id')) { ValueType $p[$key] 'id' }
   foreach ($key in @('revision','target_ref')) { ValueType $p[$key] 'short' }
  }
  'label_request' {
   Fields $p @('work_ref','classes','text')
   ValueType $p.work_ref 'short'; Values $p.classes 'class' 1 32; Unique $p.classes; ValueType $p.text 'long'
  }
  'landing_refresh' {
   Fields $p @('landing_id','project_id','repo_ref','target_ref','expected_revision','current_revision','reason')
   foreach ($key in @('landing_id','project_id')) { ValueType $p[$key] 'id' }
   foreach ($key in @('repo_ref','target_ref','expected_revision','current_revision','reason')) { ValueType $p[$key] 'short' }
  }
  'project_start' {
   ProjectStart $p
   ValueType $reply.action_id 'id'; ValueType $reply.action_revision 'positive'
  }
  'coordinator_activation' {
   ObjectFields $p @('owner_id','owner_generation','activation_token','instructions')
   ValueType $p.owner_id 'id'; ValueType $p.owner_generation 'positive'; ValueType $p.activation_token 'digest'; ValueType $p.instructions 'long'
   ValueType $reply.action_id 'id'; ValueType $reply.action_revision 'positive'
  }
  'coordinator_retirement' {
   ObjectFields $p @('owner_id','owner_generation','activation_token','reason')
   ValueType $p.owner_id 'id'; ValueType $p.owner_generation 'positive'; ValueType $p.activation_token 'digest'; ValueType $p.reason 'short'
   ValueType $reply.action_id 'id'; ValueType $reply.action_revision 'positive'
  }
 }
 # Grants authorize merging/deploying; only a release-manager-v1 generation consumes them,
 # refused before any receipt or journal change.
 if ($reply.kind -cin @('landing_grant','deploy_grant') -and -not (Capable 'release-manager-v1')) { Fail 'unsupported_capability' }
 # Deliver only to an already provisioned writer. ACK records receipt, not a document write.
 if ($reply.kind -ceq 'record_ruling' -and -not (Capable 'coordinator-control-v1')) { Fail 'unsupported_capability' }
 if ($reply.kind -ceq 'project_start' -and (-not (Capable 'coordinator-control-v1') -or -not (Capable 'project-start-v1'))) { Fail 'unsupported_capability' }
 if ($reply.kind -eq 'report_request' -and $bytes.Length -gt 2048) { Fail 'oversize' }
 CompactJournal
 $retained=0L; foreach ($fact in $script:journal.consumed) { $retained+=[Convert]::FromBase64String($fact.bytes).Length }
 if ($script:journal.consumed.Count -ge 8) { Full 'retained_executions' ($script:journal.consumed.Count+1) 8 }
 if ($retained+$bytes.Length -gt 524288) { Full 'retained_reply_bytes' ($retained+$bytes.Length) 524288 }
 $consumption=@{reply_seq=$seq;message_id=$reply.message_id;sha256=$manifest.message_sha256;action_id=$reply.action_id;action_revision=$reply.action_revision;bytes=[Convert]::ToBase64String($bytes);length=$bytes.Length;ack_seq=0;acknowledged=$false;execution='unclaimed'}
 $script:journal.consumed+=,$consumption; $script:journal.reply_next=$seq+1
 # One atomic commit contains receipt bytes AND its complete pending reply_ack.
 # Admission failure cannot leave a receipt that consumed the ACK's headroom.
 $null=Allocate @{kind='reply_ack';action_id=$reply.action_id;action_revision=$reply.action_revision;payload=@{message_id=$reply.message_id;reply_seq=$seq;reply_sha256=$manifest.message_sha256;status='recorded'}} $consumption
 return ,$bytes
}
function Consume {
 EnterCapacity
 try { $bytes=Receive } finally { LeaveCapacity }
 if ($null -eq $bytes) { return $false }
 # Emit stored UTF-8 bytes, not a locale-dependent Console text re-encoding.
 $stdout=[Console]::OpenStandardOutput()
 $stdout.Write($bytes,0,$bytes.Length); $stdout.Flush()
 return $true
}
# SPAWN supplies these settled cursors only after exact stopped observation and
# ORCH+ authorization. This mode never collects receipts or resolves executions.
function AuthorizedFloor([string]$Value) {
 [long]$floor=0
 if ($Value -cnotmatch '^(0|[1-9][0-9]*)\z' -or -not [long]::TryParse($Value,[ref]$floor) -or $floor -gt 9007199254740991) { Fail 'invalid_schema' }
 return $floor
}
function RetirementBinding {
 $keys=@('logical_session_id','worker_id','worker_generation','launch_request_id','work_id','enrolment_token','mailbox_handle')
 if ($ExpectedBinding.Length -eq 0 -or $ExpectedBinding.Length -gt 2732 -or $ExpectedBinding -cnotmatch '^[A-Za-z0-9+/]*={0,2}\z') { Fail 'invalid_schema' }
 $expectedBytes=[Convert]::FromBase64String($ExpectedBinding)
 if ([Convert]::ToBase64String($expectedBytes) -cne $ExpectedBinding) { Fail 'invalid_schema' }
 $expected=Decode $expectedBytes 2048
 Fields $expected $keys; Fields $binding $keys
 foreach ($key in $keys) {
  $type='id'; if ($key -ceq 'worker_generation') { $type='positive' } elseif ($key -ceq 'enrolment_token') { $type='token' }
  ValueType $expected[$key] $type; ValueType $binding[$key] $type
  if ($binding[$key] -cne $expected[$key]) { Fail 'binding_mismatch' }
 }
 if ($binding.enrolment_token -cne $Owner) { Fail 'binding_mismatch' }
}
# Read-only authorization: never consumes a reply, advances a cursor, or emits ACK.
function WithdrawnTail([long]$Floor) {
 if ($WithdrawnStarts.Length -eq 0) { return }
 if ($WithdrawnStarts.Length -gt 5464 -or $WithdrawnStarts -cnotmatch '^[A-Za-z0-9+/]*={0,2}\z') { Fail 'invalid_schema' }
 $encoded=[Convert]::FromBase64String($WithdrawnStarts)
 if ([Convert]::ToBase64String($encoded) -cne $WithdrawnStarts) { Fail 'invalid_schema' }
 $entries=Decode $encoded 4096
 if ($entries -isnot [array] -or $entries.Count -lt 1 -or $entries.Count -gt 8) { Fail 'invalid_schema' }
 if ($descriptor.capabilities -isnot [array] -or $descriptor.capabilities.Count -lt 1 -or $descriptor.capabilities.Count -gt 8 -or 'coordinator-control-v1' -cnotin $descriptor.capabilities -or 'project-start-v1' -cnotin $descriptor.capabilities) { Fail 'unsupported_capability' }
 $capSeen=[Collections.Hashtable]::new([StringComparer]::Ordinal)
 foreach ($cap in $descriptor.capabilities) {
  if ($cap -isnot [string] -or $cap -cnotin @('report-files-v1','native-ask-v1','worker-poll-v1','argv-v1','coordinator-control-v1','check-runner-v1','release-manager-v1','project-start-v1') -or $capSeen.ContainsKey($cap)) { Fail 'invalid_schema' }
  $capSeen[$cap]=$true
 }
 $expected=@{}; $previous=$Floor
 foreach ($entry in $entries) {
  Fields $entry @('reply_seq','message_id','message_sha256')
  ValueType $entry.reply_seq 'positive'; ValueType $entry.message_id 'id'; ValueType $entry.message_sha256 'digest'
  if ($entry.reply_seq -ne $previous+1) { Fail 'incomplete' }; $previous=$entry.reply_seq
  $expected[[string]$entry.reply_seq]=$entry
 }
 $seen=0; $directory=Join-Path $box 'replies'; DirectorySafe $directory
 foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
  $leaf=[IO.Path]::GetFileName($path)
  if ($leaf -cnotmatch '^[1-9][0-9]{0,15}\z') { Fail 'binding_mismatch' }
  DirectorySafe $path
  if ([long]$leaf -le $Floor) {
   foreach ($file in [IO.Directory]::EnumerateFileSystemEntries($path)) {
    $name=[IO.Path]::GetFileName($file)
    if ($name -cnotmatch '^(manifest|chunk-([1-9]|[12][0-9]|3[0-2]))\.json\z') { Fail 'binding_mismatch' }
    $null=ReadFile $file 4096
   }
   continue
  }
  if (-not $expected.ContainsKey($leaf)) { Fail 'incomplete' }
  $entry=$expected[$leaf]; $seen++
  $manifest=Decode (ReadFile (Join-Path $path 'manifest.json') 2048) 2048
  Fields $manifest @('transport','version','type','mailbox_handle','direction','slot','message_id','message_sha256','message_bytes','count')
  foreach ($key in @('version','slot','message_bytes','count')) { ValueType $manifest[$key] 'positive' }
  ValueType $manifest.message_id 'id'; ValueType $manifest.message_sha256 'digest'
  if ($manifest.transport -cne 'report-files-v1' -or $manifest.version -ne 1 -or $manifest.type -cne 'manifest' -or $manifest.direction -cne 'reply' -or $manifest.mailbox_handle -cne $Handle -or $manifest.slot -ne $entry.reply_seq -or $manifest.message_id -cne $entry.message_id -or $manifest.message_sha256 -cne $entry.message_sha256 -or $manifest.message_bytes -gt 65536 -or $manifest.count -ne [Math]::Ceiling($manifest.message_bytes/2048.0)) { Fail 'binding_mismatch' }
  $files=@([IO.Directory]::EnumerateFileSystemEntries($path))
  if ($files.Count -ne $manifest.count+1) { Fail 'incomplete' }
  foreach ($file in $files) {
   $name=[IO.Path]::GetFileName($file)
   if ($name -ceq 'manifest.json') { continue }
   if ($name -cnotmatch '^chunk-([1-9]|[12][0-9]|3[0-2])\.json\z' -or [int]$Matches[1] -gt $manifest.count) { Fail 'binding_mismatch' }
  }
  $memory=New-Object IO.MemoryStream
  try {
   for ($i=1;$i -le $manifest.count;$i++) {
    $chunk=Decode (ReadFile (Join-Path $path ('chunk-'+$i+'.json')) 4096) 4096
    Fields $chunk @('transport','version','type','mailbox_handle','direction','slot','message_id','message_sha256','index','count','data_b64')
    foreach ($key in @('version','slot','index','count')) { ValueType $chunk[$key] 'positive' }
    foreach ($key in @('transport','version','mailbox_handle','direction','slot','message_id','message_sha256','count')) { if ($chunk[$key] -cne $manifest[$key]) { Fail 'content_conflict' } }
    if ($chunk.type -cne 'chunk' -or $chunk.index -ne $i -or $chunk.data_b64 -isnot [string] -or $chunk.data_b64.Length -eq 0 -or $chunk.data_b64.Length -gt 2732 -or $chunk.data_b64 -cnotmatch '^[A-Za-z0-9+/]*={0,2}\z') { Fail 'invalid_schema' }
    $part=[Convert]::FromBase64String($chunk.data_b64)
    if ([Convert]::ToBase64String($part) -cne $chunk.data_b64 -or $part.Length -ne [Math]::Min(2048,$manifest.message_bytes-($i-1)*2048)) { Fail 'incomplete' }
    $memory.Write($part,0,$part.Length)
   }
   $bytes=$memory.ToArray()
  } finally { $memory.Dispose() }
  if ($bytes.Length -ne $manifest.message_bytes -or (Hash $bytes) -cne $entry.message_sha256) { Fail 'content_conflict' }
  $reply=Decode $bytes
  Fields $reply @('version','logical_session_id','worker_id','worker_generation','launch_request_id','work_id','message_id','reply_seq','action_id','action_revision','kind','payload')
  foreach ($key in @('version','worker_generation','reply_seq','action_revision')) { ValueType $reply[$key] 'positive' }
  foreach ($key in @('logical_session_id','worker_id','launch_request_id','work_id','message_id','action_id')) { ValueType $reply[$key] 'id' }
  foreach ($key in @('logical_session_id','worker_id','worker_generation','launch_request_id','work_id')) { if ($reply[$key] -cne $binding[$key]) { Fail 'binding_mismatch' } }
  if ($reply.version -ne 1 -or $reply.kind -cne 'project_start' -or $reply.reply_seq -ne $entry.reply_seq -or $reply.message_id -cne $entry.message_id) { Fail 'binding_mismatch' }
  ProjectStart $reply.payload
 }
 if ($seen -ne $entries.Count) { Fail 'incomplete' }
}
function RetireAbsent {
 $report=AuthorizedFloor $ReportFloor; $reply=AuthorizedFloor $ReplyFloor
 ValueType $ReceiptChain 'digest'; RetirementBinding
 if ($WithdrawnStarts.Length -gt 0) { Fail 'producer_unsettled' }
 EnterCapacity
 try {
  Capacity 0 0 $true
  if (Test-Path -LiteralPath $journalPath) { Fail 'producer_unsettled' }
  if ($report -ne 0 -or $reply -ne 0 -or $ReceiptChain -cne (Hash ($utf8.GetBytes("report-files-v1`n"+$Handle+"`n")))) { Fail 'producer_unsettled' }
  foreach ($lane in @('reports','replies','acks','watermarks')) {
   $path=Join-Path $box $lane; DirectorySafe $path
   if (@([IO.Directory]::EnumerateFileSystemEntries($path)).Count -ne 0) { Fail 'producer_unsettled' }
  }
 } finally { LeaveCapacity }
}
function WithdrawalPhysical([long]$Report) {
 if ($WithdrawnStarts.Length -eq 0) { return }
 foreach ($name in @('consumer','staging')) {
  $path=Join-Path $box $name; DirectorySafe $path
  if (@([IO.Directory]::EnumerateFileSystemEntries($path)).Count -ne 0) { Fail 'producer_unsettled' }
 }
 $producer=Join-Path $box 'producer'; DirectorySafe $producer
 foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($producer)) {
  $leaf=[IO.Path]::GetFileName($path)
  if ($leaf -cnotin @('journal.json','lock')) { Fail 'producer_unsettled' }
  $limit=128; if ($leaf -ceq 'journal.json') { $limit=1572864 }
  # The producer lock is exclusively held by this invocation; inspect its metadata
  # rather than trying to reopen it. Every other file is bounded and read-only.
  if ($leaf -ceq 'lock') {
   $item=Get-Item -LiteralPath $path -Force
   if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 128) { Fail 'binding_mismatch' }
  } else { $null=ReadFile $path $limit }
 }
 foreach ($name in @('reports','acks','watermarks')) {
  $directory=Join-Path $box $name; DirectorySafe $directory
  foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
   $leaf=[IO.Path]::GetFileName($path)
   if ($name -ceq 'reports') {
    if ($leaf -cnotmatch '^[1-9][0-9]{0,15}\z') { Fail 'binding_mismatch' }
    if ([long]$leaf -gt $Report) { Fail 'producer_unsettled' }
    DirectorySafe $path
    foreach ($part in [IO.Directory]::EnumerateFileSystemEntries($path)) {
     $file=[IO.Path]::GetFileName($part)
     if ($file -cnotmatch '^(manifest|chunk-([1-9]|[12][0-9]|3[0-2]))\.json\z') { Fail 'binding_mismatch' }
     $null=ReadFile $part 4096
    }
   } else {
    if ($leaf -cnotmatch '^[1-9][0-9]{0,15}\.json\z') { Fail 'binding_mismatch' }
    if ($name -ceq 'acks' -and [long][IO.Path]::GetFileNameWithoutExtension($path) -gt $Report) { Fail 'producer_unsettled' }
    $null=ReadFile $path 4096
   }
  }
 }
 foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($box)) {
  $leaf=[IO.Path]::GetFileName($path)
  if ($leaf -cin @('reports','replies','acks','watermarks','producer','consumer','staging','capacity.lock')) { DirectorySafe $path }
  elseif ($leaf -cin @('provision.json','manifest.json','checkout-base')) { $null=ReadFile $path 4096 }
  else { Fail 'binding_mismatch' }
 }
}
function RetireAuthorized {
 $report=AuthorizedFloor $ReportFloor; $reply=AuthorizedFloor $ReplyFloor
 ValueType $ReceiptChain 'digest'; RetirementBinding
 Fields $script:journal @('version','owner','binding','next_seq','pending','receipt_seq','receipt_chain','reply_next','consumed','consumed_reply_floor')
 $keys=@('logical_session_id','worker_id','worker_generation','launch_request_id','work_id','enrolment_token','mailbox_handle')
 Fields $script:journal.binding $keys
 foreach ($key in $keys) {
  $type='id'; if ($key -ceq 'worker_generation') { $type='positive' } elseif ($key -ceq 'enrolment_token') { $type='token' }
  ValueType $script:journal.binding[$key] $type
  if ($script:journal.binding[$key] -cne $binding[$key]) { Fail 'binding_mismatch' }
 }
 if ($script:journal.owner -cne $Owner) { Fail 'binding_mismatch' }
 foreach ($key in @('receipt_seq','next_seq','consumed_reply_floor','reply_next')) {
  $value=$script:journal[$key]
  if (($value -isnot [long] -and $value -isnot [int]) -or $value -lt 0 -or $value -gt 9007199254740991) { Fail 'journal_corrupt' }
 }
 $withdrawalAdmission=$WithdrawnStarts.Length -gt 0
 if ($withdrawalAdmission) { EnterCapacity }
 try {
 if ($withdrawalAdmission) {
  # Authorize the exact physical exception before receipt ingestion can save or
  # publish anything. Keep admission through the final settlement and deletion.
  Capacity 0 0 $true; WithdrawalPhysical $report; WithdrawnTail $reply
  if ($script:journal.pending -isnot [array] -or $script:journal.consumed -isnot [array]) { Fail 'journal_corrupt' }
  if ($script:journal.receipt_seq -lt $report -and (Test-Path -LiteralPath (Join-Path $box ('acks/'+($script:journal.receipt_seq+1)+'.json')))) { CollectReceipts }
 }
 # An unsettled journal is refused before anything is removed; the outer handler reports the
 # definite pre-effect outcome on stdout so SPAWN never records it as uncertain.
 if ($script:journal.receipt_seq -ne $report -or $script:journal.next_seq -ne $report+1 -or $script:journal.consumed_reply_floor -ne $reply -or $script:journal.reply_next -ne $reply+1 -or $script:journal.receipt_chain -cne $ReceiptChain) { Fail 'producer_unsettled' }
 if ($script:journal.pending -isnot [array] -or $script:journal.consumed -isnot [array]) { Fail 'journal_corrupt' }
 if ($script:journal.pending.Count -ne 0) { Fail 'producer_unsettled' }
 foreach ($fact in $script:journal.consumed) {
  if ($fact -isnot [hashtable] -or $fact.acknowledged -isnot [bool] -or -not $fact.acknowledged -or $fact.execution -cne 'resolved') { Fail 'producer_unsettled' }
 }
 EnterCapacity
 try { Capacity 0 0 $true; WithdrawalPhysical $report; WithdrawnTail $reply; $null=ReadFile $journalPath 1572864; [IO.File]::Delete($journalPath) } finally { LeaveCapacity }
 } finally { if ($withdrawalAdmission) { LeaveCapacity } }
}
# Helper-only modes. The provisioned manifest (sha256 bound into the provision binding)
# is the only check source; argv runs without a shell, before any gate or producer lock.
function Capable([string]$Name) {
 if (-not $descriptor.ContainsKey('capabilities')) { return $false }
 Values $descriptor.capabilities 'short' 1 8
 return $Name -cin $descriptor.capabilities
}
function ProvisionedManifest {
 if (-not $descriptor.ContainsKey('manifest_sha256')) { Fail 'manifest_missing' }
 $path=Join-Path $box 'manifest.json'
 if (-not (Test-Path -LiteralPath $path)) { Fail 'manifest_mismatch' }
 try { $bytes=ReadFile $path 4096 } catch { Fail 'manifest_mismatch' }
 if ($descriptor.manifest_sha256 -isnot [string] -or (Hash $bytes) -cne $descriptor.manifest_sha256) { Fail 'manifest_mismatch' }
 $manifest=Decode $bytes 4096
 if ($manifest -isnot [hashtable] -or $manifest.checks -isnot [array] -or $manifest.checks.Count -gt 16) { Fail 'manifest_mismatch' }
 foreach ($check in $manifest.checks) {
  if ($check -isnot [hashtable] -or $check.argv -isnot [array] -or $check.argv.Count -lt 1 -or $check.argv.Count -gt 16) { Fail 'manifest_mismatch' }
  foreach ($argument in $check.argv) { if ($argument -isnot [string] -or $argument.Length -eq 0 -or $utf8.GetByteCount($argument) -gt 512) { Fail 'manifest_mismatch' } }
 }
 if ($manifest.ContainsKey('base_ref') -and $manifest.base_ref -isnot [string]) { Fail 'manifest_mismatch' }
 return $manifest
}
# Same bytes as POSIX `jq -j -c .argv`: only quote, backslash, C0 controls and DEL escape.
function CanonicalArgv([string[]]$Argv) {
 $builder=New-Object Text.StringBuilder; $null=$builder.Append('[')
 for ($i=0;$i -lt $Argv.Length;$i++) {
  if ($i -gt 0) { $null=$builder.Append(',') }
  $null=$builder.Append('"')
  foreach ($c in $Argv[$i].ToCharArray()) {
   $code=[int]$c
   if ($code -eq 34) { $null=$builder.Append('\"') }
   elseif ($code -eq 92) { $null=$builder.Append('\\') }
   elseif ($code -eq 8) { $null=$builder.Append('\b') }
   elseif ($code -eq 9) { $null=$builder.Append('\t') }
   elseif ($code -eq 10) { $null=$builder.Append('\n') }
   elseif ($code -eq 12) { $null=$builder.Append('\f') }
   elseif ($code -eq 13) { $null=$builder.Append('\r') }
   elseif ($code -lt 32 -or $code -eq 127) { $null=$builder.Append('\u'+$code.ToString('x4')) }
   else { $null=$builder.Append($c) }
  }
  $null=$builder.Append('"')
 }
 $null=$builder.Append(']')
 return ,$utf8.GetBytes($builder.ToString())
}
# Windows CRT (CommandLineToArgvW) encoding of one literal argument. PowerShell 5.1's
# native `& $exe @args` drops embedded quotes and empty strings; this never does.
function CrtArgument([string]$Value) {
 if ($Value.Length -gt 0 -and $Value -notmatch '[ \t\n\v"]') { return $Value }
 $builder=New-Object Text.StringBuilder; $null=$builder.Append('"'); $slashes=0
 foreach ($c in $Value.ToCharArray()) {
  if ($c -eq [char]92) { $slashes++; continue }
  if ($c -eq [char]34) { $null=$builder.Append([char]92,2*$slashes+1) } else { $null=$builder.Append([char]92,$slashes) }
  $null=$builder.Append($c); $slashes=0
 }
 $null=$builder.Append([char]92,2*$slashes); $null=$builder.Append('"')
 return $builder.ToString()
}
# PATH lookup only (no alias, function, cmdlet or script); a native .exe is required
# because .cmd/.bat would be re-parsed by cmd.exe.
function Application([string]$Name) {
 $found=@(Get-Command -Name ([Management.Automation.WildcardPattern]::Escape($Name)) -CommandType Application -ErrorAction SilentlyContinue)
 if ($found.Count -eq 0) { return '' }
 $path=$found[0].Path
 if ($path -isnot [string] -or -not $path.EndsWith('.exe',[StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($path)) { return '' }
 return $path
}
# Direct CreateProcess with an argument array, stdin closed, both pipes drained in arrival
# order. Check mode hashes the first 65536 combined bytes (nothing else is kept or
# published); git mode keeps stdout. Returns $null when the program cannot start.
function RunProgram([string]$File,[string[]]$Arguments,[bool]$Check) {
 $info=New-Object Diagnostics.ProcessStartInfo
 $encoded=@(); foreach ($argument in $Arguments) { $encoded+=,(CrtArgument $argument) }
 $info.FileName=$File; $info.Arguments=$encoded -join ' '; $info.WorkingDirectory=$script:checkout
 $info.UseShellExecute=$false; $info.CreateNoWindow=$true
 $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
 $process=New-Object Diagnostics.Process; $process.StartInfo=$info
 try { $null=$process.Start() } catch { $process.Dispose(); return $null }
 $sha=$null; $memory=$null; [long]$taken=0
 if ($Check) { $sha=[Security.Cryptography.SHA256]::Create() } else { $memory=New-Object IO.MemoryStream }
 try {
  # Closed stdin (POSIX </dev/null); a child that already exited may have broken the pipe.
  try { $process.StandardInput.Close() } catch { }
  $streams=@($process.StandardOutput.BaseStream,$process.StandardError.BaseStream)
  $buffers=@((New-Object byte[] 65536),(New-Object byte[] 65536))
  $reads=@{}; for ($i=0;$i -lt 2;$i++) { $reads[$i]=$streams[$i].ReadAsync($buffers[$i],0,65536) }
  while ($reads.Count -gt 0) {
   $open=@($reads.Keys)
   $tasks=New-Object 'System.Threading.Tasks.Task[]' $open.Count
   for ($i=0;$i -lt $open.Count;$i++) { $tasks[$i]=$reads[$open[$i]] }
   $done=$open[[Threading.Tasks.Task]::WaitAny($tasks)]
   $n=$reads[$done].Result
   if ($n -le 0) { $reads.Remove($done); continue }
   if ($Check) {
    $take=[int][Math]::Min([long]$n,65536-$taken)
    if ($take -gt 0) { $null=$sha.TransformBlock($buffers[$done],0,$take,$null,0); $taken+=$take }
   } elseif ($done -eq 0) {
    if ($memory.Length+$n -gt 67108864) { Fail 'oversize' }
    $memory.Write($buffers[$done],0,$n)
   }
   $reads[$done]=$streams[$done].ReadAsync($buffers[$done],0,65536)
  }
  $process.WaitForExit()
  $result=@{code=[long]$process.ExitCode}
  if ($Check) { $null=$sha.TransformFinalBlock((New-Object byte[] 0),0,0); $result.sha256=([BitConverter]::ToString($sha.Hash)).Replace('-','').ToLowerInvariant() }
  else { $result.out=$memory.ToArray() }
  return $result
 } finally {
  if (-not $process.HasExited) { try { $process.Kill() } catch { } }
  $process.Dispose(); if ($null -ne $sha) { $sha.Dispose() }; if ($null -ne $memory) { $memory.Dispose() }
 }
}
# Not named Git/Run: a function named Git would shadow git.exe for `& git` in any scope
# that loads these definitions (the Windows regression suite does).
function GitRun([string[]]$Arguments) {
 $result=RunProgram $script:git $Arguments $false
 if ($null -eq $result) { Fail 'git_unavailable' }
 return $result
}
function GitLine([string[]]$Arguments) {
 $result=GitRun $Arguments
 if ($result.code -ne 0) { return '' }
 return $utf8.GetString($result.out).TrimEnd([char[]]@([char]13,[char]10))
}
# Refusal order: unsupported_capability, manifest_missing, manifest_mismatch, check_undeclared,
# git_unavailable. Not a worktree / unborn HEAD is git_unavailable with a suffix.
function HelperReport {
 if (-not (Capable 'check-runner-v1')) { Fail 'unsupported_capability' }
 $manifest=ProvisionedManifest
 if ($Mode -eq 'run-checks') {
  $declared=@($manifest.checks | Where-Object { $_.check_id -ceq $CheckId })
  if ($CheckId.Length -eq 0 -or $declared.Count -ne 1) { Fail 'check_undeclared' }
  $argv=[string[]]$declared[0].argv
 }
 $script:git=Application 'git'; if ($script:git.Length -eq 0) { Fail 'git_unavailable' }
 $script:checkout=(Get-Location -PSProvider FileSystem).ProviderPath
 $worktree='git_unavailable: not a git worktree'; $revision='^([0-9a-f]{40}|[0-9a-f]{64})\z'
 if ($Mode -eq 'run-checks') {
  $startHead=GitLine @('rev-parse','HEAD'); if ($startHead -cnotmatch $revision) { Fail $worktree }
  $started=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $rest=@(); if ($argv.Length -gt 1) { $rest=$argv[1..($argv.Length-1)] }
  $code=[long]127; $output=Hash ([byte[]]@())
  $program=Application $argv[0]
  if ($program.Length -gt 0) { $run=RunProgram $program $rest $true; if ($null -ne $run) { $code=$run.code; $output=$run.sha256 } }
  $head=GitLine @('rev-parse','HEAD'); if ($head -cnotmatch $revision) { Fail $worktree }
  if ($head -cne $startHead) { Fail 'git_unavailable: HEAD changed while the check ran' }
  return @{kind='CHECK_RESULT';payload=@{check_id=$CheckId;argv_sha256=(Hash (CanonicalArgv $argv));exit_code=$code;output_sha256=$output;head=$head;ran_at_ms=[long]$started}}
 }
 $top=GitLine @('rev-parse','--show-toplevel'); if ($top.Length -eq 0) { Fail $worktree }
 $common=GitLine @('rev-parse','--path-format=absolute','--git-common-dir'); if ($common.Length -eq 0) { Fail $worktree }
 $head=GitLine @('rev-parse','HEAD'); if ($head -cnotmatch $revision) { Fail $worktree }
 $branch=GitLine @('symbolic-ref','--short','-q','HEAD'); if ($branch.Length -eq 0) { $branch='HEAD' }
 # A hyphen-led base_ref would be read as an option: treated as absent, like a failed merge-base.
 $base=''
 if ($manifest.ContainsKey('base_ref') -and $manifest.base_ref.Length -gt 0) {
  if (-not $manifest.base_ref.StartsWith('-')) { $base=GitLine @('merge-base',$manifest.base_ref,'HEAD'); if ($base -cnotmatch $revision) { $base='' } }
 } else {
  # No manifest base_ref: the first checkout pins HEAD as the launch base, so later
  # checkouts still report committed work (including out-of-scope files).
  $pin=Join-Path $box 'checkout-base'
  if (-not (Test-Path -LiteralPath $pin)) {
   $temp=$pin+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
   try { [IO.File]::WriteAllBytes($temp,$utf8.GetBytes($head+"`n")); try { [IO.File]::Move($temp,$pin) } catch [IO.IOException] { } } catch { Fail 'storage_error' } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
  }
  $item=Get-Item -LiteralPath $pin -Force -ErrorAction SilentlyContinue
  if ($null -eq $item -or $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 66) { Fail 'storage_error' }
  $launch=$utf8.GetString([IO.File]::ReadAllBytes($pin)).TrimEnd("`n")
  if ($launch -cnotmatch $revision) { Fail 'storage_error' }
  $base=GitLine @('merge-base',$launch,'HEAD'); if ($base -cnotmatch $revision) { $base='' }
 }
 $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 if ($base.Length -gt 0) {
  $diff=GitRun @('diff','--name-only','-z',($base+'...HEAD')); if ($diff.code -ne 0) { Fail $worktree }
  foreach ($name in $utf8.GetString($diff.out).Split([char]0)) { if ($name.Length -gt 0) { $null=$paths.Add($name) } }
 }
 # Staged, unstaged and untracked; a rename/copy entry carries its original path next.
 $status=GitRun @('status','--porcelain=v1','-z','--untracked-files=all'); if ($status.code -ne 0) { Fail $worktree }
 $entries=$utf8.GetString($status.out).Split([char]0)
 for ($i=0;$i -lt $entries.Length;$i++) {
  $entry=$entries[$i]; if ($entry.Length -eq 0) { continue }
  if ($entry.Length -lt 4) { Fail 'invalid_schema' }
  $null=$paths.Add($entry.Substring(3))
  if ('RC'.Contains([string]$entry[0]) -or 'RC'.Contains([string]$entry[1])) { $i++; if ($i -lt $entries.Length -and $entries[$i].Length -gt 0) { $null=$paths.Add($entries[$i]) } }
 }
 # Bytewise UTF-8 order (jq `unique`): ordinal order of per-byte hex keys.
 $sorted=[string[]]@($paths); $keys=New-Object string[] $sorted.Length
 for ($i=0;$i -lt $sorted.Length;$i++) { $keys[$i]=[BitConverter]::ToString($utf8.GetBytes($sorted[$i])) }
 [Array]::Sort([Array]$keys,[Array]$sorted,[Collections.IComparer][StringComparer]::Ordinal)
 $total=$sorted.Length; $kept=[Math]::Min(512,$total)
 # A shorter sorted prefix (still overflow=true) keeps the report inside the 65536-byte bound.
 while ($true) {
  $files=[string[]]@(); if ($kept -gt 0) { $files=[string[]]$sorted[0..($kept-1)] }
  $payload=@{worktree_path=$top;common_dir=$common;branch=$branch;head=$head;changed_files=$files;changed_overflow=($total -gt $kept);changed_total=[long]$total;dirty=($status.out.Length -gt 0)}
  if ($base.Length -gt 0) { $payload.base=$base }
  $report=@{kind='CHECKOUT';payload=$payload}
  $length=(Encode $report).Length
  if ($length -le 64000 -or $kept -eq 0) { return $report }
  $kept=[int][Math]::Min($kept-1,[Math]::Floor($kept*60000.0/$length))
 }
}
try {
if ($WithdrawnStarts.Length -gt 0 -and $Mode -cne 'retire-authorized') { Fail 'invalid_schema' }
# init takes no input. A report piped here would otherwise vanish silently, so
# probe one byte before any mailbox effect; an empty pipe held open settles after 1s.
if ($Mode -eq 'init' -and [Console]::IsInputRedirected) {
 $stdinProbe=[Console]::OpenStandardInput(); $probeByte=New-Object byte[] 1
 $probeRead=$stdinProbe.ReadAsync($probeByte,0,1)
 $probeReady=$false; try { $probeReady=$probeRead.Wait(1000) } catch { $probeReady=$false }
 if ($probeReady -and $probeRead.Result -gt 0) { [Console]::Error.Write("init takes no input; it only creates a new journal. Publish reports with mode report (stdin = one report object).`n"); exit 1 }
}
if ($Handle -notmatch '^[A-Za-z0-9_-]{1,96}$' -or $Owner -notmatch '^[A-Za-z0-9_-]{16,128}$' -or $Root -notmatch '^[A-Za-z]:[\\/]' -or $Root.Contains('..')) { Fail 'binding_mismatch' }
DirectorySafe $Root; $box=Join-Path $Root $Handle; DirectorySafe $box
$descriptor=Decode (ReadFile (Join-Path $box 'provision.json') 2048) 2048
$binding=$descriptor.binding; if ($descriptor.handle -cne $Handle -or $binding.mailbox_handle -cne $Handle) { Fail 'binding_mismatch' }
# Helper-only reports are produced before the shared gate and producer lock: a long check
# holds neither, and every refusal precedes any journal read or mutation.
$helperReport=$null
if ($Mode -eq 'run-checks' -or $Mode -eq 'checkout') { $helperReport=HelperReport }
$journalPath=Join-Path $box 'producer/journal.json'; $lockPath=Join-Path $box 'producer/lock'
DirectorySafe (Join-Path $box 'producer'); DirectorySafe (Join-Path $box 'staging')
EnterCapacity
try {
 if (Test-Path -LiteralPath $lockPath) { $null=ReadFile $lockPath 128 } else { Capacity 0 1 $true }
 $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
} finally { LeaveCapacity }
$retire=$false; $producerAbsent=$false
try {
 if ($Mode -eq 'init') {
  if (Test-Path -LiteralPath $journalPath) { Fail 'journal_corrupt' }
  foreach ($lane in @('reports','acks','watermarks')) { if (@([IO.Directory]::EnumerateFileSystemEntries((Join-Path $box $lane))).Count -gt 0) { Fail 'journal_corrupt' } }
  $script:journal=@{version=1;owner=$Owner;binding=$binding;next_seq=1;pending=@();receipt_seq=0;receipt_chain=(Hash ($utf8.GetBytes("report-files-v1`n"+$Handle+"`n")));reply_next=1;consumed=@();consumed_reply_floor=0}
  Save $false
  [Console]::Error.Write("journal initialized; next: publish ACCEPTED with mode report`n")
 } elseif ($Mode -eq 'retire-authorized' -and -not (Test-Path -LiteralPath $journalPath)) {
  RetireAbsent; $retire=$true; $producerAbsent=$true
 } else {
  $script:journal=Decode (ReadFile $journalPath 1572864) 1572864
  if ($script:journal.owner -cne $Owner -or $script:journal.version -ne 1) { Fail 'journal_corrupt' }; MatchBinding $script:journal.binding $true
  if ($script:journal.next_seq -ne $script:journal.receipt_seq+$script:journal.pending.Count+1) { Fail 'journal_corrupt' }
  if ($Mode -eq 'report') {
   # Do not reference PowerShell's automatic $input enumerator here: under
   # -File it can consume redirected stdin before this bounded reader runs.
   # Read original bytes, independent of the console's OEM text encoding.
   $reportBuffer=New-Object byte[] 65537; $reportLength=0
   $stdinStream=[Console]::OpenStandardInput()
   try {
    while ($reportLength -lt $reportBuffer.Length) { $n=$stdinStream.Read($reportBuffer,$reportLength,$reportBuffer.Length-$reportLength); if ($n -eq 0) { break }; $reportLength+=$n }
   } finally { $stdinStream.Dispose() }
   if ($reportLength -gt 65536) { Fail 'oversize' }
   if ($reportLength -eq 0) { Fail 'invalid_schema' }
   $reportBytes=New-Object byte[] $reportLength
   [Array]::Copy($reportBuffer,$reportBytes,$reportLength)
   $reportInput=Decode $reportBytes
   # CHECK_RESULT/CHECKOUT exist only through run-checks/checkout, never caller-typed.
   if ($reportInput -is [hashtable] -and $reportInput.kind -cin @('CHECK_RESULT','CHECKOUT')) { Fail 'helper_only_kind' }
   if ($reportInput -is [hashtable] -and $reportInput.kind -ceq 'DEPLOY_RESULT' -and -not (Capable 'release-manager-v1')) { Fail 'unsupported_capability' }
   $null=Allocate $reportInput
  } elseif ($Mode -eq 'run-checks' -or $Mode -eq 'checkout') {
   $null=Allocate $helperReport
  } elseif ($Mode -eq 'replay') {
   foreach ($p in $script:journal.pending) { PublishPending $p $true }
   foreach ($c in $script:journal.consumed) { if ($c.ack_seq -eq 0) { $null=Allocate @{kind='reply_ack';action_id=$c.action_id;action_revision=$c.action_revision;payload=@{message_id=$c.message_id;reply_seq=$c.reply_seq;reply_sha256=$c.sha256;status='recorded'}} $c } }
  } elseif ($Mode -eq 'receipts') { Receipts }
  elseif ($Mode -eq 'consume') { $null=Consume }
  elseif ($Mode -eq 'wait') {
   # A later poll that meets a target's short commit waits it out, not a refusal.
   $watch=[Diagnostics.Stopwatch]::StartNew(); $script:gateWaitMs=10000
   do { Receipts; if (Consume) { break }; if ($watch.Elapsed.TotalSeconds -ge $WaitSeconds) { break }; Start-Sleep -Milliseconds ([Math]::Min($PollMs,[Math]::Max(1,$WaitSeconds*1000-$watch.ElapsedMilliseconds))) } while ($true)
  } elseif ($Mode -eq 'claim' -or $Mode -eq 'resolve') {
   $facts=@($script:journal.consumed | Where-Object { $_.message_id -ceq $MessageId }); if ($facts.Count -ne 1) { Fail 'binding_mismatch' }; $fact=$facts[0]
   if ($Mode -eq 'claim') {
    if ($fact.execution -ne 'unclaimed') { Fail 'uncertain' }
    foreach ($other in $script:journal.consumed) { if ($other.action_id -ceq $fact.action_id -and $other.action_revision -gt $fact.action_revision) { Fail 'binding_mismatch' } }
    $fact.execution='claimed'
   }
   else { if ($fact.execution -ne 'claimed') { Fail 'binding_mismatch' }; $fact.execution='resolved' }
   Save
  } elseif ($Mode -eq 'retire-authorized') {
   RetireAuthorized; $retire=$true
  } elseif ($Mode -eq 'retire-local') {
   if ($script:journal.pending.Count -ne 0) { Fail 'incomplete' }
   foreach ($c in $script:journal.consumed) { if (-not $c.acknowledged -or $c.execution -cne 'resolved') { Fail 'incomplete' } }
   EnterCapacity
   try { [IO.File]::Delete($journalPath); $retire=$true } finally { LeaveCapacity }
  }
 }
} finally { $lock.Dispose() }
# The OS already released the exclusive lock handle. Its retained file is inventory, so
# it is removed under the gate; the journal is gone, so a busy gate is waited out.
if ($retire) {
 $script:gateWaitMs=10000; EnterCapacity
 try { [IO.File]::Delete($lockPath) } finally { LeaveCapacity }
}
if ($retire -and $Mode -eq 'retire-authorized') {
 if ($producerAbsent) { [Console]::Out.Write("producer_absent`n") }
 else { [Console]::Out.Write("producer_retired`n") }
}
} catch {
 if ($_.Exception.Message.StartsWith("full`n") -or $_.Exception.Message.StartsWith("invalid_schema`n")) {
  [Console]::Error.Write($_.Exception.Message+"`n"); exit 1
 }
 if ($Mode -eq 'retire-authorized' -and $_.Exception.Message -ceq 'producer_unsettled') { [Console]::Out.Write("producer_unsettled`n"); exit 0 }
 throw
}
