"""SSH browser mode: open the paired page on the machine the operator is logged in from. Standard library only.

The agent runs on a VM, the operator's browser is on his computer, and an ssh reverse tunnel joins the two
(`ssh -R <browser_port>:127.0.0.1:<browser_port> vm`). This mode refuses to open anything until it has
proved, with the VM -> computer key (the detected alias) and a fresh-nonce probe through the standing tunnel (which is the
computer -> VM direction, on its own forward-only key), that the page on that
computer really is this service. Every check runs BEFORE a session is allocated, so a failed check creates nothing.

Process rules for this host: every subprocess call is an argv list with a timeout and BatchMode=yes, never a
shell string. The pairing URL carries a one-time code and ps is world-readable, so the URL is only ever sent
on the ssh command's STDIN and read by the remote side; it never appears in any argv.
"""
import base64
import hmac
import ipaddress
import json
import os
import re
import secrets
import socket
import struct
import subprocess

SSH_BASE = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-o', 'LogLevel=ERROR']
UTMP_PATH = '/run/utmp'  # a missing file means no logins
UTMP_FORMAT = '<h2xi32s4s32s256shhiii16s20x'  # glibc x86_64/aarch64 struct utmp, 384 bytes
USER_PROCESS = 7
# The pairing-URL grammar, Result and default_runner live in idea_tern (shared with pane mode) and stay importable here.
from idea_tern import PAIR_URL_PATTERN, URL_SHAPE, Result, default_runner  # noqa: E402,F401


MESSAGES = {
    'ssh_no_key': 'The VM -> computer ssh key is missing or refused: this account has no working key to your computer.',
    'ssh_tunnel_down': 'The computer -> VM direction is down: the standing ssh tunnel from your computer to this VM is not answering.',
    'ssh_tunnel_foreign': 'Something other than this service answers the tunnel port on your computer.',
    'ssh_no_client': 'No ssh login address matched an ssh config alias with a working key; set ssh_client.',
    'ssh_client_ambiguous': 'More than one computer matches; set ssh_client to choose one.',
    'ssh_requires_fixed_port': 'SSH mode needs browser_port set, so the tunnel has a fixed port.',
}


class SshError(Exception):
    def __init__(self, code, **details):
        super().__init__(code)
        self.code, self.details = code, details


def valid_ssh_alias(value):
    """One ssh config Host alias: a non-empty one-word string, never an option (no leading dash)."""
    return (type(value) is str and 1 <= len(value) <= 255 and not value.startswith('-')
            and not any(ch.isspace() or ord(ch) < 32 or ord(ch) == 127 for ch in value))


def _ssh(runner, alias, remote, *, input=None, timeout=15):
    """Run one remote command string on a client alias. `--` keeps an alias from ever being an option."""
    return runner(SSH_BASE + ['--', alias, remote], input=input, timeout=timeout)


def _refused(result):
    return result.returncode == 255 and 'permission denied' in result.stderr.lower()


def _address(text):
    try:
        return ipaddress.ip_address(str(text).strip().strip('[]').split('%')[0])
    except ValueError:
        return None


# ---- where is the operator logged in from ------------------------------------------------------------

def utmp_addresses(user=None, path=UTMP_PATH):
    """Remote addresses of current logins (one account, or all when user is None), read from utmp directly."""
    size, found = struct.calcsize(UTMP_FORMAT), []
    try:
        with open(path, 'rb') as stream:
            data = stream.read(size * 4096)
    except OSError:
        return found
    for offset in range(0, len(data) - size + 1, size):
        kind, _, _, _, name, _, _, _, _, _, _, raw = struct.unpack_from(UTMP_FORMAT, data, offset)
        if kind != USER_PROCESS or (user is not None and name.split(b'\0')[0].decode('ascii', 'replace') != user):
            continue
        address = ipaddress.IPv4Address(raw[:4]) if not any(raw[4:]) else ipaddress.IPv6Address(raw)
        if not address.is_unspecified and not address.is_loopback and address not in found:
            found.append(address)
    return found


