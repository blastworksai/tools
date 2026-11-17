"""Explicit plan pointers owned by live agent processes. CodexBWAI; MIT.

This metadata is not a second plan or a work queue. No input reaches an agent.
"""
import contextlib
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import time

from process_identity import ProcessEnded, process, session_process

LIMIT = 16384
PREFIX = 'tern-todo-publications-'
LIVE = 'live'
ENDED = 'ended-or-changed'
UNKNOWN = 'unknown'


class PublicationEnded(ValueError):
    terminal = True


class PublicationUnavailable(OSError):
    terminal = False


def owner():
    return process(os.getpid())['owner']


def _linux():
    return sys.platform.startswith('linux')


def root():
    # Explicit fixture configuration; unset in deployments. Both host and publisher
    # inherit the same private test root; normal native discovery uses OS caches.
    fixture = os.environ.get('TODO_PUBLICATION_ROOT')
    if fixture:
        base = Path(fixture)
        if not base.is_absolute() or str(base).startswith(('\\\\', '//')):
            raise ValueError('publication root must be an absolute local path')
        try:
            base.mkdir(mode=0o700, parents=True)
            if os.name == 'nt': _windows_security(base,owner(),True)
        except FileExistsError: pass
        _safe(base, owner(), True)
        return base
    if os.name == 'nt':
        buffer = ctypes.create_unicode_buffer(32768)
        if ctypes.windll.shell32.SHGetFolderPathW(None, 28, None, 0, buffer) != 0:
            raise OSError('cannot locate the native user cache')
        return Path(buffer.value)/'Tern'/'TODO-publications'
    if sys.platform == 'darwin':
        return Path.home()/'Library'/'Caches'/'Tern'/'TODO-publications'
    return Path('/var/tmp')


def _group():
    if not _linux(): return None
    import grp
    try:
        gid = grp.getgrnam('agents').gr_gid
        if gid == os.getegid() or gid in os.getgroups(): return gid
    except KeyError: pass
    return os.getegid()


def _windows_security(path, identity, create=False, *, handle=None):
    from ctypes import wintypes as w
    api=ctypes.WinDLL('advapi32',use_last_error=True);kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    pointer=ctypes.c_void_p
    api.ConvertStringSecurityDescriptorToSecurityDescriptorW.argtypes=[w.LPCWSTR,w.DWORD,ctypes.POINTER(pointer),ctypes.POINTER(w.DWORD)]
    api.SetFileSecurityW.argtypes=[w.LPCWSTR,w.DWORD,pointer]
    api.GetNamedSecurityInfoW.argtypes=[w.LPWSTR,ctypes.c_int,w.DWORD,ctypes.POINTER(pointer),pointer,ctypes.POINTER(pointer),pointer,ctypes.POINTER(pointer)]
    api.GetSecurityInfo.argtypes=[w.HANDLE,ctypes.c_int,w.DWORD,ctypes.POINTER(pointer),pointer,ctypes.POINTER(pointer),pointer,ctypes.POINTER(pointer)]
    api.GetSecurityInfo.restype=w.DWORD
    api.ConvertSidToStringSidW.argtypes=[pointer,ctypes.POINTER(w.LPWSTR)]
    api.GetAce.argtypes=[pointer,w.DWORD,ctypes.POINTER(pointer)]
    kernel.LocalFree.argtypes=[pointer]
    if create:
        sd=pointer();sddl='D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;'+identity+')'
        if not api.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl,1,ctypes.byref(sd),None):
            raise OSError('cannot create private publication permissions')
        try:
            if not api.SetFileSecurityW(str(path),0x80000004,sd):raise OSError('cannot protect publication permissions')
        finally:kernel.LocalFree(sd)
    sid=pointer();acl=pointer();sd=pointer()
    if handle is None:
        status=api.GetNamedSecurityInfoW(str(path),1,5,ctypes.byref(sid),None,ctypes.byref(acl),None,ctypes.byref(sd))
    else:
        status=api.GetSecurityInfo(handle,1,5,ctypes.byref(sid),None,ctypes.byref(acl),None,ctypes.byref(sd))
    if status!=0:
        raise OSError('cannot inspect publication permissions')
    allowed={identity,'S-1-5-18','S-1-5-32-544'}
    def sid_text(value):
        text=w.LPWSTR()
        if not api.ConvertSidToStringSidW(value,ctypes.byref(text)):raise OSError('cannot read publication owner')
        try:return text.value
        finally:kernel.LocalFree(ctypes.cast(text,pointer))
    try:
        if sid_text(sid) not in allowed or not acl:raise ValueError('unsafe publication owner or permissions')
        # ACL's public header carries its ACE count at byte 4; plain allowed ACEs
        # contain mask then SID. Other grant forms fail closed.
        count=ctypes.c_ushort.from_address(acl.value+4).value
        for index in range(count):
            ace=pointer()
            if not api.GetAce(acl,index,ctypes.byref(ace)):raise OSError('cannot read publication permissions')
            kind=ctypes.c_ubyte.from_address(ace.value).value
            if kind==1:continue
            if kind!=0:raise ValueError('unsupported publication permissions')
            mask=ctypes.c_uint32.from_address(ace.value+4).value
            if mask & 0x500d0156 and sid_text(pointer(ace.value+8)) not in allowed:
                raise ValueError('publication permits another account to write')
    finally:kernel.LocalFree(sd)


