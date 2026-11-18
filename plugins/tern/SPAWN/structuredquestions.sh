#!/bin/sh
# SPAWN Guided setup: the exact structured-question script (SKILLS-210).
# Read-only and deterministic. It discovers the machine itself, then prints ONE JSON
# object on stdout that the setup helper renders 1:1 with its native structured-question
# tool. It starts no provider, installs nothing and writes nothing outside its own
# private temporary folder (removed on exit).
#
#   structuredquestions.sh [--glitch-root <path>]... [--cwd <path>]
#
# --glitch-root: a root the host already verified (repeatable). --cwd: the launch folder.
# Output: {"intro":[...],"prompts":[{"id","title","questions":[...]}],"derived":{...},"limits":{...}}
# Limits: every prompt carries at most 4 questions and every question at most 4 options
# (Claude Code AskUserQuestion: 1-4 questions, 2-4 options, automatic "Other"; OMP's ask
# tool accepts more, so the stricter bound is used). The windows twin is structuredquestions.ps1.
set -u
umask 077

glitch_roots=""
launch_cwd=$(pwd)
while [ "$#" -gt 0 ]; do
	case $1 in
	--glitch-root) [ "$#" -ge 2 ] || exit 2; glitch_roots="$glitch_roots
$2"; shift 2 ;;
	--cwd) [ "$#" -ge 2 ] || exit 2; launch_cwd=$2; shift 2 ;;
	*) printf 'usage: structuredquestions.sh [--glitch-root <path>]... [--cwd <path>]\n' >&2; exit 2 ;;
	esac
done

TAB=$(printf '\t')
T=$(mktemp -d "${TMPDIR:-/tmp}/spawn-questions.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
trap 'exit 1' INT TERM
FACTS=$T/facts
: >"$FACTS"
# Every external call is bounded: SPAWN_QUESTIONS_TIMEOUT seconds (default 20), then TERM, then KILL.
# This works without GNU timeout (macOS has none): a background watcher kills the call.
TMO=${SPAWN_QUESTIONS_TIMEOUT:-20}

operator=$(id -un)
operator_home=${HOME:-}
providers="claude codex kimi grok agy muse omp"
# The one system-wide Glitch location; SPAWN_QUESTIONS_SYSTEM_GLITCH exists only so tests can run hermetically.
system_glitch=${SPAWN_QUESTIONS_SYSTEM_GLITCH:-/opt/glitch}

pname() {
	case $1 in
	claude) echo Claude ;; codex) echo Codex ;; kimi) echo Kimi ;; grok) echo Grok ;;
	agy) echo Agy ;; muse) echo Muse ;; omp) echo OMP ;;
	esac
}
pfamily() {
	case $1 in
	claude) echo anthropic ;; codex) echo openai ;; kimi) echo moonshot ;; grok) echo xai ;;
	agy) echo google ;; muse) echo meta ;; omp) echo "" ;;
	esac
}

# One line per permission choice: label, flag the installed --help must show, argv words, consequence.
perm_lines() {
	case $1 in
	claude)
		printf '%s|||%s\n' 'Normal (asks before actions)' 'Claude asks before it edits files or runs commands.'
		printf '%s|%s|%s|%s\n' 'Skip permission prompts (--dangerously-skip-permissions)' '--dangerously-skip-permissions' '--dangerously-skip-permissions' 'Claude acts without asking first.' ;;
	codex)
		printf '%s|||%s\n' 'Normal' 'Codex keeps its approvals and its sandbox.'
		printf '%s|%s|%s|%s\n' 'YOLO, no sandbox (--dangerously-bypass-approvals-and-sandbox)' '--dangerously-bypass-approvals-and-sandbox' '--dangerously-bypass-approvals-and-sandbox' 'Codex runs with no approvals and no sandbox.' ;;
	kimi)
		printf '%s|||%s\n' 'Normal' 'Kimi uses its default mode.'
		printf '%s|%s|%s|%s\n' 'Ask when needed (--yolo)' '--yolo' '--yolo' 'Kimi asks only when it needs to.'
		printf '%s|%s|%s|%s\n' 'Never ask (--auto)' '--auto' '--auto' 'Kimi never asks for approval.' ;;
	grok)
		printf '%s|||%s\n' 'Normal' 'Grok uses its default permission mode.'
		printf '%s|%s|%s|%s\n' 'Bypass permissions (--permission-mode bypassPermissions)' '--permission-mode' '--permission-mode bypassPermissions' 'Grok skips its permission checks.' ;;
	agy)
		printf '%s|||%s\n' 'Normal' 'Agy asks before actions.'
		printf '%s|%s|%s|%s\n' 'Skip permission prompts (--dangerously-skip-permissions)' '--dangerously-skip-permissions' '--dangerously-skip-permissions' 'Agy acts without asking first.' ;;
	muse)
		printf '%s|||%s\n' 'Normal' 'Muse asks before actions.'
		printf '%s|%s|%s|%s\n' 'No approval prompts (--yolo)' '--yolo' '--yolo' 'Muse runs without approval prompts.' ;;
	omp)
		printf '%s|||%s\n' 'Normal' 'OMP asks before tool actions.'
		printf '%s|%s|%s|%s\n' 'YOLO (--approval-mode yolo)' '--approval-mode' '--approval-mode yolo' 'OMP runs tools without approval.' ;;
	esac
}