PROC_TCP = ('/proc/net/tcp', '/proc/net/tcp6')
ESTABLISHED = '01'


def _proc_text():
    texts = []
    for path in PROC_TCP:
        try:
            with open(path, 'rb') as stream:
                texts.append(stream.read().decode('ascii', 'replace'))
        except OSError:
            texts.append('')
    return tuple(texts)


def _proc_address(hexed):
    """/proc/net/tcp prints each 32-bit word of an address little-endian; a v4-mapped v6 is the v4 address."""
    try:
        raw = b''.join(bytes.fromhex(hexed[i:i + 8])[::-1] for i in range(0, len(hexed), 8))
        address = ipaddress.ip_address(raw)
    except ValueError:
        return None
    return address.ipv4_mapped or address if address.version == 6 else address


def proc_tcp_peers(port=22, texts=None):
    """Remote addresses of ESTABLISHED TCP connections to this host's sshd port, for ALL accounts. /proc/net/tcp and
    tcp6 are world-readable, so no `ss` and no privilege. Loopback and unspecified peers are skipped."""
    texts = _proc_text() if texts is None else texts
    found = []
    for text in texts:
        for line in text.splitlines()[1:]:
            columns = line.split()
            if len(columns) < 4 or columns[3] != ESTABLISHED or ':' not in columns[1] or ':' not in columns[2]:
                continue
            local, remote = columns[1].rsplit(':', 1), columns[2].rsplit(':', 1)
            if not re.fullmatch(r'[0-9A-Fa-f]{4}', local[1]) or int(local[1], 16) != port:
                continue
            address = _proc_address(remote[0])
            if address is not None and not address.is_loopback and not address.is_unspecified and address not in found:
                found.append(address)
    return found


def login_addresses(env, utmp=utmp_addresses, proc=proc_tcp_peers, port=22):
    """Candidate client addresses, in order: $SSH_CONNECTION (first field) when this process has it, then the live
    ssh connections to this host's sshd port (/proc), then utmp logins of every account.

    Tern's remote link and VS Code Remote run without a pty, so utmp alone can be empty while hosts are connected."""
    found = []
    for text in str(env.get('SSH_CONNECTION', '')).split()[:1]:
        address = _address(text)
        if address is not None:
            found.append(address)
    for source in (lambda: proc(port), lambda: utmp(None)):
        for address in source():
            if address not in found:
                found.append(address)
    return found


def ssh_config_stanzas(path=None):
    """The Host lines of an ssh config as lists of aliases: a Host line is one configuration stanza and says
    nothing about machine identity (the same line can configure two computers). Wildcards, negations and anything that could be read as an option are skipped."""
    path = path or os.path.expanduser('~/.ssh/config')
    stanzas = []
    try:
        with open(path, 'rb') as stream:
            lines = stream.read().decode('utf-8', 'replace').splitlines()
    except OSError:
        return stanzas
    for line in lines:
        match = re.match(r'\s*Host\s*[=\s]\s*(.+?)\s*$', line, re.IGNORECASE)
        if not match:
            continue
        names = [t for t in match.group(1).split() if not any(ch in t for ch in '*?!') and valid_ssh_alias(t)]
        if names:
            stanzas.append(list(dict.fromkeys(names)))
    return stanzas


def ssh_config_aliases(path=None):
    return list(dict.fromkeys(alias for stanza in ssh_config_stanzas(path) for alias in stanza))


def _resolved(runner, alias):
    """`ssh -G` on this host: the effective hostname, user, port and identity files of an alias."""
    done = runner(['ssh', '-G', '--', alias], timeout=5)
    values = {}
    for line in done.stdout.splitlines() if done.returncode == 0 else ():
        key, _, value = line.partition(' ')
        values.setdefault(key.lower(), []).append(value.strip())
    if not values.get('hostname'):
        return None
    return (values['hostname'][0], values.get('user', [''])[0], values.get('port', ['22'])[0],
            tuple(values.get('identityfile', [])))


