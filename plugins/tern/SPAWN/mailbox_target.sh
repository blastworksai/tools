#!/bin/sh
# Fixed report-files-v1 adapter. Install reviewed asset explicitly, not from a
# public request. No eval, arbitrary child path, recursive rm, or runtime install.
set -eu
umask 077
root=$1 handle=$2 mode=$3 selected=$4 operation=$5 identity=$6 report_floor=$7 reply_floor=$8
producer_helper=$9
withdrawn_starts_b64=${10:-}
[ -z "$withdrawn_starts_b64" ] || [ "$mode" = retire ] || [ "$mode" = reconcile_retire ] || { printf "binding_mismatch\n"; exit 0; }
out() { printf '%s\n' "$1"; exit 0; }
full() { printf 'full\n%s\n%s\n%s\n' "$1" "$2" "$3"; exit 0; }
case "$handle" in ''|*[!A-Za-z0-9_-]*) out binding_mismatch;; esac
case "$operation" in ''|*[!A-Za-z0-9_-]*) out binding_mismatch;; esac
[ "${#handle}" -le 96 ] && [ "${#operation}" -le 96 ] || out binding_mismatch
[ "$(id -un)" = "$identity" ] || out binding_mismatch
safe_dir() {
 case "$1" in /*) ;; *) out binding_mismatch;; esac
 case "$1" in *'/../'*|*'/./'*|*'//'*) out binding_mismatch;; esac
 walk=$1
 while [ "$walk" != / ]; do
  [ ! -L "$walk" ] && [ -d "$walk" ] || out binding_mismatch
  walk=${walk%/*}; [ -n "$walk" ] || walk=/
 done
}
safe_dir "$root"
box=$root/$handle
# The primitive probe tests the actual selected account, filesystem, hash tool,
# exclusive-create, hard-link no-replace and exact readback before admission.
hash() {
 if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1
 elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d ' ' -f 1
 else out storage_error; fi
}
decode() {
 if printf Zg== | base64 -d >/dev/null 2>&1; then base64 -d
 else base64 -D; fi
}
regular() { [ ! -L "$1" ] && [ -f "$1" ]; }
# Withdrawal checks use the same reviewed, bundled JSON validators as consumption.
fail() { out "$1"; }
b64() { base64 < "$1" | tr -d '\r\n'; }
un64() { decode; }
safe_file() { regular "$1" && [ "$(wc -c < "$1")" -le "$2" ] || out binding_mismatch; }
strict() {
 safe_file "$1" "$2"
 [ "$(wc -c < "$1")" -eq "$(tr -d '\000' < "$1" | wc -c)" ] || out invalid_schema
 { if iconv -f UTF-8 -t UTF-8 "$1" 2>/dev/null; then printf '\n0\n'; else printf '\n1\n'; fi; } | awk 'END { exit ($0 != "0") }' || out invalid_schema
 awk -f "$validator" "$1" || out invalid_schema
}
has_capability() { jq -e --arg name "$1" '(.capabilities // [])|type=="array" and index($name)!=null' "$box/provision.json" >/dev/null || out unsupported_capability; }
bind_check() {
 jq -e --argjson binding "$binding" 'all(["logical_session_id","worker_id","worker_generation","launch_request_id","work_id"][];. as $key|$binding[$key]==$value[$key])' --argjson value "$(cat "$1")" "$box/provision.json" >/dev/null || out binding_mismatch
}
# This is authorization to discard exact physical bytes, never a consumer ACK.
validate_withdrawn() {
 [ -n "$withdrawn_starts_b64" ] || return 0
 [ "${#withdrawn_starts_b64}" -le 4096 ] || fail invalid_schema
 printf '%s' "$withdrawn_starts_b64" | un64 > "$work/withdrawn" || fail invalid_schema
 strict "$work/withdrawn" 3072
 [ "$(b64 "$work/withdrawn")" = "$withdrawn_starts_b64" ] || fail invalid_schema
 jq -e --argjson floor "$reply_floor" '
  def integer: type=="number" and .>=1 and .<=9007199254740991 and .==floor;
  type=="array" and length>=1 and length<=8 and
  all(.[]; type=="object" and keys==["message_id","message_sha256","reply_seq"] and
   (.reply_seq|integer) and (.message_id|type=="string" and test("\\A[A-Za-z0-9_-]{1,96}\\z")) and
   (.message_sha256|type=="string" and test("\\A[0-9a-f]{64}\\z"))) and
  ([.[].reply_seq]==[range($floor+1;$floor+1+length)])
 ' "$work/withdrawn" >/dev/null || fail invalid_schema
 has_capability coordinator-control-v1; has_capability project-start-v1
 jq -e --arg handle "$handle" '
  def id: type=="string" and test("\\A[A-Za-z0-9_-]{1,96}\\z");
  .binding as $b | .handle==$handle and $b.mailbox_handle==$handle and
  ($b|keys)==["enrolment_token","launch_request_id","logical_session_id","mailbox_handle","work_id","worker_generation","worker_id"] and
  ([$b.logical_session_id,$b.worker_id,$b.launch_request_id,$b.work_id,$b.mailbox_handle]|all(.[];id)) and
  ($b.worker_generation|type=="number" and .>=1 and .<=9007199254740991 and .==floor) and
  ($b.enrolment_token|type=="string" and test("\\A[A-Za-z0-9_-]{16,128}\\z"))
 ' "$box/provision.json" >/dev/null || fail binding_mismatch
 jq -r '.[].reply_seq' "$work/withdrawn" > "$work/withdrawn-seqs"
 # Include hidden entries; every above-floor slot must be expressly named.
 for entry in "$box/replies/"* "$box/replies/".[!.]* "$box/replies/"..?*; do
  [ ! -e "$entry" ] && [ ! -L "$entry" ] && continue
  safe_dir "$entry"
  n=${entry##*/}; case "$n" in ''|0*|*[!0-9]*) fail binding_mismatch;; esac
  [ "${#n}" -le 16 ] && [ "$n" -le 9007199254740991 ] || fail binding_mismatch
  [ "$n" -le "$reply_floor" ] || jq -e --argjson n "$n" 'any(.[];.reply_seq==$n)' "$work/withdrawn" >/dev/null || fail incomplete
 done
 while IFS= read -r reply_seq; do
  slot_dir=$box/replies/$reply_seq; safe_dir "$slot_dir"
  manifest=$slot_dir/manifest.json; strict "$manifest" 2048
  jq -e --arg handle "$handle" --argjson seq "$reply_seq" --slurpfile withdrawn "$work/withdrawn" '
   (keys|sort)==(["transport","version","type","mailbox_handle","direction","slot","message_id","message_sha256","message_bytes","count"]|sort) and
   .transport=="report-files-v1" and .version==1 and .type=="manifest" and .direction=="reply" and .mailbox_handle==$handle and .slot==$seq and
   (.message_bytes|type=="number" and .>=1 and .<=65536 and .==floor) and .count==(.message_bytes/2048|ceil) and
   (. as $m|any($withdrawn[0][];.reply_seq==$seq and .message_id==$m.message_id and .message_sha256==$m.message_sha256))
  ' "$manifest" >/dev/null || fail binding_mismatch
  count=$(jq -r '.count' "$manifest"); seen=0
  for part in "$slot_dir/"* "$slot_dir/".[!.]* "$slot_dir/"..?*; do
   [ ! -e "$part" ] && [ ! -L "$part" ] && continue
   safe_file "$part" 4096; name=${part##*/}
   case "$name" in manifest.json) ;; chunk-*.json)
    idx=${name#chunk-}; idx=${idx%.json}; case "$idx" in ''|0*|*[!0-9]*) fail binding_mismatch;; esac
    [ "${#idx}" -le 2 ] && [ "$idx" -le "$count" ] || fail binding_mismatch;;
    *) fail binding_mismatch;; esac
   seen=$((seen+1))
  done
  [ "$seen" -eq "$((count+1))" ] || fail incomplete
  index=1; : > "$work/reply"
  while [ "$index" -le "$count" ]; do
   chunk=$slot_dir/chunk-$index.json; strict "$chunk" 4096
   jq -e --argjson manifest "$(cat "$manifest")" --argjson index "$index" '
    (keys|sort)==(["transport","version","type","mailbox_handle","direction","slot","message_id","message_sha256","index","count","data_b64"]|sort) and
    .type=="chunk" and .index==$index and (. as $chunk|all(["transport","version","mailbox_handle","direction","slot","message_id","message_sha256","count"][];. as $key|$chunk[$key]==$manifest[$key])) and
    (.data_b64|type=="string" and length>=4 and length<=2732 and length%4==0 and test("^[A-Za-z0-9+/]*={0,2}$"))
   ' "$chunk" >/dev/null || fail content_conflict
   encoded=$(jq -r '.data_b64' "$chunk"); printf '%s' "$encoded" | un64 > "$work/slice" 2>/dev/null || fail invalid_schema
   [ "$(b64 "$work/slice")" = "$encoded" ] || fail invalid_schema
   expected=2048; [ "$index" -lt "$count" ] || expected=$(jq '.message_bytes-(.count-1)*2048' "$manifest")
   [ "$(wc -c < "$work/slice")" -eq "$expected" ] || fail incomplete
   cat "$work/slice" >> "$work/reply"; index=$((index+1))
  done
  [ "$(hash "$work/reply")" = "$(jq -r '.message_sha256' "$manifest")" ] || fail content_conflict
  strict "$work/reply" 65536; bind_check "$work/reply"
  jq -e --argjson seq "$reply_seq" --arg message "$(jq -r '.message_id' "$manifest")" '.kind=="project_start" and .reply_seq==$seq and .message_id==$message' "$work/reply" >/dev/null || fail binding_mismatch
  jq -e -f "$reply_validator" "$work/reply" >/dev/null || fail invalid_schema
 done < "$work/withdrawn-seqs"
}
if [ "$mode" = provision ]; then
 safe_dir "${producer_helper%/*}"
 regular "$producer_helper" && [ -r "$producer_helper" ] || out binding_mismatch
 for tool in jq iconv awk base64; do command -v "$tool" >/dev/null 2>&1 || out storage_error; done
 for asset in mailbox_json.awk mailbox_reply.jq; do regular "${producer_helper%/*}/$asset" && [ -r "${producer_helper%/*}/$asset" ] || out binding_mismatch; done
