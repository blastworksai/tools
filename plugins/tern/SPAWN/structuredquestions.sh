#!/bin/sh
# SPAWN Guided setup: the exact structured-question script (SKILLS-210, redesigned for the common case in SKILLS-213).
# Read-only and deterministic. It discovers the machine itself, then prints ONE JSON object on stdout that the
# setup helper renders 1:1 with its native structured-question tool. It starts no provider session, installs
# nothing, logs nothing in and writes nothing outside its own private temporary folder (removed on exit).
#
#   structuredquestions.sh [--glitch-root <path>]... [--cwd <path>]                       phase 1
#   structuredquestions.sh --phase 2 [--accounts <cli>=<label>,<label>]... [--map <id>=<key|path>]...
#                          [--skip <id>]... [--glitch-root <path>]... [--cwd <path>]      phase 2
#   structuredquestions.sh --check-args <cli> <word>...                                   one Custom argument check
#
# Phase 1 asks only about accounts (how many per provider and their labels); it never proposes a label and names no
# discovered user or install. Phase 2 runs the discovery again with those answers and proposes which install runs
# each account, then asks permissions, folder, OMP service and the review.
# --glitch-root: a root the host already verified (repeatable). --cwd: the launch folder.
# Limits: every prompt carries at most 4 questions and every question at most 4 options (Claude Code
# AskUserQuestion: 1-4 questions, 2-4 options, automatic "Other"; OMP's ask tool accepts more, so the stricter
# bound is used). The Windows twin is structuredquestions.ps1.
set -u
umask 077

TAB=$(printf '\t')
providers="claude codex kimi grok agy muse omp"

# One Custom permission answer: the words the helper split from the typed text, checked as argv data. The words are
# stored as a list and never pass through a shell, so the check refuses only what could be mistaken for shell text.
if [ "${1:-}" = --check-args ]; then
	shift
	exec env LC_ALL=C awk '
	function esc(s,   r, i, c) { r = ""; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "\\") r = r "\\\\"; else if (c == "\"") r = r "\\\""; else if (c < " " || c == "\177") r = r sprintf("\\u%04x", 0); else r = r c }; return r }
	function fail(m) { printf "{\"ok\":false,\"why\":\"%s\"}\n", esc(m); exit 3 }
	# JSON travels as UTF-8: a word that is not valid UTF-8 is refused, never printed as broken JSON.
	function utf8ok(s,   i, n, c, k, j, d) {
		n = length(s)
		for (i = 1; i <= n; i++) {
			c = ordv[substr(s, i, 1)]
			if (c < 128) continue
			if (c >= 194 && c <= 223) k = 1; else if (c >= 224 && c <= 239) k = 2; else if (c >= 240 && c <= 244) k = 3; else return 0
			if (i + k > n) return 0
			for (j = 1; j <= k; j++) { d = ordv[substr(s, i + j, 1)]; if (d < 128 || d > 191) return 0 }
			d = ordv[substr(s, i + 1, 1)]
			if ((c == 224 && d < 160) || (c == 237 && d > 159) || (c == 240 && d < 144) || (c == 244 && d > 143)) return 0
			i += k
		}
		return 1
	}
	BEGIN {
		for (i = 0; i < 256; i++) ordv[sprintf("%c", i)] = i
		bad["\047"] = "a single quote (\047)"; bad["\""] = "a double quote (\")"; bad["\\"] = "a backslash (\\)"
		bad["`"] = "a backtick (`)"; bad["$"] = "a dollar sign ($)"; bad[";"] = "a semicolon (;)"; bad["&"] = "an ampersand (&)"
		bad["|"] = "a vertical bar (|)"; bad["<"] = "a less-than sign (<)"; bad[">"] = "a greater-than sign (>)"
		bad["("] = "a parenthesis (()"; bad[")"] = "a parenthesis ())"; bad["{"] = "a brace ({)"; bad["}"] = "a brace (})"
		bad["*"] = "an asterisk (*)"; bad["?"] = "a question mark (?)"; bad["!"] = "an exclamation mark (!)"
		bad["#"] = "a hash sign (#)"; bad["~"] = "a tilde (~)"
		if (ARGC < 2 || ARGV[1] !~ /^(claude|codex|kimi|grok|agy|muse|omp)$/) fail("SPAWN knows no such CLI.")
		if (ARGC < 3) fail("Type at least one argument.")
		if (ARGC - 2 > 256) fail("At most 256 arguments.")
		out = ""
		for (i = 2; i < ARGC; i++) {
			w = ARGV[i]
			if (w == "") fail("An argument is empty.")
			if (length(w) > 4096) fail("An argument is longer than 4096 characters.")
			if (substr(w, 1, 1) == "=") fail("An argument cannot start with =.")
			if (!utf8ok(w)) fail("Arguments must be valid UTF-8 text.")
			for (j = 1; j <= length(w); j++) {
				c = substr(w, j, 1)
				if (c < " " || c == "\177") fail("Arguments cannot contain control characters, such as a tab or a line break.")
				if (c in bad) fail("Arguments cannot contain " bad[c] ".")
			}
			out = out (out == "" ? "" : ",") "\"" w "\""
		}
		printf "{\"ok\":true,\"arguments\":[%s]}\n", out
		exit 0
	}' "$@"
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/spawn-questions.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
trap 'exit 1' INT TERM
FACTS=$T/facts
: >"$FACTS"
# Every external call is bounded: SPAWN_QUESTIONS_TIMEOUT seconds (default 20), then TERM, then KILL.
# This works without GNU timeout (macOS has none): a background watcher kills the call.
TMO=${SPAWN_QUESTIONS_TIMEOUT:-20}

# Fact fields are written percent-encoded (percent, control bytes), so a tab or newline inside a path or a label can
# never split a field or forge a fact row; the formatter decodes them.
fe() {
	printf '%s' "$1" | od -An -v -to1 | LC_ALL=C awk '{for(i=1;i<=NF;i++){d=substr($i,1,1)*64+substr($i,2,1)*8+substr($i,3,1);if(d<32||d==127||d==37)printf "%%%02X",d;else printf "%c",d}}'
}
printable() { case $1 in *[![:print:]]*) return 1 ;; esac; return 0; }
usage() {
	printf 'usage: structuredquestions.sh [--phase 1|2] [--accounts <cli>=<labels>]... [--map <id>=<key|path>]... [--skip <id>]... [--glitch-root <path>]... [--cwd <path>]\n       structuredquestions.sh --check-args <cli> <word>...\n' >&2
	exit 2
}

glitch_roots=""
launch_cwd=$(pwd)
phase=1
while [ "$#" -gt 0 ]; do
	[ "$#" -ge 2 ] || usage
	case $1 in
	--glitch-root) glitch_roots="$glitch_roots
$2" ;;
	--cwd) launch_cwd=$2 ;;
	--phase) case $2 in 1|2) phase=$2 ;; *) usage ;; esac ;;
	# Answers cross as argv data and are stored encoded; the mapper parses and checks them.
	--accounts) phase=2; printf 'ANS\t%s\n' "$(fe "$2")" >>"$FACTS"; printf 'RARG\t%s\t%s\n' "$1" "$(fe "$2")" >>"$FACTS" ;;
	--map) phase=2; printf 'MAPO\t%s\n' "$(fe "$2")" >>"$FACTS"; printf 'RARG\t%s\t%s\n' "$1" "$(fe "$2")" >>"$FACTS" ;;
	--skip) phase=2; printf 'SKIP\t%s\n' "$(fe "$2")" >>"$FACTS"; printf 'RARG\t%s\t%s\n' "$1" "$(fe "$2")" >>"$FACTS" ;;
	*) usage ;;
	esac
	shift 2