_GUID = r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}'
_IDENTITY_COMMAND = {
    'windows': 'reg query HKLM\\SOFTWARE\\Microsoft\\Cryptography /v MachineGuid',
    'linux': 'cat /etc/machine-id',
    'macos': 'ioreg -rd1 -c IOPlatformExpertDevice',
}


def _parse_identity(os_name, text):
    """The one machine id in a command's whole output, or None for anything but exactly one well-formed record
    (extra ids, garbage, duplicates, conflicts and malformed values are all unknown)."""
    if os_name == 'linux':
        text = text[:-1] if text.endswith('\n') else text
        return text if re.fullmatch(r'[0-9a-f]{32}', text) else None
    lines = [line for line in text.splitlines() if line.strip()]
    if os_name == 'windows':
        header = r'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography'
        records = [line for line in lines if line.strip() != header]
        found = [re.fullmatch(r'\s*MachineGuid\s+REG_SZ\s+(' + _GUID + r')\s*', line) for line in records]
        return found[0].group(1).lower() if len(found) == 1 and found[0] else None
    records = [line for line in lines if 'IOPlatformUUID' in line]
    found = [re.fullmatch(r'[\s|]*"IOPlatformUUID" = "(' + _GUID + r')"\s*', line) for line in records]
    return found[0].group(1).lower() if len(found) == 1 and found[0] else None


def machine_identity(runner, alias):
    """The machine id the computer reports over this alias (Windows MachineGuid, Linux machine-id, macOS
    IOPlatformUUID), or None when it is unknown or unreadable. The only thing allowed to say two aliases are one computer."""
    try:
        os_name = client_os(runner, alias)
    except SshError:
        return None
    done = _ssh(runner, alias, _IDENTITY_COMMAND[os_name])
    identity = _parse_identity(os_name, done.stdout) if done.returncode == 0 else None
    return (os_name, identity) if identity else None


def _host_addresses(hostname, resolver):
    literal = _address(hostname)
    if literal is not None:
        return {literal}
    try:
        return {a for a in (_address(item[4][0]) for item in resolver(hostname, None)) if a is not None}
    except (OSError, UnicodeError):
        return set()


def _host_matches(hostname, addresses, resolver):
    literal = _address(hostname)
    if literal is not None:
        return literal in addresses
    try:
        return any(_address(item[4][0]) in addresses for item in resolver(hostname, None))
    except (OSError, UnicodeError):
        return False


def client_os(runner, alias):
    """windows / macos / linux, cheaply: `ver` answers on Windows, `uname -s` elsewhere."""
    done = _ssh(runner, alias, 'ver')
    if done.returncode == 255:
        raise SshError('ssh_client_unreachable', ssh_client=alias)
    if 'windows' in done.stdout.lower():
        return 'windows'
    done = _ssh(runner, alias, 'uname -s')
    kind = done.stdout.strip().lower()
    if kind == 'darwin':
        return 'macos'
    if kind == 'linux':
        return 'linux'
    raise SshError('ssh_client_os_unknown', ssh_client=alias)


def _client_addresses(runner, alias):
    os_name = client_os(runner, alias)
    command = 'ipconfig' if os_name == 'windows' else "sh -c 'ip -o addr 2>/dev/null || ifconfig'"
    done = _ssh(runner, alias, command)
    found = set()
    for token in re.findall(r'[0-9A-Fa-f:.]+(?:%[A-Za-z0-9_]+)?', done.stdout):
        address = _address(token.rstrip('.:'))
        if address is not None:
            found.add(address)
    return found


