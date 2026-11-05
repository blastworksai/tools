# Fixed report-files-v1 filesystem primitive. No runtime public paths or code.
param([string]$Root,[string]$Handle,[string]$Mode,[string]$Selected,[string]$Operation,[string]$Identity,[long]$ReportFloor,[long]$ReplyFloor,[string]$ProducerHelper)
$ErrorActionPreference='Stop'
$script:capacityHeld=$false
$script:tempOwned=$false
function ReleaseCapacity {
 if ($script:capacityHeld) {
  [IO.Directory]::Delete((Join-Path $box 'capacity.lock'),$false)
  $script:capacityHeld=$false
 }
}
function Finish([string]$Status) {
 if ($script:tempOwned) { [IO.File]::Delete($tmp); $script:tempOwned=$false }
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
function InputBytes {
 $chars=New-Object char[] 5466; $length=0
 while ($length -lt 5466) { $n=[Console]::In.Read($chars,$length,5466-$length); if ($n -eq 0) { break }; $length+=$n }
 if ($length -eq 0) { Finish 'binding_mismatch' }
 $encoded=(-join $chars[0..($length-1)]).TrimEnd("`n")
 if ($encoded.Length -eq 0 -or $encoded.Length -gt 5464 -or $encoded -notmatch '^[A-Za-z0-9+/]*={0,2}$') { Finish 'binding_mismatch' }
 $bytes=[Convert]::FromBase64String($encoded)
 if ($bytes.Length -gt 4096 -or [Convert]::ToBase64String($bytes) -cne $encoded) { Finish 'binding_mismatch' }
 return ,$bytes
}
try {
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
 $box=Join-Path $Root $Handle
 if ($Mode -eq 'provision') {
  if (Test-Path -LiteralPath $box) { Finish 'content_conflict' }
  # New-Item without Force refuses an existing directory; no merge admission.
  $null=New-Item -ItemType Directory -Path $box
  foreach ($name in @('reports','replies','acks','watermarks','producer','consumer','staging')) { $null=New-Item -ItemType Directory -Path (Join-Path $box $name) }
 } elseif (-not (Test-Path -LiteralPath $box)) { if ($Mode -eq 'reconcile_retire') { Finish 'retired' }; Finish 'missing' }
 SafeDirectory $box
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
  foreach ($name in @('reports','replies','acks')) {
   $floor=$ReportFloor; if ($name -eq 'replies') { $floor=$ReplyFloor }
   foreach ($path in [IO.Directory]::EnumerateFileSystemEntries((Join-Path $box $name))) {
    $leaf=[IO.Path]::GetFileName($path); if ($name -eq 'acks') { $leaf=[IO.Path]::GetFileNameWithoutExtension($path) }
    if ($leaf -notmatch '^[1-9][0-9]{0,15}$') { Finish 'binding_mismatch' }
    if ([long]$leaf -gt $floor) { if ($Mode -eq 'retire') { Finish 'incomplete' }; continue }
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
  $null=Regular (Join-Path $box 'provision.json'); [IO.File]::Delete((Join-Path $box 'provision.json'))
  ReleaseCapacity
  [IO.Directory]::Delete($box,$false); Finish 'retired'
 }
 if ($Mode -notin @('provision','publish','reconcile','reconcile_provision')) { Finish 'binding_mismatch' }
 $final=Join-Path $box $Selected; $parent=[IO.Path]::GetDirectoryName($final)
 if ($Mode -in @('reconcile','reconcile_provision')) {
  if (-not (Test-Path -LiteralPath $final)) { Finish 'missing' }
  if (-not (Exact (ReadBounded $final) $bytes)) { Finish 'content_conflict' }
  if ($Mode -eq 'reconcile_provision') { Finish 'provisioned' }; Finish 'already_published'
 }
 # Existing exact immutable bytes need no new space, including at saturation.
 if (Test-Path -LiteralPath $final) {
  if (-not (Exact (ReadBounded $final) $bytes)) { Finish 'content_conflict' }
  Finish 'already_published'
 }
 Capacity $bytes.Length 1 ($Selected -match '^(acks|watermarks)/')
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
