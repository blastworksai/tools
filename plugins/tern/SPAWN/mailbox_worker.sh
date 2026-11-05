#!/bin/sh
# Existing-tool producer/consumer, deliberately not a daemon. Requires reviewed
# sibling mailbox_json.awk plus already installed jq, iconv, base64, sha256sum or
# shasum. Invoke at work checkpoints and use `wait` while awaiting a reply.
set -eu
LC_ALL=C; export LC_ALL
umask 077
root=$1 handle=$2 owner=$3 mode=$4
message=${5:-} poll=${6:-5} wait_seconds=${7:-30}
report_floor=${8:-} reply_floor=${9:-} report_chain=${10:-}
expected_binding_b64=${11:-}
fail() { printf '%s\n' "$1" >&2; exit 1; }
full() { printf 'full\n%s\n%s\n%s\n' "$1" "$2" "$3" >&2; exit 1; }
case "$handle" in ''|*[!A-Za-z0-9_-]*) fail binding_mismatch;; esac
case "$owner" in ''|*[!A-Za-z0-9_-]*) fail binding_mismatch;; esac
[ "${#handle}" -le 96 ] && [ "${#owner}" -ge 16 ] && [ "${#owner}" -le 128 ] || fail binding_mismatch
safe_dir() {
 case "$1" in /*) ;; *) fail binding_mismatch;; esac
 case "$1" in *'..'*|*'//'*) fail binding_mismatch;; esac
 current=$1
 while [ "$current" != / ]; do [ -d "$current" ] && [ ! -L "$current" ] || fail binding_mismatch; current=${current%/*}; [ -n "$current" ] || current=/; done
}
safe_file() { [ -f "$1" ] && [ ! -L "$1" ] || fail binding_mismatch; [ "$(wc -c < "$1")" -le "$2" ] || fail oversize; }
script_dir=${0%/*}; safe_dir "$script_dir"
validator=$script_dir/mailbox_json.awk; safe_file "$validator" 16384
reply_validator=$script_dir/mailbox_reply.jq; safe_file "$reply_validator" 16384
for tool in jq iconv base64 awk; do command -v "$tool" >/dev/null 2>&1 || fail unsupported_capability; done
safe_dir "$root"; box=$root/$handle; safe_dir "$box"
for lane in producer consumer staging reports replies acks watermarks; do safe_dir "$box/$lane"; done
hash() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1; elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d ' ' -f 1; else fail unsupported_capability; fi; }
b64() { base64 < "$1" | tr -d '\r\n'; }
un64() { if printf Zg== | base64 -d >/dev/null 2>&1; then base64 -d; else base64 -D; fi; }
strict() { safe_file "$1" "$2"; iconv -f UTF-8 -t UTF-8 "$1" >/dev/null || fail invalid_schema; awk -v journal="${3:-0}" -f "$validator" "$1" || fail invalid_schema; }
strict "$box/provision.json" 2048
[ "$(jq -r '.handle' "$box/provision.json")" = "$handle" ] || fail binding_mismatch
binding=$(jq -c '.binding' "$box/provision.json")
lock=$box/producer/lock
# A crashed mkdir lock is a recovery gate. Never auto-remove it or infer that an
# old producer is stopped from a timeout/PID. Owner performs explicit recovery.
work=$box/staging/worker-$owner
admission=$box/capacity.lock
admitted=0 locked=0 workspace=0
clear_work() {
 for file in "$work/"*; do [ ! -e "$file" ] || { [ -f "$file" ] && [ ! -L "$file" ] && rm "$file"; }; done
}
cleanup() {
 [ "$admitted" != 0 ] || [ "$locked" != 0 ] || return 0
 if [ "$admitted" = 0 ]; then
  # Interrupted waits may be between transactions. Never remove inventory
  # under another helper's scan, or steal its gate to force cleanup.
  mkdir "$admission" 2>/dev/null || { printf 'producer_locked\n' >&2; return 1; }
  admitted=1
 fi
 if [ "$workspace" != 0 ]; then clear_work; rmdir "$work"; workspace=0; fi
 if [ "$locked" != 0 ]; then rmdir "$lock"; locked=0; fi
 rmdir "$admission"; admitted=0
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
journal=$box/producer/journal.json
# Both helpers use this short-lived admission gate. The producer lock remains
# invocation-long; the shared gate never spans polling/sleep or stdout delivery.
# A crash leaves a recovery gate; neither PID inspection nor timeouts steal it.
scan_error() { printf '%s' "$1"; exit 0; }
capacity() {
 extra_bytes=${1:-0} extra_files=${2:-0} tier=${3:-hard}
 # The optional opening case parentheses keep Bash 3.2's nested $() parser
 # balanced without changing any containment or durable-accounting pattern.
 scan=$(
  { find "$box" -print || printf '!storage_error\n'; } | (
   files=0 bytes=0 durable_files=0 durable_bytes=0 directories=0
   while IFS= read -r candidate; do
    [ "$candidate" != "$box" ] || continue
    case "$candidate" in ("$box"/*) ;; (*) scan_error storage_error;; esac
    [ ! -L "$candidate" ] || scan_error binding_mismatch
    relative=${candidate#"$box"/}; case "$relative" in (*/*/*/*) scan_error binding_mismatch;; esac
    if [ -d "$candidate" ]; then directories=$((directories+1)); [ "$directories" -le 1024 ] || scan_error "full mailbox_directories $directories 1024"
    elif [ -f "$candidate" ]; then
     files=$((files+1)); size=$(wc -c < "$candidate") || scan_error storage_error; bytes=$((bytes+size))
     [ "$files" -le 1024 ] || scan_error "full mailbox_files $files 1024"
     [ "$bytes" -le 4194304 ] || scan_error "full mailbox_bytes $bytes 4194304"
     case "$candidate" in ("$work"/*) ;; (*) durable_files=$((durable_files+1)); durable_bytes=$((durable_bytes+size));; esac
    else scan_error binding_mismatch; fi
   done
   printf 'ok %s %s %s %s' "$files" "$bytes" "$durable_files" "$durable_bytes"
  )
 )
 case "$scan" in
  'ok '*) set -- $scan; files=$2 bytes=$3 durable_files=$4 durable_bytes=$5;;
  'full '*) set -- $scan; full "$2" "$3" "$4";;
  *) fail "$scan";;
 esac
 case "$tier" in
  hard)
   [ "$((files+extra_files))" -le 1024 ] || full mailbox_files "$((files+extra_files))" 1024
   [ "$((bytes+extra_bytes))" -le 4194304 ] || full mailbox_bytes "$((bytes+extra_bytes))" 4194304;;
  ordinary)
   [ "$((durable_files+extra_files))" -le 896 ] || full mailbox_files "$((durable_files+extra_files))" 896
   [ "$((durable_bytes+extra_bytes))" -le 2097152 ] || full mailbox_bytes "$((durable_bytes+extra_bytes))" 2097152;;
  settlement)
   [ "$((durable_files+extra_files))" -le 1008 ] || full mailbox_files "$((durable_files+extra_files))" 1008
   [ "$((durable_bytes+extra_bytes))" -le 2359296 ] || full mailbox_bytes "$((durable_bytes+extra_bytes))" 2359296;;
  *) fail journal_corrupt;;
 esac
}
begin() {
 if [ "$admitted" = 0 ]; then
  mkdir "$admission" 2>/dev/null || fail producer_locked
  admitted=1
 fi
 # Real peak space: a 1.5MiB replacement plus 256KiB/16 workspace files.
 # Ordinary durable writes leave a further 256KiB/112 files for settlement.
 capacity 1835008 16
}
stage_journal() {
 # Bound the replacement before opening its file, not after disk allocation.
 [ "${#1}" -le 1572864 ] || full journal_bytes "${#1}" 1572864
 printf '%s' "$1" > "$work/next" || fail storage_error
}
save() {
 strict "$work/next" 1572864 1
 compacted=$(jq -c '(reduce (.consumed|sort_by(.reply_seq)[]) as $c (.consumed_reply_floor; if $c.reply_seq==.+1 and $c.acknowledged then .+1 else . end)) as $floor | .consumed_reply_floor=$floor | .consumed |= map(select(.reply_seq>$floor or .execution!="resolved"))' "$work/next") || fail journal_corrupt
 stage_journal "$compacted"
 size=$(wc -c < "$work/next"); [ "$size" -le 1572864 ] || full journal_bytes "$size" 1572864
 retained_count=$(jq '.consumed|length' "$work/next")
 [ "$retained_count" -le 8 ] || full retained_executions "$retained_count" 8
 retained_bytes=$(jq '[.consumed[].length]|add//0' "$work/next")
 [ "$retained_bytes" -le 524288 ] || full retained_reply_bytes "$retained_bytes" 524288
 old_size=0 new_file=1
 if [ -e "$journal" ]; then old_size=$(wc -c < "$journal"); new_file=0; fi
 capacity "$((size-old_size+${2:-0}))" "$((new_file+${3:-0}))" "${1:-settlement}"
 # Same-filesystem atomic replacement commits all state together. Explicitly
 # abort even under `if consume`, where POSIX shells disable nested errexit.
 mv -f "$work/next" "$journal" || fail storage_error
}
publish() {
 relative=$1 source=$2
 case "$relative" in reports/*/chunk-*.json|reports/*/manifest.json|watermarks/*.json) ;; *) fail binding_mismatch;; esac
 safe_file "$source" 4096
 parent=$box/${relative%/*}
 if [ ! -d "$parent" ]; then safe_dir "${parent%/*}"; mkdir "$parent"; fi
 safe_dir "$parent"
 destination=$box/$relative
 if [ -e "$destination" ] || [ -L "$destination" ]; then safe_file "$destination" 4096; cmp -s "$source" "$destination" || fail content_conflict; rm "$source" || fail storage_error; return; fi
 capacity "$(wc -c < "$source")" 1 "${publication_tier:-settlement}"
 capacity "$(wc -c < "$source")" 1
 ln "$source" "$destination" || { safe_file "$destination" 4096; cmp -s "$source" "$destination" || fail content_conflict; }
 safe_file "$destination" 4096; cmp -s "$source" "$destination" || fail content_conflict
 # Unlink staging before reusing its name: a retained hard link must never be
 # truncated by the next chunk's encoder.
 rm "$source" || fail storage_error
}
bind_check() {
 jq -e --argjson binding "$binding" 'all(["logical_session_id","worker_id","worker_generation","launch_request_id","work_id"][]; . as $key | $binding[$key] == $value[$key])' --argjson value "$(cat "$1")" "$box/provision.json" >/dev/null || fail binding_mismatch
}
publish_pending() {
 seq=$1
 jq -r --argjson seq "$seq" '.pending[]|select(.seq==$seq)|.bytes' "$journal" | un64 > "$work/logical"
 expected=$(jq -r --argjson seq "$seq" '.pending[]|select(.seq==$seq)|.sha256' "$journal")
 [ "$(hash "$work/logical")" = "$expected" ] || fail journal_corrupt
 event=$(jq -r --argjson seq "$seq" '.pending[]|select(.seq==$seq)|.event_id' "$journal")
 length=$(wc -c < "$work/logical"); count=$(( (length+2047)/2048 )); index=1
 while [ "$index" -le "$count" ]; do
  dd if="$work/logical" of="$work/slice" bs=2048 skip="$((index-1))" count=1 2>/dev/null
  jq -cn --arg handle "$handle" --argjson seq "$seq" --arg event "$event" --arg digest "$expected" --argjson index "$index" --argjson count "$count" --arg data "$(b64 "$work/slice")" '{transport:"report-files-v1",version:1,type:"chunk",mailbox_handle:$handle,direction:"report",slot:$seq,message_id:$event,message_sha256:$digest,index:$index,count:$count,data_b64:$data}' > "$work/part"
  publish "reports/$seq/chunk-$index.json" "$work/part"
  index=$((index+1))
 done
 jq -cn --arg handle "$handle" --argjson seq "$seq" --arg event "$event" --arg digest "$expected" --argjson count "$count" --argjson length "$length" '{transport:"report-files-v1",version:1,type:"manifest",mailbox_handle:$handle,direction:"report",slot:$seq,message_id:$event,message_sha256:$digest,message_bytes:$length,count:$count}' > "$work/part"
 publish "reports/$seq/manifest.json" "$work/part"
}
allocate() {
 input=$1 consumed=${2:-0} source_journal=${3:-$journal}
 strict "$input" 65536
 jq -e --arg schema report_input -f "$reply_validator" "$input" >/dev/null || fail invalid_schema
 seq=$(jq -r '.next_seq' "$source_journal"); [ "$seq" -ge 1 ] && [ "$seq" -lt 9007199254740991 ] || fail journal_corrupt
 kind=$(jq -r '.kind' "$input")
 count=$(jq --arg kind "$kind" '[.pending[]|select((.kind=="reply_ack")==($kind=="reply_ack"))]|length' "$source_journal")
 [ "$count" -lt 8 ] || full pending_reports "$count" 8
 printf '%s:report:%s' "$handle" "$seq" > "$work/hash"
 event=$(hash "$work/hash")
 jq -c --argjson binding "$binding" --argjson seq "$seq" --arg event "$event" '$binding|{logical_session_id,worker_id,worker_generation,launch_request_id,work_id,enrolment_token}|. + {version:3,event_id:$event,seq:$seq} + $report' --argjson report "$(cat "$input")" "$box/provision.json" > "$work/logical"
 strict "$work/logical" 65536
 jq -e --arg schema report -f "$reply_validator" "$work/logical" >/dev/null || fail invalid_schema
 length=$(wc -c < "$work/logical"); [ "$kind" != reply_ack ] || [ "$length" -le 2048 ] || fail oversize
 digest=$(hash "$work/logical"); encoded=$(b64 "$work/logical")
 next_journal=$(jq -c --argjson seq "$seq" --arg kind "$kind" --arg event "$event" --arg digest "$digest" --arg bytes "$encoded" --argjson length "$length" --argjson consumed "$consumed" '.next_seq=$seq+1|.pending += [{seq:$seq,kind:$kind,event_id:$event,sha256:$digest,bytes:$bytes,length:$length}] | .consumed |= map(if .reply_seq==$consumed then .ack_seq=$seq else . end)' "$source_journal") || fail journal_corrupt
 stage_journal "$next_journal"
 pending_bytes=$(jq '[.pending[]|select(.kind!="reply_ack")|.length]|add//0' "$work/next")
 [ "$pending_bytes" -le 524288 ] || full pending_report_bytes "$pending_bytes" 524288
 publication_tier=ordinary; [ "$kind" != reply_ack ] || publication_tier=settlement
 parts=$(( (length+2047)/2048 ))
 # Admit the whole publication, not only its journal, before allocating seq.
 save "$publication_tier" "$((parts*4096+2048))" "$((parts+1))"
 publish_pending "$seq"
 publication_tier=settlement
}
watermark() {
 through=$(jq -r '.receipt_seq' "$journal"); [ "$through" -gt 0 ] || return 0
 chain=$(jq -r '.receipt_chain' "$journal")
 # Three fixed-pattern files at most. Verify newest cumulative proof before
 # removing older surplus; newest two remain through any interrupted publish.
 n=0
 : > "$work/watermarks"
 for file in "$box/watermarks/"*.json; do
  [ -e "$file" ] || continue; strict "$file" 2048
  slot=${file##*/}; slot=${slot%.json}; case "$slot" in ''|0*|*[!0-9]*) fail journal_corrupt;; esac
  n=$((n+1)); [ "$n" -le 3 ] || full watermark_files "$n" 3; printf '%s\n' "$slot" >> "$work/watermarks"
 done
 sort -nr "$work/watermarks" > "$work/sorted"
 if [ "$n" -ge 2 ]; then
  latest=$(awk 'NR==1{print;exit}' "$work/sorted"); bind_check "$box/watermarks/$latest.json"
  jq -e --arg handle "$handle" --argjson through "$through" '.type=="receipt_watermark" and .mailbox_handle==$handle and .through_seq<=$through' "$box/watermarks/$latest.json" >/dev/null || fail journal_corrupt
  awk 'NR>2' "$work/sorted" | while IFS= read -r old; do rm "$box/watermarks/$old.json"; done
 fi
 jq -cn --argjson binding "$binding" --arg handle "$handle" --argjson seq "$through" --arg chain "$chain" '$binding + {version:1,type:"receipt_watermark",mailbox_handle:$handle,through_seq:$seq,receipt_chain_sha256:$chain}' > "$work/part"
 publish "watermarks/$through.json" "$work/part"
}
receipts() {
 while :; do
  next=$(jq -r '.receipt_seq+1' "$journal"); file=$box/acks/$next.json
  [ -e "$file" ] || break
  strict "$file" 2048; bind_check "$file"
  jq -e '(keys|sort)==(["version","logical_session_id","worker_id","worker_generation","launch_request_id","work_id","event_id","seq","event_sha256","committed_revision","disposition","receipt_chain_sha256"]|sort) and .version==1 and .disposition=="accepted" and (.committed_revision|type)=="number" and .committed_revision>=1 and .committed_revision<=9007199254740991 and .committed_revision==(.committed_revision|floor)' "$file" >/dev/null || fail invalid_schema
  jq -e --argjson ack "$(cat "$file")" --argjson next "$next" '$ack.seq==$next and ([.pending[]|select(.seq==$next and .event_id==$ack.event_id and .sha256==$ack.event_sha256)]|length==1)' "$journal" >/dev/null || fail binding_mismatch
  previous=$(jq -r '.receipt_chain' "$journal")
  # POSIX printf octal decodes the previous raw32 digest, never shell evaluation.
  octal=$(printf '%s' "$previous" | awk '{for(i=1;i<=64;i+=2){a=index("0123456789abcdef",substr($0,i,1))-1;b=index("0123456789abcdef",substr($0,i+1,1))-1;if(a<0||b<0)exit 1;printf "\\%03o",a*16+b}}')
  printf '%b' "$octal" > "$work/hash"
  jq -j --argjson next "$next" '($next|tostring)+"\n"+.event_id+"\n"+.event_sha256+"\n"+(.committed_revision|tostring)+"\n"' "$file" >> "$work/hash"
  chain=$(hash "$work/hash"); [ "$chain" = "$(jq -r '.receipt_chain_sha256' "$file")" ] || fail content_conflict
  next_journal=$(jq -c --argjson seq "$next" --arg chain "$chain" '.receipt_seq=$seq|.receipt_chain=$chain|.pending |= map(select(.seq!=$seq))|.consumed |= map(if .ack_seq==$seq then .acknowledged=true else . end)' "$journal") || fail journal_corrupt
  stage_journal "$next_journal"
  save
 done
 watermark
}
ack_consumed() {
 cseq=$1 source_journal=${2:-$journal}
 jq -c --argjson seq "$cseq" '.consumed[]|select(.reply_seq==$seq)|{kind:"reply_ack",action_id,action_revision,payload:{message_id,reply_seq,reply_sha256:.sha256,status:"recorded"}}' "$source_journal" > "$work/input"
 allocate "$work/input" "$cseq" "$source_journal"
}
consume() {
 # Receipt cursors compact transport evidence, not execution permission.
 # Until claim, exact retained bytes remain deliverable even after host GC.
 retained=$(jq -r '[.consumed[]|select(.execution=="unclaimed")]|sort_by(.reply_seq)|.[0].reply_seq//0' "$journal")
 if [ "$retained" -gt 0 ]; then
  jq -r --argjson seq "$retained" '.consumed[]|select(.reply_seq==$seq)|.bytes' "$journal" | un64 > "$work/reply"
  strict "$work/reply" 65536
  expected=$(jq -r --argjson seq "$retained" '.consumed[]|select(.reply_seq==$seq)|.sha256' "$journal")
  [ "$(hash "$work/reply")" = "$expected" ] || fail journal_corrupt
  bind_check "$work/reply"
  jq -e -f "$reply_validator" "$work/reply" >/dev/null || fail journal_corrupt
  ack_seq=$(jq -r --argjson seq "$retained" '.consumed[]|select(.reply_seq==$seq)|.ack_seq' "$journal")
  if [ "$ack_seq" = 0 ]; then ack_consumed "$retained"
  elif jq -e --argjson seq "$ack_seq" 'any(.pending[];.seq==$seq)' "$journal" >/dev/null; then publish_pending "$ack_seq"; fi
  delivery=$(b64 "$work/reply")
  return 0
 fi
 reply_seq=$(jq -r '.reply_next' "$journal"); manifest=$box/replies/$reply_seq/manifest.json
 [ -e "$manifest" ] || return 1
 strict "$manifest" 2048
 jq -e --arg handle "$handle" --argjson seq "$reply_seq" '(keys|sort)==(["transport","version","type","mailbox_handle","direction","slot","message_id","message_sha256","message_bytes","count"]|sort) and .transport=="report-files-v1" and .version==1 and .type=="manifest" and .direction=="reply" and .mailbox_handle==$handle and .slot==$seq and .message_bytes>=1 and .message_bytes<=65536 and .message_bytes==(.message_bytes|floor) and .count==(.message_bytes/2048|ceil)' "$manifest" >/dev/null || fail binding_mismatch
 count=$(jq -r '.count' "$manifest"); index=1; : > "$work/reply"
 while [ "$index" -le "$count" ]; do
  chunk=$box/replies/$reply_seq/chunk-$index.json; strict "$chunk" 4096
  jq -e --argjson manifest "$(cat "$manifest")" --argjson index "$index" '(keys|sort)==(["transport","version","type","mailbox_handle","direction","slot","message_id","message_sha256","index","count","data_b64"]|sort) and .type=="chunk" and .index==$index and (. as $chunk|all(["transport","version","mailbox_handle","direction","slot","message_id","message_sha256","count"][]; . as $key|$chunk[$key]==$manifest[$key])) and (.data_b64|test("^[A-Za-z0-9+/]*={0,2}$"))' "$chunk" >/dev/null || fail content_conflict
  encoded=$(jq -r '.data_b64' "$chunk"); printf '%s' "$encoded" | un64 > "$work/slice"
  [ "$(b64 "$work/slice")" = "$encoded" ] || fail invalid_schema
  expected=2048; [ "$index" -lt "$count" ] || expected=$(jq '.message_bytes-(.count-1)*2048' "$manifest")
  [ "$(wc -c < "$work/slice")" -eq "$expected" ] || fail incomplete
  cat "$work/slice" >> "$work/reply"; index=$((index+1))
 done
 digest=$(hash "$work/reply"); [ "$digest" = "$(jq -r '.message_sha256' "$manifest")" ] || fail content_conflict
 strict "$work/reply" 65536; bind_check "$work/reply"
 jq -e --argjson seq "$reply_seq" --arg message "$(jq -r '.message_id' "$manifest")" '.reply_seq==$seq and .message_id==$message' "$work/reply" >/dev/null || fail binding_mismatch
 jq -e -f "$reply_validator" "$work/reply" >/dev/null || fail invalid_schema
 retained_count=$(jq '.consumed|length' "$journal")
 [ "$retained_count" -lt 8 ] || full retained_executions "$retained_count" 8
 length=$(wc -c < "$work/reply")
 retained_bytes=$(( $(jq '[.consumed[].length]|add//0' "$journal") + length ))
 [ "$retained_bytes" -le 524288 ] || full retained_reply_bytes "$retained_bytes" 524288
 if [ "$(jq -r '.kind' "$work/reply")" = report_request ]; then [ "$length" -le 2048 ] || fail oversize; fi
 next_journal=$(jq -c --argjson reply "$(cat "$work/reply")" --arg digest "$digest" --arg bytes "$(b64 "$work/reply")" --argjson length "$length" '.reply_next=$reply.reply_seq+1|.consumed += [{reply_seq:$reply.reply_seq,message_id:$reply.message_id,sha256:$digest,action_id:$reply.action_id,action_revision:$reply.action_revision,bytes:$bytes,length:$length,ack_seq:0,acknowledged:false,execution:"unclaimed"}]' "$journal") || fail journal_corrupt
 stage_journal "$next_journal"
 # Receipt bytes, reply cursor and the pending ACK allocate in ONE commit.
 # Consuming an already admitted reply is settlement, not new ordinary traffic.
 ack_consumed "$reply_seq" "$work/next"
 delivery=$(b64 "$work/reply")
 return 0
}
delivery=
publication_tier=settlement
# Buffer input before taking either gate: a slow sender must not hold shared
# admission. All producer lock/workspace creation and removal is serialized
# with the target's complete inventory scan.
if [ "$mode" = report ]; then report_input=$(dd bs=1 count=65537 2>/dev/null | base64 | tr -d '\r\n'); fi
# init takes no input. A report piped here would otherwise vanish silently, so
# probe one byte; an empty pipe held open by its writer settles after 1s.
stdin_bytes() {
 [ ! -t 0 ] || { printf 0; return 0; }
 { dd bs=1 count=1 2>/dev/null <&3 3<&- & probe_reader=$!
   ( sleep 1; kill "$probe_reader" 2>/dev/null ) </dev/null >/dev/null 2>&1 3<&- & probe_timer=$!
   wait "$probe_reader" 2>/dev/null || :
   kill "$probe_timer" 2>/dev/null || :
 } 3<&0 | wc -c | tr -d ' '
}
if [ "$mode" = init ] && [ "$(stdin_bytes)" != 0 ]; then
 fail 'init takes no input; it only creates a new journal. Publish reports with mode report (stdin = one report object).'