def _safe(path, expected, directory=False, migrating=False):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
        raise ValueError('publication paths must not be links or reparse points')
    if directory != stat.S_ISDIR(info.st_mode) or (not directory and not stat.S_ISREG(info.st_mode)):
        raise ValueError('invalid publication file type')
    if not directory and info.st_nlink != 1:
        raise ValueError('publication files must not have additional links')
    if os.name == 'nt':
        _windows_security(path,expected)
    else:
        if str(info.st_uid) != expected or info.st_mode & 0o022:
            raise ValueError('publication ownership or write permissions are unsafe')
        if not _linux() and not migrating and info.st_mode & 0o077:
            raise ValueError('publication metadata must be owner-only on this OS')
    return info


def _metadata_inventory(folder, identity):
    inventory = []
    entries = [(folder, True, 0o700)]
    entries.extend((path, False, 0o600) for path in sorted(folder.iterdir()))
    for path, is_directory, target_mode in entries:
        info = _safe(path, identity, is_directory, migrating=True)
        mode = stat.S_IMODE(info.st_mode)
        if mode != target_mode:
            inventory.append({'path': str(path), 'from_mode': mode, 'target_mode': target_mode,
                              'device': info.st_dev, 'inode': info.st_ino, 'directory': is_directory})
    return inventory


def _open_metadata_directory(folder, identity):
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0) | getattr(os, 'O_DIRECTORY', 0)
    descriptor = os.open(folder, flags)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISDIR(info.st_mode) or str(info.st_uid) != identity or info.st_mode & 0o022:
            raise ValueError('publication directory ownership or permissions are unsafe')
        return descriptor, info
    except Exception:
        os.close(descriptor)
        raise


def _apply_metadata_inventory(folder, identity, inventory):
    descriptor, folder_info = _open_metadata_directory(folder, identity)
    try:
        for item in inventory:
            if not item['directory']: continue
            if (folder_info.st_dev, folder_info.st_ino) != (item['device'], item['inode']):
                raise ValueError('publication directory changed during migration')
            os.fchmod(descriptor, item['target_mode'])
        flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
        for item in inventory:
            if item['directory']: continue
            child = os.open(Path(item['path']).name, flags, dir_fd=descriptor)
            try:
                info = os.fstat(child)
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or str(info.st_uid) != identity:
                    raise ValueError('invalid publication metadata during migration')
                if (info.st_dev, info.st_ino, stat.S_IMODE(info.st_mode)) != (
                        item['device'], item['inode'], item['from_mode']):
                    raise ValueError('publication metadata changed during migration')
                os.fchmod(child, item['target_mode'])
            finally:
                os.close(child)
    finally:
        os.close(descriptor)


def migration_inventory(identity):
    """List only this account's publication metadata that needs owner-only modes."""
    if _linux() or os.name == 'nt': return []
    if identity != owner(): raise ValueError('publication belongs to another native account')
    return _metadata_inventory(root()/(PREFIX+identity), identity)


