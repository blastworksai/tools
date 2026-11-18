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

operator=$(id -un)
operator_home=${HOME:-}
providers="claude codex kimi grok agy muse omp"
# The one system-wide Glitch location; SPAWN_QUESTIONS_SYSTEM_GLITCH exists only so tests can run hermetically.
system_glitch=${SPAWN_QUESTIONS_SYSTEM_GLITCH:-/opt/glitch}
tmo=""
command -v timeout >/dev/null 2>&1 && tmo="timeout 20"

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

# Run a command as the account that will run it, through the login route SPAWN launches with.
as_seat() { # account, then the command words
	acct=$1; shift
	$tmo sudo -n -i -u "$acct" -- "$@" </dev/null 2>/dev/null
}
resolve_seat() { # account cli: prints the absolute path the account can execute
	out=$(as_seat "$1" sh -c "command -v $2") || return 1
	rpath=$(printf '%s\n' "$out" | awk '/^\//{p=$0} END{print p}')
	[ -n "$rpath" ] || return 1
	case $rpath in *[![:print:]]*) return 1 ;; esac
	as_seat "$1" test -x "$rpath" || return 1
	printf '%s' "$rpath"
}
resolve_operator() { # cli
	rpath=$(command -v "$1" 2>/dev/null) || return 1
	case $rpath in /*) ;; *) return 1 ;; esac
	case $rpath in *[![:print:]]*) return 1 ;; esac
	[ -x "$rpath" ] || return 1
	printf '%s' "$rpath"
}
omp_family() { # config text on stdin
	awk '/^modelRoles:/{m=1;next} m&&/^[^ \t]/{m=0} m&&$1=="default:"{v=$0;sub(/^[^:]*:[ \t]*/,"",v);gsub(/["'"'"']/,"",v);n=split(v,a,"/");if(n>=2&&a[1]~/^[a-z0-9._-]+$/)print a[1];exit}'
}

# Candidate OS accounts: named for a provider, a real login, not the operator.
accounts() {
	if command -v getent >/dev/null 2>&1; then
		getent passwd | awk -F: '$3+0>=1000 && $3+0<60000 && $7!~/(nologin|false)$/ {print $1"\t"$6}'
	elif command -v dscl >/dev/null 2>&1; then
		dscl . -list /Users UniqueID | awk '$2+0>=500 && $2+0<60000 {print $1"\t/Users/"$1}'
	fi
}
accounts >"$T/accts" 2>/dev/null || :

sudo_ok=1
command -v sudo >/dev/null 2>&1 || sudo_ok=0
[ "$sudo_ok" = 1 ] && ! $tmo sudo -n true </dev/null >/dev/null 2>&1 && sudo_ok=0
[ "$sudo_ok" = 0 ] && printf 'NOSUDO\n' >>"$FACTS"

printf 'OP\t%s\t%s\n' "$operator" "$operator_home" >>"$FACTS"
printf 'CWD\t%s\n' "$launch_cwd" >>"$FACTS"

while IFS="$TAB" read -r name home; do
	[ -n "$name" ] || continue
	[ "$name" = "$operator" ] && continue
	case $name in *[!A-Za-z0-9._-]*) continue ;; esac
	prov=""
	for p in $providers; do
		case $name in "$p"*) prov=$p ;; esac
	done
	[ -n "$prov" ] || continue
	if [ "$sudo_ok" = 0 ]; then
		printf 'UNAV\t%s\t%s\tsudo -n is not available, so this account was not checked\n' "$name" "$prov" >>"$FACTS"
		continue
	fi
	if ! as_seat "$name" true; then
		printf 'UNAV\t%s\t%s\tit cannot be reached with sudo -n -i\n' "$name" "$prov" >>"$FACTS"
		continue
	fi
	if path=$(resolve_seat "$name" "$prov"); then
		fam=$(pfamily "$prov")
		[ "$prov" = omp ] && fam=$(as_seat "$name" cat .omp/agent/config.yml | omp_family)
		printf 'ACC\t%s\t%s\tseat\t%s\t%s\t%s\n' "$prov" "$name" "$path" "$home" "$fam" >>"$FACTS"
	else
		printf 'UNAV\t%s\t%s\tit has no %s it can run\n' "$name" "$prov" "$prov" >>"$FACTS"
	fi
done <"$T/accts"

for p in $providers; do
	if path=$(resolve_operator "$p"); then
		fam=$(pfamily "$p")
		if [ "$p" = omp ] && [ -r "$operator_home/.omp/agent/config.yml" ]; then fam=$(omp_family <"$operator_home/.omp/agent/config.yml"); fi
		printf 'ACC\t%s\t%s\toperator\t%s\t%s\t%s\n' "$p" "$operator" "$path" "$operator_home" "$fam" >>"$FACTS"
	fi
done