done

operator=$(id -un)
operator_home=${HOME:-}
# The one system-wide Glitch location; SPAWN_QUESTIONS_SYSTEM_GLITCH exists only so tests can run hermetically.
system_glitch=${SPAWN_QUESTIONS_SYSTEM_GLITCH:-/opt/glitch}

# Run one command with stdin closed, output to a private file, killed after TMO seconds.
# Each call is started as the leader of its own process group (setsid where there is one, else perl's setpgrp,
# both exec in place so $! is the group id), so TERM then KILL reaches the whole tree a CLI wrapper started,
# a straggler is killed even when the wrapper exits normally, and the watcher is a group of its own whose
# sleep is reaped with it. Where neither tool exists only the leader's pid is signalled.
# bounded <merge-stderr 0|1> command words...; prints the output, returns the status.
GRP=""
if command -v setsid >/dev/null 2>&1; then GRP="setsid"
elif command -v perl >/dev/null 2>&1; then GRP="perl -e setpgrp(0,0);exec(@ARGV)||exit(127) --"; fi
gkill() { # signal, pid: the pid's whole process group when it leads one
	if [ -n "$GRP" ]; then kill -s "$1" -- "-$2" 2>/dev/null || kill -s "$1" "$2" 2>/dev/null; else kill -s "$1" "$2" 2>/dev/null; fi
	return 0
}
bounded() {
	bmerge=$1; shift
	bf=$T/b.out
	if [ "$bmerge" = 1 ]; then $GRP "$@" >"$bf" 2>&1 </dev/null & else $GRP "$@" >"$bf" 2>/dev/null </dev/null & fi
	bpid=$!
	if [ -n "$GRP" ]; then
		$GRP /bin/sh -c 'sleep "$1"; kill -s TERM -- "-$2"; sleep 2; kill -s KILL -- "-$2"' watcher "$TMO" "$bpid" >/dev/null 2>&1 </dev/null &
	else
		( sleep "$TMO"; kill -s TERM "$bpid"; sleep 2; kill -s KILL "$bpid" ) >/dev/null 2>&1 </dev/null &
	fi
	wpid=$!
	wait "$bpid" 2>/dev/null; brc=$?
	gkill TERM "$bpid"
	gkill KILL "$bpid"
	gkill KILL "$wpid"
	wait "$wpid" 2>/dev/null
	cat "$bf"
	return $brc
}
# Run a program as the account that will run it, through the login route SPAWN launches with: sudo -n -i
# starts a constant /bin/sh script that decodes ONE word of octal escapes and execs it, so every argument
# crosses as data (the same road as launch_resolution's login_wrap). Nothing is ever put inside a shell string.
sq() { printf "'"; printf '%s' "$1" | sed "s/'/'\\\\''/g"; printf "'"; }
login_run() { # merge-stderr, account, then literal argv words
	lm=$1; lacct=$2; shift 2
	ltext=exec
	for lw in "$@"; do ltext="$ltext $(sq "$lw")"; done
	lenc=$(printf '%s' "$ltext" | od -An -v -to1 | LC_ALL=C awk '{for(i=1;i<=NF;i++)printf "\\%s",$i}')
	bounded "$lm" sudo -n -i -u "$lacct" -- /bin/sh -c 'eval "$(printf "${1}")"' spawn-login "$lenc"
}
# Every program of each CLI name on the running account's PATH, in PATH order: a constant script, the CLI names
# are its arguments. macOS and Linux have no portable `which -a`, so PATH is walked here. A folder that is not
# absolute, or holds a tab or a line break, is skipped, so a printed line is always "<cli><tab><absolute path>".
WALK='t=$(printf "\t"); nl="
"; set -f; IFS=:; for c do for d in $PATH; do case $d in /*) ;; *) continue ;; esac; case $d in *"$t"*|*"$nl"*) continue ;; esac; d=${d%/}; f=$d/$c; if [ -f "$f" ] && [ -x "$f" ]; then printf "%s\t%s\n" "$c" "$f"; fi; done; done; :'
cands_from() { # account kind home: reads walker output on stdin, writes CAND facts, prints the CLIs found
	while IFS="$TAB" read -r c p; do
		case $c in claude|codex|kimi|grok|agy|muse|omp) ;; *) continue ;; esac
		case $p in /*) ;; *) continue ;; esac
		printable "$p" || continue
		printf 'CAND\t%s\t%s\t%s\t%s\t%s\n' "$c" "$(fe "$1")" "$2" "$(fe "$p")" "$(fe "$3")" >>"$FACTS"
		printf '%s\n' "$c"
	done
}
omp_family() { # config text on stdin
	awk '/^modelRoles:/{m=1;next} m&&/^[^ \t]/{m=0} m&&$1=="default:"{v=$0;sub(/^[^:]*:[ \t]*/,"",v);gsub(/["'"'"']/,"",v);n=split(v,a,"/");if(n>=2&&a[1]~/^[a-z0-9._-]+$/)print a[1];exit}'
}

# Does this --help text list the flag as its own token (so --yolo-extra is not --yolo), and, for a valued
# flag, the value in that flag's own entry (its line plus lines indented deeper than it)?
help_has() { # help text, flag, value-or-empty
	printf '%s\n' "$1" | LC_ALL=C awk -v f="$2" -v v="$3" '
	function has(s, t,   i, off, b, a) {
		off = 0
		while ((i = index(substr(s, off + 1), t)) > 0) {
			i += off; b = (i > 1) ? substr(s, i - 1, 1) : " "; a = substr(s, i + length(t), 1)
			if (b !~ /[A-Za-z0-9_-]/ && a !~ /[A-Za-z0-9_-]/) return 1
			off = i
		}
		return 0
	}
	function judge() { if (v == "" || has(cur, v)) ok = 1 }
	{ ind = match($0, /[^ \t]/) - 1
	  # A continuation is indented deeper than the entry that holds the flag; a line at the same or a shallower
	  # indent (a sibling entry, a positional or environment name) or one starting with a dash ends the entry.
	  if (coll && $0 ~ /^[ \t]+[^ \t-]/ && ind > eind) { cur = cur " " $0; next }
	  if (coll) { judge(); coll = 0 }
	  if (has($0, f)) { coll = 1; cur = $0; eind = (ind < 0) ? 0 : ind } }
	END { if (coll) judge(); exit ok ? 0 : 1 }'
}
# The YOLO choice per provider: the flag its installed --help must show, its value (or empty) and the argv words.
yolo_flag() {
	case $1 in
	claude|agy) echo '--dangerously-skip-permissions||--dangerously-skip-permissions' ;;
	codex) echo '--dangerously-bypass-approvals-and-sandbox||--dangerously-bypass-approvals-and-sandbox' ;;
	kimi) echo '--auto||--auto' ;;
	grok) echo '--permission-mode|bypassPermissions|--permission-mode bypassPermissions' ;;
	muse) echo '--yolo||--yolo' ;;
	omp) echo '--approval-mode|yolo|--approval-mode yolo' ;;
	esac
}