def directory(identity, create=False):
    base = root()
    # Linux alone shares pointer metadata through agents. Other POSIX platforms
    # remain owner-only; canonical plans are never included in mode migration.
    if not _linux():
        if identity != owner(): raise ValueError('publication belongs to another native account')
        if create: base.mkdir(mode=0o700, parents=True, exist_ok=True)
    else:
        info = base.stat()
        if info.st_mode & 0o002 and not info.st_mode & stat.S_ISVTX:
            raise ValueError('publication parent must protect per-user directories')
    folder = base/(PREFIX+identity)
    created = False
    if create:
        try:
            folder.mkdir(mode=0o700)
            created = True
        except FileExistsError: pass
        if os.name == 'nt':
            if created: _windows_security(folder,identity,True)
        elif _linux():
            descriptor, _ = _open_metadata_directory(folder, identity)
            try:
                os.fchown(descriptor, -1, _group())
                os.fchmod(descriptor, 0o751)
            finally:
                os.close(descriptor)
        else:
            _apply_metadata_inventory(folder, identity, _metadata_inventory(folder, identity))
    _safe(folder, identity, True)
    if _linux() and not create and not folder.stat().st_mode & 0o001:
        raise ValueError('publication directory does not support safe targeted lookup')
    return folder


@contextlib.contextmanager
def _writer_lock(target, identity):
    lock_path = target.with_name(target.name+'.lock')
    flags = os.O_RDWR | os.O_CREAT | getattr(os, 'O_NOFOLLOW', 0)
    descriptor = os.open(lock_path, flags, 0o600)
    locked = False
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError('invalid publication lock file')
        if os.name == 'nt':
            _windows_security(lock_path, identity)
            if info.st_size == 0: os.write(descriptor, b'\0')
        else:
            if str(info.st_uid) != identity or info.st_mode & 0o022:
                raise ValueError('publication lock ownership or permissions are unsafe')
            if _linux():
                os.fchown(descriptor, -1, _group()); os.fchmod(descriptor, 0o640)
            else:
                os.fchmod(descriptor, 0o600)
        deadline = time.monotonic()+5
        while True:
            try:
                if os.name == 'nt':
                    import msvcrt
                    os.lseek(descriptor, 0, os.SEEK_SET)
                    msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                locked = True
                break
            except OSError as error:
                if error.errno not in {errno.EACCES, errno.EAGAIN} or time.monotonic() >= deadline:
                    raise
                time.sleep(0.02)
        yield
    finally:
        if locked:
            if os.name == 'nt':
                import msvcrt
                os.lseek(descriptor, 0, os.SEEK_SET)
                msvcrt.locking(descriptor, msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _key(agent):
    return str(agent['pid'])+'-'+hashlib.sha256(agent['birth'].encode()).hexdigest()[:20]+'.json'


@contextlib.contextmanager
def _windows_checked_handle(path, identity, access):
    from ctypes import wintypes as w
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [w.LPCWSTR, w.DWORD, w.DWORD, ctypes.c_void_p,
                                   w.DWORD, w.DWORD, w.HANDLE]
    kernel.CreateFileW.restype = w.HANDLE
    kernel.GetFileType.argtypes = [w.HANDLE]
    kernel.GetFileInformationByHandle.argtypes = [w.HANDLE, ctypes.c_void_p]
    kernel.CloseHandle.argtypes = [w.HANDLE]
    class Info(ctypes.Structure):
        _fields_ = [('attributes', w.DWORD), ('created', w.FILETIME),
                    ('accessed', w.FILETIME), ('written', w.FILETIME),
                    ('volume', w.DWORD), ('size_high', w.DWORD), ('size_low', w.DWORD),
                    ('links', w.DWORD), ('index_high', w.DWORD), ('index_low', w.DWORD)]
    handle = kernel.CreateFileW(str(path), access, 0x1 | 0x2 | 0x4, None, 3,
                                0x00200000 | 0x80, None)
    if handle == ctypes.c_void_p(-1).value:
        error = ctypes.get_last_error()
        if error in {2, 3}: raise FileNotFoundError(error, 'publication not found', str(path))
        if error == 5: raise PermissionError(error, 'publication access denied', str(path))
        raise ctypes.WinError(error)
    try:
        info = Info()
        if kernel.GetFileType(handle) != 1 or not kernel.GetFileInformationByHandle(handle, ctypes.byref(info)):
            raise OSError('cannot inspect the open publication')
        if info.attributes & 0x410 or info.links != 1:
            raise ValueError('publication changed while opening')
        _windows_security(path, identity, handle=handle)
        yield kernel, handle
    finally:
        kernel.CloseHandle(handle)


def _windows_read(path, identity):
    from ctypes import wintypes as w
    with _windows_checked_handle(path, identity, 0x80000000) as (kernel, handle):
        kernel.ReadFile.argtypes = [w.HANDLE, ctypes.c_void_p, w.DWORD,
                                   ctypes.POINTER(w.DWORD), ctypes.c_void_p]
        buffer = ctypes.create_string_buffer(LIMIT+1)
        count = w.DWORD()
        if not kernel.ReadFile(handle, buffer, LIMIT+1, ctypes.byref(count), None):
            raise ctypes.WinError(ctypes.get_last_error())
        return buffer.raw[:count.value]


def _replace_publication(source, target, identity):
    if os.name != 'nt':
        os.replace(source, target)
        return
    from ctypes import wintypes as w
    # FileRenameInfoEx with POSIX semantics preserves an already-open reader's
    # original bytes while replacing its directory entry. Do not ignore
    # readonly, sharing or security failures.
    # https://learn.microsoft.com/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information
    class RenameInfo(ctypes.Structure):
        _fields_ = [('flags', w.DWORD), ('root', w.HANDLE),
                    ('name_bytes', w.DWORD), ('name', w.WCHAR * 1)]
    encoded = str(target).encode('utf-16-le')
    buffer = ctypes.create_string_buffer(ctypes.sizeof(RenameInfo)+len(encoded))
    info = RenameInfo.from_buffer(buffer)
    info.flags = 0x1 | 0x2  # REPLACE_IF_EXISTS | POSIX_SEMANTICS
    info.name_bytes = len(encoded)
    ctypes.memmove(ctypes.addressof(buffer)+RenameInfo.name.offset, encoded, len(encoded))
    # DELETE for rename; READ_CONTROL and FILE_READ_ATTRIBUTES for validation.
    with _windows_checked_handle(source, identity, 0x00010000 | 0x00020000 | 0x80) as (kernel, handle):
        kernel.SetFileInformationByHandle.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD]
        kernel.SetFileInformationByHandle.restype = w.BOOL
        if not kernel.SetFileInformationByHandle(handle, 22, buffer, len(buffer)):
            raise ctypes.WinError(ctypes.get_last_error())