# Permission choices: only the flags the installed --help shows (the first account stands for its provider).
for p in $providers; do
	line=$(awk -F'\t' -v p="$p" '$1=="ACC"&&$2==p{print $3"\t"$4"\t"$5; exit}' "$FACTS")
	[ -n "$line" ] || continue
	acct=${line%%"$TAB"*}; rest=${line#*"$TAB"}; kind=${rest%%"$TAB"*}; cli=${rest#*"$TAB"}
	if [ "$kind" = seat ]; then help=$(as_seat "$acct" sh -c "$cli --help 2>&1") || help=""; else help=$($tmo "$cli" --help 2>&1 </dev/null) || help=""; fi
	perm_lines "$p" | while IFS="|" read -r label flag argv desc; do
		if [ -z "$flag" ] || printf '%s\n' "$help" | grep -F -q -e "$flag"; then
			printf 'PERM\t%s\t%s\t%s\t%s\n' "$p" "$label" "$argv" "$desc" >>"$FACTS"
		else
			printf 'NOFLAG\t%s\t%s\n' "$p" "$flag" >>"$FACTS"
		fi
	done
done

# Glitch folder: verify each candidate the same way SPAWN does (the two marker scripts are regular, readable files).
cands="$glitch_roots
$system_glitch"
[ -n "$operator_home" ] && cands="$cands
$operator_home/Glitch"
walk=$launch_cwd
i=0
while [ -n "$walk" ] && [ "$i" -lt 32 ]; do
	cands="$cands
$walk"
	next=${walk%/*}
	[ "$next" = "$walk" ] && break
	[ -z "$next" ] && next=/
	[ "$walk" = / ] && break
	walk=$next
	i=$((i + 1))
done
printf '%s\n' "$cands" | while IFS= read -r root; do
	[ -n "$root" ] || continue
	if [ -f "$root/.claude/scripts/workspaces.py" ] && [ -r "$root/.claude/scripts/workspaces.py" ] && [ -f "$root/.claude/scripts/plan_check.py" ] && [ -r "$root/.claude/scripts/plan_check.py" ]; then
		grep -F -x -q -e "$root" "$T/glitch" 2>/dev/null || printf '%s\n' "$root" >>"$T/glitch"
	fi
done
[ -f "$T/glitch" ] && while IFS= read -r root; do printf 'GLITCH\t%s\n' "$root" >>"$FACTS"; done <"$T/glitch"
printf 'PLACE\t%s\n' "$system_glitch" >>"$FACTS"
[ -n "$operator_home" ] && printf 'PLACE\t%s\n' "$operator_home/Glitch" >>"$FACTS"
printf 'PLACE\t%s\n' "the launch folder and its parents" >>"$FACTS"

awk -F'\t' '
function esc(s,   r, i, c) {
	r = ""
	for (i = 1; i <= length(s); i++) {
		c = substr(s, i, 1)
		if (c == "\\") r = r "\\\\"
		else if (c == "\"") r = r "\\\""
		else if (c == "\t") r = r "\\t"
		else if (c >= " ") r = r c
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
function pname(p) {
	if (p == "claude") return "Claude"; if (p == "codex") return "Codex"; if (p == "kimi") return "Kimi"
	if (p == "grok") return "Grok"; if (p == "agy") return "Agy"; if (p == "muse") return "Muse"
	return "OMP"
}
BEGIN {
	np = split("claude codex kimi grok agy muse omp", plist, " ")
	nacc = 0; nperm = 0; nunav = 0; nglitch = 0; nplace = 0; nosudo = 0; pcount = 0
}
$1 == "OP" { op = $2; ophome = $3 }
$1 == "CWD" { cwd = $2 }
$1 == "NOSUDO" { nosudo = 1 }
$1 == "ACC" { nacc++; aprov[nacc] = $2; aname[nacc] = $3; akind[nacc] = $4; apath[nacc] = $5; ahome[nacc] = $6; afam[nacc] = $7 }
$1 == "UNAV" { nunav++; uacct[nunav] = $2; uprov[nunav] = $3; ureason[nunav] = $4 }
$1 == "PERM" { nperm++; pprov[nperm] = $2; plabel[nperm] = $3; pargv[nperm] = $4; pdesc[nperm] = $5 }
$1 == "NOFLAG" { noflag[$2] = noflag[$2] (noflag[$2] == "" ? "" : ", ") $3 }
$1 == "GLITCH" { glitch[++nglitch] = $2 }
$1 == "PLACE" { place[++nplace] = $2 }
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
	else { g = ""; for (i = 1; i <= nplace; i++) g = g (i > 1 ? ", " : "") place[i]; intro = intro "," js("Glitch folder: not found in " g ".") }
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
	if (nglitch >= 1) for (i = 1; i <= nglitch; i++) fo = fo (fo == "" ? "" : ",") opt("Glitch folder: " glitch[i] (nglitch == 1 ? " (Recommended)" : ""), "Every agent starts in this Glitch installation.", nglitch == 1)
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
		for (i = 1; i <= nperm; i++) if (pprov[i] == p) { cnt++; po = po (po == "" ? "" : ",") opt(plabel[i], pdesc[i], pargv[i] == "") }
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
		for (i = 1; i <= nperm; i++) if (pprov[i] == p) { cnt++; list = list (list == "" ? "" : ",") "{\"label\":" js(plabel[i]) ",\"arguments\":" jarr(pargv[i]) "}" }
		if (cnt > 0) perms = perms (perms == "" ? "" : ",") js(pname(p)) ":[" list "]"
	}
	gl = ""
	for (i = 1; i <= nglitch; i++) gl = gl (i > 1 ? "," : "") js(glitch[i])
	derived = "{\"operator\":" js(op) ",\"launch_folder\":" js(cwd) ",\"providers\":[" provs "],\"accounts\":[" accs "],\"permissions\":{" perms "},\"glitch_folders\":[" gl "],"
	derived = derived "\"omp_prompt\":" js("Follow the explicitly assigned task. Role text is guidance, not identity isolation.") ","
	derived = derived "\"review\":{\"columns\":[\"ID\",\"account\",\"CLI\",\"permission flags\",\"folder\",\"paid check\"],\"paid_check_native\":\"one harmless paid model message\",\"paid_check_terminal\":\"offline checks only\"}}"
	printf "{\"intro\":%s,\"prompts\":[%s],\"derived\":%s,\"limits\":{\"questions_per_prompt\":4,\"options_per_question\":4,\"header_characters\":12}}\n", intro, prompts, derived
}' "$FACTS"
