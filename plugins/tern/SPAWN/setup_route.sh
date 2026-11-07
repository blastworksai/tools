#!/bin/sh
# Offline native-terminal route observation. No provider process or repository writes.
set -eu
umask 077
output=$1 nonce=$2 value=$3
case "$nonce" in ''|*[!a-z0-9_-]*) exit 1;; esac
[ "$#" = 3 ] && [ ! -e "$output" ] && [ ! -L "$output" ] || exit 1
case "$output" in /*) ;; *) exit 1;; esac
parent=${output%/*}
while [ -n "$parent" ] && [ "$parent" != / ]; do
 [ ! -L "$parent" ] && [ -d "$parent" ] || exit 1
 parent=${parent%/*}
done
if command -v sha256sum >/dev/null 2>&1; then digest=$(printf '%s' "$value" | sha256sum | cut -d ' ' -f 1)
else digest=$(printf '%s' "$value" | shasum -a 256 | cut -d ' ' -f 1); fi
(set -C; printf '%s\n%s\n%s\n' "$nonce" "$digest" "$(id -un)" > "$output")
# Keep this exact helper shell inspectable until native owner cleanup, at most
# 45 seconds after publication. The trailing builtin prevents a final-command
# exec optimization from replacing its identity with sleep.
sleep 45
exit 0