def _read(path, identity):
    _safe(path, identity)
    if os.name == 'nt':
        raw = _windows_read(path, identity)
    else:
        flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, 'rb') as stream:
            info = os.fstat(stream.fileno())
            unsafe_posix = str(info.st_uid) != identity or info.st_mode & 0o022 or (not _linux() and info.st_mode & 0o077)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or unsafe_posix:
                raise ValueError('publication changed while opening')
            raw = stream.read(LIMIT+1)
    if len(raw)>LIMIT: raise ValueError('publication exceeds its size limit')
    record = json.loads(raw)
    if not isinstance(record, dict) or record.get('schema') != 1 or record.get('owner') != identity or record.get('state') not in {'active','none'}:
        raise ValueError('invalid publication record')
    if type(record.get('published_ns')) is not int or record['published_ns'] <= 0:
        raise ValueError('invalid publication revision')
    anchors = record.get('anchors')
    if not isinstance(anchors,list) or not 2<=len(anchors)<=48:
        raise ValueError('invalid publication process chain')
    return record


def _identity(saved):
    try:
        current = process(saved['pid'])
    except ProcessEnded:
        return ENDED, None
    except OSError as error:
        return UNKNOWN, error
    if any(current.get(key) != saved.get(key) for key in ['pid','ppid','owner','birth']):
        return ENDED, None
    return LIVE, current


def _unknown(saved, error):
    raise PublicationUnavailable(f"cannot inspect native process {saved.get('pid')}: {error}") from error