# Fact fields are written percent-encoded (percent, control bytes), so a tab or newline inside a path can
# never split a field or forge a fact row; the formatter decodes them.
fe() {
	printf '%s' "$1" | od -An -v -to1 | LC_ALL=C awk '{for(i=1;i<=NF;i++){d=substr($i,1,1)*64+substr($i,2,1)*8+substr($i,3,1);if(d<32||d==127||d==37)printf "%%%02X",d;else printf "%c",d}}'
}
printable() { case $1 in *[![:print:]]*) return 1 ;; esac; return 0; }

# Run one command with stdin closed, output to a private file, killed after TMO seconds.
# bounded <merge-stderr 0|1> command words...; prints the output, returns the status.
bounded() {
	bmerge=$1; shift
	bf=$T/b.out
	if [ "$bmerge" = 1 ]; then "$@" >"$bf" 2>&1 </dev/null & else "$@" >"$bf" 2>/dev/null </dev/null & fi
	bpid=$!
	( sleep "$TMO"; kill -TERM "$bpid"; sleep 2; kill -KILL "$bpid" ) >/dev/null 2>&1 </dev/null &
	wpid=$!
	wait "$bpid"; brc=$?
	kill "$wpid" >/dev/null 2>&1
	wait "$wpid" >/dev/null 2>&1
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
resolve_seat() { # account cli: prints the absolute path the account can execute
	out=$(login_run 0 "$1" sh -c "command -v $2") || return 1
	rpath=$(printf '%s\n' "$out" | awk '/^\//{p=$0} END{print p}')
	[ -n "$rpath" ] || return 1
	printable "$rpath" || return 1
	login_run 0 "$1" test -x "$rpath" >/dev/null || return 1
	printf '%s' "$rpath"
}
resolve_operator() { # cli
	rpath=$(command -v "$1" 2>/dev/null) || return 1
	case $rpath in /*) ;; *) return 1 ;; esac
	printable "$rpath" || return 1
	[ -x "$rpath" ] || return 1
	printf '%s' "$rpath"
}
omp_family() { # config text on stdin
	awk '/^modelRoles:/{m=1;next} m&&/^[^ \t]/{m=0} m&&$1=="default:"{v=$0;sub(/^[^:]*:[ \t]*/,"",v);gsub(/["'"'"']/,"",v);n=split(v,a,"/");if(n>=2&&a[1]~/^[a-z0-9._-]+$/)print a[1];exit}'
}

# Candidate OS accounts: named for a provider, a real login, not the operator.
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

: >"$T/acc.list"
while IFS="$TAB" read -r name home; do
	[ -n "$name" ] || continue
	[ "$name" = "$operator" ] && continue
	case $name in *[!A-Za-z0-9._-]*) continue ;; esac
	printable "$home" || continue
	prov=""
	for p in $providers; do
		case $name in "$p"*) prov=$p ;; esac
	done
	[ -n "$prov" ] || continue
	if [ "$sudo_ok" = 0 ]; then
		printf 'UNAV\t%s\t%s\tsudo is not installed, so this account was not checked\n' "$name" "$prov" >>"$FACTS"
		continue
	fi
	# The route SPAWN will use for this very account, not root's: sudo -n -i -u <account>.
	if ! login_run 0 "$name" true >/dev/null; then
		printf 'UNAV\t%s\t%s\tit cannot be reached with sudo -n -i -u\n' "$name" "$prov" >>"$FACTS"
		continue
	fi
	if path=$(resolve_seat "$name" "$prov"); then
		fam=$(pfamily "$prov")
		[ "$prov" = omp ] && fam=$(login_run 0 "$name" sh -c 'cat "$HOME/.omp/agent/config.yml"' | omp_family)
		printf 'ACC\t%s\t%s\tseat\t%s\t%s\t%s\n' "$prov" "$name" "$(fe "$path")" "$(fe "$home")" "$fam" >>"$FACTS"
		printf '%s\t%s\t%s\t%s\n' "$prov" seat "$name" "$path" >>"$T/acc.list"
	else
		printf 'UNAV\t%s\t%s\tit has no %s it can run\n' "$name" "$prov" "$prov" >>"$FACTS"
	fi