def detect_client(config, runner=default_runner, *, env=None, utmp=utmp_addresses, proc=proc_tcp_peers,
                  ssh_config=None, resolver=socket.getaddrinfo, tunnel_check=None, **_ignored):
    """-> (alias, login_addresses). The alias of the machine the operator is connected from.

    ssh_client in the config skips the search (its key still has to answer). Otherwise candidates are this account's
    ssh config aliases with a working key whose addresses match a live ssh connection. tunnel_check(alias), when
    given, must raise SshError unless that client's tunnel proves this service: it is run on the one candidate, and
    it is the tie-break between several."""
    env = os.environ if env is None else env
    configured = (config or {}).get('ssh_client')
    port = (config or {}).get('ssh_server_port') or 22
    if configured is not None:
        if not valid_ssh_alias(configured):
            raise SshError('invalid_config')
        probe = _ssh(runner, configured, 'exit')
        if probe.returncode != 0:
            raise SshError('ssh_no_key' if _refused(probe) else 'ssh_client_unreachable', ssh_client=configured)
        if tunnel_check is not None:
            tunnel_check(configured)
        return configured, login_addresses(env, utmp, proc, port)
    addresses = login_addresses(env, utmp, proc, port)
    if not addresses:
        raise SshError('ssh_no_client')
    # Every ssh config alias is its own candidate: nothing is grouped before verification (a shared Host line, a DNS
    # overlap or a host/user/port tuple can still be two computers behind a jump host). The login addresses and the
    # alias's own interface addresses only FILTER which aliases are worth probing; they never establish identity.
    stanzas = (ssh_config_stanzas(ssh_config) if ssh_config is None or isinstance(ssh_config, str)
               else [[s_] if isinstance(s_, str) else list(s_) for s_ in ssh_config])
    good, refused = [], []
    for alias in dict.fromkeys(alias for stanza in stanzas for alias in stanza):
        resolved = _resolved(runner, alias)
        cheap = resolved is not None and _host_matches(resolved[0], addresses, resolver)
        probe = _ssh(runner, alias, 'exit')
        if _refused(probe):
            refused.append(alias)
            continue
        if probe.returncode != 0:
            continue
        try:
            if cheap or any(a in addresses for a in _client_addresses(runner, alias)):
                good.append(alias)
        except SshError:
            continue
    if len(good) == 1:
        if tunnel_check is not None:
            tunnel_check(good[0])
        return good[0], addresses
    if len(good) > 1:
        if tunnel_check is None:
            raise SshError('ssh_client_ambiguous', client_aliases=good)  # no proof, no folding
        proven = []
        for alias in good:
            try:
                tunnel_check(alias)
                proven.append(alias)
            except SshError:
                continue  # this client's tunnel is down, foreign or unreachable: it cannot be the one
        if len(proven) > 1:  # fold two aliases into one machine only when both report the same machine identity
            kept, seen = [], set()
            for alias in proven:
                identity = machine_identity(runner, alias)
                if identity is None or identity not in seen:
                    kept.append(alias)
                    if identity is not None:
                        seen.add(identity)
            proven = kept
        if len(proven) == 1:
            return proven[0], addresses
        raise SshError('ssh_client_ambiguous' if proven else 'ssh_tunnel_down', client_aliases=proven or good)
    if refused:
        raise SshError('ssh_no_key', **(dict(ssh_client=refused[0]) if len(refused) == 1 else {}))
    raise SshError('ssh_no_client')


def _account():
    import pwd
    return pwd.getpwuid(os.geteuid()).pw_name


# ---- the two directions of the keypair, and the tunnel ------------------------------------------------

def check_tunnel(runner, alias, port, secret, expected_proof):
    """A fresh nonce goes through the tunnel; only the live owner behind it can answer with the matching proof."""
    nonce = secrets.token_hex(16)
    done = _ssh(runner, alias, f'curl -s -m 5 "http://127.0.0.1:{int(port)}/api/v1/tunnel-probe?nonce={nonce}"', timeout=20)
    if done.returncode == 255:
        raise SshError('ssh_client_unreachable', ssh_client=alias)
    body = done.stdout.strip()
    if not body:
        if re.search(r'not recognized|not found|no such file', done.stderr, re.IGNORECASE):
            raise SshError('ssh_client_no_curl', ssh_client=alias)
        raise SshError('ssh_tunnel_down', ssh_client=alias, port=port)
    try:
        value = json.loads(body)
        proof = value.get('proof') if type(value) is dict and value.get('ok') is True else None
    except ValueError:
        proof = None
    if not (type(proof) is str and hmac.compare_digest(proof, expected_proof(secret, nonce))):
        raise SshError('ssh_tunnel_foreign', ssh_client=alias, port=port)


