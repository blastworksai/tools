"""Owner-private authority, pinned installation TLS, and one-use pairing.

Peer verifiers and invitations live exclusively in Store. Local authority is a
separate startup-rotated capability, never a peer credential. Public failures
contain fixed protocol messages, not OS, OpenSSL, ACL, or request diagnostics.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import stat
import subprocess
import tempfile
import threading
import time
from datetime import datetime, timedelta, timezone
from urllib.parse import urlsplit

from .protocol import Authority, PROTOCOL, ServiceError, identifier

INVITATION_SECONDS = 600
_TOKEN = re.compile(r"[A-Za-z0-9_-]{43,128}\Z", re.ASCII)
_HEX = re.compile(r"[0-9a-fA-F]{64}\Z", re.ASCII)
_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z", re.ASCII)

# Fixed code; the path is JSON on stdin, never interpolated into executable code.
# Use SID objects, not localized account names, and replace the entire DACL.
_WINDOWS_ACL = r"""
$ErrorActionPreference = 'Stop'
try {
    $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $path = [string]$request.path
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $item = Get-Item -LiteralPath $path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'unsafe' }
    if ($request.protect) {
        if ($item.PSIsContainer) {
            $acl = New-Object System.Security.AccessControl.DirectorySecurity
            $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
        } else {
            $acl = New-Object System.Security.AccessControl.FileSecurity
            $inherit = [Security.AccessControl.InheritanceFlags]::None
        }
        # Do not request an owner change for an already-owned object: normal
        # desktop tokens can replace its DACL without SeRestorePrivilege.
        $existing = Get-Acl -LiteralPath $path
        if ($existing.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value) {
            $acl.SetOwner($sid)
        }
        $acl.SetAccessRuleProtection($true, $false)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [Security.AccessControl.FileSystemRights]::FullControl,
            $inherit, [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
        # Persist only modified access/owner sections, without requesting audit
        # access through Set-Acl's provider (SeSecurityPrivilege).
        $item.SetAccessControl($acl)
    }
    $acl = Get-Acl -LiteralPath $path
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value) { throw 'unsafe' }
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    if ($rules.Count -eq 0) { throw 'unsafe' }
    $effective = $false
    foreach ($rule in $rules) {
        if ($rule.IdentityReference.Value -ne $sid.Value -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl) { throw 'unsafe' }
        if (($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -eq 0) {
            $effective = $true
        }
    }
    if (-not $effective) { throw 'unsafe' }
    [Console]::Out.Write('private')
} catch { exit 1 }
"""


def _windows_acl(path: Path, *, protect: bool = False) -> None:
    try:
        # A full system path prevents a writable PATH entry from supplying PowerShell.
        system = os.environ.get("SystemRoot")
        if not system or not Path(system).is_absolute():
            raise OSError()
        executable = Path(system) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        result = subprocess.run(
            [str(executable), "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand",
             base64.b64encode(_WINDOWS_ACL.encode("utf-16le")).decode("ascii")],
            input=json.dumps({"path": str(path.absolute()), "protect": protect}),
            text=True, capture_output=True, timeout=15, check=False,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        if result.returncode != 0 or result.stdout != "private":
            raise OSError()
    except (OSError, subprocess.SubprocessError, ValueError):
        raise ServiceError("setup_required", 503) from None


def check_private(path: Path) -> None:
    """Reject links, foreign ownership and any non-owner access; never repair."""
    try:
        path = Path(path)
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
            raise OSError()
        if stat.S_ISREG(info.st_mode) and info.st_nlink != 1:
            raise OSError()
        if os.name == "nt":
            _windows_acl(path)
        elif os.name == "posix":
            expected = 0o700 if stat.S_ISDIR(info.st_mode) else 0o600
            if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != expected:
                raise OSError()
        else:
            raise OSError()
    except (OSError, ValueError, TypeError):
        raise ServiceError("setup_required", 503) from None


def private_directory(root: Path) -> None:
    """Create only the requested data directory; existing permissions must be safe."""
    try:
        root = Path(root)
        try:
            root.mkdir(mode=0o700)
        except FileExistsError:
            check_private(root)
            if not root.is_dir():
                raise OSError()
            return
        if os.name == "nt":
            _windows_acl(root, protect=True)
        check_private(root)
    except (OSError, ValueError, TypeError):
        raise ServiceError("setup_required", 503) from None


def private_staging_directory(parent: Path, prefix: str) -> Path:
    """Protect only this newly created staging directory, never existing state."""
    check_private(parent)
    path = Path(tempfile.mkdtemp(prefix=prefix, dir=parent))
    try:
        if os.name == "nt":
            # Python's mode-0700 directory ACL includes system/admin principals.
            _windows_acl(path, protect=True)
        check_private(path)
        return path
    except BaseException:
        path.rmdir()
        raise


def write_private(path: Path, data: bytes) -> None:
    """Atomic replacement within a private directory, with no public staging file."""
    temporary = None
    descriptor = None
    try:
        path = Path(path)
        if not isinstance(data, bytes):
            raise TypeError()
        check_private(path.parent)
        if not path.parent.is_dir():
            raise OSError()
        if os.path.lexists(path):
            check_private(path)
            if not path.is_file():
                raise OSError()
        descriptor, name = tempfile.mkstemp(prefix=".private-", dir=path.parent)
        temporary = Path(name)
        if os.name == "nt":
            _windows_acl(temporary, protect=True)
        check_private(temporary)
        with os.fdopen(descriptor, "wb") as stream:
            descriptor = None
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    except (OSError, ValueError, TypeError):
        raise ServiceError("setup_required", 503) from None
    finally:
        try:
            if descriptor is not None:
                os.close(descriptor)
            if temporary is not None:
                temporary.unlink(missing_ok=True)
        except OSError:
            raise ServiceError("setup_required", 503) from None


def endpoint(value: str) -> str:
    """A canonical HTTPS origin, not an arbitrary URL or path prefix."""
    try:
        if not isinstance(value, str) or not 1 <= len(value) <= 2048:
            raise ValueError()
        if not value.isascii() or re.search(r"[\s\\%?#@]", value) or not value.startswith("https://"):
            raise ValueError()
        parsed = urlsplit(value)
        if parsed.scheme != "https" or not parsed.netloc or parsed.path not in ("", "/"):
            raise ValueError()
        host = parsed.hostname
        port = parsed.port
        if not host or parsed.netloc.endswith(":") or (port is not None and not 1 <= port <= 65535):
            raise ValueError()
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            # Reject legacy inet_aton forms and DNS labels that disguise IP literals.
            if len(host) > 253 or host.endswith(".") or re.fullmatch(r"[0-9.]+", host):
                raise ValueError()
            if any(not _LABEL.fullmatch(label) for label in host.split(".")):
                raise ValueError()
            if any(label.startswith("0x") and re.fullmatch(r"0x[0-9a-f]+", label) for label in host.split(".")):
                raise ValueError()
            if "[" in parsed.netloc or "]" in parsed.netloc:
                raise ValueError()
            canonical = host
        else:
            if address.is_unspecified or address.is_multicast:
                raise ValueError()
            canonical = f"[{address.compressed}]" if address.version == 6 else str(address)
        suffix = f":{port}" if port is not None else ""
        # No hidden suffix after an IPv6 bracket, leading-zero ports, or alternate host syntax.
        if parsed.netloc.lower() != canonical + suffix:
            raise ValueError()
        return "https://" + canonical + suffix
    except (ValueError, TypeError, UnicodeError):
        raise ServiceError("invalid_request") from None


def pin(value: str) -> bytes:
    if not isinstance(value, str) or not _HEX.fullmatch(value):
        raise ServiceError("invalid_request")
    return bytes.fromhex(value)


def secret() -> str:
    return secrets.token_urlsafe(32)


def _token(value: object) -> bool:
    return isinstance(value, str) and _TOKEN.fullmatch(value) is not None


def verifier(token: str) -> str:
    if not _token(token):
        raise ServiceError("unauthorized", 401)
    return hashlib.sha256(token.encode("ascii")).hexdigest()


def matches(token: str, stored_hash: str) -> bool:
    if not _token(token) or not isinstance(stored_hash, str) or not _HEX.fullmatch(stored_hash):
        return False
    return hmac.compare_digest(verifier(token), stored_hash.lower())


def bearer(header: str | None) -> str:
    if not isinstance(header, str) or not header.startswith("Bearer ") or not _token(header[7:]):
        raise ServiceError("unauthorized", 401)
    return header[7:]


def _group(value: object) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}", value, re.ASCII):
        raise ServiceError("invalid_request")
    return value


def validate_invitation(value: dict, *, now_ms: int | None = None) -> dict:
    fields = {"protocol", "endpoint", "device_id", "fingerprint", "secret", "expires_at_ms", "group_id"}
    if not isinstance(value, dict) or set(value) != fields:
        raise ServiceError("invalid_request")
    if type(value["protocol"]) is not int or value["protocol"] != PROTOCOL:
        raise ServiceError("incompatible_version")
    now = int(time.time() * 1000) if now_ms is None else now_ms
    expiry = value["expires_at_ms"]
    # The hub enforces the real expiry with its own clock; only reject what is already past here.
    if type(expiry) is not int or expiry <= now:
        raise ServiceError("expired", 410)
    if not _token(value["secret"]):
        raise ServiceError("invalid_request")
    return {"protocol": PROTOCOL, "endpoint": endpoint(value["endpoint"]),
            "device_id": identifier(value["device_id"]), "fingerprint": pin(value["fingerprint"]).hex(),
            "secret": value["secret"], "expires_at_ms": expiry, "group_id": _group(value["group_id"])}


def ensure_certificate(root: Path) -> dict:
    """Keep a stable pinned identity; invalid/partial existing pairs fail closed."""
    # Bootstrap needs private filesystem helpers before the locked environment
    # exists. Cryptography is mandatory only when starting the TLS identity.
    try:
        from cryptography import x509
        from cryptography.exceptions import InvalidSignature, UnsupportedAlgorithm
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
    except ImportError:
        raise ServiceError("setup_required", 503) from None
    try:
        root = Path(root)
        private_directory(root)
        cert_path, key_path = root / "tls-cert.pem", root / "tls-key.pem"
        existing = os.path.lexists(cert_path), os.path.lexists(key_path)
        if any(existing) and not all(existing):
            raise ValueError()
        now = datetime.now(timezone.utc)
        if not any(existing):
            key = ec.generate_private_key(ec.SECP256R1())
            name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "USAGE installation")])
            cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                    .public_key(key.public_key()).serial_number(x509.random_serial_number())
                    .not_valid_before(now - timedelta(minutes=5)).not_valid_after(now + timedelta(days=3650))
                    .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
                    .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
                    .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost")]), critical=False)
                    .sign(key, hashes.SHA256()))
            write_private(key_path, key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                     serialization.NoEncryption()))
            write_private(cert_path, cert.public_bytes(serialization.Encoding.PEM))
        check_private(cert_path)
        check_private(key_path)
        if cert_path.stat().st_size > 16384 or key_path.stat().st_size > 16384:
            raise ValueError()
        cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
        key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
        if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(key.curve, ec.SECP256R1):
            raise ValueError()
        public = cert.public_key()
        if not isinstance(public, ec.EllipticCurvePublicKey) or public.public_numbers() != key.public_key().public_numbers():
            raise ValueError()
        if cert.issuer != cert.subject or cert.signature_hash_algorithm.name != "sha256":
            raise ValueError()
        public.verify(cert.signature, cert.tbs_certificate_bytes, ec.ECDSA(cert.signature_hash_algorithm))
        if not cert.not_valid_before_utc <= now < cert.not_valid_after_utc:
            raise ValueError()
        if cert.extensions.get_extension_for_class(x509.BasicConstraints).value.ca:
            raise ValueError()
        if ExtendedKeyUsageOID.SERVER_AUTH not in cert.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value:
            raise ValueError()
        return {"cert": cert_path, "key": key_path, "fingerprint": cert.fingerprint(hashes.SHA256()).hex()}
    except (OSError, ValueError, TypeError, InvalidSignature, UnsupportedAlgorithm,
            x509.ExtensionNotFound, x509.DuplicateExtension):
        raise ServiceError("setup_required", 503) from None


def tls_context(root: Path) -> ssl.SSLContext:
    certificate = ensure_certificate(root)
    try:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(certificate["cert"], certificate["key"])
        return context
    except (OSError, ValueError, ssl.SSLError):
        raise ServiceError("setup_required", 503) from None


def validate_local(host: str, origin: str | None, authorization: str | None,
                   expected_host: str, token: str) -> None:
    """Call only on the separate literal-loopback listener; duplicate headers rejected upstream."""
    try:
        if origin is not None or not isinstance(expected_host, str):
            raise ValueError()
        parsed = urlsplit("http://" + expected_host)
        address = ipaddress.ip_address(parsed.hostname or "")
        if not address.is_loopback or not parsed.port or parsed.path or parsed.query or parsed.fragment:
            raise ValueError()
        literal = f"[{address.compressed}]" if address.version == 6 else str(address)
        if expected_host != f"{literal}:{parsed.port}" or host != expected_host:
            raise ValueError()
        supplied = bearer(authorization)
        if not _token(token) or not hmac.compare_digest(supplied, token):
            raise ValueError()
    except (ValueError, TypeError, ServiceError):
        raise ServiceError("unauthorized", 401) from None


class FailureLimiter:
    """Fixed-window per-remote and global failure limits with a hard memory bound.

    Never evict an active bucket to admit a new remote: address rotation must not
    erase failures. Keys are bounded digests; credentials are never retained.
    """
    def __init__(self, limit: int = 8, global_limit: int = 128, window: float = 60,
                 max_keys: int = 1024, clock=time.monotonic):
        if min(limit, global_limit, max_keys) < 1 or window <= 0:
            raise ServiceError("invalid_request")
        self.limit, self.global_limit, self.window, self.max_keys = limit, global_limit, window, max_keys
        self.clock = clock
        self._buckets: dict[bytes, tuple[float, int]] = {}
        self._global = (clock(), 0)
        self._lock = threading.Lock()

    def _key(self, remote: str) -> bytes:
        if not isinstance(remote, str) or not 1 <= len(remote) <= 256:
            raise ServiceError("unauthorized", 429)
        return hashlib.sha256(remote.encode("utf-8", errors="replace")).digest()

    def _prune(self, now: float) -> None:
        self._buckets = {key: value for key, value in self._buckets.items() if now - value[0] < self.window}
        if now - self._global[0] >= self.window:
            self._global = (now, 0)

    def check(self, remote: str = "global") -> None:
        key = self._key(remote)
        with self._lock:
            self._prune(self.clock())
            if (self._global[1] >= self.global_limit or self._buckets.get(key, (0, 0))[1] >= self.limit
                    or (key not in self._buckets and len(self._buckets) >= self.max_keys)):
                raise ServiceError("unauthorized", 429)

    def failure(self, remote: str = "global") -> None:
        key = self._key(remote)
        with self._lock:
            now = self.clock()
            self._prune(now)
            self._global = (self._global[0], min(self.global_limit, self._global[1] + 1))
            if key in self._buckets or len(self._buckets) < self.max_keys:
                start, count = self._buckets.get(key, (now, 0))
                self._buckets[key] = (start, min(self.limit, count + 1))


class Security:
    def __init__(self, store, root: Path, *, clock=time.time):
        self.store, self.root, self.clock = store, Path(root), clock
        private_directory(self.root)
        self.local_token = secret()
        write_private(self.root / "local.token", self.local_token.encode("ascii"))
        self.auth_failures = FailureLimiter()
        self.pair_failures = FailureLimiter(limit=5, global_limit=64)

    def offer(self, endpoint_url: str, group_id: str) -> dict:
        # Validate all user-controlled fields before generating/persisting secrets.
        normalized_endpoint = endpoint(endpoint_url)
        group_id = _group(group_id)
        certificate = ensure_certificate(self.root)
        invitation_secret = secret()
        expiry = int(self.clock() * 1000) + INVITATION_SECONDS * 1000
        identity = self.store.identity()
        self.store.create_invitation(verifier(invitation_secret), expiry, group_id)
        return {"protocol": PROTOCOL, "endpoint": normalized_endpoint, "device_id": identity["device_id"],
                "fingerprint": certificate["fingerprint"], "secret": invitation_secret,
                "expires_at_ms": expiry, "group_id": group_id}

    def consume(self, invitation_secret: str, device_id: str, *, remote: str = "global") -> dict:
        self.pair_failures.check(remote)
        try:
            device_id = identifier(device_id)
            identity = self.store.identity()
            if device_id == identity["device_id"]:
                raise ServiceError("unauthorized", 401)
            credential = secret()
            result = self.store.consume_invitation(verifier(invitation_secret), int(self.clock() * 1000), device_id,
                                                   verifier(credential))
        except ServiceError:
            self.pair_failures.failure(remote)
            raise ServiceError("unauthorized", 401) from None
        return {"credential": credential, "device_id": identity["device_id"],
                "group_id": result["group_id"], "protocol": PROTOCOL}

    def authenticate(self, token: str, *, remote: str = "global") -> Authority:
        # Hash once, compare every peer verifier without returning on the first match.
        candidate = verifier(token) if _token(token) else "0" * 64
        found = None
        for peer in self.store.peers():
            equal = hmac.compare_digest(candidate, peer["credential_hash"])
            if equal and not peer.get("revoked"):
                found = peer
        if not _token(token) or hmac.compare_digest(candidate, verifier(self.local_token)) or found is None:
            # Valid 256-bit credentials are checked first, so failed guesses from
            # other hosts cannot lock paired members out.
            self.auth_failures.check(remote)
            self.auth_failures.failure(remote)
            raise ServiceError("unauthorized", 401)
        return Authority(found["device_id"], found["group_id"])

    def authenticate_local(self, host: str, origin: str | None, authorization: str | None,
                           expected_host: str) -> Authority:
        validate_local(host, origin, authorization, expected_host, self.local_token)
        identity = self.store.identity()
        return Authority(identity["device_id"], identity["group_id"], role="owner", local=True)