fi
# Traversal is bounded by the allocation, rejects every unexpected node/type,
# and never follows links. Files and bounded directory traversal are separate.
files=0 total=0 directories=0
walk_bounded() {
 # find streams; expanding an unchecked directory glob could allocate an
 # unbounded list before a loop has a chance to enforce the allocation.
 # Balance case-arm parentheses inside $(): Bash 3.2 otherwise mistakes an
 # unpaired arm terminator for the end of the command substitution.
 scan=$(
  { find "$box" -print || printf '!storage_error\n'; } | (
   files=0 total=0 directories=0
   while IFS= read -r entry; do
    [ "$entry" != "$box" ] || continue
    case "$entry" in ("$box"/*) ;; (*) out storage_error;; esac
    [ ! -L "$entry" ] || out binding_mismatch
    relative=${entry#"$box"/}
    case "$relative" in (*/*/*/*) out binding_mismatch;; esac
    if [ -d "$entry" ]; then directories=$((directories+1)); [ "$directories" -le 1024 ] || full mailbox_directories "$directories" 1024
    elif regular "$entry"; then
     files=$((files+1)); [ "$files" -le 4096 ] || full mailbox_scan_files "$files" 4096
     size=$(wc -c < "$entry") || out storage_error
     total=$((total+size))
    else out binding_mismatch; fi
   done
   printf 'ok %s %s' "$files" "$total"
  )
 )
 case "$scan" in 'ok '*) set -- $scan; files=$2 total=$3;; *) out "$scan";; esac
}
case "$mode" in
 provision)
  [ ! -e "$box" ] && [ ! -L "$box" ] || out content_conflict
  mkdir "$box" || out storage_error
  for child in reports replies acks watermarks producer consumer staging; do mkdir "$box/$child" || out storage_error; done
  ;;
 *) if [ ! -e "$box" ] && [ ! -L "$box" ]; then [ "$mode" != reconcile_retire ] || out retired; out missing; fi; safe_dir "$box";;
esac
# Read-only observation: no admission lock, publication or cleanup side effect.
if [ "$mode" = inventory ]; then
 case "$selected" in ''|*[!0-9]*) out binding_mismatch;; esac
 [ "${#selected}" -le 12 ] && [ "$selected" -ge 1 ] && [ "$selected" -le 315360000000 ] || out binding_mismatch
 now=$(date +%s) || out storage_error
 case "$now" in ''|*[!0-9]*) out storage_error;; esac
 observed=$((now*1000)); cutoff=$((observed-selected))
 inventory=$(
  { find "$box" -print || printf '!storage_error\n'; } | (
   files=0 stale=0 directories=0
   while IFS= read -r entry; do
    [ "$entry" != "$box" ] || continue
    case "$entry" in ("$box"/*) ;; (*) out storage_error;; esac
    [ ! -L "$entry" ] || out binding_mismatch
    relative=${entry#"$box"/}
    case "$relative" in (*/*/*/*) out binding_mismatch;; esac
    if [ -d "$entry" ]; then
     directories=$((directories+1)); [ "$directories" -le 1024 ] || out storage_error
    elif regular "$entry"; then
     files=$((files+1)); [ "$files" -le 1000000 ] || out storage_error
     if modified=$(stat -c %Y "$entry" 2>/dev/null); then :
     elif modified=$(stat -f %m "$entry" 2>/dev/null); then :
     else out storage_error; fi
     case "$modified" in ''|*[!0-9]*) out storage_error;; esac
     [ $((modified*1000)) -gt "$cutoff" ] || stale=$((stale+1))
    else out binding_mismatch; fi
   done
   printf '{"observed_at_ms":%s,"open_files":%s,"stale_files":%s}\n' "$observed" "$files" "$stale"
  )
 )
 out "$inventory"
fi
# Read request input before acquiring shared admission: a slow stdin sender
# cannot hold the mailbox capacity gate. Read-only/compaction need no input.
case "$mode" in
 publish|reconcile)
  encoded=$(dd bs=1 count=5466 2>/dev/null)
  [ "${#encoded}" -le 5464 ] || full encoded_bytes "${#encoded}" 5464
  case "$encoded" in ''|*[!A-Za-z0-9+/=]*) out binding_mismatch;; esac;;
 provision|reconcile_provision)
  # Line 1 is provision.json; an optional line 2 is the assignment manifest
  # (<=4096 bytes, 5464 base64), bound by provision.json's manifest_sha256.
  request=$(dd bs=1 count=10932 2>/dev/null)
  [ "${#request}" -le 10929 ] || full encoded_bytes "${#request}" 10929
  nl='
'
  encoded=${request%%"$nl"*} manifest_b64=
  [ "$encoded" = "$request" ] || manifest_b64=${request#*"$nl"}
  [ "${#encoded}" -le 5464 ] || full encoded_bytes "${#encoded}" 5464
  [ "${#manifest_b64}" -le 5464 ] || full manifest_bytes "${#manifest_b64}" 5464
  case "$encoded" in ''|*[!A-Za-z0-9+/=]*) out binding_mismatch;; esac
  case "$manifest_b64" in *[!A-Za-z0-9+/=]*) out binding_mismatch;; esac;;
esac
admission=$box/capacity.lock
if ! mkdir "$admission" 2>/dev/null; then
 [ ! -L "$admission" ] || out binding_mismatch
 [ -d "$admission" ] || out storage_error
 if [ "$mode" = provision ]; then full capacity_admission 1 1; fi
 printf 'admission_full\ncapacity_admission\n1\n1\n'; exit 0
fi
admitted=1
clear_withdrawn_work() {
 [ -z "${work:-}" ] || { for file in "$work/"*; do [ ! -e "$file" ] || rm "$file"; done; rmdir "$work"; work=; }
}
cleanup() { clear_withdrawn_work; [ "$admitted" = 0 ] || rmdir "$admission"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# Target and worker hold the same short-lived lock through scan and commit.
# Never steal an interrupted gate by PID or elapsed time.
walk_bounded
case "$selected" in
 provision.json) ;;
 watermarks) [ "$mode" = read ] || out binding_mismatch;;
 reports/*/manifest.json|replies/*/manifest.json|reports/*/chunk-*.json|replies/*/chunk-*.json)
  stream=${selected%%/*}; rest=${selected#*/}; slot=${rest%%/*}; part=${rest#*/}
  case "$slot" in ''|0*|*[!0-9]*) out binding_mismatch;; esac
  case "$part" in manifest.json) ;; chunk-*.json) idx=${part#chunk-}; idx=${idx%.json}; case "$idx" in ''|0*|*[!0-9]*) out binding_mismatch;; esac; [ "$idx" -le 32 ] || out binding_mismatch;; *) out binding_mismatch;; esac
  case "$rest" in */*/*) out binding_mismatch;; esac
  ;;
 acks/*.json|watermarks/*.json)
  slot=${selected#*/}; slot=${slot%.json}; case "$slot" in ''|0*|*[!0-9]*) out binding_mismatch;; esac;;
 -) case "$mode" in compact|retire|reconcile_compact|reconcile_retire) ;; *) out binding_mismatch;; esac;;
 *) out binding_mismatch;;