# ---- opening the page on the client ---------------------------------------------------------------

# Windows opens the page through the Glitch Idea Tern plugin only, by a request file in a private folder: that road puts
# the URL in no argv on the computer either. The plugin not being ready, not claiming the request or answering not-ok
# prints nothing opened (exit != 0), and the caller returns the link instead. There is no CLI or default-browser road.
_WINDOWS_OPEN = r'''
$sb = New-Object System.Text.StringBuilder
$buf = New-Object char[] 64
while (($n = [Console]::In.Read($buf, 0, 64)) -gt 0) { [void]$sb.Append($buf, 0, $n); if ($sb.Length -gt 512) { exit 3 } }
$u = $sb.ToString()
if ($u.EndsWith("`r`n")) { $u = $u.Substring(0, $u.Length - 2) } elseif ($u.EndsWith("`n")) { $u = $u.Substring(0, $u.Length - 1) }
if ($u -cnotmatch '^@@PAT@@\z') { exit 3 }
$tern = Join-Path $env:LOCALAPPDATA 'Programs\Tern\tern.com'
if (-not $env:LOCALAPPDATA -or -not (Test-Path -LiteralPath $tern)) { exit 4 }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$me = $identity.User
# An administrator's ssh login is elevated, and an elevated tern.com talks to Tern's elevated daemon, not the one the
# operator's window uses. So: an inherited TERN_DAEMON_SOCKET, then the default daemon (the variable cleared), then
# every Tern daemon pipe this user's own SID owns; the first daemon with a window AND the ready plugin is the one.
$sockets = @()
if ($env:TERN_DAEMON_SOCKET) { $sockets += $env:TERN_DAEMON_SOCKET }
$sockets += ''
try {
  foreach ($p in @([IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -like '\\.\pipe\tern-*' } | Select-Object -First 16)) {
    try { if ([IO.Directory]::GetAccessControl($p).GetOwner([Security.Principal.SecurityIdentifier]).Value -eq $me.Value) { $sockets += $p } } catch { }
  }
} catch { }
$window = $false
$ready = $false
foreach ($s in $sockets) {
  if ($s) { $env:TERN_DAEMON_SOCKET = $s } else { Remove-Item -LiteralPath Env:TERN_DAEMON_SOCKET -ErrorAction SilentlyContinue }
  $here = $false
  try {
    $i = (& $tern inspect --json | Out-String) | ConvertFrom-Json
    $here = @($i.clients | Where-Object { $_.kind -eq 'window' }).Count -gt 0
  } catch { }
  if (-not $here) { continue }
  $window = $true
  try {
    $pl = (& $tern plugin list --json | Out-String) | ConvertFrom-Json
    $ready = @($pl.plugins | Where-Object { $_.id -eq 'glitch-idea' -and $_.window -eq $true -and $_.status -eq 'ready' }).Count -gt 0
  } catch { }
  if ($ready) { break }
}
if (-not $window) { exit 9 }
if (-not $ready) { exit 10 }
$system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
$admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole($admins)
$base = Join-Path $env:LOCALAPPDATA 'glitch-idea'
$dir = Join-Path $base 'open'
foreach ($d in @($base, $dir)) {
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -ErrorAction Stop | Out-Null }
  $item = Get-Item -LiteralPath $d -Force
  if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { exit 8 }
  $owner = (Get-Acl -LiteralPath $d).GetOwner([Security.Principal.SecurityIdentifier]).Value
  if (-not ($owner -eq $me.Value -or ($owner -eq $admins.Value -and $isAdmin))) { exit 8 }
  try { $own = New-Object System.Security.AccessControl.DirectorySecurity; $own.SetOwner($me); Set-Acl -LiteralPath $d -AclObject $own } catch { }
  $acl = New-Object System.Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($sid in @($me, $system, $admins)) {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
  }
  Set-Acl -LiteralPath $d -AclObject $acl
  $check = Get-Acl -LiteralPath $d
  $rules = @($check.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
  if (-not $check.AreAccessRulesProtected -or $rules.Count -eq 0 -or @($rules | Where-Object { $_.IdentityReference.Value -ne $me.Value -and $_.IdentityReference.Value -ne $system.Value -and $_.IdentityReference.Value -ne $admins.Value }).Count -gt 0) { exit 8 }
}
$rb = New-Object byte[] 16
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($rb)
$id = ([BitConverter]::ToString($rb) -replace '-', '').ToLower()
$tmp = Join-Path $dir ($id + '.tmp')
$req = Join-Path $dir ($id + '.req')
$res = Join-Path $dir ($id + '.res')
$body = (@{ v = 1; url = $u; created = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } | ConvertTo-Json -Compress)
[IO.File]::WriteAllText($tmp, $body, (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tmp -Destination $req
for ($n = 0; $n -lt 20 -and (Test-Path -LiteralPath $req); $n++) { Start-Sleep -Milliseconds 200 }
if (Test-Path -LiteralPath $req) {
  # Withdraw it. A remove that fails means the plugin holds it (claimed): keep waiting for the answer.
  $withdrawn = $false
  try { Remove-Item -LiteralPath $req -Force -ErrorAction Stop; $withdrawn = $true } catch { }
  if ($withdrawn) { exit 6 }
}
for ($n = 0; $n -lt 75 -and -not (Test-Path -LiteralPath $res); $n++) { Start-Sleep -Milliseconds 200 }
if (-not (Test-Path -LiteralPath $res)) { exit 5 }
Start-Sleep -Milliseconds 100
$r = $null
try { $r = (Get-Content -LiteralPath $res -Raw) | ConvertFrom-Json } catch { }
Remove-Item -LiteralPath $res -Force -ErrorAction SilentlyContinue
if ($r -ne $null -and $r.ok -eq $true) { Write-Output 'OPENED tern-plugin'; exit 0 }
exit 7
'''.replace('@@PAT@@', PAIR_URL_PATTERN)
_POSIX_OPEN = ("sh -c 'f=$(mktemp) || exit 3; trap \"rm -f $f\" EXIT; cat > \"$f\"; "
               "[ \"$(tr -d \"\\000\" < \"$f\" | wc -c | tr -d \" \")\" = \"$(wc -c < \"$f\" | tr -d \" \")\" ] || exit 3; "
               "{ IFS= read -r u; IFS= read -r x && exit 3; [ -z \"$x\" ] || exit 3; } < \"$f\"; "
               "printf \"%%s\\n\" \"$u\" | LC_ALL=C grep -Eqx \"" + PAIR_URL_PATTERN + "\" || exit 3; "
               "%s && echo OPENED default'")