def _valid(record, parent=None):
    anchors = record['anchors']
    if anchors[0]['owner'] != record['owner']:
        raise ValueError('publication agent does not own its record')
    state, last = _identity(anchors[-1])
    if state == UNKNOWN: _unknown(anchors[-1], last)
    if state != LIVE: return False
    name=last['name'].lower()
    if name.endswith('.exe'):name=name[:-4]
    if name!='tern':return False
    if parent is not None and anchors[-2].get('pid')!=parent:
        return False
    previous = None
    for saved in anchors:
        state, live = _identity(saved)
        if state == UNKNOWN: _unknown(saved, live)
        if state != LIVE:
            return False
        if previous is not None and previous != live['pid']:
            return False
        previous = live['ppid']
    return True


def _source(record):
    path = record.get('path'); plan_id = record.get('plan_id')
    import re
    if not isinstance(path,str) or not Path(path).is_absolute() or path.startswith(('\\\\','//')) or any(ord(c)<32 for c in path):
        raise ValueError('published plan path is invalid')
    if not isinstance(plan_id,str) or not re.fullmatch('plan-[0-9a-f]{12}',plan_id):
        raise ValueError('published plan id is invalid')
    agent = record['anchors'][0]
    parent=record['anchors'][-2]
    return {'path':path,'plan_id':plan_id,'publication':{'owner':record['owner'],'pid':agent['pid'],'birth':agent['birth'],'parent_pid':parent['pid'],'parent_birth':parent['birth']}}


def _revision(record):
    return record['owner'], record['published_ns'], record['anchors']


def _retract_observed(target, identity, expected):
    try:
        current = _read(target, identity)
    except FileNotFoundError:
        return
    if expected is None or _revision(current) != expected:
        return
    # The native writer lock excludes cooperating writers. This check and unlink
    # are not an atomic compare-delete against outside modification.
    target.unlink()


def publish(path, read_plan, agent_pid):
    anchors = session_process(agent_pid); identity = anchors[0]['owner']
    folder=directory(identity,True);target=folder/_key(anchors[-2])
    # Prune before taking the target lock, and take each candidate's own lock so
    # cross-session pruning has no nested lock order or stale revalidation window.
    for old in list(folder.glob('*.json'))[:128]:
        if old == target: continue
        try:
            with _writer_lock(old, identity):
                old_record = _read(old,identity)
                if not _valid(old_record):
                    _retract_observed(old, identity, _revision(old_record))
        except (OSError,ValueError,KeyError,TypeError): pass
    with _writer_lock(target, identity):
        try:
            existing = _read(target,identity)
        except FileNotFoundError:
            existing = None
        observed = _revision(existing) if existing is not None else None
        def same_agent(saved):
            return all(saved[key] == anchors[0][key] for key in ['pid','birth','owner'])
        if existing is not None and _valid(existing) and not same_agent(existing['anchors'][0]):
            raise ValueError('another live publisher already owns this native session')
        if path is None:
            _retract_observed(target, identity, observed)
            return {'ok':True,'state':'none'}
        replacement_attempted = False
        replaced = False
        try:
            revision = time.time_ns()
            if existing is not None: revision = max(revision, existing['published_ns']+1)
            record = {'schema':1,'owner':identity,'anchors':anchors,'state':'none','published_ns':revision}
            selected=Path(path)
            if not selected.is_absolute() or str(selected).startswith(('\\\\','//')):
                raise ValueError('the published plan must be an absolute local path')
            if os.name=='nt':
                drive=ctypes.windll.kernel32.GetDriveTypeW(ctypes.c_wchar_p(selected.anchor))
                if drive==4:raise ValueError('network plan roots are not accepted')
                for part in [*reversed(selected.parents),selected]:
                    if getattr(part.lstat(),'st_file_attributes',0)&0x400:
                        raise ValueError('published plan paths must not cross reparse points')
            canonical = selected.resolve(strict=True)
            if str(canonical).startswith(('\\\\','//')): raise ValueError('network plan roots are not accepted')
            plan = read_plan(canonical)
            record.update(state='active',path=str(canonical),plan_id=plan['plan_id'])
            data=json.dumps(record,ensure_ascii=True,separators=(',',':')).encode()
            if len(data)>LIMIT: raise ValueError('publication exceeds its size limit')
            descriptor,temporary=tempfile.mkstemp(prefix='.publish-',dir=folder)
            try:
                with os.fdopen(descriptor,'wb') as stream:
                    if os.name!='nt':
                        if _linux(): os.fchown(stream.fileno(),-1,_group());os.fchmod(stream.fileno(),0o640)
                        else: os.fchmod(stream.fileno(),0o600)
                    stream.write(data);stream.flush();os.fsync(stream.fileno())
                replacement_attempted = True
                _replace_publication(temporary, target, identity)
                replaced = True
            finally:
                if os.path.exists(temporary): os.unlink(temporary)
        except (OSError,ValueError,KeyError,TypeError):
            if replaced:
                _retract_observed(target, identity, _revision(record))
            elif not replacement_attempted:
                _retract_observed(target, identity, observed)
            raise
    return {'ok':True,'state':record['state'],'publication':{'owner':identity,'pid':anchors[0]['pid'],'birth':anchors[0]['birth'],'parent_pid':anchors[-2]['pid'],'parent_birth':anchors[-2]['birth']}}