esac
if [ "$mode" = read ] && [ "$selected" = watermarks ]; then
 latest=0 count=0
 for file in "$box/watermarks/"*.json; do
  [ -e "$file" ] || continue
  regular "$file" || out binding_mismatch
  n=${file##*/}; n=${n%.json}; case "$n" in ''|0*|*[!0-9]*) out binding_mismatch;; esac
  count=$((count+1)); [ "$count" -le 3 ] || full watermark_files "$count" 3
  [ "$n" -le "$latest" ] || latest=$n
 done
 [ "$latest" != 0 ] || out missing
 selected=watermarks/$latest.json
elif [ "$mode" = read ]; then
 [ -e "$box/$selected" ] || out missing
fi
if [ "$mode" = read ]; then
 if [ "$selected" = provision.json ]; then safe_dir "$box"; else safe_dir "${box}/${selected%/*}"; fi
 regular "$box/$selected" || out binding_mismatch
 size=$(wc -c < "$box/$selected"); [ "$size" -le 4096 ] || full object_bytes "$size" 4096
 printf 'object\n'; [ -z "${latest:-}" ] || printf '%s\n' "$latest"
 dd if="$box/$selected" bs=4097 count=1 2>/dev/null | base64 | tr -d '\r\n'; printf '\n'; exit 0
fi
if [ "$mode" = reconcile_retire ]; then out incomplete; fi
if [ "$mode" = reconcile_compact ]; then
 for stream in reports replies acks; do
  safe_dir "$box/$stream"
  floor=$report_floor; [ "$stream" != replies ] || floor=$reply_floor
  for entry in "$box/$stream/"*; do
   [ -e "$entry" ] || continue
   n=${entry##*/}; [ "$stream" != acks ] || n=${n%.json}
   case "$n" in ''|0*|*[!0-9]*) out binding_mismatch;; esac
   [ "$n" -gt "$floor" ] || out incomplete
  done
 done
 out compacted
fi
# All retirement safety checks precede deletion, including settled-prefix deletion.
if [ "$mode" = retire ]; then
 case "$report_floor:$reply_floor" in *[!0-9:]*) out binding_mismatch;; esac
 [ -n "$report_floor" ] && [ -n "$reply_floor" ] && [ "${#report_floor}" -le 16 ] && [ "${#reply_floor}" -le 16 ] &&
  [ "$report_floor" -le 9007199254740991 ] && [ "$reply_floor" -le 9007199254740991 ] || out binding_mismatch
 for entry in "$box/"* "$box/".[!.]* "$box/"..?*; do
  [ ! -e "$entry" ] && [ ! -L "$entry" ] && continue
  case "${entry##*/}" in reports|replies|acks|watermarks|producer|consumer|staging|capacity.lock) safe_dir "$entry";;
   provision.json|manifest.json) regular "$entry" || out binding_mismatch;; *) out binding_mismatch;; esac
 done
 for child in producer consumer staging; do
  safe_dir "$box/$child"
  for entry in "$box/$child/"* "$box/$child/".[!.]* "$box/$child/"..?*; do
   [ ! -e "$entry" ] && [ ! -L "$entry" ] || out incomplete
  done
 done
 for stream in reports replies acks watermarks; do
  safe_dir "$box/$stream"
  floor=$report_floor; [ "$stream" != replies ] || floor=$reply_floor
  for entry in "$box/$stream/"* "$box/$stream/".[!.]* "$box/$stream/"..?*; do
   [ ! -e "$entry" ] && [ ! -L "$entry" ] && continue
   n=${entry##*/}; case "$stream" in acks|watermarks) n=${n%.json}; [ "${entry##*/}" = "$n.json" ] || out binding_mismatch;; esac
   case "$n" in ''|0*|*[!0-9]*) out binding_mismatch;; esac
   [ "${#n}" -le 16 ] && [ "$n" -le 9007199254740991 ] || out binding_mismatch
   if [ "$n" -gt "$floor" ]; then
    [ "$stream" = watermarks ] || { [ "$stream" = replies ] && [ -n "$withdrawn_starts_b64" ]; } || out incomplete
   fi
   case "$stream" in acks|watermarks) regular "$entry" || out binding_mismatch;; *)
    safe_dir "$entry"
    for part in "$entry/"* "$entry/".[!.]* "$entry/"..?*; do
     [ ! -e "$part" ] && [ ! -L "$part" ] && continue
     regular "$part" || out binding_mismatch
     name=${part##*/}; case "$name" in manifest.json) ;; chunk-*.json)
      idx=${name#chunk-}; idx=${idx%.json}; case "$idx" in ''|0*|*[!0-9]*) out binding_mismatch;; esac
      [ "${#idx}" -le 2 ] && [ "$idx" -le 32 ] || out binding_mismatch;; *) out binding_mismatch;; esac
    done;; esac
  done
 done
 regular "$box/provision.json" || out incomplete
 if [ -n "$withdrawn_starts_b64" ]; then
  safe_dir "${producer_helper%/*}"
  validator=${producer_helper%/*}/mailbox_json.awk; reply_validator=${producer_helper%/*}/mailbox_reply.jq
  safe_file "$validator" 16384; safe_file "$reply_validator" 32768
  for tool in jq iconv awk base64; do command -v "$tool" >/dev/null 2>&1 || out storage_error; done
  strict "$box/provision.json" 2048
  jq -e --arg handle "$handle" '.handle==$handle and .binding.mailbox_handle==$handle' "$box/provision.json" >/dev/null || out binding_mismatch
  binding=$(jq -c '.binding' "$box/provision.json")
  work=$box/staging/withdraw-$operation; mkdir "$work" || out incomplete
  validate_withdrawn
  clear_withdrawn_work
 fi
fi
if [ "$mode" = compact ] || [ "$mode" = retire ]; then
 for stream in reports replies acks; do
  floor=$report_floor; [ "$stream" != replies ] || floor=$reply_floor
  for entry in "$box/$stream/"*; do
   [ -e "$entry" ] || continue
   n=${entry##*/}; [ "$stream" != acks ] || n=${n%.json}
   case "$n" in ''|0*|*[!0-9]*) out binding_mismatch;; esac
   [ "$n" -le "$floor" ] || { [ "$mode" = retire ] && [ "$stream" = replies ] && [ -n "$withdrawn_starts_b64" ]; } || { [ "$mode" != retire ] || out incomplete; continue; }
   if [ "$stream" = acks ]; then regular "$entry" || out binding_mismatch; rm "$entry"
   else
    safe_dir "$entry"
    for part in "$entry/"*; do
     [ -e "$part" ] || continue
     regular "$part" || out binding_mismatch
     name=${part##*/}; case "$name" in manifest.json|chunk-*.json) ;; *) out binding_mismatch;; esac
     rm "$part"
    done
    rmdir "$entry" || out incomplete
   fi
  done
 done
 if [ "$mode" = compact ]; then out compacted; fi
 # A producer must explicitly settle/clear its private journal. Never erase an
 # unresolved worker claim just because the host's report prefix is settled.
 for child in producer consumer staging; do rmdir "$box/$child" || out incomplete; done
 for file in "$box/watermarks/"*.json; do [ ! -e "$file" ] || { regular "$file" || out binding_mismatch; rm "$file"; }; done
 for child in reports replies acks watermarks; do rmdir "$box/$child" || out incomplete; done
 regular "$box/provision.json" || out incomplete
 if [ -e "$box/manifest.json" ] || [ -L "$box/manifest.json" ]; then regular "$box/manifest.json" || out binding_mismatch; rm "$box/manifest.json"; fi
 rm "$box/provision.json"
 rmdir "$admission" || out incomplete; admitted=0
 rmdir "$box" || out incomplete; out retired
fi
case "$mode" in provision|publish|reconcile|reconcile_provision) ;; *) out binding_mismatch;; esac
[ -z "${manifest_b64:-}" ] || [ "$selected" = provision.json ] || out binding_mismatch
manifest=$box/manifest.json
if [ -e "$manifest" ] || [ -L "$manifest" ]; then regular "$manifest" || out binding_mismatch; fi
if [ "$selected" = provision.json ]; then parent=$box; else parent=$box/${selected%/*}; fi
if [ ! -d "$parent" ]; then
 case "$mode:$selected" in publish:replies/*/*) safe_dir "$box/replies"; mkdir "$parent" || out storage_error;; *) out missing;; esac