# cmd.exe refuses a command line over 8191 characters, and the real script is far past that once encoded. So the
# command carries only this fixed bootstrap: it reads line 1 of stdin (the script, base64 of UTF-8), builds a
# scriptblock and runs it; the script then reads the rest of the same stdin (the one URL line) itself.
_WINDOWS_BOOTSTRAP = r'''
$sb = New-Object System.Text.StringBuilder
while ($true) { $c = [Console]::In.Read(); if ($c -lt 0 -or $c -eq 10) { break }; [void]$sb.Append([char]$c); if ($sb.Length -gt 65536) { exit 3 } }
$s = $sb.ToString().TrimEnd("`r")
if (-not $s) { exit 3 }
& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))))
exit $LASTEXITCODE
'''


def windows_script():
    return _WINDOWS_OPEN.strip()


def windows_command():
    encoded = base64.b64encode(_WINDOWS_BOOTSTRAP.strip().encode('utf-16-le')).decode('ascii')
    return 'powershell -NoLogo -NoProfile -NonInteractive -EncodedCommand ' + encoded


def windows_stdin(url):
    """Line 1 the script, line 2 the one URL line. Neither is in any argv."""
    return base64.b64encode(windows_script().encode('utf-8')).decode('ascii') + '\n' + url + '\n'