# Candidate OS accounts: every real login (uid 1000-59999 and a login shell; macOS uid 500+), not the operator.
accounts() {
	if command -v getent >/dev/null 2>&1; then
		bounded 0 getent passwd | awk -F: '$3+0>=1000 && $3+0<60000 && $7!~/(nologin|false)$/ {print $1"\t"$6}'
	elif command -v dscl >/dev/null 2>&1; then
		bounded 0 dscl . -list /Users UniqueID | awk '$2+0>=500 && $2+0<60000 {print $1"\t/Users/"$1}'
	fi
}
accounts >"$T/accts" 2>/dev/null || :

sudo_ok=1
command -v sudo >/dev/null 2>&1 || sudo_ok=0
[ "$sudo_ok" = 0 ] && printf 'NOSUDO\n' >>"$FACTS"

printf 'OP\t%s\t%s\n' "$(fe "$operator")" "$(fe "$operator_home")" >>"$FACTS"
printf 'CWD\t%s\n' "$(fe "$launch_cwd")" >>"$FACTS"

# One bounded login run per OS account lists every CLI program on that account's own PATH. An account named for a
# provider that cannot be reached, or has no such CLI, is said plainly; any other account is simply not a candidate.
while IFS="$TAB" read -r name home; do
	[ -n "$name" ] || continue
	[ "$name" = "$operator" ] && continue
	case $name in *[!A-Za-z0-9._-]*) continue ;; esac
	printable "$home" || continue
	named=""
	for p in $providers; do
		case $name in "$p"*) named=$p ;; esac
	done
	if [ "$sudo_ok" = 0 ]; then
		[ -n "$named" ] && printf 'UNAV\t%s\t%s\tsudo is not installed, so this account was not checked\n' "$name" "$named" >>"$FACTS"
		continue
	fi
	# The route SPAWN will use for this very account, not root's: sudo -n -i -u <account>.
	if ! out=$(login_run 0 "$name" /bin/sh -c "$WALK" spawn-walk $providers); then
		[ -n "$named" ] && printf 'UNAV\t%s\t%s\tit cannot be reached with sudo -n -i -u\n' "$name" "$named" >>"$FACTS"
		continue
	fi
	printf 'USER\t%s\t%s\n' "$name" "$(fe "$home")" >>"$FACTS"
	got=$(printf '%s\n' "$out" | cands_from "$name" user "$home")
	if [ -n "$named" ] && ! printf '%s\n' "$got" | grep -F -x -q -e "$named"; then
		printf 'UNAV\t%s\t%s\tit has no %s it can run\n' "$name" "$named" "$named" >>"$FACTS"
	fi
done <"$T/accts"

# The operator's own installs, found on the operator's own PATH.
bounded 0 /bin/sh -c "$WALK" spawn-walk $providers | cands_from "$operator" operator "$operator_home" >/dev/null

