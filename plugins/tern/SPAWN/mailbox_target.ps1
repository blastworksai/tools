# Fixed report-files-v1 filesystem primitive. No runtime public paths or code.
param([string]$Root,[string]$Handle,[string]$Mode,[string]$Selected,[string]$Operation,[string]$Identity,[long]$ReportFloor,[long]$ReplyFloor,[string]$ProducerHelper,[string]$WithdrawnStarts)
$ErrorActionPreference='Stop'
$script:capacityHeld=$false
$script:tempOwned=$false
$script:manifestTemp=''
$script:manifestBytes=$null
function ReleaseCapacity {
 if ($script:capacityHeld) {
  [IO.Directory]::Delete((Join-Path $box 'capacity.lock'),$false)
  $script:capacityHeld=$false
 }
}
function Finish([string]$Status) {
 if ($script:tempOwned) { [IO.File]::Delete($tmp); $script:tempOwned=$false }
 if ($script:manifestTemp.Length -gt 0) { [IO.File]::Delete($script:manifestTemp); $script:manifestTemp='' }
 ReleaseCapacity
 [Console]::Out.Write($Status+"`n"); exit 0
}
function Full([string]$Resource,[long]$Current,[long]$Limit) { Finish ("full`n"+$Resource+"`n"+$Current+"`n"+$Limit) }
function SafeDirectory([string]$Path) {
 $item=Get-Item -LiteralPath $Path -Force
 while ($null -ne $item) {
  if ($item -isnot [IO.DirectoryInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Finish 'binding_mismatch' }
  $item=$item.Parent
 }
}
function Regular([string]$Path) {
 $item=Get-Item -LiteralPath $Path -Force
 if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Finish 'binding_mismatch' }
 return $item
}
function ReadBounded([string]$Path) {
 SafeDirectory ([IO.Path]::GetDirectoryName($Path))
 $item=Regular $Path
 if ($item.Length -gt 4096) { Full 'object_bytes' $item.Length 4096 }
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try {
  $bytes=New-Object byte[] 4097
  $length=0
  while ($length -lt 4097) { $n=$stream.Read($bytes,$length,4097-$length); if ($n -eq 0) { break }; $length+=$n }
  if ($length -gt 4096) { Full 'object_bytes' $length 4096 }
  $result=New-Object byte[] $length; [Array]::Copy($bytes,$result,$length)
  return ,$result
 } finally { $stream.Dispose() }
}
function Exact([byte[]]$A,[byte[]]$B) {
 if ($A.Length -ne $B.Length) { return $false }
 for ($i=0;$i -lt $A.Length;$i++) { if ($A[$i] -ne $B[$i]) { return $false } }
 return $true
}
function TakeCapacity {
 # Shared with the worker, separate from its invocation-long producer lock.
 # A crashed directory lock is an explicit recovery gate, never PID/time-stolen.
 try { $null=New-Item -ItemType Directory -Path (Join-Path $box 'capacity.lock') -ErrorAction Stop }
 catch {
  $gate=Join-Path $box 'capacity.lock'
  if (-not (Test-Path -LiteralPath $gate)) { Finish 'storage_error' }
  SafeDirectory $gate
  if ($Mode -eq 'provision') { Full 'capacity_admission' 1 1 }
  Finish "admission_full`ncapacity_admission`n1`n1"
 }
 $script:capacityHeld=$true
}
function Capacity([int]$ExtraBytes,[int]$ExtraFiles,[bool]$Drain) {
 $files=0; $dirs=0; [long]$total=0
 $pending=New-Object 'System.Collections.Generic.Queue[string]'; $pending.Enqueue($box)
 while ($pending.Count -gt 0) {
  foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($pending.Dequeue())) {
   $item=Get-Item -LiteralPath $path -Force
   if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Finish 'binding_mismatch' }
   if ($item.PSIsContainer) { $dirs++; if ($dirs -gt 1024) { Full 'mailbox_directories' $dirs 1024 }; $pending.Enqueue($path) }
   else { $files++; $total+=$item.Length }
  }
 }
 # Reserve 1.5MiB for a real journal replacement plus 256KiB/16 staging slots.
 # Ordinary publication also leaves 256KiB/112 files for settlement traffic.
 $byteLimit=2097152; $fileLimit=896
 if ($Drain) { $byteLimit=2359296; $fileLimit=1008 }
 if ($files+$ExtraFiles -gt 1024) { Full 'mailbox_files' ($files+$ExtraFiles) 1024 }
 if ($total+$ExtraBytes -gt 4194304) { Full 'mailbox_bytes' ($total+$ExtraBytes) 4194304 }
 if ($files+$ExtraFiles -gt $fileLimit) { Full 'mailbox_files' ($files+$ExtraFiles) $fileLimit }
 if ($total+$ExtraBytes -gt $byteLimit) { Full 'mailbox_bytes' ($total+$ExtraBytes) $byteLimit }
}
# One base64 line per object, each at most 4096 decoded bytes. Provision and its
# reconciliation carry an optional second line: the exact ORCH+ check manifest.
function Base64Line([string]$Encoded) {
 if ($Encoded.Length -eq 0 -or $Encoded.Length -gt 5464 -or $Encoded -notmatch '^[A-Za-z0-9+/]*={0,2}$') { Finish 'binding_mismatch' }
 $bytes=[Convert]::FromBase64String($Encoded)
 if ($bytes.Length -gt 4096 -or [Convert]::ToBase64String($bytes) -cne $Encoded) { Finish 'binding_mismatch' }
 return ,$bytes
}
function InputBytes {
 $chars=New-Object char[] 10931; $length=0
 while ($length -lt 10931) { $n=[Console]::In.Read($chars,$length,10931-$length); if ($n -eq 0) { break }; $length+=$n }
 if ($length -eq 0 -or $length -gt 10930) { Finish 'binding_mismatch' }
 $lines=(-join $chars[0..($length-1)]).TrimEnd("`n").Split("`n")
 $allowed=1; if ($Mode -in @('provision','reconcile_provision')) { $allowed=2 }
 if ($lines.Length -gt $allowed) { Finish 'binding_mismatch' }
 $bytes=Base64Line $lines[0]
 if ($lines.Length -eq 2) { $script:manifestBytes=Base64Line $lines[1] }
 return ,$bytes
}
function Sha([byte[]]$Bytes) {
 $sha=[Security.Cryptography.SHA256]::Create()
 try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
# provision.json names manifest_sha256 exactly when a manifest was provisioned.
function ProvisionedManifestDigest([byte[]]$Bytes) {
 try { $document=(New-Object Text.UTF8Encoding($false,$true)).GetString($Bytes) | ConvertFrom-Json } catch { Finish 'binding_mismatch' }
 if ($document -isnot [Management.Automation.PSCustomObject]) { Finish 'binding_mismatch' }
 $property=@($document.PSObject.Properties | Where-Object { $_.Name -ceq 'manifest_sha256' })
 if ($property.Count -eq 0) { return $null }
 if ($property[0].Value -isnot [string] -or $property[0].Value -cnotmatch '^[0-9a-f]{64}\z') { Finish 'binding_mismatch' }
 return $property[0].Value
}
function ManifestReconciled {
 $path=Join-Path $box 'manifest.json'
 $present=Test-Path -LiteralPath $path
 if ($null -eq $script:manifestBytes) { if ($present) { Finish 'content_conflict' }; return }
 # manifest.json commits before provision.json, so a provisioned box always has it.
 if (-not $present -or -not (Exact (ReadBounded $path) $script:manifestBytes)) { Finish 'content_conflict' }
}
$utf8=New-Object Text.UTF8Encoding($false,$true)
function Fail([string]$Code) { Finish $Code }
function Hash([byte[]]$Bytes) { return (Sha $Bytes) }
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
function Fields($Value,[string[]]$Required) {
 if ($Value -isnot [hashtable] -or $Value.Count -ne $Required.Length) { Fail 'invalid_schema' }
 foreach ($key in $Required) { if (-not $Value.ContainsKey($key)) { Fail 'invalid_schema' } }
}
function ObjectFields($Value,[string[]]$Required,[string[]]$Optional=@()) {
 if ($Value -isnot [hashtable]) { Fail 'invalid_schema' }
 foreach ($key in $Required) { if (-not $Value.ContainsKey($key)) { Fail 'invalid_schema' } }
 foreach ($key in $Value.Keys) { if ($key -cnotin $Required -and $key -cnotin $Optional) { Fail 'invalid_schema' } }
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
 if (-not $valid) { Fail 'invalid_schema' }
}
function ProjectStart($p) {
 ObjectFields $p @('owner_id','owner_generation','activation_token','orch_project_id','project_revision','decision_context')
 ValueType $p.owner_id 'id'; ValueType $p.owner_generation 'positive'; ValueType $p.activation_token 'digest'
 ValueType $p.orch_project_id 'id'; ValueType $p.project_revision 'positive'; ValueType $p.decision_context 'digest'
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
try {
 if ($WithdrawnStarts.Length -gt 0 -and $Mode -cnotin @('retire','reconcile_retire')) { Finish 'binding_mismatch' }
 if ($Handle -notmatch '^[A-Za-z0-9_-]{1,96}$' -or $Operation -notmatch '^[A-Za-z0-9_-]{1,96}$' -or $Root -notmatch '^[A-Za-z]:[\\/]' -or $Root.Contains('..')) { Finish 'binding_mismatch' }
 if ([Security.Principal.WindowsIdentity]::GetCurrent().Name -cne $Identity) { Finish 'binding_mismatch' }
 SafeDirectory $Root
 if ($Mode -eq 'provision') {
  SafeDirectory ([IO.Path]::GetDirectoryName($ProducerHelper))
  $null=Regular $ProducerHelper
  $probe=[IO.File]::Open($ProducerHelper,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  $probe.Dispose()
 }
 # Never hold the shared admission lock while waiting for caller stdin.
 if ($Mode -in @('provision','publish','reconcile','reconcile_provision')) { $bytes=InputBytes }
 # The manifest line is present exactly when provision.json binds its sha256.
 if ($Mode -in @('provision','reconcile_provision')) {
  $declared=ProvisionedManifestDigest $bytes
  if (($null -eq $declared) -ne ($null -eq $script:manifestBytes)) { Finish 'binding_mismatch' }
  if ($null -ne $declared -and (Sha $script:manifestBytes) -cne $declared) { Finish 'binding_mismatch' }
 }
 $box=Join-Path $Root $Handle
 if ($Mode -eq 'provision') {
  if (Test-Path -LiteralPath $box) { Finish 'content_conflict' }
  # New-Item without Force refuses an existing directory; no merge admission.
  $null=New-Item -ItemType Directory -Path $box
  foreach ($name in @('reports','replies','acks','watermarks','producer','consumer','staging')) { $null=New-Item -ItemType Directory -Path (Join-Path $box $name) }
 } elseif (-not (Test-Path -LiteralPath $box)) { if ($Mode -eq 'reconcile_retire') { Finish 'retired' }; Finish 'missing' }
 SafeDirectory $box
 # Read-only observation: do not acquire admission or alter a mailbox.
 if ($Mode -eq 'inventory') {
  if ($Selected -notmatch '^[0-9]{1,12}$') { Finish 'binding_mismatch' }
  [long]$staleMs=[long]$Selected
  if ($staleMs -lt 1 -or $staleMs -gt 315360000000) { Finish 'binding_mismatch' }
  [long]$observed=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  [long]$cutoff=$observed-$staleMs
  $files=0; $stale=0; $directories=0
  $pending=New-Object 'System.Collections.Generic.Queue[string]'
  $pending.Enqueue($box)
  while ($pending.Count -gt 0) {
   $directory=$pending.Dequeue()
   SafeDirectory $directory
   foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
    $item=Get-Item -LiteralPath $path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Finish 'binding_mismatch' }
    if ($item.PSIsContainer) {
     $directories++
     if ($directories -gt 1024) { Finish 'storage_error' }
     $relative=$item.FullName.Substring($box.Length).TrimStart('\','/')
     if (($relative -split '[\\/]').Count -gt 3) { Finish 'binding_mismatch' }
     $pending.Enqueue($path)
    } elseif ($item -is [IO.FileInfo]) {
     $files++; if ($files -gt 1000000) { Finish 'storage_error' }
     if (([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeMilliseconds() -le $cutoff) { $stale++ }
    } else { Finish 'binding_mismatch' }
   }
  }
  Finish ('{"observed_at_ms":'+$observed+',"open_files":'+$files+',"stale_files":'+$stale+'}')
 }
 TakeCapacity
 $fixed=$Selected -eq 'provision.json' -or $Selected -match '^(reports|replies)/[1-9][0-9]{0,15}/(manifest|chunk-([1-9]|[12][0-9]|3[0-2]))\.json$' -or $Selected -match '^(acks|watermarks)/[1-9][0-9]{0,15}\.json$'
 if (-not $fixed -and -not ($Mode -eq 'read' -and $Selected -eq 'watermarks') -and -not ($Mode -in @('compact','retire','reconcile_compact','reconcile_retire') -and $Selected -eq '-')) { Finish 'binding_mismatch' }
 if ($Mode -eq 'read') {
  $hint=''
  if ($Selected -eq 'watermarks') {
   [long]$latest=0; $count=0
   foreach ($path in [IO.Directory]::EnumerateFileSystemEntries((Join-Path $box 'watermarks'))) {
    $item=Regular $path; $count++; if ($count -gt 3) { Full 'watermark_files' $count 3 }
    if ($item.Name -notmatch '^([1-9][0-9]{0,15})\.json$') { Finish 'binding_mismatch' }
    [long]$seq=$Matches[1]; if ($seq -gt 9007199254740991) { Finish 'binding_mismatch' }; $latest=[Math]::Max($latest,$seq)
   }
   if ($latest -eq 0) { Finish 'missing' }
   $Selected='watermarks/'+$latest+'.json'; $hint=[string]$latest+"`n"
  }
  $final=Join-Path $box $Selected
  if (-not (Test-Path -LiteralPath $final)) { Finish 'missing' }
  $bytes=ReadBounded $final
  ReleaseCapacity
  [Console]::Out.Write("object`n"+$hint+[Convert]::ToBase64String($bytes)+"`n"); exit 0
 }
 if ($Mode -eq 'reconcile_retire') { Finish 'incomplete' }
 if ($Mode -eq 'reconcile_compact') {
  foreach ($name in @('reports','replies','acks')) {
   $floor=$ReportFloor; if ($name -eq 'replies') { $floor=$ReplyFloor }
   $directory=Join-Path $box $name; SafeDirectory $directory
   foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
    $leaf=[IO.Path]::GetFileName($path); if ($name -eq 'acks') { $leaf=[IO.Path]::GetFileNameWithoutExtension($path) }
    if ($leaf -notmatch '^[1-9][0-9]{0,15}$') { Finish 'binding_mismatch' }
    if ([long]$leaf -le $floor) { Finish 'incomplete' }
   }
  }
  Finish 'compacted'
 }
 if ($Mode -in @('compact','retire')) {
  # Validate every cleanup lane before deleting anything, including lanes only
  # retirement touches. A regular leaf does not make a junction ancestor safe.
  $cleanupLanes=@('reports','replies','acks')
  if ($Mode -eq 'retire') { $cleanupLanes+=@('producer','consumer','staging','watermarks') }
  foreach ($name in $cleanupLanes) { SafeDirectory (Join-Path $box $name) }
  if ($Mode -eq 'retire' -and $WithdrawnStarts.Length -gt 0) {
   $descriptor=Decode (ReadFile (Join-Path $box 'provision.json') 2048) 2048
   $binding=$descriptor.binding
   $keys=@('logical_session_id','worker_id','worker_generation','launch_request_id','work_id','enrolment_token','mailbox_handle')
   Fields $binding $keys
   foreach ($key in $keys) {
    $type='id'; if ($key -ceq 'worker_generation') { $type='positive' } elseif ($key -ceq 'enrolment_token') { $type='token' }
    ValueType $binding[$key] $type
   }
   if ($descriptor.handle -cne $Handle -or $binding.mailbox_handle -cne $Handle -or $ReportFloor -lt 0 -or $ReplyFloor -lt 0 -or $ReportFloor -gt 9007199254740991 -or $ReplyFloor -gt 9007199254740991) { Finish 'binding_mismatch' }
   WithdrawnTail $ReplyFloor
   # Full destructive preflight, including settled prefix and residual lanes. No
   # prefix bytes may disappear when any tail or local-execution evidence fails.
   foreach ($name in @('producer','consumer','staging')) {
    if (@([IO.Directory]::EnumerateFileSystemEntries((Join-Path $box $name))).Count -ne 0) { Finish 'incomplete' }
   }
   foreach ($name in @('reports','replies','acks','watermarks')) {
    $floor=$ReportFloor; if ($name -ceq 'replies') { $floor=$ReplyFloor }
    foreach ($path in [IO.Directory]::EnumerateFileSystemEntries((Join-Path $box $name))) {
     $leaf=[IO.Path]::GetFileName($path)
     if ($name -cin @('acks','watermarks')) {
      if ($leaf -cnotmatch '^[1-9][0-9]{0,15}\.json\z') { Finish 'binding_mismatch' }
      $null=Regular $path
      if ($name -ceq 'acks' -and [long][IO.Path]::GetFileNameWithoutExtension($path) -gt $floor) { Finish 'incomplete' }
     } else {
      if ($leaf -cnotmatch '^[1-9][0-9]{0,15}\z') { Finish 'binding_mismatch' }
      if ($name -ceq 'reports' -and [long]$leaf -gt $floor) { Finish 'incomplete' }
      SafeDirectory $path
      foreach ($part in [IO.Directory]::EnumerateFileSystemEntries($path)) {
       $item=Regular $part
       if ($item.Name -cnotmatch '^(manifest|chunk-([1-9]|[12][0-9]|3[0-2]))\.json\z') { Finish 'binding_mismatch' }
      }
     }
    }
   }
   foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($box)) {
    $leaf=[IO.Path]::GetFileName($path)
    if ($leaf -cin @('reports','replies','acks','watermarks','producer','consumer','staging','capacity.lock')) { SafeDirectory $path }
    elseif ($leaf -cin @('provision.json','manifest.json','checkout-base')) { $null=Regular $path }
    else { Finish 'binding_mismatch' }
   }
  }
  foreach ($name in @('reports','replies','acks')) {
   $floor=$ReportFloor; if ($name -eq 'replies') { $floor=$ReplyFloor }
   foreach ($path in [IO.Directory]::EnumerateFileSystemEntries((Join-Path $box $name))) {
    $leaf=[IO.Path]::GetFileName($path); if ($name -eq 'acks') { $leaf=[IO.Path]::GetFileNameWithoutExtension($path) }
    if ($leaf -notmatch '^[1-9][0-9]{0,15}$') { Finish 'binding_mismatch' }
    if ([long]$leaf -gt $floor -and -not ($Mode -ceq 'retire' -and $name -ceq 'replies' -and $WithdrawnStarts.Length -gt 0)) { if ($Mode -eq 'retire') { Finish 'incomplete' }; continue }
    if ($name -eq 'acks') { $null=Regular $path; [IO.File]::Delete($path) }
    else {
     SafeDirectory $path
     foreach ($part in [IO.Directory]::EnumerateFileSystemEntries($path)) {
      $item=Regular $part
      if ($item.Name -notmatch '^(manifest|chunk-([1-9]|[12][0-9]|3[0-2]))\.json$') { Finish 'binding_mismatch' }
      [IO.File]::Delete($part)
     }
     [IO.Directory]::Delete($path,$false)
    }
   }
  }
  if ($Mode -eq 'compact') { Finish 'compacted' }
  # Nonempty journals/staging retain unresolved claims and block retirement.
  foreach ($name in @('producer','consumer','staging')) { [IO.Directory]::Delete((Join-Path $box $name),$false) }
  foreach ($path in [IO.Directory]::EnumerateFileSystemEntries((Join-Path $box 'watermarks'))) {
   $item=Regular $path; if ($item.Name -notmatch '^[1-9][0-9]{0,15}\.json$') { Finish 'binding_mismatch' }; [IO.File]::Delete($path)
  }
  foreach ($name in @('reports','replies','acks','watermarks')) { [IO.Directory]::Delete((Join-Path $box $name),$false) }
  $manifestPath=Join-Path $box 'manifest.json'
  if (Test-Path -LiteralPath $manifestPath) { $null=Regular $manifestPath; [IO.File]::Delete($manifestPath) }
  $pinPath=Join-Path $box 'checkout-base'
  if (Test-Path -LiteralPath $pinPath) { $null=Regular $pinPath; [IO.File]::Delete($pinPath) }
  $null=Regular (Join-Path $box 'provision.json'); [IO.File]::Delete((Join-Path $box 'provision.json'))
  ReleaseCapacity
  [IO.Directory]::Delete($box,$false); Finish 'retired'
 }
 if ($Mode -notin @('provision','publish','reconcile','reconcile_provision')) { Finish 'binding_mismatch' }
 $final=Join-Path $box $Selected; $parent=[IO.Path]::GetDirectoryName($final)
 if ($Mode -in @('reconcile','reconcile_provision')) {
  if (-not (Test-Path -LiteralPath $final)) { Finish 'missing' }
  if (-not (Exact (ReadBounded $final) $bytes)) { Finish 'content_conflict' }
  if ($Mode -eq 'reconcile_provision') { ManifestReconciled; Finish 'provisioned' }; Finish 'already_published'
 }
 # Existing exact immutable bytes need no new space, including at saturation.
 if (Test-Path -LiteralPath $final) {
  if (-not (Exact (ReadBounded $final) $bytes)) { Finish 'content_conflict' }
  Finish 'already_published'
 }
 $manifestLength=0; $manifestFiles=0
 if ($Mode -eq 'provision' -and $null -ne $script:manifestBytes) { $manifestLength=$script:manifestBytes.Length; $manifestFiles=1 }
 Capacity ($bytes.Length+$manifestLength) (1+$manifestFiles) ($Selected -match '^(acks|watermarks)/')
 if (-not (Test-Path -LiteralPath $parent)) {
  if ($Mode -ne 'publish' -or $Selected -notmatch '^replies/') { Finish 'missing' }
  SafeDirectory (Join-Path $box 'replies'); $null=New-Item -ItemType Directory -Path $parent
 }
 SafeDirectory $parent; SafeDirectory (Join-Path $box 'staging')
 $tmp=Join-Path $box ('staging/'+$Operation+'.tmp')
 $stream=[IO.File]::Open($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 $script:tempOwned=$true
 try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
 if ($Mode -eq 'provision') {
  $sha=[Security.Cryptography.SHA256]::Create()
  try { $probe=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('abc')))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
  if ($probe -cne 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') { Finish 'storage_error' }
 }
 # manifest.json is written and read back before provision.json commits the box.
 if ($manifestFiles -eq 1) {
  $manifestFinal=Join-Path $box 'manifest.json'; $manifestTmp=Join-Path $box ('staging/'+$Operation+'.manifest.tmp')
  $stream=[IO.File]::Open($manifestTmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  $script:manifestTemp=$manifestTmp
  try { $stream.Write($script:manifestBytes,0,$script:manifestBytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
  [IO.File]::Move($manifestTmp,$manifestFinal); $script:manifestTemp=''
  if (-not (Exact (ReadBounded $manifestFinal) $script:manifestBytes)) { Finish 'content_conflict' }
 }
 $status='published'
 try { [IO.File]::Move($tmp,$final) }
 catch [IO.IOException] {
  if (-not (Test-Path -LiteralPath $final)) { throw }
  if (-not (Exact (ReadBounded $final) $bytes)) { Finish 'content_conflict' }
  [IO.File]::Delete($tmp); $status='already_published'
 }
 $script:tempOwned=$false
 if (-not (Exact (ReadBounded $final) $bytes)) { Finish 'content_conflict' }
 if ($Mode -eq 'provision') { $status='provisioned' }; Finish $status
} catch { Finish 'storage_error' }