fi
mkdir "$admission" 2>/dev/null || fail producer_locked
admitted=1
mkdir "$lock" 2>/dev/null || fail producer_locked
locked=1
[ ! -e "$work" ] && [ ! -L "$work" ] || fail journal_corrupt
mkdir "$work"; workspace=1
if [ "$mode" = init ]; then
 begin
 [ ! -e "$journal" ] && [ ! -L "$journal" ] || fail journal_corrupt
 for lane in reports acks watermarks; do for entry in "$box/$lane/"*; do [ ! -e "$entry" ] || fail journal_corrupt; done; done
 printf 'report-files-v1\n%s\n' "$handle" > "$work/hash"
 next_journal=$(jq -cn --arg owner "$owner" --argjson binding "$binding" --arg chain "$(hash "$work/hash")" '{version:1,owner:$owner,binding:$binding,next_seq:1,pending:[],receipt_seq:0,receipt_chain:$chain,reply_next:1,consumed:[],consumed_reply_floor:0}') || fail journal_corrupt
 stage_journal "$next_journal"
 save ordinary; cleanup
 printf 'journal initialized; next: publish ACCEPTED with mode report\n' >&2; exit 0
fi
strict "$journal" 1572864 1
jq -e --arg owner "$owner" --argjson binding "$binding" '.version==1 and .owner==$owner and .binding==$binding and .next_seq==(.receipt_seq+(.pending|length)+1) and (.consumed|length)<=8 and all(.consumed[]; (.length|type)=="number" and .length>=1 and .length<=65536 and (.execution|IN("unclaimed","claimed","resolved","uncertain"))) and ([.consumed[].length]|add//0)<=524288' "$journal" >/dev/null || fail journal_corrupt
if [ "$mode" = wait ]; then
 case "$poll:$wait_seconds" in *[!0-9:]*) fail invalid_schema;; esac
 [ "$poll" -ge 1 ] && [ "$poll" -le 60 ] && [ "$wait_seconds" -ge 1 ] && [ "$wait_seconds" -le 30 ] || fail invalid_schema
 started=$(date +%s)
 while :; do
  begin; receipts
  found=0; if consume; then found=1; fi
  [ "$found" = 0 ] || { cleanup; break; }
  now=$(date +%s)
  [ "$((now-started))" -lt "$wait_seconds" ] || { cleanup; break; }
  clear_work; rmdir "$admission"; admitted=0
  remaining=$((wait_seconds-now+started)); delay=$poll; [ "$delay" -le "$remaining" ] || delay=$remaining
  sleep "$delay"
 done