# Glitch folder: verify each candidate the same way SPAWN does (the two marker scripts are regular, readable files).
: >"$T/cands"
add_cand() { printable "$1" && [ -n "$1" ] && printf '%s\n' "$1" >>"$T/cands"; return 0; }
printf '%s\n' "$glitch_roots" | while IFS= read -r r; do add_cand "$r"; done
add_cand "$system_glitch"
[ -n "$operator_home" ] && add_cand "$operator_home/Glitch"
walk=$launch_cwd
i=0
while [ -n "$walk" ] && [ "$i" -lt 32 ]; do
	add_cand "$walk"
	next=${walk%/*}
	[ "$next" = "$walk" ] && break
	[ -z "$next" ] && next=/
	[ "$walk" = / ] && break
	walk=$next
	i=$((i + 1))
done
: >"$T/glitch"
while IFS= read -r root; do
	[ -f "$root/.claude/scripts/workspaces.py" ] && [ -r "$root/.claude/scripts/workspaces.py" ] && [ -f "$root/.claude/scripts/plan_check.py" ] && [ -r "$root/.claude/scripts/plan_check.py" ] || continue
	grep -F -x -q -e "$root" "$T/glitch" 2>/dev/null || printf '%s\n' "$root" >>"$T/glitch"
done <"$T/cands"
while IFS= read -r root; do printf 'GLITCH\t%s\n' "$(fe "$root")" >>"$FACTS"; done <"$T/glitch"
printf 'PLACE\t%s\n' "$(fe "$system_glitch")" >>"$FACTS"
[ -n "$operator_home" ] && printf 'PLACE\t%s\n' "$(fe "$operator_home/Glitch")" >>"$FACTS"
printf 'PLACE\t%s\n' "the launch folder and its parents" >>"$FACTS"

# The one awk program: mode "map" turns the phase-2 answers into agents, mode "p1" and "p2" print the JSON.
PROG='
function esc(s,   r, i, c) {
	r = ""
	for (i = 1; i <= length(s); i++) {
		c = substr(s, i, 1)
		if (c == "\\") r = r "\\\\"
		else if (c == "\"") r = r "\\\""
		else if (c in ctl) r = r ctl[c]
		else r = r c
	}
	return r
}
function hexv(h) { return index("0123456789ABCDEF", toupper(h)) - 1 }
function dec(s,   r, i, c) {
	r = ""
	for (i = 1; i <= length(s); i++) {
		c = substr(s, i, 1)
		if (c == "%" && i + 2 <= length(s)) { r = r sprintf("%c", hexv(substr(s, i + 1, 1)) * 16 + hexv(substr(s, i + 2, 1))); i += 2 }
		else r = r c
	}
	return r
}
function enc(s,   r, i, c) {
	r = ""
	for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "%") r = r "%25"; else if (c in ctl) r = r sprintf("%%%02X", ctlv[c]); else r = r c }
	return r
}
function js(s) { return "\"" esc(s) "\"" }
function jb(b) { return b ? "true" : "false" }
function jarr(str,   n, a, i, r) {
	n = split(str, a, " ")
	r = ""
	for (i = 1; i <= n; i++) r = r (i > 1 ? "," : "") js(a[i])
	return "[" r "]"
}
# Characters, not bytes: a UTF-8 continuation byte does not start a character.
function clen(s,   i, n, c) { n = 0; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (!(c >= "\200" && c < "\300")) n++ }; return n }
function cut(s, m,   i, n, c, r) {
	if (clen(s) <= m) return s
	n = 0; r = ""
	for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (!(c >= "\200" && c < "\300")) { if (++n > m) break }; r = r c }
	return r
}
function utf8ok(s,   i, n, c, k, j, d) {
	n = length(s)
	for (i = 1; i <= n; i++) {
		c = ordv[substr(s, i, 1)]
		if (c < 128) continue
		if (c >= 194 && c <= 223) k = 1; else if (c >= 224 && c <= 239) k = 2; else if (c >= 240 && c <= 244) k = 3; else return 0
		if (i + k > n) return 0
		for (j = 1; j <= k; j++) { d = ordv[substr(s, i + j, 1)]; if (d < 128 || d > 191) return 0 }
		d = ordv[substr(s, i + 1, 1)]
		if ((c == 224 && d < 160) || (c == 237 && d > 159) || (c == 240 && d < 144) || (c == 244 && d > 143)) return 0
		i += k
	}
	return 1
}
function printable(s,   i, c) { for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c in ctl) return 0 }; return 1 }
function trim(s) { sub(/^ +/, "", s); sub(/ +$/, "", s); return s }
function reduce(s) { s = tolower(s); gsub(/[^a-z0-9]/, "", s); return s }
function slug(s) { s = tolower(s); gsub(/[^a-z0-9]+/, "-", s); sub(/^-+/, "", s); sub(/-+$/, "", s); return s }
function parentname(p,   n, a) { n = split(p, a, "/"); return n >= 2 ? a[n - 1] : "" }
function pname(p) {
	if (p == "claude") return "Claude"; if (p == "codex") return "Codex"; if (p == "kimi") return "Kimi"
	if (p == "grok") return "Grok"; if (p == "agy") return "Agy"; if (p == "muse") return "Muse"
	return "OMP"
}
function pfam(p) {
	if (p == "claude") return "anthropic"; if (p == "codex") return "openai"; if (p == "kimi") return "moonshot"
	if (p == "grok") return "xai"; if (p == "agy") return "google"; if (p == "muse") return "meta"
	return ""
}
# How an agent is named to a person: its label, after the provider name unless the label already starts with it.
function disp(p, label) { return index(tolower(label), tolower(pname(p))) == 1 ? label : pname(p) " " label }
function ordinal(n) {
	if (n == 2) return "second"; if (n == 3) return "third"; if (n == 4) return "fourth"; if (n == 5) return "fifth"
	if (n == 6) return "sixth"; if (n == 7) return "seventh"; if (n == 8) return "eighth"; if (n == 9) return "ninth"
	return n "th"
}
function refuse(m) { printf "{\"ok\":false,\"why\":%s}\n", js(m); refused = 1; exit 3 }
function opt(label, desc, pre, extra) { return "{\"label\":" js(label) ",\"description\":" js(desc) ",\"preselected\":" jb(pre) (extra != "" ? "," extra : "") "}" }
function question(id, q, header, multi, opts, extra) {
	return "{\"id\":" js(id) ",\"question\":" js(q) ",\"header\":" js(header) ",\"multiSelect\":" jb(multi) ",\"options\":[" opts "]" (extra != "" ? "," extra : "") "}"
}
function when(qid, label) { return "\"when\":{\"question\":" js(qid) ",\"is\":" js(label) "}" }
function lines_json(arr, n,   i, r) { r = ""; for (i = 1; i <= n; i++) r = r (i > 1 ? "," : "") js(arr[i]); return "[" r "]" }
# Prompts of at most 4 questions: a section longer than that continues in the next prompt. Lines are printed
# verbatim before the prompt (only before its first part).
function emit_section(id, title, qs, n, note, lines,   i, k, chunk, total, pid, ptitle) {
	if (n == 0) return
	total = int((n + 3) / 4)
	for (k = 1; k <= total; k++) {
		chunk = ""
		for (i = (k - 1) * 4 + 1; i <= n && i <= k * 4; i++) chunk = chunk (chunk == "" ? "" : ",") qs[i]
		pid = total == 1 ? id : id "-" k
		ptitle = total == 1 ? title : title " (" k " of " total ")"
		prompt_json[++pcount] = "{\"id\":" js(pid) ",\"title\":" js(ptitle) (k == 1 && lines != "" ? ",\"lines\":" lines : "") (note != "" ? "," note : "") ",\"questions\":[" chunk "]}"
	}
}
# Options split evenly into questions of at most 4 (ids qid-1, qid-2; one question keeps qid).
function chunked(qid, text, header, multi, olist, no, extra,   chunks, base, more, c, size, pos, j, opts, qt, hd, idl) {
	chunks = int((no + 3) / 4); base = int(no / chunks); more = no % chunks; pos = 1; idl = ""
	for (c = 1; c <= chunks; c++) {
		size = base + (c <= more ? 1 : 0); opts = ""
		for (j = 0; j < size; j++) opts = opts (opts == "" ? "" : ",") olist[pos + j]
		pos += size
		qt = chunks > 1 ? text " (" c " of " chunks ")" : text
		hd = chunks > 1 ? header " " c : header
		cq[++ncq] = question(chunks > 1 ? qid "-" c : qid, qt, hd, multi, opts, extra)
		idl = idl (idl == "" ? "" : ",") js(chunks > 1 ? qid "-" c : qid)
	}
	return "[" idl "]"
}
BEGIN {
	for (i = 1; i < 32; i++) { ctl[sprintf("%c", i)] = sprintf("\\u%04x", i); ctlv[sprintf("%c", i)] = i }
	ctl[sprintf("%c", 127)] = "\\u007f"; ctlv[sprintf("%c", 127)] = 127
	np = split("claude codex kimi grok agy muse omp", plist, " ")
	ncand = 0; nunav = 0; nglitch = 0; nplace = 0; nosudo = 0; pcount = 0; nans = 0; nmapo = 0; nrarg = 0; nag = 0; nmiss = 0
	EMD = "\342\200\224"; DOT = "\302\267"
	for (i = 0; i < 256; i++) ordv[sprintf("%c", i)] = i
}
$1 == "OP" { op = dec($2); ophome = dec($3) }
$1 == "CWD" { cwd = dec($2) }
$1 == "NOSUDO" { nosudo = 1 }
$1 == "USER" { uhome[$2] = dec($3); users[++nusers] = $2 }
$1 == "CAND" {
	u = dec($3); pth = dec($5)
	if (!utf8ok(pth) || !utf8ok(dec($6))) next
	if ((u SUBSEP $2 SUBSEP pth) in seencand) next
	seencand[u SUBSEP $2 SUBSEP pth] = 1
	ncand++; ccli[ncand] = $2; cuser[ncand] = u; ckind[ncand] = $4; cpath[ncand] = pth; chome[ncand] = dec($6)
	cn[ncand] = ++perusr[u SUBSEP $2]; ckey[ncand] = u "#" cn[ncand]; bykey[$2, ckey[ncand]] = ncand
	crank[ncand] = $4 == "operator" ? 1 : (index(u, $2) == 1 ? 0 : 2)
	found[$2] = 1
}
$1 == "UNAV" { nunav++; uacct[nunav] = $2; uprov[nunav] = $3; ureason[nunav] = $4 }
$1 == "GLITCH" { glitch[++nglitch] = dec($2) }
$1 == "PLACE" { place[++nplace] = dec($2) }
$1 == "ANS" { ans[++nans] = dec($2) }
$1 == "MAPO" { mapo[++nmapo] = dec($2) }
$1 == "SKIP" { skip[dec($2)] = 1 }
$1 == "RARG" { rarg[++nrarg] = $2; rarg[++nrarg] = dec($3) }
$1 == "AG" {
	nag++; gid[nag] = $2; gcli[nag] = $3; glabel[nag] = dec($4); guser[nag] = $5; gkind[nag] = $6; gpath[nag] = dec($7); ghome[nag] = dec($8)
	gkey[nag] = $9; gtyped[nag] = $10; gpos[nag] = $11; gsingle[nag] = $12; agcount[$3]++
}
$1 == "MISS" { nmiss++; mid[nmiss] = $2; mcli[nmiss] = $3; mlabel[nmiss] = dec($4); mpos[nmiss] = $5; agcount[$3]++ }
$1 == "SUP" { sup[$2] = $3 }
$1 == "FAM" { fam[$2] = $3 }
function sort_cands(p,   i, j, m, t, kk) {
	m = 0
	for (i = 1; i <= ncand; i++) if (ccli[i] == p) { so[++m] = i; sk[i] = crank[i] "\t" (crank[i] == 1 ? "" : cuser[i]) "\t" sprintf("%04d", cn[i]) }
	for (i = 2; i <= m; i++) { t = so[i]; kk = sk[t]; for (j = i - 1; j >= 1 && sk[so[j]] > kk; j--) so[j + 1] = so[j]; so[j + 1] = t }
	return m
}
function owner_of(path,   best, bl, u, h) {
	best = op; bl = length(ophome)
	if (!(ophome != "" && index(path, ophome "/") == 1)) bl = -1
	for (u in uhome) { h = uhome[u]; if (h != "" && index(path, h "/") == 1 && length(h) > bl) { best = u; bl = length(h) } }
	return best
}
# ---- mode map: answers -> agents (AG rows), accounts with no install (MISS rows), candidate keys (CK rows) ----
function do_map(   a, v, cli, lab, n, parts, k, l, p, pi, m, i, j, c, r, suf, par, id, base, sfx, pos, u, pth, hit, typedp) {
	for (a = 1; a <= nans; a++) {
		v = ans[a]
		if (index(v, "=") == 0) refuse("An --accounts answer needs the form <cli>=<label>,<label>.")
		cli = substr(v, 1, index(v, "=") - 1); lab = substr(v, index(v, "=") + 1)
		if (cli !~ /^(claude|codex|kimi|grok|agy|muse|omp)$/) refuse("SPAWN knows no CLI with that name.")
		if (!found[cli]) refuse("No " pname(cli) " was found on this machine, so it cannot have accounts.")
		if (cli in labels_of) refuse(pname(cli) " accounts were given twice.")
		n = split(lab, parts, ",")
		if (n > 16) refuse("At most 16 " pname(cli) " accounts.")
		if (n == 0) refuse("A " pname(cli) " label is empty.")
		labels_of[cli] = n
		for (k = 1; k <= n; k++) {
			l = trim(parts[k])
			if (l == "") refuse("A " pname(cli) " label is empty.")
			if (!printable(l)) refuse("A " pname(cli) " label has a control character, such as a tab or a line break.")
			if (!utf8ok(l)) refuse("A " pname(cli) " label must be valid UTF-8 text.")
			if (clen(l) > 32) refuse("The " pname(cli) " label \"" l "\" is longer than 32 characters.")
			if ((cli SUBSEP tolower(l)) in seenlab) refuse("Two " pname(cli) " accounts have the label \"" l "\".")
			seenlab[cli SUBSEP tolower(l)] = 1
			lbl[cli, k] = l
		}
	}
	# Accounts in provider order; one account without answers is labelled with the provider name.
	na = 0
	for (pi = 1; pi <= np; pi++) {
		p = plist[pi]
		if (!found[p]) continue
		if (p in labels_of) {
			for (k = 1; k <= labels_of[p]; k++) {
				base = slug(lbl[p, k])
				if (index(base, p "-") == 1) base = substr(base, length(p) + 2)
				else if (base == p) base = ""
				if (base == "") base = k
				id = p "-" base; sfx = 1
				while (id in usedid) { sfx++; id = p "-" base "-" sfx }
				usedid[id] = 1
				na++; aid[na] = id; acli[na] = p; alab[na] = lbl[p, k]; apos[na] = k; asingle[na] = 0
			}
		} else { na++; aid[na] = p; acli[na] = p; alab[na] = pname(p); apos[na] = 1; asingle[na] = 1; usedid[p] = 1 }
	}
	for (a = 1; a <= na; a++) byid[aid[a]] = a
	for (k in skip) if (!(k in byid)) refuse("No agent has the ID \"" k "\".")
	# Overrides first: a candidate key, or a typed absolute path run by the account whose home holds it. The
	# rerun argv keeps every earlier answer, so the last --map for an agent is the one that counts.
	for (i = 1; i <= nmapo; i++) {
		v = mapo[i]
		if (index(v, "=") == 0) refuse("A --map answer needs the form <id>=<install key or absolute path>.")
		id = substr(v, 1, index(v, "=") - 1)
		if (!(id in byid)) refuse("No agent has the ID \"" id "\".")
		lastmap[id] = i
	}
	for (i = 1; i <= nmapo; i++) {
		v = mapo[i]
		id = substr(v, 1, index(v, "=") - 1); pth = substr(v, index(v, "=") + 1)
		if (lastmap[id] != i) continue
		a = byid[id]
		if (id in skip) continue
		if (substr(pth, 1, 1) == "/") {
			if (!printable(pth) || !utf8ok(pth)) refuse("A typed path must be valid UTF-8 text without control characters.")
			u = owner_of(pth); hit = 0
			for (c = 1; c <= ncand; c++) if (ccli[c] == acli[a] && cuser[c] == u && cpath[c] == pth) hit = c
			if (hit && (hit in taken)) refuse("Two agents cannot use the same install: " ckey[hit] ".")
			if (hit) { take(a, hit) } else { ause[a] = "typed"; tuser[a] = u; tpath[a] = pth }
		} else {
			if (!((acli[a], pth) in bykey)) refuse("\"" pth "\" is not a " pname(acli[a]) " install found on this machine.")
			if (bykey[acli[a], pth] in taken) refuse("Two agents cannot use the same install: " pth ".")
			take(a, bykey[acli[a], pth])
		}
	}
	# Pass 1: a label that names a seat account (its name after the CLI) or the folder that holds an install, among
		# accounts named for the provider and the operator only (another OS account is used only when chosen).
	for (pi = 1; pi <= np; pi++) {
		p = plist[pi]; if (!found[p]) continue
		m = sort_cands(p)
		for (i = 1; i <= m; i++) srt[p, i] = so[i]
		nsrt[p] = m
		for (a = 1; a <= na; a++) {
			if (acli[a] != p || asingle[a] || (a in ause) || (aid[a] in skip)) continue
			r = reduce(alab[a]); if (r == "") continue
			for (i = 1; i <= m; i++) {
				c = srt[p, i]; if ((c in taken) || crank[c] > 1) continue
				suf = crank[c] == 0 ? reduce(substr(cuser[c], length(p) + 1)) : ""
				par = reduce(parentname(cpath[c]))
				if (suf == r || par == r) { take(a, c); break }
			}
		}
		# Pass 2: the rest in candidate order, from accounts named for the provider and the operator only; any other
		# account that can run the CLI stays listed, never proposed.
		for (a = 1; a <= na; a++) {
			if (acli[a] != p || (a in ause) || (aid[a] in skip)) continue
			for (i = 1; i <= m; i++) { c = srt[p, i]; if (!(c in taken) && crank[c] <= 1) { take(a, c); break } }
		}
	}
	# Two agents on one install as one account would share one login: refused, never proposed.
	for (a = 1; a <= na; a++) {
		if (!(a in ause) || (aid[a] in skip)) continue
		u = ause[a] == "typed" ? tuser[a] : cuser[ause[a]]; pth = ause[a] == "typed" ? tpath[a] : cpath[ause[a]]
		if ((u SUBSEP pth) in runs) refuse(aid[runs[u SUBSEP pth]] " and " aid[a] " would run the same install as the same account, so they would share one login.")
		runs[u SUBSEP pth] = a
	}
	for (a = 1; a <= na; a++) {
		if (aid[a] in skip) continue
		if (!(a in ause)) { print "MISS\t" aid[a] "\t" acli[a] "\t" enc(alab[a]) "\t" apos[a]; continue }
		if (ause[a] == "typed") { u = tuser[a]; pth = tpath[a]; k = ""; typedp = 1 }
		else { c = ause[a]; u = cuser[c]; pth = cpath[c]; k = ckey[c]; typedp = 0 }
		kind = (u == op) ? "operator" : "user"
		hm = (u == op) ? ophome : uhome[u]
		print "AG\t" aid[a] "\t" acli[a] "\t" enc(alab[a]) "\t" u "\t" kind "\t" enc(pth) "\t" enc(hm) "\t" k "\t" typedp "\t" apos[a] "\t" asingle[a]
		print aid[a] "\t" acli[a] "\t" u "\t" kind "\t" pth "\t" typedp > (ENVIRON["SQ_T"] "/ag.list")
	}
	for (c = 1; c <= ncand; c++) print "CK\t" ccli[c] "\t" ckey[c] "\t" (c in takenby ? aid[takenby[c]] : "")
}
function take(a, c) { ause[a] = c; taken[c] = 1; takenby[c] = a }
$1 == "CK" { ckused[$2, $3] = $4 }
END {
	if (refused) exit 3
	if (mode == "map") { do_map(); exit 0 }
	if (mode == "p1") p1(); else p2()
	prompts = ""
	for (i = 1; i <= pcount; i++) prompts = prompts (i > 1 ? "," : "") prompt_json[i]
	printf "{\"phase\":%d,\"intro\":%s,\"prompts\":[%s]%s,\"derived\":%s,\"limits\":{\"questions_per_prompt\":4,\"options_per_question\":4,\"header_characters\":12}}\n", mode == "p1" ? 1 : 2, intro, prompts, nextj, derived
}
function provs_json(   pi, p, r) {
	r = ""
	for (pi = 1; pi <= np; pi++) { p = plist[pi]; r = r (pi > 1 ? "," : "") "{\"name\":" js(pname(p)) ",\"cli\":" js(p) ",\"found\":" jb(found[p]) "}" }
	return "[" r "]"
}
function glitch_json(   i, r) { r = ""; for (i = 1; i <= nglitch; i++) r = r (i > 1 ? "," : "") js(glitch[i]); return "[" r "]" }
# ---- phase 1: the intro and the accounts questions; nothing discovered about accounts is named ----
function p1(   pi, p, fl, missing, g, i, nf, fo, ol, no, idl, items, fe1) {
	fl = ""; missing = ""; nf = 0
	for (pi = 1; pi <= np; pi++) { p = plist[pi]; if (found[p]) { nf++; fone = p; fl = fl (fl == "" ? "" : ", ") pname(p) } else missing = missing (missing == "" ? "" : ", ") pname(p) }
	intro = "[" js("Found on this machine: " (fl == "" ? "nothing" : fl) ".")
	if (missing != "") intro = intro "," js("Not found: " missing ".")
	if (nglitch == 1) intro = intro "," js("Glitch folder detected: " glitch[1] ".")
	else if (nglitch > 1) { g = ""; for (i = 1; i <= nglitch; i++) g = g (i > 1 ? ", " : "") glitch[i]; intro = intro "," js("Glitch folders detected: " g ".") }
	if (nglitch > 3) { g = ""; for (i = 4; i <= nglitch; i++) g = g (i > 4 ? ", " : "") glitch[i]; intro = intro "," js("More Glitch folders found, not listed as choices (pick Other and type one): " g ".") }
	if (nglitch == 0) { g = ""; for (i = 1; i <= nplace; i++) g = g (i > 1 ? ", " : "") place[i]; intro = intro "," js("Glitch folder: not found in " g ".") }
	for (i = 1; i <= nunav; i++) intro = intro "," js("Unavailable: " uacct[i] " (" ureason[i] ").")
	intro = intro "]"
	nextj = ""
	if (nf > 0) {
		delete qs
		qs[1] = question("multi", "Are there any providers for which you have more than one account?", "Accounts", 0, opt("No", "One account for each provider found.", 1, "") "," opt("Yes", "Say which providers, how many accounts and their labels.", 0, ""), "")
		emit_section("accounts", "Accounts", qs, 1, "", "")
		if (nf >= 2) {
			no = 0; delete ol
			for (pi = 1; pi <= np; pi++) { p = plist[pi]; if (found[p]) ol[++no] = opt(pname(p), "More than one " pname(p) " account.", 0, "\"value\":" js(p)) }
			ncq = 0; delete cq
			idl = chunked("providers", "Which providers have more than one account?", "Providers", 1, ol, no, when("multi", "Yes"))
			emit_section("providers", "Providers", cq, ncq, "", "")
			items = "\"for_each\":{\"questions\":" idl "}"
		} else items = "\"for_each\":{\"items\":[{\"label\":" js(pname(fone)) ",\"value\":" js(fone) "}]}"
		delete qs
		qs[1] = question("count", "How many {provider} accounts?", "{provider}", 0, opt("2", "Two {provider} accounts.", 1, "") "," opt("3", "Three {provider} accounts.", 0, "") "," opt("4", "Four {provider} accounts.", 0, ""), when("multi", "Yes") "," items ",\"other\":{\"whole_number\":[2,16]}")
		emit_section("count", "Number of accounts", qs, 1, "", "")
		delete qs
		qs[1] = question("labels", "Labels for your {N} {provider} accounts?", "{provider}", 0, opt("Number them ({provider} 1, {provider} 2)", "The labels are {provider} 1 to {provider} {N}.", 1, "\"value\":\"numbered\"") "," opt("Type my own labels", "Type {N} labels, separated by commas: at most 32 characters each.", 0, "\"value\":\"typed\",\"type\":true"), when("multi", "Yes") "," items ",\"for_each_count\":{\"question\":\"count\"}")
		emit_section("labels", "Labels", qs, 1, "", "")
		nextj = ",\"next\":{\"argv\":[\"--phase\",\"2\"],\"per_answer\":{\"question\":\"labels\",\"argv\":[\"--accounts\",\"{cli}={labels}\"]},\"numbered\":\"{provider} 1,{provider} 2,...,{provider} {N}\"}"
	}
	derived = "{\"providers\":" provs_json() ",\"glitch_folders\":" glitch_json() "}"
}
function row_of(g) { return disp(gcli[g], glabel[g]) " " EMD " " guser[g] (gkind[g] == "operator" ? " (you)" : "") " " EMD " " gpath[g] }
# ---- phase 2: mapping, permissions, folder, OMP service, review ----
function p2(   g, i, k, m, p, pi, c, one, u, show, nl, nq, ol, no, fl, nf, idl, unused, cnt, y, parts, lineno, yl, desc, dname, hd, pre) {
	intro = "[]"; nextj = ""
	# Mapping.
	one = nag > 0; u = nag > 0 ? guser[1] : ""; show = 0
	for (g = 1; g <= nag; g++) { if (guser[g] != u) one = 0; if (gtyped[g] || (gkey[g] != "" && substr(gkey[g], index(gkey[g], "#") + 1) + 0 > 1)) show = 1 }
	# The table is shown whenever it carries news: several OS accounts, a second install, or an account left without one.
	if (!one || nmiss > 0) show = 1
	nl = 0; delete ln
	if (show) {
		for (g = 1; g <= nag; g++) ln[++nl] = row_of(g)
		for (pi = 1; pi <= np; pi++) {
			p = plist[pi]; if (!(p in agcount)) continue
			unused = ""; cnt = 0
			for (c = 1; c <= ncand; c++) {
				if (ccli[c] != p || ckused[p, ckey[c]] != "") continue
				cnt++
				if (cnt <= 3) unused = unused (unused == "" ? "" : ", ") cuser[c] (ckind[c] == "operator" ? " (you)" : "") " " EMD " " cpath[c]
			}
			if (cnt > 3) unused = unused ", and " (cnt - 3) " more"
			if (cnt > 0) ln[++nl] = "Not used for " pname(p) ": " unused "."
		}
	}
	for (i = 1; i <= nmiss; i++) {
		dname = disp(mcli[i], mlabel[i])
		ln[++nl] = dname ": no " (mpos[i] > 1 ? ordinal(mpos[i]) " " : "") "install or OS user found. Each " pname(mcli[i]) " account needs its own install with its own login. Type its path, or skip it."
		if (mcli[i] == "agy") agywarn = 1
	}
	for (g = 1; g <= nag; g++) if (gcli[g] == "agy") { if ((guser[g] SUBSEP "agy") in agyuser) agywarn = 1; agyuser[guser[g] SUBSEP "agy"] = 1; if (gtyped[g]) agywarn = 1 }
	if (agywarn) ln[++nl] = "Agy keeps its login per OS user; a second install may share the first one\047s login."
	delete qs; nq = 0
	if (nag > 0) {
		if (one) qs[++nq] = question("mapping", "All agents run as " u "?", "Accounts", 0, opt("Yes (Recommended)", "Every agent runs as " u ".", 1, "") "," opt("Change some", "Pick another install, type a path or skip an agent.", 0, ""), "")
		else qs[++nq] = question("mapping", "Use this mapping?", "Accounts", 0, opt("Use it (Recommended)", "Run each agent as shown above.", 1, "") "," opt("Change some", "Pick another install, type a path or skip an agent.", 0, ""), "")
	}
	for (i = 1; i <= nmiss; i++) {
		dname = disp(mcli[i], mlabel[i])
		qs[++nq] = question("missing-" mid[i], dname ": type its path, or skip it?", cut(dname, 12), 0, opt("Skip it (Recommended)", "Save no agent for " dname ".", 1, "") "," opt("Type its path", "Type the absolute path of the " pname(mcli[i]) " install that has this account\047s login.", 0, "\"type\":true"), "\"agent_id\":" js(mid[i]))
	}
	emit_section("mapping", "Accounts", qs, nq, "", nl > 0 ? lines_json(ln, nl) : "")
	if (nag == 0) { finish_p2(); return }
	# Permissions: a gate, then per agent Default, YOLO (when its installed --help shows the flag) or Custom.
	delete qs
	qs[1] = question("perm-gate", "Do you want to set special permission modes to start some of these agents with?", "Permissions", 0, opt("No, all Default (Recommended)", "Every agent starts with no extra arguments.", 1, "") "," opt("Yes", "Choose Default, YOLO or Custom for each agent.", 0, ""), "")
	emit_section("permissions", "Permissions", qs, 1, "", "")
	delete qs; nq = 0; nl = 0; delete ln
	for (g = 1; g <= nag; g++) {
		dname = disp(gcli[g], glabel[g]); y = yolo[gcli[g]]; split(y, parts, "|")
		ol = opt("Default (no arguments)", pname(gcli[g]) " starts with no extra arguments.", 1, "")
		if (sup[gid[g]] == "1") ol = ol "," opt("YOLO (" parts[3] ")", ydesc[gcli[g]], 0, "")
		else ln[++nl] = "YOLO is not offered for " dname ": its --help does not show " parts[1] (parts[2] != "" ? " " parts[2] : "") "."
		ol = ol "," opt("Custom (type the arguments)", "Type the arguments; SPAWN checks them before they are saved.", 0, "\"type\":true")
		qs[++nq] = question("perm-" gid[g], dname ": which permission mode?", cut(dname, 12), 0, ol, when("perm-gate", "Yes") ",\"agent_id\":" js(gid[g]))
	}
	emit_section("permission-modes", "Permission modes", qs, nq, "", nl > 0 ? lines_json(ln, nl) : "")
	# Folder: only when Glitch was found; every agent not started in Glitch starts in its own home folder.
	if (nglitch > 0) {
		delete qs; nq = 0
		if (nglitch > 1) {
			fl = ""; m = nglitch > 3 ? 3 : nglitch
			for (i = 1; i <= m; i++) fl = fl (fl == "" ? "" : ",") opt(glitch[i], "The Glitch installation at " glitch[i] ".", 0, "\"value\":" js(glitch[i]))
			qs[++nq] = question("glitch-root", "Which Glitch folder?", "Glitch", 0, fl, "")
			qt = "Would you like to start all these agents within Glitch?"
		} else qt = "I detected Glitch at " glitch[1] ". Would you like to start all these agents within Glitch?"
		fl = opt("All (Recommended)", "Every agent starts in Glitch.", 1, "")
		if (nag > 1) fl = fl "," opt("Choose per agent", "Pick the agents that start in Glitch; the rest start in their own home folder.", 0, "")
		fl = fl "," opt("None", "Every agent starts in its own home folder.", 0, "")
		qs[++nq] = question("folder", qt, "Folder", 0, fl, "")
		emit_section("folder", "Folder", qs, nq, "", nglitch > 3 ? "[" js("More Glitch folders found, not listed as choices (pick Other and type one): " more_glitch() ".") "]" : "")
		if (nag > 1) {
			no = 0; delete ol2
			for (g = 1; g <= nag; g++) ol2[++no] = opt(disp(gcli[g], glabel[g]), "Starts in Glitch.", 0, "\"value\":" js(gid[g]))
			ncq = 0; delete cq
			chunked("folder-agents", "Which agents start in Glitch?", "Glitch", 1, ol2, no, when("folder", "Choose per agent"))
			emit_section("folder-agents", "Agents in Glitch", cq, ncq, "", "")
		}
	}
	# The OMP service per OMP agent. No startup-prompt or model question exists.
	delete qs; nq = 0
	for (g = 1; g <= nag; g++) {
		if (gcli[g] != "omp") continue
		f = fam[gid[g]]; fl = ""
		if (f != "") fl = opt(f " (from its config) (Recommended)", "The service named in this agent\047s own OMP configuration.", 1, "")
		alt = 0
		split("openai google anthropic", cand3, " ")
		for (c = 1; c <= 3 && alt < (f == "" ? 3 : 2); c++) if (cand3[c] != f) { alt++; fl = fl (fl == "" ? "" : ",") opt(cand3[c], "Run this agent\047s OMP model through " cand3[c] ".", 0, "") }
		qs[++nq] = question("omp-" gid[g], "Which service runs " gid[g] "\047s model?", "OMP service", 0, fl, "\"agent_id\":" js(gid[g]))
	}
	emit_section("omp", "OMP service", qs, nq, "", "")
	# Review.
	delete qs
	qs[1] = question("review", "Save these {N} agents?", "Save", 0, opt("Save and set up (Recommended)", "Save the roster and let SPAWN prepare it.", 1, "") "," opt("Change something", "Go back and change a choice.", 0, ""), "")
	emit_section("review", "Review", qs, 1, "\"show_first\":\"derived.review table for the agents; {N} is their count\"", "")
	finish_p2()
}
function more_glitch(   g, i) { g = ""; for (i = 4; i <= nglitch; i++) g = g (i > 4 ? ", " : "") glitch[i]; return g }
function finish_p2(   g, accs, cands, c, perms, y, parts, miss, i, ra, f) {
	accs = ""
	for (g = 1; g <= nag; g++) {
		f = gcli[g] == "omp" ? fam[gid[g]] : pfam(gcli[g])
		accs = accs (g > 1 ? "," : "") "{\"id\":" js(gid[g]) ",\"provider\":" js(pname(gcli[g])) ",\"provider_family\":" js(f) ",\"account_label\":" js(glabel[g]) ",\"display\":" js(disp(gcli[g], glabel[g])) ",\"account\":" js(guser[g]) ",\"operator\":" jb(gkind[g] == "operator") ",\"command\":" js(gpath[g]) ",\"home\":" js(ghome[g]) ",\"install\":" js(gkey[g]) ",\"row\":" js(row_of(g)) "}"
	}
	cands = ""
	for (c = 1; c <= ncand; c++) cands = cands (c > 1 ? "," : "") "{\"key\":" js(ckey[c]) ",\"provider\":" js(pname(ccli[c])) ",\"account\":" js(cuser[c]) ",\"operator\":" jb(ckind[c] == "operator") ",\"command\":" js(cpath[c]) ",\"option\":" js(cuser[c] (ckind[c] == "operator" ? " (you)" : "") " " EMD " " cpath[c]) ",\"used_by\":" js(ckused[ccli[c], ckey[c]]) "}"
	perms = ""
	for (g = 1; g <= nag; g++) {
		split(yolo[gcli[g]], parts, "|")
		perms = perms (g > 1 ? "," : "") js(gid[g]) ":[{\"label\":\"Default (no arguments)\",\"arguments\":[]}" (sup[gid[g]] == "1" ? ",{\"label\":" js("YOLO (" parts[3] ")") ",\"arguments\":" jarr(parts[3]) "}" : "") "]"
	}
	miss = ""
	for (i = 1; i <= nmiss; i++) miss = miss (i > 1 ? "," : "") "{\"id\":" js(mid[i]) ",\"provider\":" js(pname(mcli[i])) ",\"account_label\":" js(mlabel[i]) ",\"display\":" js(disp(mcli[i], mlabel[i])) "}"
	ra = "\"--phase\",\"2\""
	for (i = 1; i <= nrarg; i++) ra = ra "," js(rarg[i])
	derived = "{\"operator\":" js(op) ",\"launch_folder\":" js(cwd) ",\"providers\":" provs_json() ",\"accounts\":[" accs "],\"missing\":[" miss "],\"candidates\":[" cands "],\"permissions\":{" perms "},"
	derived = derived "\"custom_arguments\":{\"label\":\"Custom (type the arguments)\",\"check\":[\"--check-args\",\"{cli}\",\"{words}\"]},"
	derived = derived "\"glitch_folders\":" glitch_json() ",\"rerun\":{\"argv\":[" ra "],\"map\":[\"--map\",\"{id}={install key or absolute path}\"],\"skip\":[\"--skip\",\"{id}\"]},"
	derived = derived "\"omp_prompt\":" js("Follow the explicitly assigned task. Role text is guidance, not identity isolation.") ","
	derived = derived "\"review\":{\"columns\":[\"ID\",\"account\",\"CLI\",\"permission flags\",\"folder\",\"paid check\"],\"paid_check_native\":\"one harmless paid model message\",\"paid_check_terminal\":\"offline checks only\"}}"
}
'
run_awk() { # mode, files...
	am=$1; shift
	SQ_T=$T LC_ALL=C awk -F'\t' -v mode="$am" "BEGIN {
		yolo[\"claude\"] = \"--dangerously-skip-permissions||--dangerously-skip-permissions\"; ydesc[\"claude\"] = \"Claude acts without asking first.\"
		yolo[\"agy\"] = \"--dangerously-skip-permissions||--dangerously-skip-permissions\"; ydesc[\"agy\"] = \"Agy acts without asking first.\"
		yolo[\"codex\"] = \"--dangerously-bypass-approvals-and-sandbox||--dangerously-bypass-approvals-and-sandbox\"; ydesc[\"codex\"] = \"Codex runs with no approvals and no sandbox.\"
		yolo[\"kimi\"] = \"--auto||--auto\"; ydesc[\"kimi\"] = \"Kimi never asks for approval.\"
		yolo[\"grok\"] = \"--permission-mode|bypassPermissions|--permission-mode bypassPermissions\"; ydesc[\"grok\"] = \"Grok skips its permission checks.\"
		yolo[\"muse\"] = \"--yolo||--yolo\"; ydesc[\"muse\"] = \"Muse runs without approval prompts.\"
		yolo[\"omp\"] = \"--approval-mode|yolo|--approval-mode yolo\"; ydesc[\"omp\"] = \"OMP runs tools without approval.\"
	}
	$PROG" "$@"
}

if [ "$phase" = 1 ]; then
	run_awk p1 "$FACTS"
	exit $?
fi

# Phase 2: map the answers to installs, then check what each chosen install itself supports.
: >"$T/ag.list"
run_awk map "$FACTS" >"$T/map"
rc=$?
if [ "$rc" = 3 ]; then cat "$T/map"; exit 3; fi
[ "$rc" = 0 ] || exit 1
cat "$T/map" >>"$FACTS"
jsq() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
while IFS="$TAB" read -r id cli user kind path typed; do
	if [ "$typed" = 1 ]; then
		if [ "$kind" = operator ]; then [ -f "$path" ] && [ -x "$path" ]; else login_run 0 "$user" sh -c '[ -f "$1" ] && [ -x "$1" ]' spawn-check "$path" >/dev/null; fi || {
			printf '{"ok":false,"why":"%s cannot run %s, so it cannot be %s."}\n' "$(jsq "$user")" "$(jsq "$path")" "$(jsq "$id")"
			exit 3
		}
	fi
	if [ "$kind" = user ]; then help=$(login_run 1 "$user" "$path" --help) || help=""; else help=$(bounded 1 "$path" --help) || help=""; fi
	y=$(yolo_flag "$cli")
	flag=${y%%|*}; rest=${y#*|}; val=${rest%%|*}
	if help_has "$help" "$flag" "$val"; then printf 'SUP\t%s\t1\n' "$id" >>"$FACTS"; else printf 'SUP\t%s\t0\n' "$id" >>"$FACTS"; fi
	if [ "$cli" = omp ]; then
		if [ "$kind" = user ]; then f=$(login_run 0 "$user" sh -c 'cat "$HOME/.omp/agent/config.yml"' | omp_family)
		elif [ -r "$operator_home/.omp/agent/config.yml" ]; then f=$(omp_family <"$operator_home/.omp/agent/config.yml")
		else f=""; fi
		printf 'FAM\t%s\t%s\n' "$id" "$f" >>"$FACTS"
	fi
done <"$T/ag.list"
run_awk p2 "$FACTS"