done <"$T/accts"

for p in $providers; do
	if path=$(resolve_operator "$p"); then
		fam=$(pfamily "$p")
		if [ "$p" = omp ] && [ -r "$operator_home/.omp/agent/config.yml" ]; then fam=$(omp_family <"$operator_home/.omp/agent/config.yml"); fi
		printf 'ACC\t%s\t%s\toperator\t%s\t%s\t%s\n' "$p" "$(fe "$operator")" "$(fe "$path")" "$(fe "$operator_home")" "$fam" >>"$FACTS"
		printf '%s\t%s\t%s\t%s\n' "$p" operator "$operator" "$path" >>"$T/acc.list"
	fi
done

# Permission choices: every option is listed; each account's own installed --help decides, per flag, whether
# that account supports it (the formatter names the accounts that do not, so the helper drops the option when
# one of them is chosen).
for p in $providers; do
	perm_lines "$p" | while IFS="|" read -r label flag argv desc; do
		printf 'PERM\t%s\t%s\t%s\t%s\t%s\n' "$p" "$label" "$flag" "$argv" "$desc" >>"$FACTS"
	done
done
while IFS="$TAB" read -r p kind acct cli; do
	if [ "$kind" = seat ]; then help=$(login_run 1 "$acct" "$cli" --help) || help=""; else help=$(bounded 1 "$cli" --help) || help=""; fi
	perm_lines "$p" | while IFS="|" read -r label flag argv desc; do
		[ -n "$flag" ] || continue
		if printf '%s\n' "$help" | grep -F -q -e "$flag"; then sup=1; else sup=0; fi
		printf 'SUP\t%s\t%s\t%s\t%s\t%s\n' "$p" "$acct" "$kind" "$label" "$sup" >>"$FACTS"
	done
done <"$T/acc.list"

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

