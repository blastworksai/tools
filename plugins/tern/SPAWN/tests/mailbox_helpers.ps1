# Run explicitly on Windows: powershell -NoProfile -File tests/mailbox_helpers.ps1
# Uses private temporary mailboxes only. No installed worker, host, or live mailbox.
# Function-level crash injection uses the production AST, not production test hooks.
param()
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT') { throw 'These helper regressions require Windows PowerShell or PowerShell on Windows.' }
$utf8=New-Object Text.UTF8Encoding($false,$true)
$spawn=Split-Path -Parent $PSScriptRoot
$workerPath=Join-Path $spawn 'mailbox_worker.ps1'
$targetPath=Join-Path $spawn 'mailbox_target.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($workerPath,[ref]$tokens,[ref]$errors)
if ($errors.Count -ne 0) { throw ($errors | Out-String) }
$definitions=@{}
foreach ($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) {
 $definitions[$definition.Name]=$definition.Extent.Text
 . ([scriptblock]::Create($definition.Extent.Text))
}
$targetAst=[Management.Automation.Language.Parser]::ParseFile($targetPath,[ref]$tokens,[ref]$errors)
if ($errors.Count -ne 0) { throw ($errors | Out-String) }
$targetDirectoryDefinition=$targetAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'SafeDirectory'},$false).Extent.Text
function TargetDirectory([string]$Path) {
 function Finish([string]$Status) { throw $Status }
 . ([scriptblock]::Create($targetDirectoryDefinition))
 SafeDirectory $Path
}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('spawn-mailbox-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($testRoot)
$Root=$testRoot; $Owner='regression_owner_1234'; $script:capacityDepth=0
$identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$engine=(Get-Process -Id $PID).Path
$children=New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function EqualBytes([byte[]]$Left,[byte[]]$Right) { Assert ([Convert]::ToBase64String($Left) -ceq [Convert]::ToBase64String($Right)) 'Exact logical bytes changed' }
function Reject([scriptblock]$Operation,[string]$Code) {
 $caught=$false
 try { $null=& $Operation } catch { $caught=$true; Assert ($_.Exception.Message.StartsWith($Code)) ('Expected '+$Code+', got '+$_.Exception.Message) }
 Assert $caught ('Expected rejection '+$Code)
}
function Fixture([string]$Prefix='box_') {
 $script:Handle=$Prefix+[Guid]::NewGuid().ToString('N')
 $script:box=Join-Path $testRoot $Handle
 $null=[IO.Directory]::CreateDirectory($box)
 foreach ($lane in @('reports','replies','acks','watermarks','producer','consumer','staging')) { $null=[IO.Directory]::CreateDirectory((Join-Path $box $lane)) }
 $script:binding=@{logical_session_id='session';worker_id='worker';worker_generation=1;launch_request_id='launch';work_id='work';enrolment_token='enrolment_token_1234';mailbox_handle=$Handle}
 [IO.File]::WriteAllBytes((Join-Path $box 'provision.json'),(Encode @{handle=$Handle;binding=$binding}))
 # The real entrypoint retains this zero-byte producer lock file between calls.
 [IO.File]::WriteAllBytes((Join-Path $box 'producer/lock'),[byte[]]@())
 $script:journalPath=Join-Path $box 'producer/journal.json'
 $script:journal=@{version=1;owner=$Owner;binding=$binding;next_seq=1;pending=@();receipt_seq=0;receipt_chain=(Hash ($utf8.GetBytes("report-files-v1`n"+$Handle+"`n")));reply_next=1;consumed=@();consumed_reply_floor=0}
 Save $false
}
function Reload { $script:journal=Decode (ReadFile $journalPath 1572864) 1572864 }
function ReadReply { EnterCapacity; try { return ,(Receive) } finally { LeaveCapacity } }
function Usage {
 $items=@(Get-ChildItem -LiteralPath $box -File -Force -Recurse)
 return @{bytes=[long](($items | Measure-Object -Property Length -Sum).Sum);files=$items.Count}
}
function PadTo([long]$Bytes) {
 $current=Usage; Assert ($Bytes -ge $current.bytes) 'Fixture already exceeds requested padding'
 $file=[IO.File]::Open((Join-Path $box 'consumer/filler'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try { $file.SetLength($Bytes-$current.bytes) } finally { $file.Dispose() }
}
function ReplyBytes([long]$Sequence=1) {
 $reply=@{version=1;message_id=('reply_'+$Sequence);reply_seq=$Sequence;action_id='action';action_revision=$Sequence;kind='assignment';payload=@{assignment_ref='fixture';assignment_sha256=('a'*64);instructions=('preserve '+[char]0x00E9+' exactly')}}
 foreach ($key in @('logical_session_id','worker_id','worker_generation','launch_request_id','work_id')) { $reply[$key]=$binding[$key] }
 # Noncanonical whitespace makes decode/re-encode observable.
 return ,$utf8.GetBytes(" `n"+$utf8.GetString((Encode $reply))+" `t")
}
function InstallReply([byte[]]$Bytes,[long]$Sequence=1) {
 $directory=Join-Path $box ('replies/'+$Sequence); $null=[IO.Directory]::CreateDirectory($directory)
 $digest=Hash $Bytes; $count=[int][Math]::Ceiling($Bytes.Length/2048.0)
 for ($index=1;$index -le $count;$index++) {
  $length=[Math]::Min(2048,$Bytes.Length-($index-1)*2048); $part=New-Object byte[] $length
  [Array]::Copy($Bytes,($index-1)*2048,$part,0,$length)
  $chunk=@{transport='report-files-v1';version=1;type='chunk';mailbox_handle=$Handle;direction='reply';slot=$Sequence;message_id=('reply_'+$Sequence);message_sha256=$digest;index=$index;count=$count;data_b64=[Convert]::ToBase64String($part)}
  [IO.File]::WriteAllBytes((Join-Path $directory ('chunk-'+$index+'.json')),(Encode $chunk))
 }
 $manifest=@{transport='report-files-v1';version=1;type='manifest';mailbox_handle=$Handle;direction='reply';slot=$Sequence;message_id=('reply_'+$Sequence);message_sha256=$digest;message_bytes=$Bytes.Length;count=$count}
 [IO.File]::WriteAllBytes((Join-Path $directory 'manifest.json'),(Encode $manifest))
}
function AckBytes {
 $pending=@($journal.pending | Where-Object { $_.seq -eq $journal.receipt_seq+1 })[0]
 $previous=New-Object byte[] 32
 for ($index=0;$index -lt 32;$index++) { $previous[$index]=[Convert]::ToByte($journal.receipt_chain.Substring($index*2,2),16) }
 $suffix=$utf8.GetBytes([string]$pending.seq+"`n"+$pending.event_id+"`n"+$pending.sha256+"`n1`n")
 $ack=@{version=1;event_id=$pending.event_id;seq=$pending.seq;event_sha256=$pending.sha256;committed_revision=1;disposition='accepted';receipt_chain_sha256=(Hash ([byte[]]($previous+$suffix)))}
 foreach ($key in @('logical_session_id','worker_id','worker_generation','launch_request_id','work_id')) { $ack[$key]=$binding[$key] }
 return ,(Encode $ack)
}
function QuoteArg([string]$Argument) { return '"'+$Argument.Replace('"','\"')+'"' }
function StartHelper([string]$Path,[string[]]$Arguments,[string]$InputText='',[byte[]]$RawInput=$null) {
 $info=New-Object Diagnostics.ProcessStartInfo
 $info.FileName=$engine; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
 $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
 $info.StandardOutputEncoding=$utf8; $info.StandardErrorEncoding=$utf8
 $argv=@('-NoProfile','-NonInteractive','-File',$Path)+$Arguments
 $info.Arguments=($argv | ForEach-Object { QuoteArg $_ }) -join ' '
 $process=New-Object Diagnostics.Process; $process.StartInfo=$info
 $null=$process.Start(); $children.Add($process)
 # Windows PowerShell's default process writer can use an OEM code page.
 # Feed the helper's actual UTF-8 byte contract without text-writer conversion.
 $inputBytes=$RawInput; if ($null -eq $inputBytes) { $inputBytes=$utf8.GetBytes($InputText) }; $stdin=$process.StandardInput.BaseStream
 $stdin.Write($inputBytes,0,$inputBytes.Length); $stdin.Flush(); $stdin.Close()
 return $process
}
function FinishHelper($Process,[switch]$RawOutput) {
 $buffer=$null
 try {
  if ($RawOutput) { $buffer=New-Object IO.MemoryStream; $out=$Process.StandardOutput.BaseStream.CopyToAsync($buffer) }
  else { $out=$Process.StandardOutput.ReadToEndAsync() }
  $err=$Process.StandardError.ReadToEndAsync()
  if (-not $Process.WaitForExit(20000)) { $Process.Kill(); throw 'Helper regression timed out' }
  if ($RawOutput) { $out.GetAwaiter().GetResult(); $bytes=$buffer.ToArray(); return @{code=$Process.ExitCode;out=$bytes;err=$err.GetAwaiter().GetResult()} }
  return @{code=$Process.ExitCode;out=$out.GetAwaiter().GetResult();err=$err.GetAwaiter().GetResult()}
 } finally { if ($null -ne $buffer) { $buffer.Dispose() } }
}
function Target([string]$Mode,[string]$Selected,[byte[]]$Bytes=([byte[]]@()),[long]$ReportFloor=0,[long]$ReplyFloor=0) {
 $args=@('-Root:',$Root,'-Handle:',$Handle,'-Mode:',$Mode,'-Selected:',$Selected,'-Operation:',('op_'+[Guid]::NewGuid().ToString('N')),'-Identity:',$identity,'-ReportFloor:',[string]$ReportFloor,'-ReplyFloor:',[string]$ReplyFloor)
 return FinishHelper (StartHelper $targetPath $args ([Convert]::ToBase64String($Bytes)))
}
function Worker([string]$Mode,[string]$InputText='',[string]$Message='',[switch]$RawOutput) {
 $args=@('-Root:',$Root,'-Handle:',$Handle,'-Owner:',$Owner,'-Mode:',$Mode)
 if ($Message -ne '') { $args+=@('-MessageId:',$Message) }
 return FinishHelper (StartHelper $workerPath $args $InputText) -RawOutput:$RawOutput
}
function AuthorizedFixture {
 Fixture '-retire_'
 $binding['enrolment_token']=$Owner
 [IO.File]::WriteAllBytes((Join-Path $box 'provision.json'),(Encode @{handle=$Handle;binding=$binding}))
 $journal['receipt_seq']=2; $journal['next_seq']=3
 $journal['consumed_reply_floor']=1; $journal['reply_next']=2
 $bytes=ReplyBytes
 $journal['consumed']=@(@{reply_seq=1;message_id='reply_1';sha256=(Hash $bytes);action_id='action';action_revision=1;bytes=[Convert]::ToBase64String($bytes);length=$bytes.Length;ack_seq=2;acknowledged=$true;execution='resolved'})
 # Do not Save: compaction would remove the retained resolved fact under test.
 [IO.File]::WriteAllBytes($journalPath,(Encode $journal))
}
function AuthorizedRetire([string]$Report='2',[string]$Reply='1',[string]$Chain=$journal.receipt_chain,[string]$SuppliedOwner=$Owner,[string]$Expected=[Convert]::ToBase64String((Encode $binding))) {
 $args=@('-Root:',$Root,'-Handle:',$Handle,'-Owner:',$SuppliedOwner,'-Mode:','retire-authorized','-ReportFloor:',$Report,'-ReplyFloor:',$Reply,'-ReceiptChain:',$Chain,'-ExpectedBinding:',$Expected)
 return FinishHelper (StartHelper $workerPath $args)
}
function RefusedRetirement([scriptblock]$Operation) {
 $before=[IO.File]::ReadAllBytes($journalPath)
 $unknown=Join-Path $box 'producer/unknown'; $sentinel=$utf8.GetBytes('must retain unknown bytes')
 [IO.File]::WriteAllBytes($unknown,$sentinel)
 $result=& $Operation
 Assert ($result.code -ne 0 -and $result.out -ceq '') 'Authorized retirement accepted unsettled or mismatched state'
 EqualBytes $before ([IO.File]::ReadAllBytes($journalPath))
 EqualBytes $sentinel ([IO.File]::ReadAllBytes($unknown))
 Assert (Test-Path -LiteralPath (Join-Path $box 'producer/lock')) 'Refusal removed producer lock'
}
try {
 # DirectoryInfo.Parent is not a provider-emitted item: no PSIsContainer note
 # property is promised. Both production guards must walk real nested ancestry,
 # reject file leaves, and still reject a junction at the leaf or any ancestor.
 $guard=Join-Path $testRoot 'guard'; $nested=Join-Path $guard 'child'
 $null=[IO.Directory]::CreateDirectory($nested)
 DirectorySafe $nested; TargetDirectory $nested
 $file=Join-Path $guard 'file'; [IO.File]::WriteAllBytes($file,[byte[]]@())
 Reject { DirectorySafe $file } 'binding_mismatch'
 Reject { TargetDirectory $file } 'binding_mismatch'
 $junction=Join-Path $testRoot 'guard-junction'
 $null=New-Item -ItemType Junction -Path $junction -Value $guard
 try {
  Reject { DirectorySafe $junction } 'binding_mismatch'
  Reject { TargetDirectory $junction } 'binding_mismatch'
  Reject { DirectorySafe (Join-Path $junction 'child') } 'binding_mismatch'
  Reject { TargetDirectory (Join-Path $junction 'child') } 'binding_mismatch'
 } finally { [IO.Directory]::Delete($junction) }

 # Real destructive entrypoints reject every redirected cleanup lane before
 # deleting any earlier valid lane or a numeric sentinel in the junction target.
 foreach ($mode in @('compact','retire')) {
  $lanes=@('reports','replies','acks')
  if ($mode -eq 'retire') { $lanes+=@('producer','consumer','staging','watermarks') }
  foreach ($lane in $lanes) {
   Fixture
   if ($mode -eq 'retire') {
    [IO.File]::Delete((Join-Path $box 'producer/journal.json'))
    [IO.File]::Delete((Join-Path $box 'producer/lock'))
   }
   $outside=Join-Path $testRoot ('outside_'+[Guid]::NewGuid().ToString('N'))
   $null=[IO.Directory]::CreateDirectory($outside)
   $sentinel=Join-Path $outside '1.json'; $sentinelBytes=$utf8.GetBytes('external immutable sentinel')
   [IO.File]::WriteAllBytes($sentinel,$sentinelBytes)
   $keptLane='reports'; if ($lane -eq 'reports') { $keptLane='replies' }
   $keptDirectory=Join-Path $box ($keptLane+'/1'); $null=[IO.Directory]::CreateDirectory($keptDirectory)
   $kept=Join-Path $keptDirectory 'manifest.json'; [IO.File]::WriteAllBytes($kept,$sentinelBytes)
   $redirected=Join-Path $box $lane
   Remove-Item -LiteralPath $redirected -Recurse -Force
   $null=New-Item -ItemType Junction -Path $redirected -Value $outside
   try {
    $rejected=Target $mode '-' ([byte[]]@()) 1 1
    Assert ($rejected.code -eq 0 -and $rejected.out -ceq "binding_mismatch`n") ('Cleanup followed redirected '+$lane+' lane in '+$mode)
    EqualBytes $sentinelBytes ([IO.File]::ReadAllBytes($sentinel))
    EqualBytes $sentinelBytes ([IO.File]::ReadAllBytes($kept))
    Assert (Test-Path -LiteralPath (Join-Path $box 'provision.json')) 'Rejected cleanup removed immutable provisioning'
   } finally { [IO.Directory]::Delete($redirected) }
  }
 }

 # Exercise the existing-destination branch explicitly: PowerShell 5.1 must
 # pass a genuine null backup path to atomic File.Replace, not an empty string.
 Fixture; $before=ReadFile $journalPath 1572864
 Save; EqualBytes $before (ReadFile $journalPath 1572864)
 Assert (@(Get-ChildItem -LiteralPath (Join-Path $box 'staging') -Force).Count -eq 0) 'Atomic journal replacement retained staging or a backup'

 # -File must receive the "-" sentinel and leading-hyphen identifiers as data,
 # not as an empty or attacker-selected PowerShell parameter name.
 Fixture '-box_'
 $literal=Target 'reconcile_compact' '-'
 Assert ($literal.code -eq 0 -and $literal.out -ceq "compacted`n") ('Literal target argument binding failed; helper='+ (ConvertTo-Json -InputObject $literal -Compress))
 $literal=Worker 'replay'
 Assert ($literal.code -eq 0 -and $literal.out -ceq '') ('Literal worker argument binding failed; helper='+ (ConvertTo-Json -InputObject $literal -Compress))

 # Actual -File entrypoints: authorization is exact, never an instruction to
 # collect pending receipts, clear claims, or repair a malformed journal.
 foreach ($bad in @('-1','1.5','1e0','true','9007199254740992','9223372036854775808','')) {
  AuthorizedFixture; RefusedRetirement { AuthorizedRetire -Report $bad }
  AuthorizedFixture; RefusedRetirement { AuthorizedRetire -Reply $bad }
 }
 foreach ($bad in @('',('a'*63),('A'*64),(('a'*64)+"`n"))) {
  AuthorizedFixture; RefusedRetirement { AuthorizedRetire -Chain $bad }
 }
 AuthorizedFixture; RefusedRetirement { Worker 'retire-authorized' }
 AuthorizedFixture; RefusedRetirement { AuthorizedRetire -Report '1' }
 AuthorizedFixture; RefusedRetirement { AuthorizedRetire -Report '3' }
 AuthorizedFixture; RefusedRetirement { AuthorizedRetire -Reply '0' }
 AuthorizedFixture; RefusedRetirement { AuthorizedRetire -Reply '2' }
 AuthorizedFixture; RefusedRetirement { AuthorizedRetire -Chain ('b'*64) }
 AuthorizedFixture; RefusedRetirement { AuthorizedRetire -SuppliedOwner 'different_owner_1234' }
 foreach ($mutation in @('token','owner','binding','mailbox','receipt_seq','next_seq','consumed_reply_floor','reply_next','unclaimed','claimed','uncertain','unacknowledged','truthy','pending')) {
  AuthorizedFixture
  switch ($mutation) {
   'token' {
    $binding['enrolment_token']='different_token_1234'
    [IO.File]::WriteAllBytes((Join-Path $box 'provision.json'),(Encode @{handle=$Handle;binding=$binding}))
   }
   'owner' { $journal['owner']='different_owner_1234' }
   'binding' { $journal['binding']=Decode (Encode $binding); $journal.binding['work_id']='other' }
   'mailbox' { $journal['binding']=Decode (Encode $binding); $journal.binding['mailbox_handle']='other' }
   'receipt_seq' { $journal['receipt_seq']=1; $journal['next_seq']=2 }
   'next_seq' { $journal['next_seq']=4 }
   'consumed_reply_floor' { $journal['consumed_reply_floor']=0 }
   'reply_next' { $journal['reply_next']=3 }
   'unclaimed' { $journal.consumed[0]['execution']='unclaimed' }
   'claimed' { $journal.consumed[0]['execution']='claimed' }
   'uncertain' { $journal.consumed[0]['execution']='uncertain' }
   'unacknowledged' { $journal.consumed[0]['acknowledged']=$false }
   'truthy' { $journal.consumed[0]['acknowledged']='true' }
   'pending' { $null=Allocate @{kind='READY';payload=@{state='idle'}} }
  }
  [IO.File]::WriteAllBytes($journalPath,(Encode $journal))
  RefusedRetirement { AuthorizedRetire }
 }
 foreach ($corruption in @('trailing','duplicate','fractional_cursor','string_cursor','object_pending','object_consumed')) {
  AuthorizedFixture
  $wire=$utf8.GetString([IO.File]::ReadAllBytes($journalPath))
  switch ($corruption) {
   'trailing' { $wire+=' true' }
   'duplicate' { $wire='{"owner":"duplicate",'+$wire.Substring(1) }
   'fractional_cursor' { $wire=$wire.Replace('"reply_next":2','"reply_next":2.0') }
   'string_cursor' { $wire=$wire.Replace('"reply_next":2','"reply_next":"2"') }
   'object_pending' { $journal['pending']=@{}; $wire=$utf8.GetString((Encode $journal)) }
   'object_consumed' { $journal['consumed']=@{}; $wire=$utf8.GetString((Encode $journal)) }
  }
  [IO.File]::WriteAllBytes($journalPath,$utf8.GetBytes($wire))
  RefusedRetirement { AuthorizedRetire }
 }
 foreach ($key in @('worker_generation','work_id')) {
  AuthorizedFixture; $expected=Decode (Encode $binding)
  if ($key -ceq 'worker_generation') { $expected[$key]=2 } else { $expected[$key]='other' }
  RefusedRetirement { AuthorizedRetire -Expected ([Convert]::ToBase64String((Encode $expected))) }
 }
 foreach ($bad in @('', '!!!', ('A'*2736), [Convert]::ToBase64String($utf8.GetBytes('{}')), [Convert]::ToBase64String($utf8.GetBytes('{"work_id":"x","work_id":"y"}')))) {
  AuthorizedFixture; RefusedRetirement { AuthorizedRetire -Expected $bad }
 }
 AuthorizedFixture
 $held=[IO.File]::Open((Join-Path $box 'producer/lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try { RefusedRetirement { AuthorizedRetire } } finally { $held.Dispose() }
 AuthorizedFixture
 $null=[IO.Directory]::CreateDirectory((Join-Path $box 'capacity.lock'))
 try { RefusedRetirement { AuthorizedRetire } } finally { [IO.Directory]::Delete((Join-Path $box 'capacity.lock')) }
 AuthorizedFixture; PadTo 2359297
 RefusedRetirement { AuthorizedRetire }

 # Successful producer deletion is narrowly scoped; unknown files are not swept.
 AuthorizedFixture
 $unknown=Join-Path $box 'producer/unknown'; $sentinel=$utf8.GetBytes('retain')
 [IO.File]::WriteAllBytes($unknown,$sentinel)
 $retired=AuthorizedRetire
 Assert ($retired.code -eq 0 -and $retired.out -ceq "producer_retired`n" -and $retired.err -ceq '') 'Authorized producer retirement failed'
 Assert (-not (Test-Path -LiteralPath $journalPath)) 'Authorized retirement retained journal'
 Assert (-not (Test-Path -LiteralPath (Join-Path $box 'producer/lock'))) 'Authorized retirement retained its normal lock'
 EqualBytes $sentinel ([IO.File]::ReadAllBytes($unknown))
 Assert (Test-Path -LiteralPath (Join-Path $box 'provision.json')) 'Producer retirement deleted target provisioning'
 [IO.File]::Delete($unknown)
 $retired=Target 'retire' '-' ([byte[]]@()) 2 1
 Assert ($retired.code -eq 0 -and $retired.out -ceq "retired`n") 'Target retirement failed after authorized producer retirement'
 $replayed=Target 'reconcile_retire' '-' ([byte[]]@()) 2 1
 Assert ($replayed.code -eq 0 -and $replayed.out -ceq "retired`n") 'Retirement replay readback failed'
 Assert (-not (Test-Path -LiteralPath $box)) 'Retirement replay recreated mailbox'

 # Zero floors remain valid for a freshly initialized, exactly bound producer.
 AuthorizedFixture
 $journal['receipt_seq']=0; $journal['next_seq']=1; $journal['consumed_reply_floor']=0; $journal['reply_next']=1; $journal['consumed']=@()
 [IO.File]::WriteAllBytes($journalPath,(Encode $journal))
 $retired=AuthorizedRetire -Report '0' -Reply '0'
 Assert ($retired.code -eq 0 -and $retired.out -ceq "producer_retired`n") 'Zero-floor authorized retirement failed'

 # Every codec report kind has a positive case; each rejects an unknown payload
 # field before journal bytes/next_seq can change.
 $samples=@(
  @{kind='REGISTER';payload=@{capabilities=@('report-files-v1','worker-poll-v1','argv-v1')}},
  @{kind='READY';payload=@{state='idle'}},
  @{kind='ACCEPTED';payload=@{assignment_sha256=('a'*64)}},
  @{kind='HEARTBEAT';payload=@{state='working';request_id='request'}},
  @{kind='WAITING';payload=@{reason='waiting'}},
  @{kind='BLOCKED';payload=@{reason='blocked';evidence=@()}},
  @{kind='ASK';payload=@{question='which?';options=@(@{id='choice';label='Choice'})}},
  @{kind='CHECKPOINT';payload=@{checkpoint_id='cp';task_ref='task';project_id='project';worktree_ref='tree';artifact_revision='rev';completed=@();remaining=@('next');holds=@();checks=@(@{check_id='check';artifact_revision='rev';outcome='not_run';evidence_ref='log'});request_id='request'}},
  @{kind='COORDINATOR_PROPOSAL';payload=@{owner_id='owner';owner_generation=1;activation_token=('a'*64);proposal_id='proposal';kind='review';work_id='work';project_id='project';checkpoint_id='cp'}},
  @{kind='COORDINATOR_PROPOSAL';payload=@{owner_id='owner';owner_generation=1;activation_token=('a'*64);proposal_id='proposal';kind='report';work_id='work';project_id='project'}},
  @{kind='COORDINATOR_PROPOSAL';payload=@{owner_id='owner';owner_generation=1;activation_token=('a'*64);proposal_id='proposal';kind='dispatch';work_id='work';project_id='project';record_id='configured native';record_revision=0;prompt='Explicit task'}},
  @{kind='REVIEW_READY';payload=@{checkpoint_id='cp';artifact_revision='rev'}},
  @{kind='REVIEW_RESULT';action_id='action';action_revision=1;payload=@{artifact_revision='rev';outcome='approved';evidence=@()}},
  @{kind='DONE';payload=@{checkpoint_id='cp';artifact_revision='rev';summary='done'}},
  @{kind='ROLLOVER_REQUEST';payload=@{checkpoint_id='cp';reason='handover'}},
  @{kind='LANDING_REQUEST';payload=@{checkpoint_id='cp';project_id='project';repo_ref='repo';target_ref='main';target_revision='base';source_ref='work';source_revision='rev'}},
  @{kind='LANDING_RESULT';action_id='action';action_revision=1;payload=@{landing_id='landing';grant_id='grant';project_id='project';repo_ref='repo';target_ref='main';target_revision='base';source_revision='rev';outcome='landed';result_revision='head';evidence=@()}},
  @{kind='LANDING_RESULT';action_id='action';action_revision=1;payload=@{landing_id='landing';grant_id='grant';project_id='project';repo_ref='repo';target_ref='main';target_revision='base';source_revision='rev';outcome='rejected';reason='conflict';evidence=@()}},
  @{kind='LANDING_RESULT';action_id='action';action_revision=1;payload=@{landing_id='landing';grant_id='grant';project_id='project';repo_ref='repo';target_ref='main';target_revision='base';source_revision='rev';outcome='stale_target';observed_target_revision='moved';evidence=@()}},
  @{kind='LANDING_RESULT';action_id='action';action_revision=1;payload=@{landing_id='landing';grant_id='grant';project_id='project';repo_ref='repo';target_ref='main';target_revision='base';source_revision='rev';outcome='uncertain';reason='push timed out';evidence=@()}},
  @{kind='reply_ack';action_id='action';action_revision=1;payload=@{message_id='reply';reply_seq=1;reply_sha256=('a'*64);status='recorded'}},
  @{kind='READY';payload=@{state='idle';context_used_pct=0}},
  @{kind='READY';payload=@{state='idle';context_used_pct=100}},
  @{kind='HEARTBEAT';payload=@{state='working';context_used_pct=0}},
  @{kind='HEARTBEAT';payload=@{state='working';context_used_pct=100}}
 )
 foreach ($sample in $samples) {
  Fixture
  $before=ReadFile $journalPath 1572864
  $bad=Decode (Encode $sample); $bad.payload['unexpected']='reject'
  Reject { Allocate $bad } 'invalid_schema'; EqualBytes $before (ReadFile $journalPath 1572864)
  $pending=Allocate (Decode (Encode $sample))
  Assert ($pending.seq -eq 1 -and $journal.next_seq -eq 2) 'Valid report did not allocate exactly once'
  Assert (Test-Path -LiteralPath (Join-Path $box 'reports/1/manifest.json')) 'Valid report manifest missing'
 }
 Fixture
 $invalid=@(
  '{"kind":"ACCEPTED","payload":{}}',
  '{"kind":"HEARTBEAT","payload":{"state":"working","request_id":null}}',
  '{"kind":"HEARTBEAT","payload":{"state":"working","request_id":false}}',
  '{"kind":"COORDINATOR_PROPOSAL","payload":{"owner_id":"owner","owner_generation":1,"activation_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","proposal_id":"p","kind":"shell","work_id":"work","project_id":"project"}}',
  '{"kind":"COORDINATOR_PROPOSAL","payload":{"owner_id":"owner","owner_generation":1,"activation_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","proposal_id":"p","kind":"dispatch","work_id":"work","project_id":"project","record_id":"native","record_revision":true,"prompt":"task"}}',
  '{"kind":"ACCEPTED","payload":{"assignment_sha256":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}',
  '{"kind":"ACCEPTED","action_id":"action","action_revision":1,"payload":{"assignment_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}',
  '{"kind":"ACCEPTED","handover_id":"h","payload":{"assignment_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}',
  '{"kind":"READY","action_id":"action","action_revision":1,"payload":{"state":"idle"}}',
  '{"kind":"WAITING","action_id":"action","payload":{"reason":"wait"}}',
  '{"kind":"REVIEW_RESULT","payload":{"artifact_revision":"rev","outcome":"approved","evidence":[]}}',
  '{"kind":"REGISTER","payload":{"capabilities":["report-files-v1","report-files-v1"]}}',
  '{"kind":"REGISTER","payload":{"capabilities":{}}}',
  '{"kind":"ASK","payload":{"question":"q","options":[{"id":"x","label":"a"},{"id":"x","label":"b"}]}}',
  '{"kind":"LANDING_RESULT","action_id":"a","action_revision":true,"payload":{"project_id":"p","target_ref":"main","source_revision":"r","outcome":"landed","evidence":[]}}',
  '{"kind":"WAITING","handover_id":"h","handover_token":"token_12345678901","payload":{"reason":"wait"}}',
  '{"kind":"ready","payload":{"state":"idle"}}',
  '{"kind":"READY","payload":{"state":"idle"},"seq":99}',
  '{"kind":"READY","payload":{"state":"idle","state":"idle"}}',
  '{"kind":"READY","payload":null}',
  '{"kind":"READY","payload":[]}',
  '{"kind":"READY","payload":{"state":1}}',
  '{"kind":"WAITING","payload":{"reason":"wait","context_used_pct":10}}'
 )
 $landingCommon='"landing_id":"landing","grant_id":"grant","project_id":"project","repo_ref":"repo","target_ref":"main","target_revision":"base","source_revision":"rev","evidence":[]'
 foreach ($outcome in @(
  '"outcome":"landed"',
  '"outcome":"landed","result_revision":"head","reason":"extra"',
  '"outcome":"rejected"',
  '"outcome":"rejected","reason":"conflict","result_revision":"head"',
  '"outcome":"stale_target"',
  '"outcome":"stale_target","observed_target_revision":"base"',
  '"outcome":"uncertain"',
  '"outcome":"failed","reason":"legacy"'
 )) { $invalid+='{"kind":"LANDING_RESULT","action_id":"action","action_revision":1,"payload":{'+$landingCommon+','+$outcome+'}}' }
 $invalid+='{"kind":"LANDING_RESULT","payload":{'+$landingCommon+',"outcome":"landed","result_revision":"head"}}'
 $invalid+='{"kind":"LANDING_REQUEST","action_id":"action","action_revision":1,"payload":{"checkpoint_id":"cp","project_id":"project","repo_ref":"repo","target_ref":"main","target_revision":"base","source_ref":"work","source_revision":"rev"}}'
 $invalid+='{"kind":"LANDING_REQUEST","payload":{"checkpoint_id":"cp","project_id":"project","repo_ref":"repo","target_ref":"main","target_revision":"base","source_revision":"rev"}}'
 $invalid+='{"kind":"LANDING_REQUEST","payload":{"checkpoint_id":"cp","project_id":"bad id","repo_ref":"repo","target_ref":"main","target_revision":"base","source_ref":"work","source_revision":"rev"}}'
 foreach ($bad in @('-1','101','42.5','"42"','true')) {
  $invalid+='{"kind":"READY","payload":{"state":"idle","context_used_pct":'+$bad+'}}'
  $invalid+='{"kind":"HEARTBEAT","payload":{"state":"working","context_used_pct":'+$bad+'}}'
 }
 foreach ($wire in $invalid) {
  $before=ReadFile $journalPath 1572864
  Reject { Allocate (Decode ($utf8.GetBytes($wire))) } 'invalid_schema'
  EqualBytes $before (ReadFile $journalPath 1572864)
 }
 $accepted=@{kind='ACCEPTED';handover_id='handover';handover_token='handover_token_1234';payload=@{assignment_sha256=('b'*64)}}
 ReportInput $accepted
 $binding.assignment_sha256='a'*64
 Reject { ReportInput $accepted } 'binding_mismatch'
 $binding.Remove('assignment_sha256')

 # init takes no input: a piped report is refused before any journal exists;
 # empty stdin initializes and points at mode report.
 Fixture; [IO.File]::Delete($journalPath)
 foreach ($wire in @('{"kind":"ACCEPTED","payload":{"assignment_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}','x')) {
  $result=Worker 'init' $wire
  Assert ($result.code -ne 0 -and $result.out -ceq '' -and $result.err -ceq "init takes no input; it only creates a new journal. Publish reports with mode report (stdin = one report object).`n") ('Init accepted piped input: '+$result.err)
  Assert (-not (Test-Path -LiteralPath $journalPath)) 'Refused init created a journal'
  Assert (@([IO.Directory]::EnumerateFileSystemEntries((Join-Path $box 'reports'))).Count -eq 0) 'Refused init published a report'
 }
 $result=Worker 'init' ''
 Assert ($result.code -eq 0 -and $result.out -ceq '' -and $result.err -ceq "journal initialized; next: publish ACCEPTED with mode report`n") ('Empty-stdin init failed: '+$result.err)
 Reload; Assert ($journal.next_seq -eq 1 -and $journal.owner -ceq $Owner) 'Init journal is not fresh'

 # Coordinator wire schemas through actual helper processes, including byte
 # bounds, required correlations, rejection without allocation, and replay.
 $controlCapabilities=@('report-files-v1','native-ask-v1','worker-poll-v1','argv-v1','coordinator-control-v1')
 $release=@{kind='COORDINATOR_RELEASE';action_id='grant';action_revision=1;payload=@{owner_id='owner';owner_generation=1;activation_token=('a'*64);quiescent=$true}}
 # Ordinary provision bindings have no capabilities. Launch/intake authority
 # negotiates permission; helper acceptance here proves wire support only.
 Fixture
 $registration=@{kind='REGISTER';payload=@{capabilities=$controlCapabilities}}
 $registrationBytes=Encode $registration
 $decodedRegistration=Decode $registrationBytes
 ReportInput $decodedRegistration
 $result=Worker 'report' ($utf8.GetString($registrationBytes))
 Assert ($result.code -eq 0) ('Five capability schema rejected: '+$result.err)
 $result=Worker 'report' '{"kind":"READY","payload":{"state":"idle"}}'
 Assert ($result.code -eq 0) 'Ordinary work rejected'
 # Actual -File report stdin is bounded raw UTF-8, not Console.In's OEM text.
 $summary=(([string][char]0x96EA)*341)+'x'
 $unicodeReport=@{kind='READY';payload=@{state='idle';summary=$summary}}
 $result=Worker 'report' ($utf8.GetString((Encode $unicodeReport)))
 Assert ($result.code -eq 0) ('Exact UTF-8 report rejected: '+$result.err)
 Reload
 $storedReport=Decode ([Convert]::FromBase64String($journal.pending[2].bytes))
 Assert ($storedReport.payload.summary -ceq $summary) 'Report stdin changed Unicode bytes'
 $before=ReadFile $journalPath 1572864
 $unicodeReport.payload.summary+='x'
 $result=Worker 'report' ($utf8.GetString((Encode $unicodeReport)))
 Assert ($result.code -ne 0) 'Oversize UTF-8 short text accepted'
 EqualBytes $before (ReadFile $journalPath 1572864)
 $result=Worker 'report' (' '*65537)
 Assert ($result.code -ne 0 -and $result.err.Contains('oversize')) 'Report byte ceiling not enforced before parsing'
 EqualBytes $before (ReadFile $journalPath 1572864)
 $reportArguments=@('-Root:',$Root,'-Handle:',$Handle,'-Owner:',$Owner,'-Mode:','report')
 $result=FinishHelper (StartHelper $workerPath $reportArguments '' ([byte[]]@(0xC0,0xAF)))
 Assert ($result.code -ne 0) 'Malformed UTF-8 stdin accepted'
 EqualBytes $before (ReadFile $journalPath 1572864)
 Fixture
 $invalidRelease=@()
 foreach ($key in @('kind','payload','action_id','action_revision')) {
  $bad=Decode (Encode $release); $bad.Remove($key); $invalidRelease+=,$bad
 }
 foreach ($key in @('owner_id','owner_generation','activation_token','quiescent')) {
  $bad=Decode (Encode $release); $bad.payload.Remove($key); $invalidRelease+=,$bad
 }
 foreach ($mutation in @(
  @{key='owner_id';value="bad`n"},@{key='owner_generation';value=0},
  @{key='owner_generation';value=$true},@{key='owner_generation';value=1.5},
  @{key='owner_generation';value=9007199254740992},
  @{key='activation_token';value=('A'*64)},@{key='activation_token';value=('a'*63)},
  @{key='quiescent';value=$false},@{key='quiescent';value=1},
  @{key='quiescent';value='true'},@{key='extra';value=$true}
 )) {
  $bad=Decode (Encode $release); $bad.payload[$mutation.key]=$mutation.value; $invalidRelease+=,$bad
 }
 foreach ($mutation in @(@{key='extra';value=$true},@{key='action_revision';value=$true},@{key='action_revision';value=0})) {
  $bad=Decode (Encode $release); $bad[$mutation.key]=$mutation.value; $invalidRelease+=,$bad
 }
 $bad=Decode (Encode $release); $bad.handover_id='handover'; $bad.handover_token='x'*16; $invalidRelease+=,$bad
 $before=ReadFile $journalPath 1572864
 foreach ($bad in $invalidRelease) {
  $result=Worker 'report' ($utf8.GetString((Encode $bad)))
  Assert ($result.code -ne 0) 'Invalid coordinator release accepted'
  EqualBytes $before (ReadFile $journalPath 1572864)
 }
 $result=Worker 'report' ($utf8.GetString((Encode $release)))
 Assert ($result.code -eq 0) ('Coordinator release rejected: '+$result.err)
 Reload
 $raw=[Convert]::FromBase64String($journal.pending[0].bytes); $report=Decode $raw
 Assert ($report.kind -ceq 'COORDINATOR_RELEASE' -and $report.action_id -ceq 'grant' -and $report.action_revision -eq 1 -and $report.payload.quiescent -eq $true) 'Release correlation lost'
 Assert ((Hash $raw) -ceq $journal.pending[0].sha256) 'Release bytes digest changed'
 $manifest=ReadFile (Join-Path $box 'reports/1/manifest.json') 2048
 $result=Worker 'replay'; Assert ($result.code -eq 0) 'Release replay failed'
 EqualBytes $manifest (ReadFile (Join-Path $box 'reports/1/manifest.json') 2048)
 Reload; EqualBytes $raw ([Convert]::FromBase64String($journal.pending[0].bytes))
 foreach ($kind in @('coordinator_activation','coordinator_retirement')) {
  Fixture
  $field='instructions'; $limit=32768
  if ($kind -ceq 'coordinator_retirement') { $field='reason'; $limit=1024 }
  $grant=Decode (ReplyBytes)
  $grant.kind=$kind; $grant.payload=@{owner_id='owner';owner_generation=1;activation_token=('a'*64)}
  $grant.payload[$field]=([string][char]0x00E9)*($limit/2)
  $exact=$utf8.GetBytes(" `n"+$utf8.GetString((Encode $grant))+" `t")
  InstallReply $exact
  foreach ($mode in @('consume','wait')) {
   $result=Worker $mode -RawOutput
   Assert ($result.code -eq 0) ('Coordinator grant rejected: '+$result.err)
   EqualBytes $exact $result.out
  }
  Reload
  EqualBytes $exact ([Convert]::FromBase64String($journal.consumed[0].bytes))
  $ack=Decode ([Convert]::FromBase64String($journal.pending[0].bytes))
  Assert ($ack.payload.reply_sha256 -ceq (Hash $exact)) 'Grant ACK digest changed'
  $mutations=@()
  foreach ($key in @('owner_id','owner_generation','activation_token',$field)) { $mutations+=@{payload=$true;key=$key;remove=$true} }
  $mutations+=@(
   @{payload=$true;key='extra';value=$true},@{payload=$true;key='owner_id';value="bad`n"},
   @{payload=$true;key='owner_generation';value=0},@{payload=$true;key='owner_generation';value=$true},
   @{payload=$true;key='owner_generation';value=1.5},@{payload=$true;key='activation_token';value=('A'*64)},
   @{payload=$true;key='activation_token';value=('a'*63)},@{payload=$true;key=$field;value=''},
   @{payload=$true;key=$field;value=($grant.payload[$field]+'x')},
   @{key='extra';value=$true},@{key='action_id';remove=$true},@{key='action_revision';remove=$true},
   @{key='action_revision';value=$true},@{key='action_revision';value=0}
  )
  foreach ($mutation in $mutations) {
   Fixture; $bad=Decode (Encode $grant)
   $object=$bad; if ($mutation.ContainsKey('payload') -and $mutation['payload']) { $object=$bad.payload }
   # Missing hashtable key "remove" otherwise resolves to its Remove method,
   # which is truthy and would silently turn extra-field additions into no-ops.
   if ($mutation.ContainsKey('remove') -and $mutation['remove']) {
    $object.Remove($mutation['key'])
   } else {
    $object[$mutation['key']]=$mutation['value']
   }
   InstallReply (Encode $bad)
   $before=ReadFile $journalPath 1572864
   $result=Worker 'consume'
   Assert ($result.code -ne 0) ('Invalid coordinator grant accepted: '+$kind+' '+$mutation.key)
   EqualBytes $before (ReadFile $journalPath 1572864)
  }
 }
 # Landing grants are closed typed replies: exact landing/grant/project/checkpoint IDs plus
 # repository, target ref, expected head, source ref and source revision; nothing else.
 Fixture
 $landingGrant=Decode (ReplyBytes)
 $landingGrant.kind='landing_grant'
 $landingGrant.payload=@{landing_id='landing';grant_id='grant';project_id='project';checkpoint_id='cp';repo_ref='repo';target_ref='main';target_revision='base';source_ref='work';source_revision='rev'}
 $exact=Encode $landingGrant
 InstallReply $exact
 $result=Worker 'consume' -RawOutput
 Assert ($result.code -eq 0) ('Landing grant rejected: '+$result.err)
 EqualBytes $exact $result.out
 $landingMutations=@()
 foreach ($key in @('landing_id','grant_id','project_id','checkpoint_id','repo_ref','target_ref','target_revision','source_ref','source_revision')) { $landingMutations+=@{key=$key;remove=$true} }
 $landingMutations+=@(@{key='extra';value=$true},@{key='landing_id';value='bad id'},@{key='grant_id';value=''},@{key='repo_ref';value=''},@{key='target_revision';value=(([string][char]0x00E9)*513)},@{key='source_ref';value=1})
 foreach ($mutation in $landingMutations) {
  Fixture; $bad=Decode (Encode $landingGrant)
  if ($mutation.ContainsKey('remove') -and $mutation['remove']) { $bad.payload.Remove($mutation['key']) } else { $bad.payload[$mutation['key']]=$mutation['value'] }
  InstallReply (Encode $bad)
  $before=ReadFile $journalPath 1572864
  $result=Worker 'consume'
  Assert ($result.code -ne 0) ('Invalid landing grant accepted: '+$mutation.key)
  EqualBytes $before (ReadFile $journalPath 1572864)
 }
 # Landing refresh notices are closed typed replies: exact landing/project IDs plus repository,
 # target ref, expected head, current head and reason; never a grant.
 Fixture
 $landingRefresh=Decode (ReplyBytes)
 $landingRefresh.kind='landing_refresh'
 $landingRefresh.payload=@{landing_id='landing';project_id='project';repo_ref='repo';target_ref='main';expected_revision='base';current_revision='moved';reason='Target moved; refresh against current_revision.'}
 $exact=Encode $landingRefresh
 InstallReply $exact
 $result=Worker 'consume' -RawOutput
 Assert ($result.code -eq 0) ('Landing refresh rejected: '+$result.err)
 EqualBytes $exact $result.out
 $refreshMutations=@()
 foreach ($key in @('landing_id','project_id','repo_ref','target_ref','expected_revision','current_revision','reason')) { $refreshMutations+=@{key=$key;remove=$true} }
 $refreshMutations+=@(@{key='extra';value=$true},@{key='landing_id';value='bad id'},@{key='project_id';value=''},@{key='repo_ref';value=''},@{key='current_revision';value=(([string][char]0x00E9)*513)},@{key='reason';value=1})
 foreach ($mutation in $refreshMutations) {
  Fixture; $bad=Decode (Encode $landingRefresh)
  if ($mutation.ContainsKey('remove') -and $mutation['remove']) { $bad.payload.Remove($mutation['key']) } else { $bad.payload[$mutation['key']]=$mutation['value'] }
  InstallReply (Encode $bad)
  $before=ReadFile $journalPath 1572864
  $result=Worker 'consume'
  Assert ($result.code -ne 0) ('Invalid landing refresh accepted: '+$mutation.key)
  EqualBytes $before (ReadFile $journalPath 1572864)
 }

 # Crash boundary: atomic receipt+pending ACK committed, publication/stdout lost.
 Fixture; $exact=ReplyBytes; InstallReply $exact
 Set-Item -Path Function:PublishPending -Value { param($Pending,[bool]$Drain=$false) throw 'simulated_crash_after_receipt_commit' }
 Reject { ReadReply } 'simulated_crash_after_receipt_commit'
 . ([scriptblock]::Create($definitions.PublishPending))
 Reload
 Assert ($journal.reply_next -eq 2 -and $journal.consumed[0].ack_seq -eq 1) 'Receipt and ACK were not atomic'
 Assert (-not (Test-Path -LiteralPath (Join-Path $box 'reports/1/manifest.json'))) 'Crash injection missed publication boundary'
 Remove-Item -LiteralPath (Join-Path $box 'replies/1') -Recurse -Force
 EqualBytes $exact (ReadReply)
 Assert (Test-Path -LiteralPath (Join-Path $box 'reports/1/manifest.json')) 'Retained ACK was not republished'
 # Crash after publication, before stdout: another consume returns identical bytes.
 Reload; EqualBytes $exact (ReadReply)
 # Even an ACK-confirmed receipt floor and remote compaction cannot hide unclaimed bytes.
 [IO.File]::WriteAllBytes((Join-Path $box 'acks/1.json'),(AckBytes))
 Receipts; Reload
 Assert ($journal.consumed_reply_floor -eq 1 -and $journal.consumed.Count -eq 1) 'Unclaimed receipt was compacted'
 EqualBytes $exact (ReadReply)
 $claim=Worker 'claim' '' 'reply_1'; Assert ($claim.code -eq 0) 'First execution claim failed'
 $claim=Worker 'claim' '' 'reply_1'; Assert ($claim.code -ne 0 -and $claim.err -match 'uncertain') 'Claim was granted twice'
 $consumed=Worker 'consume'; Assert ($consumed.code -eq 0 -and $consumed.out -eq '') 'Claimed execution was redelivered'
 Reload; $journal.consumed[0].execution='uncertain'; Save
 $consumed=Worker 'consume'; Assert ($consumed.code -eq 0 -and $consumed.out -eq '') 'Uncertain execution was redelivered'


 # Capture bytes from actual consume/wait processes, not Receive's return value
 # or a text reader that could normalize encoding/newlines.
 foreach ($mode in @('consume','wait')) {
  Fixture; $exact=ReplyBytes; InstallReply $exact
  $delivered=Worker $mode -RawOutput
  Assert ($delivered.code -eq 0) ('Reply entrypoint failed: '+$mode+' '+$delivered.err)
  EqualBytes $exact $delivered.out
  Reload
  Assert ($journal.reply_next -eq 2 -and $journal.next_seq -eq 2 -and $journal.consumed.Count -eq 1) 'Entrypoint did not retain one receipt and reply_ack'
  $ack=Target 'publish' 'acks/1.json' (AckBytes)
  Assert ($ack.out -ceq "published`n") 'Entrypoint reply_ack receipt publication failed'
  $receipts=Worker 'receipts'; Assert ($receipts.code -eq 0) 'Entrypoint receipt drain failed'
  $compacted=Target 'compact' '-' ([byte[]]@()) 1 1
  Assert ($compacted.out -ceq "compacted`n" -and -not (Test-Path -LiteralPath (Join-Path $box 'replies/1'))) 'Entrypoint replay fixture did not compact transport reply'
  $replayed=Worker $mode -RawOutput
  Assert ($replayed.code -eq 0) ('Compacted reply replay failed: '+$mode+' '+$replayed.err)
  EqualBytes $exact $replayed.out
  Reload
  Assert ($journal.next_seq -eq 2 -and $journal.consumed_reply_floor -eq 1 -and $journal.consumed.Count -eq 1) 'Entrypoint replay changed receipt or allocated another reply_ack'
 }
 # Recovery also repairs pre-cutover durable receipts whose ACK was not allocated.
 Fixture; $exact=ReplyBytes; $reply=Decode $exact
 $journal.consumed=@(@{reply_seq=1;message_id='reply_1';sha256=(Hash $exact);action_id='action';action_revision=1;bytes=[Convert]::ToBase64String($exact);length=$exact.Length;ack_seq=0;acknowledged=$false;execution='unclaimed'})
 $journal.reply_next=2; Save; Reload
 EqualBytes $exact (ReadReply)
 Assert ($journal.next_seq -eq 2 -and $journal.consumed[0].ack_seq -eq 1) 'Missing ACK was not repaired once'
 Reload; EqualBytes $exact (ReadReply); Assert ($journal.next_seq -eq 2) 'Redelivery allocated a second ACK'

 # Retained ACKed execution facts count toward the bound, not just unACKed replies.
 Fixture
 $facts=@()
 for ($index=1;$index -le 8;$index++) {
  $bytes=ReplyBytes $index
  $facts+=,@{reply_seq=$index;message_id=('reply_'+$index);sha256=(Hash $bytes);action_id='action';action_revision=$index;bytes=[Convert]::ToBase64String($bytes);length=$bytes.Length;ack_seq=$index;acknowledged=$true;execution='claimed'}
 }
 $journal.consumed=$facts; $journal.reply_next=9; $journal.consumed_reply_floor=8; Save
 InstallReply (ReplyBytes 9) 9; $before=ReadFile $journalPath 1572864
 Reject { ReadReply } "full`nretained_executions`n9`n8"
 EqualBytes $before (ReadFile $journalPath 1572864)

 # Byte saturation refuses ordinary traffic without consuming seq, while receipt,
 # reply_ack, ACK, watermark, journal replacement and compaction can still drain.
 Fixture; $exact=ReplyBytes; InstallReply $exact; PadTo 2097152
 $before=ReadFile $journalPath 1572864
 Reject { Allocate @{kind='READY';payload=@{state='idle'}} } 'full'
 EqualBytes $before (ReadFile $journalPath 1572864); Reload
 $ordinary=Target 'publish' 'replies/2/chunk-1.json' ($utf8.GetBytes('{}'))
 Assert ($ordinary.out -match '^full\nmailbox_bytes\n[0-9]+\n2097152\n$') 'Target omitted truthful byte diagnostics'
 EqualBytes $exact (ReadReply)
 $ack=Target 'publish' 'acks/1.json' (AckBytes)
 Assert ($ack.out -ceq "published`n") 'ACK could not use reserved capacity'
 Receipts
 Assert (Test-Path -LiteralPath (Join-Path $box 'watermarks/1.json')) 'Watermark could not drain ordinary saturation'
 $compacted=Target 'compact' '-' ([byte[]]@()) 1 1
 Assert ($compacted.code -eq 0 -and $compacted.out -ceq "compacted`n") ('Compaction was blocked by ordinary saturation; helper='+ (ConvertTo-Json -InputObject $compacted -Compress))
 $usage=Usage; Assert ($usage.bytes -le 2359296 -and $usage.files -le 1008) 'Settlement exceeded durable budgets'

 # File saturation separately reserves control publication and replacement slots.
 Fixture
 $usage=Usage
 for ($index=$usage.files;$index -lt 896;$index++) { [IO.File]::WriteAllBytes((Join-Path $box ('consumer/filler-'+$index)),[byte[]]@()) }
 $ordinary=Target 'publish' 'replies/1/chunk-1.json' ($utf8.GetBytes('{}'))
 Assert ($ordinary.out -ceq "full`nmailbox_files`n897`n896`n") 'Target omitted truthful file diagnostics'
 $control=@{kind='reply_ack';action_id='action';action_revision=1;payload=@{message_id='reply';reply_seq=1;reply_sha256=('a'*64);status='recorded'}}
 $null=Allocate $control
 Assert (Test-Path -LiteralPath (Join-Path $box 'reports/1/manifest.json')) 'reply_ack starved at ordinary file limit'

 # Shared mutex is observable in BOTH real processes and is never stolen, even
 # when a stale-looking owner file claims an old PID/time. Explicit cleanup only.
 Fixture; EnterCapacity
 try {
  [IO.File]::WriteAllText((Join-Path $box 'capacity.lock/owner'),'pid=1 time=0')
  $target=Target 'publish' 'replies/1/chunk-1.json' ($utf8.GetBytes('{}'))
  $producer=Worker 'report' '{"kind":"READY","payload":{"state":"idle"}}'
  Assert ($target.out -ceq "admission_full`ncapacity_admission`n1`n1`n") 'Target bypassed shared capacity exclusion'
  Assert ($producer.code -ne 0 -and $producer.err -match 'capacity_locked') 'Worker bypassed shared capacity exclusion'
  Assert (Test-Path -LiteralPath (Join-Path $box 'capacity.lock/owner')) 'Admission lock was stolen'
 } finally { [IO.File]::Delete((Join-Path $box 'capacity.lock/owner')); LeaveCapacity }
 # Actual overlapping target and worker publication cannot exceed aggregate bounds.
 PadTo 2080000
 $producer=StartHelper $workerPath @('-Root:',$Root,'-Handle:',$Handle,'-Owner:',$Owner,'-Mode:','report') '{"kind":"READY","payload":{"state":"idle"}}'
 $target=Target 'publish' 'replies/1/chunk-1.json' (New-Object byte[] 4096)
 $null=FinishHelper $producer
 $usage=Usage; Assert ($usage.bytes -le 2097152 -and $usage.files -le 896) 'Concurrent writers exceeded ordinary admission'
 Assert (-not (Test-Path -LiteralPath (Join-Path $box 'capacity.lock'))) 'Finished operation retained capacity lock'

 # wait keeps producer ownership, but releases capacity before sleeping/polling.
 Fixture
 $waiting=StartHelper $workerPath @('-Root:',$Root,'-Handle:',$Handle,'-Owner:',$Owner,'-Mode:','wait','-WaitSeconds:','4','-PollMs:','1000')
 $watch=[Diagnostics.Stopwatch]::StartNew(); $observed=$false
 while ($watch.ElapsedMilliseconds -lt 3000 -and -not $waiting.HasExited) {
  try { $probe=[IO.File]::Open((Join-Path $box 'producer/lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $probe.Dispose() }
  catch [IO.IOException] { if (-not (Test-Path -LiteralPath (Join-Path $box 'capacity.lock'))) { $observed=$true; break } }
  Start-Sleep -Milliseconds 20
 }
 Assert $observed 'wait held shared admission across polling/sleep'
 $published=$false
 for ($attempt=0;$attempt -lt 3 -and -not $published;$attempt++) {
  $target=Target 'publish' 'replies/1/chunk-1.json' ($utf8.GetBytes('{}'))
  $published=$target.out -ceq "published`n" -or $target.out -ceq "already_published`n"
  if (-not $published) { Assert ($target.out -ceq "admission_full`ncapacity_admission`n1`n1`n") 'Unexpected target publication failure'; Start-Sleep -Milliseconds 20 }
 }
 Assert $published 'Target could not publish while worker waited'
 $waitResult=FinishHelper $waiting; Assert ($waitResult.code -eq 0) 'wait failed without a complete manifest'

 # Read/compaction remain available for an externally overfull mailbox.
 Fixture; $null=Allocate @{kind='READY';payload=@{state='idle'}}; PadTo 4194400
 $read=Target 'read' 'reports/1/manifest.json'; Assert ($read.out.StartsWith("object`n")) 'Overfull mailbox blocked reconciliation read'
 $compact=Target 'compact' '-' ([byte[]]@()) 1 0; Assert ($compact.out -ceq "compacted`n") 'Overfull mailbox blocked compaction'
 [Console]::Out.WriteLine('PowerShell mailbox helper regressions passed')
} finally {
 foreach ($child in $children) { if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit() }; $child.Dispose() }
 Remove-Item -LiteralPath $testRoot -Recurse -Force
}