def discover(parent, parent_birth=None, with_identity=False):
    parent=int(parent);native=process(parent)
    # A saved view names the process by PID and birth: a reused PID is another process and ends the wait.
    if parent_birth is not None and native['birth']!=parent_birth:
        raise ProcessEnded('the selected session has ended or changed')
    extra={'parent_birth':native['birth']} if with_identity else {}
    base=root(); candidates=[]
    try: base.stat()
    except FileNotFoundError: return {'ok':True,'state':'none',**extra}
    for folder in base.glob(PREFIX+'*'):
        identity=folder.name[len(PREFIX):]
        if not identity or len(identity)>100 or any(c not in '0123456789S-' for c in identity): continue
        # Namespace names are untrusted directory entries, not publications.
        try: info = folder.lstat()
        except OSError: continue
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode) or getattr(info,'st_file_attributes',0)&0x400:
            continue
        if not _linux():
            if identity != owner(): continue
        elif str(info.st_uid) != identity: continue
        path=folder/_key(native)
        try: path.lstat()
        except FileNotFoundError: continue
        directory(identity)  # A matching unsafe store is a detection error, never no-plan.
        try: record=_read(path,identity)
        except FileNotFoundError: continue
        if _valid(record,parent): candidates.append(record)
    if len(candidates)>1: raise ValueError('multiple live agent publications match this session')
    if not candidates or candidates[0]['state']=='none': return {'ok':True,'state':'none',**extra}
    return {'ok':True,'state':'active','source':_source(candidates[0]),**extra}


def read_binding(source, read_plan):
    if not isinstance(source,dict) or set(source)!={'publication','path','plan_id'}:
        raise ValueError('invalid publication source')
    binding=source['publication']
    if not isinstance(binding,dict) or set(binding)!={'owner','pid','birth','parent_pid','parent_birth'}:
        raise ValueError('invalid publication binding')
    import re
    if not isinstance(binding['owner'],str) or not re.fullmatch(r'(?:[0-9]+|S-[0-9-]+)',binding['owner']):
        raise ValueError('invalid publication owner')
    for key in ['pid','parent_pid']:
        if type(binding[key]) is not int or binding[key]<=0: raise ValueError('invalid publication process identity')
    for key in ['birth','parent_birth']:
        if not isinstance(binding[key],str) or not 1<=len(binding[key])<=160: raise ValueError('invalid publication process identity')
    native={'pid':binding['parent_pid'],'birth':binding['parent_birth']}
    try:record=_read(directory(binding['owner'])/_key(native),binding['owner'])
    except FileNotFoundError:raise PublicationEnded('this session is not working on a published plan') from None
    if not _valid(record) or any(record['anchors'][0][key]!=binding[key] for key in ['pid','birth']):
        raise PublicationEnded('the publishing agent process has ended or changed')
    if record['state']!='active': raise PublicationEnded('this session is not working on a published plan')
    current=_source(record)
    if current['publication']!=binding:raise PublicationEnded('the publishing session identity changed')
    if current['path']!=source['path'] or current['plan_id']!=source['plan_id']:
        raise PublicationEnded('this session published a different plan; attach it explicitly')
    plan=read_plan(Path(current['path']))
    if plan['plan_id']!=current['plan_id']:raise PublicationEnded('the published file now belongs to a different plan')
    return {'ok':True,'source':current,'plan':plan}