LC_ALL=C awk -F'\t' '
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
function js(s) { return "\"" esc(s) "\"" }
function jb(b) { return b ? "true" : "false" }
function jarr(str,   n, a, i, r) {
	n = split(str, a, " ")
	r = ""
	for (i = 1; i <= n; i++) r = r (i > 1 ? "," : "") js(a[i])
	return "[" r "]"
}
function opt(label, desc, pre) { return "{\"label\":" js(label) ",\"description\":" js(desc) ",\"preselected\":" jb(pre) "}" }
function question(q, header, multi, opts, when) {
	return "{\"question\":" js(q) ",\"header\":" js(header) ",\"multiSelect\":" jb(multi) ",\"options\":[" opts "]" (when != "" ? ",\"when\":" when : "") "}"
}
# Prompts of at most 4 questions: a section longer than that continues in the next prompt.
function emit_section(id, title, qs, n, note,   i, k, pn, chunk, parts, idx, total) {
	if (n == 0) return
	total = int((n + 3) / 4)
	for (k = 1; k <= total; k++) {
		chunk = ""
		for (i = (k - 1) * 4 + 1; i <= n && i <= k * 4; i++) chunk = chunk (chunk == "" ? "" : ",") qs[i]
		pid = total == 1 ? id : id "-" k
		ptitle = total == 1 ? title : title " (" k " of " total ")"
		prompt_json[++pcount] = "{\"id\":" js(pid) ",\"title\":" js(ptitle) (note != "" ? "," note : "") ",\"questions\":[" chunk "]}"
	}
}
function haveany(p,   k) { for (k = 1; k <= nacc; k++) if (aprov[k] == p) return 1; return 0 }
function opt2(label, desc, pre, unsup) { return "{\"label\":" js(label) ",\"description\":" js(desc) ",\"preselected\":" jb(pre) (unsup != "" ? ",\"unsupported_by\":[" unsup "]" : "") "}" }
function pname(p) {
	if (p == "claude") return "Claude"; if (p == "codex") return "Codex"; if (p == "kimi") return "Kimi"
	if (p == "grok") return "Grok"; if (p == "agy") return "Agy"; if (p == "muse") return "Muse"
	return "OMP"
}
BEGIN {
	for (i = 1; i < 32; i++) ctl[sprintf("%c", i)] = sprintf("\\u%04x", i)
	ctl[sprintf("%c", 127)] = "\\u007f"
	np = split("claude codex kimi grok agy muse omp", plist, " ")
	nacc = 0; nperm = 0; nunav = 0; nglitch = 0; nplace = 0; nosudo = 0; pcount = 0
}
$1 == "OP" { op = dec($2); ophome = dec($3) }
$1 == "CWD" { cwd = dec($2) }
$1 == "NOSUDO" { nosudo = 1 }
$1 == "ACC" { nacc++; aprov[nacc] = $2; aname[nacc] = $3; akind[nacc] = $4; apath[nacc] = dec($5); ahome[nacc] = dec($6); afam[nacc] = $7; if (akind[nacc] == "operator") aname[nacc] = dec($3) }
$1 == "UNAV" { nunav++; uacct[nunav] = $2; uprov[nunav] = $3; ureason[nunav] = $4 }
$1 == "PERM" { nperm++; pprov[nperm] = $2; plabel[nperm] = $3; pflag[nperm] = $4; pargv[nperm] = $5; pdesc[nperm] = $6 }
$1 == "SUP" { sup[$2 SUBSEP $3 SUBSEP $4 SUBSEP $5] = $6 }
$1 == "GLITCH" { glitch[++nglitch] = dec($2) }
$1 == "PLACE" { place[++nplace] = dec($2) }
END {
	# Order: provider order, seats first, the operator last.
	n = 0
	for (pi = 1; pi <= np; pi++) {
		p = plist[pi]
		for (pass = 1; pass <= 2; pass++)
			for (i = 1; i <= nacc; i++)
				if (aprov[i] == p && ((pass == 1 && akind[i] == "seat") || (pass == 2 && akind[i] == "operator"))) ord[++n] = i
	}
	for (k = 1; k <= n; k++) {
		i = ord[k]; p = aprov[i]
		rest = akind[i] == "seat" ? substr(aname[i], length(p) + 1) : aname[i]
		base = rest == "" ? p : p "-" tolower(rest)
		id = base; sfx = 1
		while (id in usedid) { sfx++; id = base "-" sfx }
		usedid[id] = 1
		aid[i] = id
		alabel[i] = rest == "" ? pname(p) : toupper(rest)
		aopt[i] = akind[i] == "seat" ? aname[i] " \342\200\224 " apath[i] : aname[i] " (you) \342\200\224 " apath[i]
		arow[i] = aname[i] " \342\206\222 ID " id ", label " alabel[i]
		if (akind[i] == "seat") seats[p]++; else haveop[p] = 1
	}
	# Permission options per provider. An option exists when some account supports its flag; the accounts that do
	# not are named in unsupported_by so the helper drops the option when one of them is chosen.
	for (i = 1; i <= nperm; i++) {
		p = pprov[i]; pavail[i] = (pflag[i] == ""); lst = ""
		for (k = 1; k <= n; k++) {
			a = ord[k]
			if (aprov[a] != p || pflag[i] == "") continue
			if (sup[p SUBSEP aname[a] SUBSEP akind[a] SUBSEP plabel[i]] == "1") pavail[i] = 1
			else lst = lst (lst == "" ? "" : ",") js(aid[a])
		}
		punsup[i] = lst
		if (!pavail[i] && haveany(p)) noflag[p] = noflag[p] (noflag[p] == "" ? "" : ", ") pflag[i]
	}
	# Intro.
	found = ""; missing = ""
	for (pi = 1; pi <= np; pi++) {
		p = plist[pi]
		if (seats[p] > 0) found = found (found == "" ? "" : " \302\267 ") pname(p) " " seats[p]
		else if (haveop[p]) found = found (found == "" ? "" : " \302\267 ") pname(p) " you"
		else missing = missing (missing == "" ? "" : ", ") pname(p)
	}
	intro = "[" js("Found on this machine: " (found == "" ? "nothing" : found) ".")
	if (missing != "") intro = intro "," js("Not found: " missing ".")
	if (nglitch == 1) intro = intro "," js("Glitch folder detected: " glitch[1] ".")
	else if (nglitch > 1) { g = ""; for (i = 1; i <= nglitch; i++) g = g (i > 1 ? ", " : "") glitch[i]; intro = intro "," js("Glitch folders detected: " g ".") }
	if (nglitch > 3) { g = ""; for (i = 4; i <= nglitch; i++) g = g (i > 4 ? ", " : "") glitch[i]; intro = intro "," js("More Glitch folders found, not listed as choices (pick Other and type one): " g ".") }
	if (nglitch == 0) { g = ""; for (i = 1; i <= nplace; i++) g = g (i > 1 ? ", " : "") place[i]; intro = intro "," js("Glitch folder: not found in " g ".") }
	for (i = 1; i <= nunav; i++) intro = intro "," js("Unavailable: " uacct[i] " (" ureason[i] ").")
	for (pi = 1; pi <= np; pi++) if (noflag[plist[pi]] != "") intro = intro "," js("Permissions: " pname(plist[pi]) " offers Normal only for flags its --help does not show (" noflag[plist[pi]] ").")
	intro = intro "]"

	# Prompt 1: accounts, one multi-select question per provider; more than 4 options split evenly.
	nq = 0
	for (pi = 1; pi <= np; pi++) {
		p = plist[pi]; m = 0
		for (k = 1; k <= n; k++) if (aprov[ord[k]] == p) mem[++m] = ord[k]
		if (m == 0) continue
		filler = 0
		if (m == 1) filler = 1
		total = m + filler
		chunks = int((total + 3) / 4)
		base = int(total / chunks); extra = total % chunks
		pos = 1
		for (c = 1; c <= chunks; c++) {
			size = base + (c <= extra ? 1 : 0)
			opts = ""
			for (j = 0; j < size; j++) {
				idx = pos + j
				if (idx <= m) {
					i = mem[idx]
					o = opt(aopt[i], akind[i] == "seat" ? "Seat account. ID " aid[i] ", label " alabel[i] "." : "Your own login on this machine. ID " aid[i] ", label " alabel[i] ".", akind[i] == "seat")
				} else o = opt("Skip " pname(p), "Run no " pname(p) " agents.", 0)
				opts = opts (opts == "" ? "" : ",") o
			}
			pos += size
			qtext = pname(p) ": which accounts should SPAWN run?"
			hdr = pname(p)
			if (chunks > 1) { qtext = qtext " (" c " of " chunks ")"; hdr = hdr " " c "/" chunks }
			qs[++nq] = question(qtext, hdr, 1, opts, "")
		}
	}
	emit_section("accounts", "Accounts", qs, nq, "")

	# Prompt 2: IDs and labels. The table is derived.accounts[].row for the chosen accounts.
	delete qs
	qs[1] = question("Use these IDs and labels?", "IDs", 0, opt("Use these (Recommended)", "Use the IDs and labels in the table above.", 1) "," opt("Change some", "Say which IDs or labels to change.", 0), "")
	emit_section("ids", "IDs and labels", qs, 1, "\"show_first\":\"derived.accounts[].row for the chosen accounts, one per line\"")

	# Prompt 3: folder.
	delete qs
	fo = ""
	shown = nglitch > 3 ? 3 : nglitch
	if (nglitch >= 1) for (i = 1; i <= shown; i++) fo = fo (fo == "" ? "" : ",") opt("Glitch folder: " glitch[i] (nglitch == 1 ? " (Recommended)" : ""), "Every agent starts in this Glitch installation.", nglitch == 1)
	fo = fo (fo == "" ? "" : ",") opt("Each account\047s own home folder", "Each agent starts in its own account\047s home folder.", nglitch == 0)
	if (nglitch == 0) fo = fo "," opt("This launch folder: " cwd, "Every agent starts in the folder this setup was launched from.", 0)
	qs[1] = question("Which folder should every agent start in?", "Folder", 0, fo, "")
	emit_section("folder", "Folder", qs, 1, "")

	# Prompt 4: permissions, one single-select question per provider, asked only for chosen providers.
	delete qs; nq = 0
	for (pi = 1; pi <= np; pi++) {
		p = plist[pi]
		if (seats[p] == 0 && !haveop[p]) continue
		po = ""; cnt = 0
		for (i = 1; i <= nperm; i++) if (pprov[i] == p && pavail[i]) { cnt++; po = po (po == "" ? "" : ",") opt2(plabel[i], pdesc[i], pflag[i] == "", punsup[i]) }
		if (cnt < 2) continue
		qs[++nq] = question(pname(p) ": which permission mode?", pname(p), 0, po, "{\"provider\":" js(pname(p)) "}")
	}
	emit_section("permissions", "Permissions", qs, nq, "\"ask_only_for\":\"providers with a chosen account\"")

	# Prompt 5: the OMP service per OMP account. No startup-prompt or model question exists.
	delete qs; nq = 0
	for (k = 1; k <= n; k++) {
		i = ord[k]
		if (aprov[i] != "omp") continue
		fam = afam[i]; oo = ""
		if (fam != "") oo = opt(fam " (from its config) (Recommended)", "The service named in this account\047s own OMP configuration.", 1)
		alt = 0
		split("openai google anthropic", cand, " ")
		for (c = 1; c <= 3 && alt < (fam == "" ? 3 : 2); c++) if (cand[c] != fam) { alt++; oo = oo (oo == "" ? "" : ",") opt(cand[c], "Run this account\047s OMP model through " cand[c] ".", 0) }
		qs[++nq] = question("Which service runs " aid[i] "\047s model?", "OMP service", 0, oo, "{\"account_id\":" js(aid[i]) "}")
	}
	emit_section("omp", "OMP service", qs, nq, "\"ask_only_for\":\"chosen OMP accounts\"")

	# Prompt 6: review.
	delete qs
	qs[1] = question("Save these {N} agents?", "Save", 0, opt("Save and set up (Recommended)", "Save the roster and let SPAWN prepare it.", 1) "," opt("Change something", "Go back and change a choice.", 0), "")
	emit_section("review", "Review", qs, 1, "\"show_first\":\"derived.review table for the chosen accounts; {N} is their count\"")

	# Assemble.
	prompts = ""
	for (i = 1; i <= pcount; i++) prompts = prompts (i > 1 ? "," : "") prompt_json[i]
	provs = ""
	for (pi = 1; pi <= np; pi++) {
		p = plist[pi]
		provs = provs (pi > 1 ? "," : "") "{\"name\":" js(pname(p)) ",\"cli\":" js(p) ",\"seats\":" (seats[p] + 0) ",\"operator\":" jb(haveop[p]) "}"
	}
	accs = ""
	for (k = 1; k <= n; k++) {
		i = ord[k]
		accs = accs (k > 1 ? "," : "") "{\"id\":" js(aid[i]) ",\"provider\":" js(pname(aprov[i])) ",\"provider_family\":" js(afam[i]) ",\"account_label\":" js(alabel[i]) ",\"account\":" js(aname[i]) ",\"operator\":" jb(akind[i] == "operator") ",\"command\":" js(apath[i]) ",\"home\":" js(ahome[i]) ",\"option\":" js(aopt[i]) ",\"row\":" js(arow[i]) "}"
	}
	perms = ""
	for (pi = 1; pi <= np; pi++) {
		p = plist[pi]; list = ""; cnt = 0
		for (i = 1; i <= nperm; i++) if (pprov[i] == p && pavail[i]) { cnt++; list = list (list == "" ? "" : ",") "{\"label\":" js(plabel[i]) ",\"arguments\":" jarr(pargv[i]) (punsup[i] != "" ? ",\"unsupported_by\":[" punsup[i] "]" : "") "}" }
		if (cnt > 0) perms = perms (perms == "" ? "" : ",") js(pname(p)) ":[" list "]"
	}
	gl = ""
	for (i = 1; i <= nglitch; i++) gl = gl (i > 1 ? "," : "") js(glitch[i])
	derived = "{\"operator\":" js(op) ",\"launch_folder\":" js(cwd) ",\"providers\":[" provs "],\"accounts\":[" accs "],\"permissions\":{" perms "},\"glitch_folders\":[" gl "],"
	derived = derived "\"omp_prompt\":" js("Follow the explicitly assigned task. Role text is guidance, not identity isolation.") ","
	derived = derived "\"review\":{\"columns\":[\"ID\",\"account\",\"CLI\",\"permission flags\",\"folder\",\"paid check\"],\"paid_check_native\":\"one harmless paid model message\",\"paid_check_terminal\":\"offline checks only\"}}"
	printf "{\"intro\":%s,\"prompts\":[%s],\"derived\":%s,\"limits\":{\"questions_per_prompt\":4,\"options_per_question\":4,\"header_characters\":12}}\n", intro, prompts, derived
}' "$FACTS"