# Why a page did not open, by the opener's exit status: fixed codes only, never remote output.
_WINDOWS_FAILURES = {3: 'invalid_input', 4: 'tern_missing', 5: 'plugin_no_answer', 6: 'plugin_did_not_claim',
                     7: 'plugin_refused', 8: 'request_folder_unsafe', 9: 'no_tern_window', 10: 'plugin_not_ready'}
_COMMON_FAILURES = {124: 'timeout', 255: 'ssh_failed'}


def open_failure(os_name, returncode):
    """The fixed reason for an opener that did not print OPENED."""
    table = {**_COMMON_FAILURES, **(_WINDOWS_FAILURES if os_name == 'windows' else {3: 'invalid_input'})}
    return table.get(returncode, 'open_failed')


def open_on_client(runner, alias, os_name, url):
    """-> (how, failure): how is 'tern-plugin' on Windows or 'default' on macOS and Linux with failure None, or how is
    None and failure is the fixed reason it did not open (see open_failure).

    The URL travels on ssh's stdin only. Windows opens it through the Tern plugin's request file, so it reaches no argv
    there. macOS `open` and Linux `xdg-open` take the URL as an argument, so on those computers it is briefly visible in
    that computer's own process list (no plugin exists there); the one-time code is valid for 60 s and used once."""
    if not URL_SHAPE.fullmatch(url):
        raise SshError('invalid_input')
    if os_name == 'windows':
        command = windows_command()
    elif os_name == 'macos':
        command = _POSIX_OPEN % 'open "$u"'
    else:
        command = _POSIX_OPEN % '{ [ -n "$DISPLAY" ] || export DISPLAY=:0; xdg-open "$u"; }'
    payload = windows_stdin(url) if os_name == 'windows' else url + '\n'
    done = _ssh(runner, alias, command, input=payload, timeout=30)
    match = re.search(r'^OPENED (tern-plugin|default)\s*$', done.stdout, re.MULTILINE)
    if done.returncode == 0 and match:
        return match.group(1), None
    return None, open_failure(os_name, done.returncode)


# ---- the whole door ---------------------------------------------------------------------------------

def open_ssh_session(store, runtime_root, config, *, ssh_client=None, ssh_server_port=None, runner=default_runner,
                     env=None, utmp=utmp_addresses, proc=proc_tcp_peers, ssh_config=None, resolver=socket.getaddrinfo,
                     **options):
    import idea_launch
    import idea_runtime
    port = (config or {}).get('browser_port')
    if port is None:
        raise SshError('ssh_requires_fixed_port')
    env = os.environ if env is None else env
    # The tunnel proof needs the service answering, so it starts first; nothing is allocated until the checks pass.
    idea_launch.ensure_service(store, runtime_root, config, runtime_python=options.get('runtime_python'),
                               readiness_timeout=options.get('readiness_timeout', 5))
    secret = idea_runtime.Runtime(store, runtime_root).tunnel_probe_secret(timeout=1)

    def tunnel_check(alias):
        try:
            check_tunnel(runner, alias, port, secret, idea_runtime.expected_tunnel_proof)
        except SshError as exc:
            exc.details.setdefault('ssh_client', alias)
            raise

    alias, _ = detect_client(dict(ssh_client=ssh_client, ssh_server_port=ssh_server_port), runner, env=env, utmp=utmp,
                             proc=proc, ssh_config=ssh_config, resolver=resolver, tunnel_check=tunnel_check)
    os_name = client_os(runner, alias)
    result = idea_launch.open_session(store, runtime_root, config, **options)
    code = result['pairing_code']
    link = result['origin'].rstrip('/') + '/#pair=' + code
    how, failure = open_on_client(runner, alias, os_name, link)
    browser = dict(mode='ssh', url=result['origin'], link=link, client=alias, client_os=os_name, opened=how is not None)
    result = dict(result, browser=browser,
                  fallback_line=f'Only if the tab did not open paired: type {code} within 60 s.')
    if how is None:
        # The session is live and its code lasts 60 s: hand back the link rather than waste it, but say so loudly.
        result['warning'] = 'ssh_open_failed'
        browser['failure'] = failure
    else:
        browser['how'] = how
    return result