fi
safe_dir "$parent"
final=$box/$selected
if [ -e "$final" ] || [ -L "$final" ]; then regular "$final" || out binding_mismatch; fi
# Read-only reconciliation must not create staging files or retry effects.
if [ "$mode" = reconcile ] || [ "$mode" = reconcile_provision ]; then
 [ -e "$final" ] || out missing
 regular "$final" || out binding_mismatch
 size=$(wc -c < "$final"); [ "$size" -le 4096 ] || full object_bytes "$size" 4096
 actual=$(base64 < "$final" | tr -d '\r\n')
 [ "$actual" = "$encoded" ] || out content_conflict
 if [ "$mode" = reconcile_provision ]; then
  if [ -n "$manifest_b64" ]; then
   [ -e "$manifest" ] || out missing
   size=$(wc -c < "$manifest"); [ "$size" -le 4096 ] || full manifest_bytes "$size" 4096
   [ "$(base64 < "$manifest" | tr -d '\r\n')" = "$manifest_b64" ] || out content_conflict
  elif [ -e "$manifest" ]; then out content_conflict; fi
  out provisioned
 fi
 out already_published
fi
# Identical immutable replay does not need staging or spend drain headroom.
if [ -e "$final" ]; then
 size=$(wc -c < "$final"); [ "$size" -le 4096 ] || full object_bytes "$size" 4096
 [ "$(base64 < "$final" | tr -d '\r\n')" = "$encoded" ] || out content_conflict
 [ "$mode" != provision ] || out provisioned
 out already_published
