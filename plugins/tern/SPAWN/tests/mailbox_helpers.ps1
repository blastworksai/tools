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
$Root=$testRoot; $Owner='regression_owner_1234'; $script:capacityDepth=0; $script:gateWaitMs=0
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
function Fixture([string]$Prefix='box_',[string[]]$Capabilities=$null,[byte[]]$Manifest=$null,$ExactBinding=$null) {
 $script:Handle=$Prefix+[Guid]::NewGuid().ToString('N')
 if ($null -ne $ExactBinding) { $script:Handle=$ExactBinding.mailbox_handle }
 $script:box=Join-Path $testRoot $Handle
 $null=[IO.Directory]::CreateDirectory($box)
 foreach ($lane in @('reports','replies','acks','watermarks','producer','consumer','staging')) { $null=[IO.Directory]::CreateDirectory((Join-Path $box $lane)) }
 $script:binding=@{logical_session_id='session';worker_id='worker';worker_generation=1;launch_request_id='launch';work_id='work';enrolment_token='enrolment_token_1234';mailbox_handle=$Handle}
 if ($null -ne $ExactBinding) {
  foreach ($key in @('logical_session_id','worker_id','worker_generation','launch_request_id','work_id','enrolment_token')) { $binding[$key]=$ExactBinding.$key }
 }
 $script:descriptor=@{handle=$Handle;binding=$binding}
 # Capabilities are independent of the manifest; manifest_sha256 only with a manifest.
 if ($null -ne $Capabilities) { $descriptor['capabilities']=@($Capabilities) }
 if ($null -ne $Manifest) { $descriptor['manifest_sha256']=(Hash $Manifest); [IO.File]::WriteAllBytes((Join-Path $box 'manifest.json'),$Manifest) }
 [IO.File]::WriteAllBytes((Join-Path $box 'provision.json'),(Encode $descriptor))
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
function InstallReply([byte[]]$Bytes,[long]$Sequence=1,[string]$MessageId=('reply_'+$Sequence)) {
 $directory=Join-Path $box ('replies/'+$Sequence); $null=[IO.Directory]::CreateDirectory($directory)
 $digest=Hash $Bytes; $count=[int][Math]::Ceiling($Bytes.Length/2048.0)
 for ($index=1;$index -le $count;$index++) {
  $length=[Math]::Min(2048,$Bytes.Length-($index-1)*2048); $part=New-Object byte[] $length
  [Array]::Copy($Bytes,($index-1)*2048,$part,0,$length)
  $chunk=@{transport='report-files-v1';version=1;type='chunk';mailbox_handle=$Handle;direction='reply';slot=$Sequence;message_id=$MessageId;message_sha256=$digest;index=$index;count=$count;data_b64=[Convert]::ToBase64String($part)}
  [IO.File]::WriteAllBytes((Join-Path $directory ('chunk-'+$index+'.json')),(Encode $chunk))
 }
 $manifest=@{transport='report-files-v1';version=1;type='manifest';mailbox_handle=$Handle;direction='reply';slot=$Sequence;message_id=$MessageId;message_sha256=$digest;message_bytes=$Bytes.Length;count=$count}
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
function StartHelper([string]$Path,[string[]]$Arguments,[string]$InputText='',[byte[]]$RawInput=$null,[string]$Cwd='',[hashtable]$Environment=$null) {
 $info=New-Object Diagnostics.ProcessStartInfo
 $info.FileName=$engine; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
 $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
 if ($Cwd -ne '') { $info.WorkingDirectory=$Cwd }
 if ($null -ne $Environment) { foreach ($key in $Environment.Keys) { $info.EnvironmentVariables[$key]=$Environment[$key] } }
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
function Target([string]$Mode,[string]$Selected,[byte[]]$Bytes=([byte[]]@()),[long]$ReportFloor=0,[long]$ReplyFloor=0,[string]$Withdrawn='') {
 $args=@('-Root:',$Root,'-Handle:',$Handle,'-Mode:',$Mode,'-Selected:',$Selected,'-Operation:',('op_'+[Guid]::NewGuid().ToString('N')),'-Identity:',$identity,'-ReportFloor:',[string]$ReportFloor,'-ReplyFloor:',[string]$ReplyFloor)
 if ($Withdrawn.Length -gt 0) { $args+=@('-WithdrawnStarts:',$Withdrawn) }
 return FinishHelper (StartHelper $targetPath $args ([Convert]::ToBase64String($Bytes)))
}
function Worker([string]$Mode,[string]$InputText='',[string]$Message='',[switch]$RawOutput,[string]$Cwd='',[hashtable]$Environment=$null) {
 $args=@('-Root:',$Root,'-Handle:',$Handle,'-Owner:',$Owner,'-Mode:',$Mode)
 if ($Message -ne '') { $args+=@('-MessageId:',$Message) }
 return FinishHelper (StartHelper $workerPath $args $InputText -Cwd $Cwd -Environment $Environment) -RawOutput:$RawOutput
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
function AuthorizedRetire([string]$Report='2',[string]$Reply='1',[string]$Chain=$journal.receipt_chain,[string]$SuppliedOwner=$Owner,[string]$Expected=[Convert]::ToBase64String((Encode $binding)),[string]$Withdrawn='') {
 $args=@('-Root:',$Root,'-Handle:',$Handle,'-Owner:',$SuppliedOwner,'-Mode:','retire-authorized','-ReportFloor:',$Report,'-ReplyFloor:',$Reply,'-ReceiptChain:',$Chain,'-ExpectedBinding:',$Expected)
 if ($Withdrawn.Length -gt 0) { $args+=@('-WithdrawnStarts:',$Withdrawn) }
 return FinishHelper (StartHelper $workerPath $args)
}
function WithdrawnFixture {
 AuthorizedFixture
 $descriptor=@{handle=$Handle;binding=$binding;capabilities=@('report-files-v1','coordinator-control-v1','project-start-v1')}
 [IO.File]::WriteAllBytes((Join-Path $box 'provision.json'),(Encode $descriptor))
 InstallReply (ReplyBytes 1) 1
 $entries=@()
 foreach ($seq in @(2,3)) {
  $reply=Decode (ReplyBytes $seq)
  $reply.kind='project_start'
  $reply.payload=@{owner_id='owner';owner_generation=1;activation_token=('a'*64);orch_project_id='project';project_revision=1;decision_context=('b'*64)}
  $bytes=Encode $reply; InstallReply $bytes $seq
  $entries+=@{reply_seq=$seq;message_id=$reply.message_id;message_sha256=(Hash $bytes)}
 }
 $script:withdrawal=[Convert]::ToBase64String((Encode $entries))
}
function PendingWithdrawalFixture {
 WithdrawnFixture
 $null=Allocate @{kind='WAITING';payload=@{reason='final pending report'}}
 $script:finalAck=AckBytes
 $script:finalChain=(Decode $finalAck).receipt_chain_sha256
 [IO.File]::WriteAllBytes((Join-Path $box 'acks/3.json'),$finalAck)
}
function MailboxBytes {
 $snapshot=@{}
 foreach ($file in Get-ChildItem -LiteralPath $box -File -Force -Recurse) {
  $snapshot[$file.FullName]=[Convert]::ToBase64String([IO.File]::ReadAllBytes($file.FullName))
 }
 return $snapshot
}
function UnchangedMailbox($Before) {
 $after=MailboxBytes
 Assert ($Before.Count -eq $after.Count) 'Refusal changed physical mailbox files'
 foreach ($path in $Before.Keys) { Assert ($after.ContainsKey($path) -and $Before[$path] -ceq $after[$path]) ('Refusal changed mailbox bytes: '+$path) }
}
function EnrolFixture([bool]$Initialize=$true) {
 Fixture 'enrol_'
 $binding['enrolment_token']=$Owner
 [IO.File]::WriteAllBytes((Join-Path $box 'provision.json'),(Encode @{handle=$Handle;binding=$binding}))
 [IO.File]::Delete($journalPath); [IO.File]::Delete((Join-Path $box 'producer/lock'))
 if ($Initialize) {
  $initialized=Worker 'init'
  Assert ($initialized.code -eq 0) ('Actual enrol journal init failed: '+$initialized.err)
  Reload
 }
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
# An unsettled journal at the authorized floors is a definite pre-effect refusal: exit 0 with
# exactly producer_unsettled on stdout, and nothing removed.
function UnsettledRetirement([scriptblock]$Operation) {
 $before=[IO.File]::ReadAllBytes($journalPath)
 $unknown=Join-Path $box 'producer/unknown'; $sentinel=$utf8.GetBytes('must retain unknown bytes')
 [IO.File]::WriteAllBytes($unknown,$sentinel)
 $result=& $Operation
 Assert ($result.code -eq 0 -and $result.out -ceq "producer_unsettled`n") ('Unsettled journal was not a definite pre-effect refusal; helper='+ (ConvertTo-Json -InputObject $result -Compress))
 EqualBytes $before ([IO.File]::ReadAllBytes($journalPath))
 EqualBytes $sentinel ([IO.File]::ReadAllBytes($unknown))
 Assert (Test-Path -LiteralPath (Join-Path $box 'producer/lock')) 'Refusal removed producer lock'
}
try {
 Fixture
 $prior=Usage
 $old=Join-Path $box 'staging/old.json'
 [IO.File]::WriteAllText($old,'{}')
 [IO.File]::SetLastWriteTimeUtc($old,[DateTime]::UtcNow.AddHours(-1))
 $fresh=Join-Path $box 'staging/fresh.json'
 [IO.File]::WriteAllText($fresh,'{}')
 $journalBefore=[IO.File]::ReadAllBytes($journalPath)
 $inventory=Target 'inventory' '60000'
 Assert ($inventory.code -eq 0) 'Inventory process failed'
 $observed=ConvertFrom-Json $inventory.out
 Assert ($observed.open_files -eq ($prior.files+2) -and $observed.stale_files -eq 1) 'Inventory did not count actual file ages'
 Assert ([Math]::Abs($observed.observed_at_ms-[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -lt 10000) 'Inventory observation time is not current'
 EqualBytes $journalBefore ([IO.File]::ReadAllBytes($journalPath))
 Assert (-not (Test-Path -LiteralPath (Join-Path $box 'capacity.lock'))) 'Inventory acquired a durable admission lock'
 $invalid=Target 'inventory' '0'
 Assert ($invalid.out -ceq "binding_mismatch`n") 'Inventory accepted invalid stale threshold'
 # DirectoryInfo.Parent is not a provider-emitted item: no PSIsContainer note
 # property is promised. Both production guards must walk real nested ancestry,
 # reject file leaves, and still reject a junction at the leaf or any ancestor.
 $guard=Join-Path $testRoot 'guard'; $nested=Join-Path $guard 'child'
 # Shared byte corpus: exercise the real strict parser and actual consume entrypoint.
 $repository=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $spawn))
 $corpus=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $repository 'shared/report-files-v1/corpus.json')))
 $exercised=@{}
 $rulingCases=@{}
 foreach ($case in $corpus.cases) {
  if ('powershell' -cnotin $case.helpers) { continue }
  $raw=[Convert]::FromBase64String($case.bytes_b64)
  if ($case.op -ceq 'strict_decode') {
   $maximum=65536; if ($null -ne $case.maximum) { $maximum=$case.maximum }
   $accepted=$true
   try { $null=Decode $raw $maximum } catch { $accepted=$false }
   Assert ($accepted -eq $case.expect.ok) ('Shared strict case: '+$case.id)
  } elseif ($null -ne $case.helper_report_input_b64 -and $case.expect.code -cne 'unsupported_capability') {
   $expected=$corpus.binding; if ($null -ne $case.binding) { $expected=$case.binding }
   Fixture 'corpus_' @($expected.capabilities) $null $expected
   $accepted=$true; $diagnostic=''
   try { $null=ReportInput (Decode ([Convert]::FromBase64String($case.helper_report_input_b64)) 65536) } catch { $accepted=$false; $diagnostic=$_.Exception.Message }
   Assert ($accepted -eq $case.expect.ok) ('Shared report schema: '+$case.id+': '+$diagnostic)
   [IO.Directory]::Delete($box,$true)
  } elseif ($case.op -ceq 'decode_reply' -or $null -ne $case.helper_frame -or $null -ne $case.helper_report_input_b64) {
   $expected=$corpus.binding; if ($null -ne $case.binding) { $expected=$case.binding }
   Fixture 'corpus_' @($expected.capabilities) $null $expected
   if ($null -ne $case.helper_frame) {
    $manifestBytes=[Convert]::FromBase64String($case.helper_frame.manifest_b64)
    $manifest=ConvertFrom-Json ($utf8.GetString($manifestBytes))
    $directory=Join-Path $box ('replies/'+$manifest.slot); $null=[IO.Directory]::CreateDirectory($directory)
    $index=0
    foreach ($chunk in $case.helper_frame.chunks_b64) {
     $index++
     [IO.File]::WriteAllBytes((Join-Path $directory ('chunk-'+$index+'.json')),([Convert]::FromBase64String($chunk)))
    }
    [IO.File]::WriteAllBytes((Join-Path $directory 'manifest.json'),$manifestBytes)
   } elseif ($case.op -ceq 'decode_reply') {
    $envelope=ConvertFrom-Json ($utf8.GetString($raw))
    InstallReply $raw $envelope.reply_seq $envelope.message_id
   }
   $before=ReadFile $journalPath 1572864
   if ($null -ne $case.helper_report_input_b64) {
    $result=Worker 'report' ($utf8.GetString([Convert]::FromBase64String($case.helper_report_input_b64))) -RawOutput
   } else { $result=Worker 'consume' -RawOutput }
   Assert (($result.code -eq 0) -eq $case.expect.ok) ('Shared helper case '+$case.id+': '+$result.err)
   if ($case.id.StartsWith('c3-ruling-')) {
    $rulingCases[$case.id]=$true
    Reload
    if ($case.expect.ok) {
     Assert ($journal.consumed.Count -eq 1 -and $journal.consumed[0].execution -ceq 'unclaimed') 'Ruling receipt completed an execution'
     EqualBytes $raw ([Convert]::FromBase64String($journal.consumed[0].bytes))
     $ack=Decode ([Convert]::FromBase64String($journal.pending[0].bytes))
     Assert ($ack.kind -ceq 'reply_ack' -and $ack.payload.status -ceq 'recorded' -and $ack.payload.reply_sha256 -ceq (Hash $raw) -and $ack.payload.message_id -ceq $envelope.message_id -and $ack.payload.reply_seq -eq $envelope.reply_seq) 'Ruling ACK is not exact durable receipt'
    } else {
     Assert (@(Get-ChildItem -LiteralPath (Join-Path $box 'reports') -Force).Count -eq 0) 'Refused ruling published an ACK'
    }
   }
   if ($case.expect.ok) {
    if ($case.op -ceq 'decode_reply') { EqualBytes $raw $result.out }
    elseif ($null -ne $case.helper_frame) { Assert ((Hash $result.out) -ceq $manifest.message_sha256) ('Shared frame bytes: '+$case.id) }
   }
   else {
    EqualBytes $before (ReadFile $journalPath 1572864)
    $allowed=@($case.expect.code)
    $mapping=$corpus.diagnostics.($case.expect.code)
    if ($null -ne $mapping.powershell) { $allowed=@($mapping.powershell) }
    if ($case.expect.code -ceq 'invalid_schema') { $allowed=@($corpus.diagnostics.strict_structure.powershell) }
    if ($null -ne $case.expect.helper_codes.powershell) { $allowed=@($case.expect.helper_codes.powershell) }
    $diagnostic=($result.err.Trim() -split '\r?\n',2)[0].Split(':')[0]
    Assert ($diagnostic -cin $allowed) ('Shared diagnostic '+$case.id+': '+$result.err)
   }
   [IO.Directory]::Delete($box,$true)
  } else { throw ('Unsupported marked helper corpus operation: '+$case.op) }
  $exercised[$case.op+':'+$case.expect.ok]=$true
 }
 foreach ($op in @('strict_decode','decode_reply','decode_report','decode_object')) { foreach ($ok in @($true,$false)) { Assert $exercised[$op+':'+$ok] ('Missing shared coverage '+$op+':'+$ok) } }
 foreach ($case in $corpus.cases) { if ($case.id.StartsWith('c3-ruling-')) { Assert $rulingCases[$case.id] ('Missing actual ruling receive coverage: '+$case.id) } }

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

 # Withdrawn START retirement is a physical tail exception, not consumption.
 WithdrawnFixture
 $prefix=ReadFile (Join-Path $box 'replies/1/manifest.json') 2048
 $tail=ReadFile (Join-Path $box 'replies/2/manifest.json') 2048
 $retired=AuthorizedRetire -Withdrawn $withdrawal
 Assert ($retired.code -eq 0 -and $retired.out -ceq "producer_retired`n") 'Exact unread START tail did not authorize producer retirement'
 EqualBytes $prefix (ReadFile (Join-Path $box 'replies/1/manifest.json') 2048)
 EqualBytes $tail (ReadFile (Join-Path $box 'replies/2/manifest.json') 2048)
 Assert (@([IO.Directory]::EnumerateFileSystemEntries((Join-Path $box 'acks'))).Count -eq 0) 'Withdrawal manufactured an ACK'
 Assert (@([IO.Directory]::EnumerateFileSystemEntries((Join-Path $box 'watermarks'))).Count -eq 0) 'Withdrawal manufactured a cursor'
 $result=Target 'retire' '-' ([byte[]]@()) 2 1 -Withdrawn $withdrawal
 Assert ($result.out -ceq "retired`n" -and -not (Test-Path -LiteralPath $box)) 'Target failed exact withdrawn START retirement'
 $result=Target 'reconcile_retire' '-' ([byte[]]@()) 2 1 -Withdrawn $withdrawal
 Assert ($result.out -ceq "retired`n") 'Exact withdrawn retirement proof did not reconcile after deletion'

 # A dead producer can ingest an actual final host ACK; no fabricated receipt
 # or execution resolution is needed to reach the exact authorized report floor.
 PendingWithdrawalFixture
 $reportManifest=ReadFile (Join-Path $box 'reports/3/manifest.json') 2048
 $result=AuthorizedRetire -Report '3' -Chain $finalChain -Withdrawn $withdrawal
 Assert ($result.code -eq 0 -and $result.out -ceq "producer_retired`n") 'Genuine final ACK did not drain pending report'
 EqualBytes $finalAck (ReadFile (Join-Path $box 'acks/3.json') 2048)
 EqualBytes $reportManifest (ReadFile (Join-Path $box 'reports/3/manifest.json') 2048)
 $watermark=Decode (ReadFile (Join-Path $box 'watermarks/3.json') 2048)
 Assert ($watermark.through_seq -eq 3 -and $watermark.receipt_chain_sha256 -ceq $finalChain) 'Receipt ingestion did not publish real authorized floor and chain'
 Assert (-not (Test-Path -LiteralPath $journalPath)) 'Retirement retained drained producer journal'
 Assert (@([IO.Directory]::EnumerateFileSystemEntries((Join-Path $box 'consumer'))).Count -eq 0) 'Receipt draining manufactured consumer state'
 $result=Target 'retire' '-' ([byte[]]@()) 3 1 -Withdrawn $withdrawal
 Assert ($result.code -eq 0 -and $result.out -ceq "retired`n" -and -not (Test-Path -LiteralPath $box)) 'Target failed retirement after real final ACK draining'

 foreach ($invalid in @('missing','event','hash','chain','binding','disposition','preflight')) {
  PendingWithdrawalFixture
  $ack=Decode $finalAck
  switch ($invalid) {
   'missing' { [IO.File]::Delete((Join-Path $box 'acks/3.json')) }
   'event' { $ack.event_id='foreign' }
   'hash' { $ack.event_sha256='c'*64 }
   'chain' { $ack.receipt_chain_sha256='c'*64 }
   'binding' { $ack.work_id='foreign' }
   'disposition' { $ack.disposition='refused' }
   'preflight' {
    $entries=Decode ([Convert]::FromBase64String($withdrawal)); $entries[0].message_sha256='c'*64
    $withdrawal=[Convert]::ToBase64String((Encode $entries))
   }
  }
  if ($invalid -cnotin @('missing','preflight')) { [IO.File]::WriteAllBytes((Join-Path $box 'acks/3.json'),(Encode $ack)) }
  $before=MailboxBytes
  $result=AuthorizedRetire -Report '3' -Chain $finalChain -Withdrawn $withdrawal
  if ($invalid -ceq 'missing') {
   Assert ($result.code -eq 0 -and $result.out -ceq "producer_unsettled`n") 'Missing real ACK did not definitely refuse retirement'
  } else {
   Assert ($result.code -ne 0 -and $result.out -ceq '') ('Invalid ACK or preflight did not strictly refuse: '+$invalid)
  }
  UnchangedMailbox $before
 }

 foreach ($mutation in @('missing_cap','missing_control','wrong_hash','wrong_id','duplicate','reverse','empty','extra_field','string_seq','missing_slot','extra_slot','extra_file','hidden_slot','hidden_file','report_above_floor','ack_above_floor','consumer_fact','staging_fact','unknown_producer','missing_chunk','bad_chunk','duplicate_manifest','wrong_kind','foreign_binding','bad_payload')) {
  WithdrawnFixture
  switch ($mutation) {
   'missing_cap' { $descriptor.capabilities=@('report-files-v1','coordinator-control-v1'); [IO.File]::WriteAllBytes((Join-Path $box 'provision.json'),(Encode $descriptor)) }
   'missing_control' { $descriptor.capabilities=@('report-files-v1','project-start-v1'); [IO.File]::WriteAllBytes((Join-Path $box 'provision.json'),(Encode $descriptor)) }
   'missing_slot' { [IO.Directory]::Delete((Join-Path $box 'replies/3'),$true) }
   'extra_slot' { InstallReply (ReplyBytes 4) 4 }
   'extra_file' { [IO.File]::WriteAllText((Join-Path $box 'replies/2/unknown'),'retain') }
   'hidden_slot' { $null=[IO.Directory]::CreateDirectory((Join-Path $box 'replies/.hidden')) }
   'hidden_file' { [IO.File]::WriteAllText((Join-Path $box 'replies/2/.hidden'),'retain') }
   'report_above_floor' { $path=Join-Path $box 'reports/3'; $null=[IO.Directory]::CreateDirectory($path); [IO.File]::WriteAllText((Join-Path $path 'manifest.json'),'{}') }
   'ack_above_floor' { [IO.File]::WriteAllText((Join-Path $box 'acks/3.json'),'{}') }
   'consumer_fact' { [IO.File]::WriteAllText((Join-Path $box 'consumer/claim'),'retain') }
   'staging_fact' { [IO.File]::WriteAllText((Join-Path $box 'staging/unknown'),'retain') }
   'unknown_producer' { [IO.File]::WriteAllText((Join-Path $box 'producer/unknown'),'retain') }
   'missing_chunk' { [IO.File]::Delete((Join-Path $box 'replies/2/chunk-1.json')) }
   'bad_chunk' { [IO.File]::WriteAllText((Join-Path $box 'replies/2/chunk-1.json'),'{}') }
   'duplicate_manifest' {
    $path=Join-Path $box 'replies/2/manifest.json'; $wire=$utf8.GetString((ReadFile $path 2048))
    [IO.File]::WriteAllText($path,('{"version":1,'+$wire.Substring(1)),$utf8)
   }
   { $_ -cin @('wrong_kind','foreign_binding','bad_payload') } {
    $chunk=Decode (ReadFile (Join-Path $box 'replies/2/chunk-1.json') 4096)
    $reply=Decode ([Convert]::FromBase64String($chunk.data_b64))
    if ($mutation -ceq 'wrong_kind') { $reply=Decode (ReplyBytes 2) }
    elseif ($mutation -ceq 'foreign_binding') { $reply.work_id='foreign' }
    else { $reply.payload.owner_generation='1' }
    $bytes=Encode $reply
    [IO.Directory]::Delete((Join-Path $box 'replies/2'),$true); InstallReply $bytes 2
    $entries=Decode ([Convert]::FromBase64String($withdrawal)); $entries[0].message_sha256=Hash $bytes
    $withdrawal=[Convert]::ToBase64String((Encode $entries))
   }
   default {
    $entries=Decode ([Convert]::FromBase64String($withdrawal))
    switch ($mutation) {
     'wrong_hash' { $entries[0].message_sha256='c'*64 }
     'wrong_id' { $entries[0].message_id='other' }
     'duplicate' { $entries=@($entries[0],$entries[0]) }
     'reverse' { $entries=@($entries[1],$entries[0]) }
     'empty' { $entries=@() }
     'extra_field' { $entries[0].unknown=1 }
     'string_seq' { $entries[0].reply_seq='2' }
    }
    $withdrawal=[Convert]::ToBase64String((Encode $entries))
   }
  }
  $before=ReadFile $journalPath 1572864
  $prefix=ReadFile (Join-Path $box 'replies/1/manifest.json') 2048
  $physicalBefore=MailboxBytes
  $result=AuthorizedRetire -Withdrawn $withdrawal
  if ($mutation -cin @('report_above_floor','ack_above_floor','consumer_fact','staging_fact','unknown_producer')) {
   Assert ($result.code -eq 0 -and $result.out -ceq "producer_unsettled`n") ('Physical residue was not a definite refusal: '+$mutation)
  } else {
   Assert ($result.code -ne 0 -and $result.out -ceq '') ('Producer did not strictly reject invalid withdrawn tail: '+$mutation)
  }
  UnchangedMailbox $physicalBefore
  EqualBytes $before (ReadFile $journalPath 1572864)
  EqualBytes $prefix (ReadFile (Join-Path $box 'replies/1/manifest.json') 2048)
  # Independently test target rejection with a physically absent producer fixture.
  # The target must reject the bad tail before touching the settled prefix.
  [IO.File]::Delete($journalPath); [IO.File]::Delete((Join-Path $box 'producer/lock'))
  $result=Target 'retire' '-' ([byte[]]@()) 2 1 -Withdrawn $withdrawal
  Assert ($result.out -cne "retired`n") ('Target accepted invalid withdrawn tail: '+$mutation)
  EqualBytes $prefix (ReadFile (Join-Path $box 'replies/1/manifest.json') 2048)
 }

 foreach ($block in @('pending','claimed','unclaimed','chain','floor')) {
  WithdrawnFixture
  if ($block -ceq 'pending') { $null=Allocate @{kind='WAITING';payload=@{reason='unacknowledged final report'}} }
  elseif ($block -cin @('claimed','unclaimed')) { $journal.consumed[0].execution=$block }
  elseif ($block -ceq 'chain') { $journal.receipt_chain='d'*64 }
  else { $journal.reply_next=3 }
  [IO.File]::WriteAllBytes($journalPath,(Encode $journal))
  $before=ReadFile $journalPath 1572864
  $chain=$journal.receipt_chain; if ($block -ceq 'chain') { $chain='e'*64 }
  $result=AuthorizedRetire -Withdrawn $withdrawal -Chain $chain
  Assert ($result.code -eq 0 -and $result.out -ceq "producer_unsettled`n") ('Withdrawal bypassed actual journal settlement: '+$block+'; helper='+(ConvertTo-Json -InputObject $result -Compress))
  EqualBytes $before (ReadFile $journalPath 1572864)
 }
 WithdrawnFixture
 $before=ReadFile (Join-Path $box 'replies/1/manifest.json') 2048
 $result=Target 'compact' '-' ([byte[]]@()) 2 1 -Withdrawn $withdrawal
 Assert ($result.out -ceq "binding_mismatch`n") 'Withdrawal widened compact'
 EqualBytes $before (ReadFile (Join-Path $box 'replies/1/manifest.json') 2048)
 WithdrawnFixture
 $before=ReadFile (Join-Path $box 'replies/1/manifest.json') 2048
 $result=Target 'retire' '-' ([byte[]]@()) 2 1 -Withdrawn $withdrawal
 Assert ($result.out -ceq "incomplete`n") 'Target ignored retained producer journal'
 EqualBytes $before (ReadFile (Join-Path $box 'replies/1/manifest.json') 2048)
 $result=Target 'reconcile_retire' '-' ([byte[]]@()) 2 1 -Withdrawn $withdrawal
 Assert ($result.out -ceq "incomplete`n") 'Present withdrawn retirement readback was not incomplete'
 EqualBytes $before (ReadFile (Join-Path $box 'replies/1/manifest.json') 2048)

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
 AuthorizedFixture; UnsettledRetirement { AuthorizedRetire -Report '1' }
 AuthorizedFixture; UnsettledRetirement { AuthorizedRetire -Report '3' }
 AuthorizedFixture; UnsettledRetirement { AuthorizedRetire -Reply '0' }
 AuthorizedFixture; UnsettledRetirement { AuthorizedRetire -Reply '2' }
 AuthorizedFixture; UnsettledRetirement { AuthorizedRetire -Chain ('b'*64) }
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
  if ($mutation -cin @('token','owner','binding','mailbox','next_seq')) { RefusedRetirement { AuthorizedRetire } }
  else { UnsettledRetirement { AuthorizedRetire } }
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

 # Cancellation is mailbox retirement, never a request to stop the terminal.
 $acceptedWire='{"kind":"ACCEPTED","payload":{"assignment_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
 foreach ($initialized in @($false,$true)) {
  EnrolFixture $initialized
  $chain=Hash ($utf8.GetBytes("report-files-v1`n"+$Handle+"`n"))
  $retired=AuthorizedRetire -Report '0' -Reply '0' -Chain $chain
  $expected="producer_absent`n"; if ($initialized) { $expected="producer_retired`n" }
  Assert ($retired.code -eq 0 -and $retired.out -ceq $expected) 'Unused enrol producer did not settle'
  $retired=Target 'retire' '-'
  Assert ($retired.code -eq 0 -and $retired.out -ceq "retired`n") 'Unused enrol mailbox did not retire'
  Assert (-not (Test-Path -LiteralPath $box)) 'Cancelled enrol mailbox remains'
  $delayed=Worker 'init'; Assert ($delayed.code -ne 0) 'Delayed paste recreated cancelled mailbox'
  $delayed=Worker 'report' $acceptedWire; Assert ($delayed.code -ne 0) 'Delayed ACCEPTED used cancelled mailbox'
  Assert (-not (Test-Path -LiteralPath $box)) 'Delayed report recreated cancelled mailbox'
 }
 foreach ($afterCleanup in @($false,$true)) {
  EnrolFixture
  $chain=$journal.receipt_chain
  if ($afterCleanup) {
   $retired=AuthorizedRetire -Report '0' -Reply '0' -Chain $chain
   Assert ($retired.out -ceq "producer_retired`n") 'Race setup did not retire producer'
   $initialized=Worker 'init'; Assert ($initialized.code -eq 0) 'Producer did not recreate journal in cleanup gap'
   $retired=Target 'retire' '-'
   Assert ($retired.code -eq 0 -and $retired.out -ceq "storage_error`n") 'Recreated producer was falsely retired'
  }
  $published=Worker 'report' $acceptedWire
  Assert ($published.code -eq 0) ('Actual race ACCEPTED publication failed: '+$published.err)
  $before=ReadFile $journalPath 1572864
  $manifest=ReadFile (Join-Path $box 'reports/1/manifest.json') 2048
  $chunk=ReadFile (Join-Path $box 'reports/1/chunk-1.json') 4096
  $retired=AuthorizedRetire -Report '0' -Reply '0' -Chain $chain
  Assert ($retired.code -eq 0 -and $retired.out -ceq "producer_unsettled`n") 'Published ACCEPTED was cleared at zero floors'
  $retired=Target 'retire' '-'
  Assert ($retired.code -eq 0 -and $retired.out -ceq "incomplete`n") 'Winning producer was falsely retired'
  EqualBytes $before (ReadFile $journalPath 1572864)
  EqualBytes $manifest (ReadFile (Join-Path $box 'reports/1/manifest.json') 2048)
  EqualBytes $chunk (ReadFile (Join-Path $box 'reports/1/chunk-1.json') 4096)
  Assert (Test-Path -LiteralPath (Join-Path $box 'provision.json')) 'Race refusal removed provisioning'
 }
 # An absent producer result is scoped evidence, not a tombstone: target rechecks.
 EnrolFixture $false
 $chain=Hash ($utf8.GetBytes("report-files-v1`n"+$Handle+"`n"))
 $retired=AuthorizedRetire -Report '0' -Reply '0' -Chain $chain
 Assert ($retired.code -eq 0 -and $retired.out -ceq "producer_absent`n") 'Uninitialized producer absence not proven'
 $initialized=Worker 'init'; Assert ($initialized.code -eq 0) 'Producer could not enter the retirement gap'
 $published=Worker 'report' $acceptedWire; Assert ($published.code -eq 0) 'Winning ACCEPTED publication failed'
 $before=ReadFile $journalPath 1572864
 $retired=Target 'retire' '-'; Assert ($retired.out -ceq "incomplete`n") 'Absent proof incorrectly authorized deleting a later producer'
 EqualBytes $before (ReadFile $journalPath 1572864)
 EnrolFixture $false
 $chain=Hash ($utf8.GetBytes("report-files-v1`n"+$Handle+"`n"))
 foreach ($arguments in @(@{Report='1';Reply='0';Chain=$chain},@{Report='0';Reply='1';Chain=$chain},@{Report='0';Reply='0';Chain=('0'*64)})) {
  $retired=AuthorizedRetire @arguments
  Assert ($retired.code -eq 0 -and $retired.out -ceq "producer_unsettled`n") 'Absent producer accepted nonzero floors or wrong chain'
  Assert (-not (Test-Path -LiteralPath $journalPath)) 'Absence refusal created a journal'
 }
 $wrong=Decode (Encode $binding); $wrong.worker_id='wrong'
 $retired=AuthorizedRetire -Report '0' -Reply '0' -Chain $chain -Expected ([Convert]::ToBase64String((Encode $wrong)))
 Assert ($retired.code -ne 0) 'Absent producer accepted wrong binding'
 $retired=AuthorizedRetire -Report '0' -Reply '0' -Chain $chain -SuppliedOwner 'different_owner_1234'
 Assert ($retired.code -ne 0) 'Absent producer accepted wrong owner'
 foreach ($lane in @('reports','replies','acks','watermarks')) {
  $evidence=Join-Path $box ($lane+'/.retained')
  [IO.File]::WriteAllBytes($evidence,$utf8.GetBytes('retained evidence'))
  $retired=AuthorizedRetire -Report '0' -Reply '0' -Chain $chain
  Assert ($retired.code -eq 0 -and $retired.out -ceq "producer_unsettled`n") 'Missing journal hid retained evidence'
  EqualBytes ($utf8.GetBytes('retained evidence')) ([IO.File]::ReadAllBytes($evidence))
  [IO.File]::Delete($evidence)
 }
 $retired=AuthorizedRetire -Report '0' -Reply '0' -Chain $chain
 Assert ($retired.code -eq 0 -and $retired.out -ceq "producer_absent`n") 'Exact empty absence proof refused'

 # Real Windows -File publication for new proposal variants (not schema-only calls).
 $snow=[string][char]0x96EA
 $newWork=@{owner_id='owner';owner_generation=1;activation_token=('a'*64);proposal_id='proposal';kind='new_work';new_project_name=($snow+' project');record_id='record';record_revision=0;prompt='Discuss work';scope=@{paths=@('src/'+$snow+' file');systems=@('editor')};checks=@(@{check_id='check';argv=@('check',($snow+' argument'))})}
 $newSource=@{owner_id='owner';owner_generation=1;activation_token=('a'*64);proposal_id='proposal';kind='add_source';orch_project_id='existing';source=@{kind='plan_file';path=('C:\plans\'+$snow+' plan.md');revision='r1'}}
 $proposals=@($newWork,$newSource)
 $board=Decode (Encode $newSource); $board.source=@{kind='board';path=('\\server\share\'+$snow);revision='r2'}; $proposals+=,$board
 $template=Decode (Encode $newSource); $template.source=@{kind='template';template_id='template';revision='r3';input='Describe work'}; $proposals+=,$template
 $targeted=Decode (Encode $newWork); $targeted['repository_id']='repo'; $targeted['target_ref']='main'; $targeted['target_revision']=('b'*40); $proposals+=,$targeted
 foreach ($proposal in $proposals) {
  Fixture
  $report=@{kind='COORDINATOR_PROPOSAL';payload=$proposal}
  $published=Worker 'report' ($utf8.GetString((Encode $report)))
  Assert ($published.code -eq 0) ('Proposal publication failed: '+$published.err)
  Reload; $raw=[Convert]::FromBase64String($journal.pending[0].bytes); $stored=Decode $raw
  foreach ($key in $proposal.Keys) {
   if ($key -eq 'scope') {
    EqualBytes (Encode $proposal.scope.paths) (Encode $stored.payload.scope.paths)
    EqualBytes (Encode $proposal.scope.systems) (Encode $stored.payload.scope.systems)
   } elseif ($key -eq 'checks') {
    Assert ($stored.payload.checks.Count -eq $proposal.checks.Count) 'Proposal changed check count'
    for ($i=0;$i -lt $proposal.checks.Count;$i++) {
     Assert ($stored.payload.checks[$i].check_id -ceq $proposal.checks[$i].check_id) 'Proposal changed check ID'
     EqualBytes (Encode $proposal.checks[$i].argv) (Encode $stored.payload.checks[$i].argv)
    }
   } elseif ($key -eq 'source') {
    foreach ($field in $proposal.source.Keys) { Assert ($stored.payload.source[$field] -ceq $proposal.source[$field]) ('Proposal changed source '+$field) }
   } else { Assert ($stored.payload[$key] -ceq $proposal[$key]) ('Proposal changed '+$key) }
  }
  Assert ($stored.work_id -ceq $binding.work_id -and $stored.kind -ceq 'COORDINATOR_PROPOSAL') 'Proposal changed envelope binding'
  $manifest=ReadFile (Join-Path $box 'reports/1/manifest.json') 2048
  $frame=Decode $manifest
  Assert ($frame.message_sha256 -ceq (Hash $raw)) 'Proposal manifest digest differs'
  $joined=New-Object IO.MemoryStream
  try {
   for ($index=1;$index -le $frame.count;$index++) {
    $part=Decode (ReadFile (Join-Path $box ('reports/1/chunk-'+$index+'.json')) 4096)
    $bytes=[Convert]::FromBase64String($part.data_b64); $joined.Write($bytes,0,$bytes.Length)
   }
   EqualBytes $raw ($joined.ToArray())
  } finally { $joined.Dispose() }
  $replayed=Worker 'replay'; Assert ($replayed.code -eq 0) 'Proposal replay failed'
  EqualBytes $manifest (ReadFile (Join-Path $box 'reports/1/manifest.json') 2048)
 }
 Fixture
 $before=ReadFile $journalPath 1572864
 $invalidProposals=@()
 foreach ($proposal in @($newWork,$newSource)) {
  foreach ($key in @('work_id','project_id','checkpoint_id','argv','account_id','pane_id','execution_cwd','executable')) {
   $bad=Decode (Encode $proposal); $bad[$key]='override'; $invalidProposals+=,$bad
  }
  $bad=Decode (Encode $proposal); $bad['orch_project_id']='existing'; $bad['new_project_name']='new'; $invalidProposals+=,$bad
  $bad=Decode (Encode $proposal); $bad.Remove('orch_project_id'); $bad.Remove('new_project_name'); $invalidProposals+=,$bad
 }
 foreach ($mutation in @(
  @{key='prompt';value=" `t`n"}, @{key='new_project_name';value=(([string][char]0x00E9)*81)},
  @{key='checks';value=@($newWork.checks[0],$newWork.checks[0])},
  @{key='checks';value=@(@{check_id='check';argv=@()})},
  @{key='checks';value=@(@{check_id='check';argv=@('x'*513)})},
  @{key='scope';value=@{paths=@('x')*65;systems=@()}},
  @{key='scope';value=@{paths=@();systems=@('x')*17}},
  @{key='scope';value=@{paths=@($snow*86);systems=@()}},
  @{key='scope';value=@{paths=@();systems=@($snow*27)}},
  @{key='target_ref';value='main'}, @{key='target_revision';value=('b'*40)}
 )) {
  $bad=Decode (Encode $newWork); $bad[$mutation.key]=$mutation.value; $invalidProposals+=,$bad
 }
 $bad=Decode (Encode $targeted); $bad.Remove('repository_id'); $invalidProposals+=,$bad
 foreach ($source in @(
  @{kind='plan_file';path='relative';revision='r'}, @{kind='board';path='/board';revision=" `t"},
  @{kind='plan_file';path=('/bad'+[char]0);revision='r'},
  @{kind='template';template_id='t';revision='r';input=' '},
  @{kind='template';template_id='t';revision=('r'+[char]0);input='text'},
  @{kind='board';path='/board';revision='r';input='override'}
 )) { $bad=Decode (Encode $newSource); $bad.source=$source; $invalidProposals+=,$bad }
 foreach ($proposal in $invalidProposals) {
  $rejected=Worker 'report' ($utf8.GetString((Encode @{kind='COORDINATOR_PROPOSAL';payload=$proposal})))
  Assert ($rejected.code -ne 0 -and $rejected.err.Contains('invalid_schema')) 'Invalid proposal accepted'
  EqualBytes $before (ReadFile $journalPath 1572864)
 }
 Assert (@([IO.Directory]::EnumerateFileSystemEntries((Join-Path $box 'reports'))).Count -eq 0) 'Invalid proposal published files'
 # SKILLS-214: the refusal names the field and the rule on a second line, in the jq explain wording.
 $named=@()
 $bad=Decode (Encode $newWork); $bad.checks=@(@{check_id='c';argv=@('x')*49}); $named+=,@($bad,'payload.checks[0].argv: must hold 1 to 16 entries, has 49')
 $bad=Decode (Encode $newWork); $bad.scope=@{paths=@('x')*65;systems=@()}; $named+=,@($bad,'payload.scope.paths: must hold 0 to 64 entries, has 65')
 $bad=Decode (Encode $newWork); $bad.Remove('prompt'); $named+=,@($bad,'payload: missing field prompt')
 $bad=Decode (Encode $newWork); $bad['extra']=$true; $named+=,@($bad,'payload: unknown field extra')
 $bad=Decode (Encode $newWork); $bad['repository_id']='blastworksai/tools'; $named+=,@($bad,'payload.repository_id: 1-96 of A-Z a-z 0-9 _ -')
 foreach ($pair in $named) {
  $rejected=Worker 'report' ($utf8.GetString((Encode @{kind='COORDINATOR_PROPOSAL';payload=$pair[0]})))
  Assert ($rejected.code -ne 0 -and $rejected.err.TrimEnd() -ceq ("invalid_schema`n"+$pair[1])) ('Named refusal differs: expected '+$pair[1]+', got '+$rejected.err)
  EqualBytes $before (ReadFile $journalPath 1572864)
 }

 # Parity with the POSIX helper: only ACCEPTED reads the provisioned handover. A malformed
 # one leaves authorized retirement and other reports unchanged and refuses ACCEPTED.
 $malformedHandover=@{handover_id='bad id';handover_sha256='x'}
 AuthorizedFixture
 [IO.File]::WriteAllBytes((Join-Path $box 'provision.json'),(Encode @{handle=$Handle;binding=$binding;handover=$malformedHandover}))
 $retired=AuthorizedRetire
 Assert ($retired.code -eq 0 -and $retired.out -ceq "producer_retired`n" -and $retired.err -ceq '') ('Malformed provisioned handover blocked authorized retirement: '+$retired.err)
 Fixture
 [IO.File]::WriteAllBytes((Join-Path $box 'provision.json'),(Encode @{handle=$Handle;binding=$binding;handover=$malformedHandover}))
 $before=ReadFile $journalPath 1572864
 $result=Worker 'report' '{"kind":"ACCEPTED","payload":{"assignment_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
 Assert ($result.code -ne 0 -and $result.err.Contains('binding_mismatch')) ('Malformed provisioned handover did not refuse ACCEPTED: '+$result.err)
 EqualBytes $before (ReadFile $journalPath 1572864)
 $result=Worker 'report' '{"kind":"READY","payload":{"state":"idle"}}'
 Assert ($result.code -eq 0) ('Malformed provisioned handover blocked an ordinary report: '+$result.err)

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
  @{kind='REVIEW_RESULT';action_id='action';action_revision=1;payload=@{review_id='review';round=1;artifact_revision='rev';outcome='changes_required';findings=@(@{finding_id='f1';path='a.luau';line=3;summary='Missing bound.'});summary='One'}},
  @{kind='LABEL';action_id='label';action_revision=1;payload=@{work_ref='work';class='feature';reason='new mode'}},
  @{kind='DONE';payload=@{checkpoint_id='cp';artifact_revision='rev';summary='done';output_ref='out/a.md'}},
  @{kind='REGISTER';payload=@{capabilities=@('report-files-v1','native-ask-v1','worker-poll-v1','argv-v1','coordinator-control-v1','check-runner-v1','release-manager-v1','project-start-v1')}},
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
  '{"kind":"REVIEW_RESULT","payload":{"review_id":"review","round":1,"artifact_revision":"rev","outcome":"approved","findings":[]}}',
  '{"kind":"REVIEW_RESULT","action_id":"action","action_revision":1,"payload":{"artifact_revision":"rev","outcome":"approved","evidence":[]}}',
  '{"kind":"REGISTER","payload":{"capabilities":["report-files-v1","native-ask-v1","worker-poll-v1","argv-v1","coordinator-control-v1","check-runner-v1","release-manager-v1","invented-v1"]}}',
  '{"kind":"DONE","payload":{"checkpoint_id":"cp","artifact_revision":"rev","summary":"done","output_ref":"oooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooo"}}',
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
 # Rollover successor: the producer verifies the pair against the
 # provisioned ID and sha256(handover_id:handover_token) before allocating a sequence.
 $issuedToken=('29f79cde'*7)+'b5851668'; $mistypedToken=('29f79cde'*7)+'b585166a'
 $accepted=@{kind='ACCEPTED';handover_id='handover_540';handover_token=$issuedToken;payload=@{assignment_sha256=('b'*64)}}
 Reject { ReportInput $accepted } 'binding_mismatch: handover_id was not issued'
 $script:descriptor.handover=@{handover_id='handover_540';handover_sha256=(Hash ($utf8.GetBytes('handover_540:'+$issuedToken)))}
 ReportInput $accepted
 $mistyped=@{kind='ACCEPTED';handover_id='handover_540';handover_token=$mistypedToken;payload=@{assignment_sha256=('b'*64)}}
 Reject { ReportInput $mistyped } 'binding_mismatch: handover_token differs'
 Reject { ReportInput @{kind='ACCEPTED';handover_id='handover_541';handover_token=$issuedToken;payload=@{assignment_sha256=('b'*64)}} } 'binding_mismatch: handover_id differs'
 Reject { ReportInput @{kind='ACCEPTED';payload=@{assignment_sha256=('b'*64)}} } 'binding_mismatch: handover_id and handover_token are required'
 $script:descriptor.Remove('handover')
 # Through the actual helper process: a one-digit-changed token is refused before any
 # sequence or publication, without echoing either value; the exact pair then publishes.
 Fixture
 [IO.File]::WriteAllBytes((Join-Path $box 'provision.json'),(Encode @{handle=$Handle;binding=$binding;handover=@{handover_id='handover_540';handover_sha256=(Hash ($utf8.GetBytes('handover_540:'+$issuedToken)))}}))
 $before=ReadFile $journalPath 1572864
 $result=Worker 'report' ($utf8.GetString((Encode $mistyped)))
 Assert ($result.code -ne 0 -and $result.err.Contains('binding_mismatch: handover_token differs from the provisioned handover digest') -and -not $result.err.Contains($mistypedToken) -and -not $result.err.Contains($issuedToken)) ('Mistyped handover token was not refused by field: '+$result.err)
 EqualBytes $before (ReadFile $journalPath 1572864)
 Assert (@([IO.Directory]::EnumerateFileSystemEntries((Join-Path $box 'reports'))).Count -eq 0) 'Refused handover published a report'
 $result=Worker 'report' ($utf8.GetString((Encode $accepted)))
 Assert ($result.code -eq 0 -and (Test-Path -LiteralPath (Join-Path $box 'reports/1/manifest.json'))) ('Exact handover pair was not published: '+$result.err)
 Reload; Assert ($journal.next_seq -eq 2) 'Exact ACCEPTED did not take sequence 1'

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
 # A project start is a closed, correlated grant, never executable instructions.
 $startCapabilities=@('report-files-v1','native-ask-v1','worker-poll-v1','argv-v1','coordinator-control-v1','check-runner-v1','release-manager-v1','project-start-v1')
 $startPayload=@{owner_id='owner';owner_generation=1;activation_token=('a'*64);orch_project_id='project';project_revision=1;decision_context=('b'*64)}
 $startClaim=@{kind='PROJECT_START_CLAIM';action_id='action';action_revision=1;payload=$startPayload}
 Fixture 'start_' $startCapabilities
 $start=Decode (ReplyBytes); $start.kind='project_start'; $start.payload=$startPayload
 $exact=Encode $start; InstallReply $exact
 $result=Worker 'consume' -RawOutput
 Assert ($result.code -eq 0) ('Project start rejected: '+$result.err); EqualBytes $exact $result.out
 $result=Worker 'consume' -RawOutput
 Assert ($result.code -eq 0) 'Unclaimed project start replay failed'; EqualBytes $exact $result.out
 Reload
 Assert ($journal.next_seq -eq 2 -and $journal.consumed[0].execution -ceq 'unclaimed') 'Project start replay allocated a second ACK'
 $result=Worker 'claim' '' 'reply_1'; Assert ($result.code -eq 0) 'Project start local claim failed'
 $result=Worker 'claim' '' 'reply_1'; Assert ($result.code -ne 0 -and $result.err -match 'uncertain') 'Project start local claim replayed'
 $result=Worker 'report' ($utf8.GetString((Encode $startClaim)))
 Assert ($result.code -eq 0) ('Project start claim producer rejected: '+$result.err)
 Reload; $claimReport=Decode ([Convert]::FromBase64String($journal.pending[1].bytes))
 Assert ($claimReport.kind -ceq 'PROJECT_START_CLAIM' -and $claimReport.action_id -ceq 'action' -and $claimReport.action_revision -eq 1) 'Project start claim lost action correlation'
 foreach ($key in $startPayload.Keys) { Assert ($claimReport.payload[$key] -ceq $startPayload[$key]) ('Project start claim changed '+$key) }
 $result=Worker 'consume'; Assert ($result.code -eq 0 -and $result.out -ceq '') 'Claimed project start redelivered'
 $startMutations=@()
 foreach ($key in $startPayload.Keys) { $startMutations+=@{key=$key;remove=$true} }
 $startMutations+=@(
  @{key='instructions';value='execute this'},@{key='owner_id';value='bad id'},
  @{key='owner_generation';value=$true},@{key='owner_generation';value=0},
  @{key='activation_token';value=('A'*64)},@{key='orch_project_id';value=''},
  @{key='project_revision';value=0},@{key='project_revision';value=-1},
  @{key='project_revision';value=1.5},@{key='project_revision';value=$true},
  @{key='project_revision';value='1'},@{key='project_revision';value=9007199254740992},
  @{key='decision_context';value=('B'*64)},@{key='decision_context';value=('b'*63)}
 )
 foreach ($mutation in $startMutations) {
  Fixture 'start_bad_' $startCapabilities
  $bad=Decode (Encode $start)
  if ($mutation.ContainsKey('remove')) { $bad.payload.Remove($mutation.key) } else { $bad.payload[$mutation.key]=$mutation.value }
  InstallReply (Encode $bad); $before=ReadFile $journalPath 1572864
  $result=Worker 'consume'
  Assert ($result.code -ne 0 -and $result.out -ceq '') ('Invalid project start consumed: '+$mutation.key)
  EqualBytes $before (ReadFile $journalPath 1572864)
  $badClaim=Decode (Encode $startClaim); $badClaim.payload=$bad.payload
  $result=Worker 'report' ($utf8.GetString((Encode $badClaim)))
  Assert ($result.code -ne 0) ('Invalid project start claim produced: '+$mutation.key)
  EqualBytes $before (ReadFile $journalPath 1572864)
 }
 foreach ($kind in @('project_start','PROJECT_START_CLAIM')) {
  foreach ($key in @('action_id','action_revision')) {
   foreach ($value in @($null,$true,0,'')) {
    Fixture 'start_action_' $startCapabilities
    if ($kind -ceq 'project_start') { $bad=Decode (Encode $start) } else { $bad=Decode (Encode $startClaim) }
    if ($null -eq $value) { $bad.Remove($key) } else { $bad[$key]=$value }
    $before=ReadFile $journalPath 1572864
    if ($kind -ceq 'project_start') { InstallReply (Encode $bad); $result=Worker 'consume' }
    else { $result=Worker 'report' ($utf8.GetString((Encode $bad))) }
    Assert ($result.code -ne 0) ('Uncorrelated project start accepted: '+$kind+' '+$key)
    EqualBytes $before (ReadFile $journalPath 1572864)
   }
  }
 }
 foreach ($missing in @('coordinator-control-v1','project-start-v1','both')) {
  $limited=@('report-files-v1')
  if ($missing -ceq 'coordinator-control-v1') { $limited+=@('project-start-v1') }
  if ($missing -ceq 'project-start-v1') { $limited+=@('coordinator-control-v1') }
  Fixture 'start_cap_' $limited
  $start=Decode (ReplyBytes); $start.kind='project_start'; $start.payload=$startPayload
  InstallReply (Encode $start); $before=ReadFile $journalPath 1572864
  $result=Worker 'consume'
  Assert ($result.code -ne 0 -and $result.err -match 'unsupported_capability' -and $result.out -ceq '') ('Unprovisioned project start consumed: '+$missing)
  EqualBytes $before (ReadFile $journalPath 1572864)
  $result=Worker 'report' ($utf8.GetString((Encode $startClaim)))
  Assert ($result.code -ne 0 -and $result.err -match 'unsupported_capability') ('Unprovisioned project start claim produced: '+$missing)
  EqualBytes $before (ReadFile $journalPath 1572864)
  Assert (@(Get-ChildItem -LiteralPath (Join-Path $box 'reports') -Force).Count -eq 0) 'Unprovisioned project start allocated a report'
  # Replaying retained bytes must re-check both capabilities before ACK/publication.
  Fixture 'start_replay_' $startCapabilities
  $start=Decode (ReplyBytes); $start.kind='project_start'; $start.payload=$startPayload
  InstallReply (Encode $start); $result=Worker 'consume'; Assert ($result.code -eq 0) 'Project start replay setup failed'
  $descriptor.capabilities=$limited
  [IO.File]::WriteAllBytes((Join-Path $box 'provision.json'),(Encode $descriptor))
  $before=ReadFile $journalPath 1572864
  $result=Worker 'consume'
  Assert ($result.code -ne 0 -and $result.err -match 'unsupported_capability' -and $result.out -ceq '') ('Retained project start bypassed capability proof: '+$missing)
  EqualBytes $before (ReadFile $journalPath 1572864)
  $result=Worker 'wait'
  Assert ($result.code -ne 0 -and $result.err -match 'unsupported_capability' -and $result.out -ceq '') ('Retained project start wait bypassed capability proof: '+$missing)
  EqualBytes $before (ReadFile $journalPath 1572864)
  Fixture 'start_report_replay_' $startCapabilities
  $result=Worker 'report' ($utf8.GetString((Encode $startClaim)))
  Assert ($result.code -eq 0) 'Project start pending claim replay setup failed'
  $descriptor.capabilities=$limited
  [IO.File]::WriteAllBytes((Join-Path $box 'provision.json'),(Encode $descriptor))
  $before=ReadFile $journalPath 1572864
  $result=Worker 'replay'
  Assert ($result.code -ne 0 -and $result.err -match 'unsupported_capability' -and $result.out -ceq '') ('Pending project start claim replay bypassed capability proof: '+$missing)
  EqualBytes $before (ReadFile $journalPath 1572864)
 }
 # Landing grants are closed typed replies: exact landing/grant/project/checkpoint IDs plus
 # repository, target ref, expected head, source ref and source revision; nothing else.
 $release=@('report-files-v1','release-manager-v1')
 Fixture 'box_' $release
 $landingGrant=Decode (ReplyBytes)
 $landingGrant.kind='landing_grant'
 $landingGrant.payload=@{landing_id='landing';grant_id='grant';project_id='project';checkpoint_id='cp';repo_ref='repo';target_ref='main';target_revision='base';source_ref='work';source_revision='rev';builder_work_id='builder';review_id='review';reviewer_family='openai';proof=@{mode='cross_family_review';artifact_revision='rev';review_id='review';check_refs=@()}}
 $exact=Encode $landingGrant
 InstallReply $exact
 $result=Worker 'consume' -RawOutput
 Assert ($result.code -eq 0) ('Landing grant rejected: '+$result.err)
 EqualBytes $exact $result.out
 $landingMutations=@()
 foreach ($key in @('landing_id','grant_id','project_id','checkpoint_id','repo_ref','target_ref','target_revision','source_ref','source_revision','builder_work_id','review_id','reviewer_family','proof')) { $landingMutations+=@{key=$key;remove=$true} }
 $landingMutations+=@(@{key='extra';value=$true},@{key='landing_id';value='bad id'},@{key='grant_id';value=''},@{key='repo_ref';value=''},@{key='target_revision';value=(([string][char]0x00E9)*513)},@{key='source_ref';value=1})
 foreach ($mutation in $landingMutations) {
  Fixture 'box_' $release; $bad=Decode (Encode $landingGrant)
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

 # record_ruling uses the same durable receipt/claim/resolve path; no helper writer.
 $document=Join-Path $testRoot "owner's existing plan.md"
 $original=$utf8.GetBytes("Plan`r`nProgress without final newline")
 [IO.File]::WriteAllBytes($document,$original)
 $rulingPayload=@{path=$document;marker='orchplus-ruling:authority:gate';entry="> Owner: approve &lt;literal&gt; &#96;work&#96;`n> Context: caf$([char]0x00E9)";expected_document_sha256=(Hash $original);expected_non_rulings_sha256=(Hash $original)}
 foreach ($withoutProof in @('legacy','release')) {
  if ($withoutProof -ceq 'legacy') { Fixture } else { Fixture 'ruling_' @('report-files-v1','release-manager-v1') }
  $ruling=Decode (ReplyBytes); $ruling.kind='record_ruling'; $ruling.gate_id='gate'; $ruling.gate_revision=1; $ruling.payload=$rulingPayload
  InstallReply (Encode $ruling)
  $before=ReadFile $journalPath 1572864; $provision=ReadFile (Join-Path $box 'provision.json') 65536
  $result=Worker 'consume'
  # Worker returns raw native stderr, including PowerShell's error-record decoration.
  # Decode the typed diagnostic exactly as the shared helper corpus does above.
  $diagnostic=($result.err.Trim() -split '\r?\n',2)[0].Split(':')[0]
  Assert ($result.code -ne 0 -and $diagnostic -ceq 'unsupported_capability' -and $result.out -ceq '') ('Unprovisioned ruling was not explicitly refused ('+$withoutProof+'); helper='+(ConvertTo-Json -InputObject $result -Compress))
  EqualBytes $before (ReadFile $journalPath 1572864)
  EqualBytes $provision (ReadFile (Join-Path $box 'provision.json') 65536)
  Assert (@(Get-ChildItem -LiteralPath (Join-Path $box 'reports') -Force).Count -eq 0) 'Unprovisioned ruling allocated ACK'
  EqualBytes $original ([IO.File]::ReadAllBytes($document))
 }
 Fixture 'ruling_' @('report-files-v1','coordinator-control-v1')
 $ruling=Decode (ReplyBytes); $ruling.kind='record_ruling'; $ruling.gate_id='gate'; $ruling.gate_revision=1; $ruling.payload=$rulingPayload
 $exact=$utf8.GetBytes(" `n"+$utf8.GetString((Encode $ruling))+" `t"); InstallReply $exact
 # Lose publication/stdout after the existing atomic receipt+ACK commit.
 Set-Item -Path Function:PublishPending -Value { param($Pending,[bool]$Drain=$false) throw 'simulated_ruling_receipt_crash' }
 Reject { ReadReply } 'simulated_ruling_receipt_crash'
 . ([scriptblock]::Create($definitions.PublishPending))
 Reload
 Assert ($journal.next_seq -eq 2 -and $journal.consumed[0].execution -ceq 'unclaimed' -and $journal.consumed[0].ack_seq -eq 1) 'Ruling receipt and ACK were not atomic'
 $ack=Decode ([Convert]::FromBase64String($journal.pending[0].bytes))
 Assert ($ack.payload.status -ceq 'recorded' -and $ack.payload.reply_sha256 -ceq (Hash $exact)) 'Ruling ACK claimed write completion'
 $delivered=Worker 'consume' -RawOutput; Assert ($delivered.code -eq 0) 'Ruling receipt recovery failed'; EqualBytes $exact $delivered.out
 EqualBytes $original ([IO.File]::ReadAllBytes($document))
 $published=Target 'publish' 'acks/1.json' (AckBytes); Assert ($published.out -ceq "published`n") 'Ruling ACK publication failed'
 $receipts=Worker 'receipts'; Assert ($receipts.code -eq 0) 'Ruling ACK receipt failed'
 $compacted=Target 'compact' '-' ([byte[]]@()) 1 1; Assert ($compacted.out -ceq "compacted`n") 'Ruling transport compaction failed'
 $delivered=Worker 'wait' -RawOutput; Assert ($delivered.code -eq 0) 'Ruling redelivery failed'; EqualBytes $exact $delivered.out
 Reload; Assert ($journal.next_seq -eq 2 -and $journal.consumed[0].execution -ceq 'unclaimed') 'ACK resolved ruling or allocated another ACK'
 $claim=Worker 'claim' '' 'reply_1'; Assert ($claim.code -eq 0) 'Ruling claim failed'
 $claim=Worker 'claim' '' 'reply_1'; Assert ($claim.code -ne 0 -and $claim.err -match 'uncertain') 'Ruling claim replayed'
 $delivered=Worker 'consume'; Assert ($delivered.code -eq 0 -and $delivered.out -ceq '') 'Claimed ruling redelivered'
 # The existing authorized writer owns the effect, not the helper or receipt ACK.
 EqualBytes $original ([IO.File]::ReadAllBytes($document))
 $resolved=Worker 'resolve' '' 'reply_1'; Assert ($resolved.code -eq 0) 'Ruling resolution failed'
 Reload; Assert ($journal.consumed.Count -eq 0) 'Settled ruling was retained'
 EqualBytes $original ([IO.File]::ReadAllBytes($document))

 # Supplement the shared ruling corpus with literal text and UTF-8 byte boundaries.
 $literalMutations=@(
  @{location='payload';key='entry';value='> ';ok=$true},
  @{location='payload';key='entry';value=('> '+([string][char]0x00E9)*4095);ok=$true},
  @{location='payload';key='path';value='\\server\share\existing.md';ok=$true},
  @{location='payload';key='entry';value=('> '+([string][char]0x00E9)*4095+'x')},
  @{location='payload';key='entry';value="> text`n"},
  @{location='payload';key='entry';value="> text`r`n> text"},
  @{location='payload';key='entry';value=('> text'+[char]0)},
  @{location='payload';key='entry';value='> `command`'},
  @{location='payload';key='entry';value='> nested > quote'},
  @{location='payload';key='path';value=('/existing'+[char]0+'.md')},
  @{location='payload';key='marker';value=('orchplus-ruling:'+('a'*237)+':gate')},
  @{location='payload';key='marker';value="orchplus-ruling:authority:gate`n"},
  @{location='envelope';key='gate_revision';value=$true},
  @{location='envelope';key='gate_revision';value=0},
  @{location='envelope';key='gate_id';value='Gate'}
 )
 foreach ($mutation in $literalMutations) {
  Fixture 'ruling_literal_' @('report-files-v1','coordinator-control-v1')
  $ruling=Decode (ReplyBytes); $ruling.kind='record_ruling'; $ruling.gate_id='gate'; $ruling.gate_revision=1
  $ruling.payload=Decode (Encode $rulingPayload)
  if ($mutation.location -ceq 'payload') { $ruling.payload[$mutation.key]=$mutation.value } else { $ruling[$mutation.key]=$mutation.value }
  $raw=Encode $ruling; InstallReply $raw; $before=ReadFile $journalPath 1572864
  $result=Worker 'consume' -RawOutput
  if ($mutation.ok) {
   Assert ($result.code -eq 0) ('Literal ruling rejected: '+$mutation.key+': '+$result.err)
   EqualBytes $raw $result.out
  } else {
   Assert ($result.code -ne 0 -and $result.out.Length -eq 0) ('Invalid literal ruling accepted: '+$mutation.key)
   EqualBytes $before (ReadFile $journalPath 1572864)
   Assert (@(Get-ChildItem -LiteralPath (Join-Path $box 'reports') -Force).Count -eq 0) 'Invalid literal ruling allocated ACK'
  }
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

 # A later wait poll that meets the short-lived shared gate waits it out instead of
 # failing, and leaves the producer lock free for the next call (POSIX lock-leak parity).
 Fixture; $exact=ReplyBytes
 $waiting=StartHelper $workerPath @('-Root:',$Root,'-Handle:',$Handle,'-Owner:',$Owner,'-Mode:','wait','-WaitSeconds:','20','-PollMs:','1000')
 $watch=[Diagnostics.Stopwatch]::StartNew(); $observed=$false
 while ($watch.ElapsedMilliseconds -lt 5000 -and -not $waiting.HasExited) {
  try { $probe=[IO.File]::Open((Join-Path $box 'producer/lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $probe.Dispose() }
  catch [IO.IOException] { if (-not (Test-Path -LiteralPath (Join-Path $box 'capacity.lock'))) { $observed=$true; break } }
  Start-Sleep -Milliseconds 20
 }
 Assert $observed 'wait did not reach its polling sleep'
 $script:gateWaitMs=5000; EnterCapacity; $script:gateWaitMs=0
 try { InstallReply $exact; Start-Sleep -Milliseconds 2500; Assert (-not $waiting.HasExited) 'wait poll gave up on a busy shared gate' }
 finally { LeaveCapacity }
 $waitResult=FinishHelper $waiting -RawOutput
 Assert ($waitResult.code -eq 0) ('wait failed on a busy shared gate: '+$waitResult.err); EqualBytes $exact $waitResult.out
 Assert (-not (Test-Path -LiteralPath (Join-Path $box 'capacity.lock'))) 'wait retained capacity lock'
 $next=Worker 'receipts'; Assert ($next.code -eq 0) ('Next call after wait refused: '+$next.err)

 # Bounded gate wait: a gate released by its holder is entered; one held past the
 # bound is reported capacity_locked and is never taken or removed.
 Fixture; $gate=Join-Path $box 'capacity.lock'
 $null=New-Item -ItemType Directory -Path $gate
 $releaser=Start-Job -ScriptBlock { param($Path) Start-Sleep -Milliseconds 1000; [IO.Directory]::Delete($Path,$false) } -ArgumentList $gate
 try {
  $script:gateWaitMs=15000; EnterCapacity
  Assert ($script:capacityDepth -eq 1 -and (Test-Path -LiteralPath $gate)) 'Gate wait did not enter the released gate'
  LeaveCapacity
 } finally { $script:gateWaitMs=0; $null=Wait-Job $releaser; Remove-Job $releaser }
 Assert (-not (Test-Path -LiteralPath $gate)) 'Gate wait retained the gate'
 $null=New-Item -ItemType Directory -Path $gate
 try { $script:gateWaitMs=500; Reject { EnterCapacity } 'capacity_locked' } finally { $script:gateWaitMs=0 }
 Assert ($script:capacityDepth -eq 0 -and (Test-Path -LiteralPath $gate)) 'Gate wait took a held gate'
 [IO.Directory]::Delete($gate,$false)

 # Read/compaction remain available for an externally overfull mailbox.
 Fixture; $null=Allocate @{kind='READY';payload=@{state='idle'}}; PadTo 4194400
 $read=Target 'read' 'reports/1/manifest.json'; Assert ($read.out.StartsWith("object`n")) 'Overfull mailbox blocked reconciliation read'
 $compact=Target 'compact' '-' ([byte[]]@()) 1 0; Assert ($compact.out -ceq "compacted`n") 'Overfull mailbox blocked compaction'

 # Checkpoint 2 reply kinds: closed payloads; grants need release-manager-v1.
 foreach ($case in @(
  @{kind='review_request';caps=$null;payload=@{review_id='review';round=1;question_id='implements_task_v1';builder_work_id='builder';task_ref='task';plan_ref='plan';plan_revision='3';source_ref='work';artifact_revision='rev';scope_paths=@('a.luau');findings_prev=@()}},
  @{kind='rework';caps=$null;payload=@{review_id='review';round=2;artifact_revision='rev';failed_checks=@(@{check_id='c1';exit_code=1});findings=@(@{finding_id='f1';path='a.luau';line=3;summary='Missing bound.'})}},
  @{kind='deploy_grant';caps=$release;payload=@{deploy_id='deploy';attempt_id='attempt';landing_id='landing';revision='rev';target_ref='production'}},
  @{kind='label_request';caps=$null;payload=@{work_ref='work';classes=@('feature','fix');text='Classify.'}}
 )) {
  Fixture 'box_' $case.caps; $value=Decode (ReplyBytes); $value.kind=$case.kind; $value.payload=$case.payload
  $exact=Encode $value; InstallReply $exact
  $result=Worker 'consume' -RawOutput
  Assert ($result.code -eq 0) ($case.kind+' rejected: '+$result.err); EqualBytes $exact $result.out
  Fixture 'box_' $case.caps; $bad=Decode (Encode $value); $bad.payload['extra']=$true; InstallReply (Encode $bad)
  $before=ReadFile $journalPath 1572864
  Assert ((Worker 'consume').code -ne 0) ($case.kind+' accepted an extra field'); EqualBytes $before (ReadFile $journalPath 1572864)
 }
 foreach ($grant in @(@{kind='deploy_grant';payload=@{deploy_id='deploy';attempt_id='attempt';landing_id='landing';revision='rev';target_ref='production'}},@{kind='landing_grant';payload=$landingGrant.payload})) {
  foreach ($caps in @($null,@('report-files-v1','check-runner-v1'))) {
   Fixture 'box_' $caps; $value=Decode (ReplyBytes); $value.kind=$grant.kind; $value.payload=$grant.payload; InstallReply (Encode $value)
   $before=ReadFile $journalPath 1572864
   Assert ((Worker 'consume').code -ne 0) ($grant.kind+' accepted without release-manager-v1'); EqualBytes $before (ReadFile $journalPath 1572864)
  }
 }
 # DEPLOY_RESULT needs release-manager-v1; report mode refuses helper-only kinds.
 $deploy='{"kind":"DEPLOY_RESULT","action_id":"deploy","action_revision":1,"payload":{"deploy_id":"deploy","attempt_id":"attempt","landing_id":"landing","outcome":"deployed","revision":"rev","evidence":[]}}'
 Fixture 'box_' $release; $result=Worker 'report' $deploy; Assert ($result.code -eq 0) ('DEPLOY_RESULT rejected: '+$result.err)
 Fixture; $result=Worker 'report' $deploy; Assert ($result.code -ne 0 -and $result.err.StartsWith('unsupported_capability')) ('DEPLOY_RESULT without capability: '+$result.err)
 $checks=@('report-files-v1','check-runner-v1')
 foreach ($wire in @(
  ('{"kind":"CHECK_RESULT","payload":{"check_id":"c","argv_sha256":"'+('a'*64)+'","exit_code":0,"output_sha256":"'+('a'*64)+'","head":"'+('a'*40)+'","ran_at_ms":1}}'),
  ('{"kind":"CHECKOUT","payload":{"worktree_path":"C:\\w","common_dir":"C:\\w\\.git","branch":"main","head":"'+('a'*40)+'","changed_files":[],"changed_overflow":false,"changed_total":0,"dirty":false}}')
 )) {
  Fixture 'box_' $checks; $before=ReadFile $journalPath 1572864
  $result=Worker 'report' $wire
  Assert ($result.code -ne 0 -and $result.err.StartsWith('helper_only_kind') -and $result.out -ceq '') ('Helper-only kind accepted by report: '+$result.err)
  EqualBytes $before (ReadFile $journalPath 1572864)
  Assert (@(Get-ChildItem -LiteralPath (Join-Path $box 'reports')).Count -eq 0) 'Helper-only refusal published'
 }

 # Helper modes on disposable git repositories. Checks are .exe argv resolved via PATH, never a shell.
 function GitIn([string]$Directory) {
  # Windows PowerShell turns redirected native stderr into error records; keep them as text here.
  $ErrorActionPreference='Continue'
  $output=@(& git -C $Directory @args 2>&1 | ForEach-Object { [string]$_ })
  if ($LASTEXITCODE -ne 0) { throw ('git failed: '+($output -join "`n")) }
  $last=@($output | Select-Object -Last 1); if ($last.Count -eq 0) { return '' }
  return ([string]$last[0]).Trim()
 }
 function NewRepo {
  $path=Join-Path $testRoot ('repo_'+[Guid]::NewGuid().ToString('N')); $null=[IO.Directory]::CreateDirectory($path)
  $null=GitIn $path init -q -b main; $null=GitIn $path config user.email test@example.invalid; $null=GitIn $path config user.name Test
  [IO.File]::WriteAllText((Join-Path $path 'tracked.txt'),"base`n"); $null=GitIn $path add tracked.txt; $null=GitIn $path commit -q -m base
  return (Resolve-Path -LiteralPath $path).ProviderPath
 }
 function ManifestBytes([string]$Base,$Checks=@()) { return ,$utf8.GetBytes((ConvertTo-Json -InputObject ([ordered]@{base_ref=$Base;checks=@($Checks);files=@();scope=[ordered]@{paths=@();systems=@()}}) -Compress -Depth 8)) }
 function HelperMode([string]$Mode,[string]$CheckId='',[string]$Cwd,[hashtable]$Environment=$null) {
  $args=@('-Root:',$Root,'-Handle:',$Handle,'-Owner:',$Owner,'-Mode:',$Mode)
  if ($CheckId -ne '') { $args+=@('-CheckId:',$CheckId) }
  return FinishHelper (StartHelper $workerPath $args '' -Cwd $Cwd -Environment $Environment)
 }
 function Published { Reload; Assert (@($journal.pending).Count -eq 1) 'Helper mode did not publish exactly one report'; return (Decode ([Convert]::FromBase64String($journal.pending[0].bytes))) }
 function HelperRefused([string]$Mode,[string]$Code,[string]$CheckId='',[string]$Cwd,[hashtable]$Environment=$null) {
  $before=ReadFile $journalPath 1572864
  $result=HelperMode $Mode $CheckId $Cwd $Environment
  Assert ($result.code -ne 0 -and $result.err.StartsWith($Code) -and $result.out -ceq '') ('Expected '+$Code+', got '+$result.err)
  EqualBytes $before (ReadFile $journalPath 1572864)
 }
 $repo=NewRepo; $base=GitIn $repo rev-parse HEAD
 $passing=@{check_id='t1-c1';argv=@('where.exe','where.exe')}; $failing=@{check_id='t1-c2';argv=@('where.exe','no_such_program_spawn_test.exe')}
 $manifest=ManifestBytes $base @($passing,$failing)
 foreach ($case in @(@{check=$passing;code=0},@{check=$failing;code=1})) {
  Fixture 'box_' $checks $manifest
  $result=HelperMode 'run-checks' $case.check.check_id $repo
  Assert ($result.code -eq 0 -and $result.out -ceq '') ('run-checks failed: '+$result.err)
  $report=Published; Assert ($report.kind -ceq 'CHECK_RESULT') 'run-checks published another kind'
  Assert ($report.payload.check_id -ceq $case.check.check_id -and $report.payload.exit_code -eq $case.code) ('Wrong check outcome for '+$case.check.check_id)
  Assert ($report.payload.head -ceq $base -and $report.payload.argv_sha256 -ceq (Hash (Encode @($case.check.argv)))) 'Check head or argv digest wrong'
  Assert ($report.payload.output_sha256 -match '^[0-9a-f]{64}$') 'Output digest missing'
 }
 Fixture 'box_' $checks $manifest; HelperRefused 'run-checks' 'check_undeclared' 't1-c9' $repo
 foreach ($mode in @('run-checks','checkout')) {
  $id=''; if ($mode -eq 'run-checks') { $id='t1-c1' }
  Fixture 'box_' @('report-files-v1') $manifest; HelperRefused $mode 'unsupported_capability' $id $repo
  Fixture 'box_' $checks; HelperRefused $mode 'manifest_missing' $id $repo
  Fixture 'box_' $checks $manifest; [IO.File]::Delete((Join-Path $box 'manifest.json')); HelperRefused $mode 'manifest_mismatch' $id $repo
  Fixture 'box_' $checks $manifest; [IO.File]::WriteAllBytes((Join-Path $box 'manifest.json'),$utf8.GetBytes($utf8.GetString($manifest).Replace('no_such','also_no'))); HelperRefused $mode 'manifest_mismatch' $id $repo
  Fixture 'box_' $checks $manifest; [IO.File]::WriteAllBytes((Join-Path $box 'manifest.json'),[byte[]]($manifest+$utf8.GetBytes(' '*4097))); HelperRefused $mode 'manifest_mismatch' $id $repo
 }
 function Checkout([string]$Directory,[string]$Base) {
  Fixture 'box_' $checks (ManifestBytes $Base)
  $result=HelperMode 'checkout' '' $Directory; Assert ($result.code -eq 0 -and $result.out -ceq '') ('checkout failed: '+$result.err)
  $report=Published; Assert ($report.kind -ceq 'CHECKOUT') 'checkout published another kind'; return $report.payload
 }
 function SamePath([string]$Left,[string]$Right) { return ([IO.Path]::GetFullPath($Left).TrimEnd('\','/') -ieq [IO.Path]::GetFullPath($Right).TrimEnd('\','/')) }
 $clean=Checkout $repo $base
 Assert ((SamePath $clean.worktree_path $repo) -and (SamePath $clean.common_dir (Join-Path $repo '.git'))) 'Clean checkout identity wrong'
 Assert ($clean.branch -ceq 'main' -and $clean.head -ceq $base -and $clean.base -ceq $base) 'Clean checkout revisions wrong'
 Assert (@($clean.changed_files).Count -eq 0 -and $clean.changed_total -eq 0 -and -not $clean.changed_overflow -and -not $clean.dirty) 'Clean checkout reported changes'
 [IO.File]::WriteAllText((Join-Path $repo 'committed.txt'),"c`n"); $null=GitIn $repo add committed.txt; $null=GitIn $repo commit -q -m work
 [IO.File]::WriteAllText((Join-Path $repo 'tracked.txt'),"changed`n"); [IO.File]::WriteAllText((Join-Path $repo 'staged.txt'),"s`n"); $null=GitIn $repo add staged.txt
 $dirty=Checkout $repo $base
 Assert ((@($dirty.changed_files) -join '|') -ceq 'committed.txt|staged.txt|tracked.txt' -and $dirty.changed_total -eq 3 -and $dirty.dirty -and -not $dirty.changed_overflow) 'Dirty checkout union wrong'
 $untrackedRepo=NewRepo; $untrackedBase=GitIn $untrackedRepo rev-parse HEAD
 $null=[IO.Directory]::CreateDirectory((Join-Path $untrackedRepo 'sub')); [IO.File]::WriteAllText((Join-Path $untrackedRepo 'sub\new.txt'),"n`n")
 $untracked=Checkout $untrackedRepo $untrackedBase
 Assert ((@($untracked.changed_files) -join '|') -ceq 'sub/new.txt' -and $untracked.changed_total -eq 1 -and $untracked.dirty) 'Untracked-only checkout wrong'
 $linked=Join-Path $testRoot ('linked_'+[Guid]::NewGuid().ToString('N')); $null=GitIn $repo worktree add -q -b side $linked
 $nested=Join-Path $linked 'nested'; $null=[IO.Directory]::CreateDirectory($nested)
 $worktree=Checkout $nested $base
 Assert ((SamePath $worktree.worktree_path $linked) -and (SamePath $worktree.common_dir (Join-Path $repo '.git')) -and $worktree.branch -ceq 'side') 'Linked worktree identity wrong'
 $manyRepo=NewRepo; $manyBase=GitIn $manyRepo rev-parse HEAD; $null=[IO.Directory]::CreateDirectory((Join-Path $manyRepo 'many'))
 $names=@(); for ($index=0;$index -lt 600;$index++) { $name='many/f'+$index.ToString('0000')+'.txt'; $names+=$name; [IO.File]::WriteAllText((Join-Path $manyRepo $name),'x') }
 $many=Checkout $manyRepo $manyBase
 Assert ($many.changed_overflow -and $many.changed_total -eq 600 -and (@($many.changed_files) -join '|') -ceq (($names | Sort-Object -CaseSensitive | Select-Object -First 512) -join '|')) 'Overflow checkout wrong'
 # No manifest base_ref: the first checkout pins HEAD, a later one reports committed work since it.
 $pinRepo=NewRepo; $launch=GitIn $pinRepo rev-parse HEAD
 Fixture 'box_' $checks (ManifestBytes ''); $pin=Join-Path $box 'checkout-base'
 $result=HelperMode 'checkout' '' $pinRepo; Assert ($result.code -eq 0) ('pinned checkout failed: '+$result.err)
 Assert ([IO.File]::ReadAllText($pin) -ceq ($launch+"`n") -and (Published).payload.base -ceq $launch) 'First checkout did not pin HEAD'
 [IO.File]::WriteAllText((Join-Path $pinRepo 'outside.txt'),"x`n"); $null=GitIn $pinRepo add outside.txt; $null=GitIn $pinRepo commit -q -m out
 $result=HelperMode 'checkout' '' $pinRepo; Assert ($result.code -eq 0) ('second pinned checkout failed: '+$result.err)
 Reload; $second=(Decode ([Convert]::FromBase64String(@($journal.pending)[-1].bytes))).payload
 Assert ($second.base -ceq $launch -and (@($second.changed_files) -join '|') -ceq 'outside.txt' -and [IO.File]::ReadAllText($pin) -ceq ($launch+"`n")) 'Pinned base missed committed out-of-scope file'
 Fixture 'box_' $checks (ManifestBytes ''); [IO.File]::WriteAllText((Join-Path $box 'checkout-base'),"--output=x`n"); HelperRefused 'checkout' 'storage_error' '' $pinRepo
 # git missing: PATH holds only the system directories, without git.
 $noGit=@{PATH=[Environment]::GetFolderPath('System')}
 Assert ($null -eq (Get-Command git -ErrorAction SilentlyContinue | Where-Object { $_.Source.StartsWith($noGit.PATH) })) 'System directory unexpectedly holds git'
 Fixture 'box_' $checks $manifest; HelperRefused 'run-checks' 'git_unavailable' 't1-c1' $repo $noGit
 Fixture 'box_' $checks $manifest; HelperRefused 'checkout' 'git_unavailable' '' $repo $noGit
 [Console]::Out.WriteLine('PowerShell mailbox helper regressions passed')
} finally {
 foreach ($child in $children) { if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit() }; $child.Dispose() }
 Remove-Item -LiteralPath $testRoot -Recurse -Force
}