else
 begin
 case "$mode" in
  report) printf '%s' "$report_input" | un64 > "$work/input"; allocate "$work/input";;
  replay)
   jq -r '.pending[].seq' "$journal" > "$work/seqs"
   while IFS= read -r seq; do publish_pending "$seq"; done < "$work/seqs"
   jq -r '.consumed[]|select(.ack_seq==0)|.reply_seq' "$journal" > "$work/seqs"
   while IFS= read -r seq; do ack_consumed "$seq"; done < "$work/seqs";;
  receipts) receipts;;
  consume) consume || :;;
  claim|resolve)
   jq -e --arg message "$message" --arg mode "$mode" '[.consumed[]|select(.message_id==$message and .execution==(if $mode=="claim" then "unclaimed" else "claimed" end))]|length==1' "$journal" >/dev/null || fail uncertain
   if [ "$mode" = claim ]; then
    jq -e --arg message "$message" '. as $journal|.consumed[]|select(.message_id==$message)|. as $fact|all($journal.consumed[]; .action_id!=$fact.action_id or .action_revision<=$fact.action_revision)' "$journal" >/dev/null || fail binding_mismatch
   fi
   next_journal=$(jq -c --arg message "$message" --arg mode "$mode" '.consumed |= map(if .message_id==$message then .execution=(if $mode=="claim" then "claimed" else "resolved" end) else . end)' "$journal") || fail journal_corrupt
   stage_journal "$next_journal"; save;;
  retire-local)
   jq -e '(.pending|length)==0 and all(.consumed[]; .acknowledged and .execution=="resolved")' "$journal" >/dev/null || fail incomplete
   rm "$journal";;
  retire-authorized)
   jq -en --arg report "$report_floor" --arg reply "$reply_floor" --arg chain "$report_chain" '
    def floor_arg: test("\\A(0|[1-9][0-9]*)\\z") and length<=16 and (tonumber<=9007199254740991);
    ($report|floor_arg) and ($reply|floor_arg) and ($chain|test("\\A[0-9a-f]{64}\\z"))
   ' >/dev/null || fail invalid_schema
   [ -n "$expected_binding_b64" ] && [ "${#expected_binding_b64}" -le 2732 ] || fail invalid_schema
   printf '%s' "$expected_binding_b64" | un64 > "$work/expected-binding" || fail invalid_schema
   strict "$work/expected-binding" 2048
   jq -e --argjson binding "$binding" '
    (keys|sort)==(["logical_session_id","worker_id","worker_generation","launch_request_id","work_id","enrolment_token","mailbox_handle"]|sort) and .==$binding
   ' "$work/expected-binding" >/dev/null || fail binding_mismatch
   jq -e --arg owner "$owner" --argjson report "$report_floor" --argjson reply "$reply_floor" --arg chain "$report_chain" '
    .binding.enrolment_token==$owner and
    .receipt_seq==$report and .next_seq==($report+1) and
    .consumed_reply_floor==$reply and .reply_next==($reply+1) and
    .receipt_chain==$chain and (.pending|length)==0 and
    all(.consumed[]; .acknowledged==true and .execution=="resolved")
   ' "$journal" >/dev/null || fail incomplete
   rm "$journal";;
  *) fail invalid_schema;;
 esac
 cleanup
fi
# Release admission before any potentially blocked caller output. Losing this
# delivery still leaves the unclaimed bytes durable for the next invocation.
[ -z "$delivery" ] || printf '%s' "$delivery" | un64
[ "$mode" != retire-authorized ] || printf 'producer_retired\n'