fi
# Policy shared with both worker/platform helpers: ordinary durable 2MiB/896;
# settlement 2.25MiB/1008. Remaining 1.75MiB/16 funds an actual 1.5MiB
# journal replacement and 256KiB workspace. Hard-link publication briefly
# counts both the staging name and final name against the hard ceiling.
byte_limit=2097152 file_limit=896
case "$selected" in acks/*.json|watermarks/*.json) byte_limit=2359296; file_limit=1008;; esac
wire_bytes=$(( ${#encoded}/4*3 ))
case "$encoded" in *==) wire_bytes=$((wire_bytes-2));; *=) wire_bytes=$((wire_bytes-1));; esac
[ "$wire_bytes" -le 4096 ] || full object_bytes "$wire_bytes" 4096
manifest_files=0 manifest_bytes=0
if [ -n "${manifest_b64:-}" ]; then
 manifest_files=1 manifest_bytes=$(( ${#manifest_b64}/4*3 ))
 case "$manifest_b64" in *==) manifest_bytes=$((manifest_bytes-2));; *=) manifest_bytes=$((manifest_bytes-1));; esac
 [ "$manifest_bytes" -ge 1 ] && [ "$manifest_bytes" -le 4096 ] || full manifest_bytes "$manifest_bytes" 4096
fi
[ "$((files+1+manifest_files))" -le "$file_limit" ] || full mailbox_files "$((files+1+manifest_files))" "$file_limit"
[ "$((total+wire_bytes+manifest_bytes))" -le "$byte_limit" ] || full mailbox_bytes "$((total+wire_bytes+manifest_bytes))" "$byte_limit"
[ "$((files+2+manifest_files*2))" -le 1024 ] || full mailbox_files "$((files+2+manifest_files*2))" 1024
[ "$((total+(wire_bytes+manifest_bytes)*2))" -le 4194304 ] || full mailbox_bytes "$((total+(wire_bytes+manifest_bytes)*2))" 4194304
safe_dir "$box/staging"
tmp=$box/staging/$operation.tmp
(set -C; printf '%s' "$encoded" | decode > "$tmp") || out storage_error
regular "$tmp" || out binding_mismatch
size=$(wc -c < "$tmp"); [ "$size" -le 4096 ] || full object_bytes "$size" 4096
[ "$(base64 < "$tmp" | tr -d '\r\n')" = "$encoded" ] || out content_conflict
# Every target must have a working hash implementation; compare a known vector.
if [ "$mode" = provision ]; then
 probe=$box/staging/$operation.probe
 (set -C; printf abc > "$probe") || out storage_error
 [ "$(hash "$probe")" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ] || out storage_error
 rm "$probe"
 # The manifest is linked before provision.json: a provisioned mailbox never
 # lacks the manifest its binding digest names. Bytes are stored verbatim.
 bound=$(jq -r 'if has("manifest_sha256") then .manifest_sha256 else "" end' "$tmp") || out binding_mismatch
 if [ -n "$manifest_b64" ]; then
  case "$bound" in *[!0-9a-f]*|'') out binding_mismatch;; esac
  [ "${#bound}" = 64 ] || out binding_mismatch
  staged=$box/staging/$operation.manifest
  (set -C; printf '%s' "$manifest_b64" | decode > "$staged") || out storage_error
  regular "$staged" || out binding_mismatch
  size=$(wc -c < "$staged"); [ "$size" -le 4096 ] || full manifest_bytes "$size" 4096
  [ "$(base64 < "$staged" | tr -d '\r\n')" = "$manifest_b64" ] || out content_conflict
  [ "$(hash "$staged")" = "$bound" ] || out binding_mismatch
  if ! ln "$staged" "$manifest" 2>/dev/null; then regular "$manifest" && cmp -s "$staged" "$manifest" || out content_conflict; fi
  regular "$manifest" && cmp -s "$staged" "$manifest" || out content_conflict
  rm "$staged"
 else
  [ -z "$bound" ] || out binding_mismatch
 fi
fi
status=published
if ! ln "$tmp" "$final" 2>/dev/null; then
 regular "$final" || out content_conflict
 cmp -s "$tmp" "$final" || out content_conflict
 status=already_published
fi
regular "$final" && cmp -s "$tmp" "$final" || out content_conflict
rm "$tmp"
[ "$mode" != provision ] || status=provisioned
out "$status"
