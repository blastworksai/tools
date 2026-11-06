#!/bin/sh
# Fixed report-files-v1 adapter. Install reviewed asset explicitly, not from a
# public request. No eval, arbitrary child path, recursive rm, or runtime install.
set -eu
umask 077
root=$1 handle=$2 mode=$3 selected=$4 operation=$5 identity=$6 report_floor=$7 reply_floor=$8
producer_helper=$9
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
cleanup() { [ "$admitted" = 0 ] || rmdir "$admission"; }
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
if [ "$mode" = compact ] || [ "$mode" = retire ]; then
 for stream in reports replies acks; do
  floor=$report_floor; [ "$stream" != replies ] || floor=$reply_floor
  for entry in "$box/$stream/"*; do
   [ -e "$entry" ] || continue
   n=${entry##*/}; [ "$stream" != acks ] || n=${n%.json}
   case "$n" in ''|0*|*[!0-9]*) out binding_mismatch;; esac
   [ "$n" -le "$floor" ] || { [ "$mode" != retire ] || out incomplete; continue; }
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
