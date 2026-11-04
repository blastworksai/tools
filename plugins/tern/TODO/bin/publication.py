"""Explicit plan pointers owned by live agent processes. CodexBWAI; MIT.

This metadata is not a second plan or a work queue. No input reaches an agent.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import time

from process_identity import process, session_process

LIMIT = 16384
PREFIX = 'tern-todo-publications-'


def owner():
    return process(os.getpid())['owner']


def root():
    if os.name == 'nt':
        buffer = ctypes.create_unicode_buffer(32768)
        if ctypes.windll.shell32.SHGetFolderPathW(None, 28, None, 0, buffer) != 0:
            raise OSError('cannot locate the native user cache')
        return Path(buffer.value)/'Tern'/'TODO-publications'
    if sys.platform == 'darwin':
        return Path.home()/'Library'/'Caches'/'Tern'/'TODO-publications'
    return Path('/var/tmp')


def _group():
    if os.name == 'nt': return None
    import grp
    try:
        gid = grp.getgrnam('agents').gr_gid
        if gid == os.getegid() or gid in os.getgroups(): return gid
    except KeyError: pass
    return os.getegid()


def _windows_security(path, identity, create=False):
    from ctypes import wintypes as w
    api=ctypes.WinDLL('advapi32',use_last_error=True);kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    pointer=ctypes.c_void_p
    api.ConvertStringSecurityDescriptorToSecurityDescriptorW.argtypes=[w.LPCWSTR,w.DWORD,ctypes.POINTER(pointer),ctypes.POINTER(w.DWORD)]
    api.SetFileSecurityW.argtypes=[w.LPCWSTR,w.DWORD,pointer]
    api.GetNamedSecurityInfoW.argtypes=[w.LPWSTR,ctypes.c_int,w.DWORD,ctypes.POINTER(pointer),pointer,ctypes.POINTER(pointer),pointer,ctypes.POINTER(pointer)]
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
    if api.GetNamedSecurityInfoW(str(path),1,5,ctypes.byref(sid),None,ctypes.byref(acl),None,ctypes.byref(sd))!=0:
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


def _safe(path, expected, directory=False):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
        raise ValueError('publication paths must not be links or reparse points')
    if directory != stat.S_ISDIR(info.st_mode) or (not directory and not stat.S_ISREG(info.st_mode)):
        raise ValueError('invalid publication file type')
    if os.name == 'nt':
        _windows_security(path,expected)
    else:
        if str(info.st_uid) != expected or info.st_mode & 0o022:
            raise ValueError('publication ownership or write permissions are unsafe')
    return info


def directory(identity, create=False):
    base = root()
    # macOS and Windows use the native user's private cache; Linux uses sticky /var/tmp
    # so the Tern host account can read the agents-group metadata without credentials.
    if os.name == 'nt' or sys.platform == 'darwin':
        if identity != owner(): raise ValueError('publication belongs to another native account')
        if create: base.mkdir(mode=0o700, parents=True, exist_ok=True)
    else:
        info = base.stat()
        if info.st_mode & 0o002 and not info.st_mode & stat.S_ISVTX:
            raise ValueError('publication parent must protect per-user directories')
    folder = base/(PREFIX+identity)
    if create:
        try:
            folder.mkdir(mode=0o700)
            if os.name != 'nt':
                os.chown(folder, -1, _group()); folder.chmod(0o751)
            else: _windows_security(folder,identity,True)
        except FileExistsError: pass
    _safe(folder, identity, True)
    if os.name != "nt" and sys.platform != "darwin":
        if create: os.chown(folder,-1,_group());folder.chmod(0o751)
        elif not folder.stat().st_mode & 0o001: raise ValueError("publication directory does not support safe targeted lookup")
    return folder


def _key(agent):
    return str(agent['pid'])+'-'+hashlib.sha256(agent['birth'].encode()).hexdigest()[:20]+'.json'


def _read(path, identity):
    _safe(path, identity)
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
    descriptor = os.open(path, flags)
    with os.fdopen(descriptor, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or (os.name != 'nt' and (str(info.st_uid) != identity or info.st_mode & 0o022)):
            raise ValueError('publication changed while opening')
        raw = stream.read(LIMIT+1)
    if len(raw)>LIMIT: raise ValueError('publication exceeds its size limit')
    record = json.loads(raw)
    if not isinstance(record, dict) or record.get('schema') != 1 or record.get('owner') != identity or record.get('state') not in {'active','none'}:
        raise ValueError('invalid publication record')
    anchors = record.get('anchors')
    if not isinstance(anchors,list) or not 2<=len(anchors)<=48:
        raise ValueError('invalid publication process chain')
    return record


def _valid(record, parent=None):
    anchors = record['anchors']
    if anchors[0]['owner'] != record['owner']:
        raise ValueError('publication agent does not own its record')
    try:last=process(anchors[-1]['pid'])
    except (OSError,ValueError):return False
    name=last['name'].lower()
    if name.endswith('.exe'):name=name[:-4]
    if name!='tern':return False
    if parent is not None and anchors[-2].get('pid')!=parent:
        return False
    previous = None
    for saved in anchors:
        try:live = process(saved['pid'])
        except (OSError,ValueError):return False
        if any(live[key] != saved[key] for key in ['pid','ppid','owner','birth']):
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


def publish(path, read_plan):
    anchors = session_process(); identity = anchors[0]['owner']
    folder=directory(identity,True);target=folder/_key(anchors[-2])
    # A failed new publication must never leave yesterday's successful binding.
    if os.path.lexists(target):
        _safe(target,identity);target.unlink()
    if path is None:return {'ok':True,'state':'none'}
    record = {'schema':1,'owner':identity,'anchors':anchors,'state':'none','published_ns':time.time_ns()}
    if path is not None:
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
            if os.name!='nt': os.fchown(stream.fileno(),-1,_group());os.fchmod(stream.fileno(),0o640)
            stream.write(data);stream.flush();os.fsync(stream.fileno())
        os.replace(temporary,target)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
    return {'ok':True,'state':record['state'],'publication':{'owner':identity,'pid':anchors[0]['pid'],'birth':anchors[0]['birth'],'parent_pid':anchors[-2]['pid'],'parent_birth':anchors[-2]['birth']}}


def discover(parent):
    parent=int(parent);native=process(parent)
    base=root(); candidates=[]
    if not base.exists(): return {'ok':True,'state':'none'}
    for folder in base.glob(PREFIX+'*'):
        identity=folder.name[len(PREFIX):]
        if not identity or len(identity)>100 or any(c not in '0123456789S-' for c in identity): continue
        try: directory(identity)
        except FileNotFoundError: continue
        except ValueError: continue
        path=folder/_key(native)
        try: record=_read(path,identity)
        except FileNotFoundError: continue
        if _valid(record,parent): candidates.append(record)
    if len(candidates)>1: raise ValueError('multiple live agent publications match this session')
    if not candidates or candidates[0]['state']=='none': return {'ok':True,'state':'none'}
    return {'ok':True,'state':'active','source':_source(candidates[0])}


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
    except FileNotFoundError:raise ValueError('this session is not working on a published plan') from None
    if not _valid(record) or any(record['anchors'][0][key]!=binding[key] for key in ['pid','birth']):
        raise ValueError('the publishing agent process has ended or changed')
    if record['state']!='active': raise ValueError('this session is not working on a published plan')
    current=_source(record)
    if current['publication']!=binding:raise ValueError('the publishing session identity changed')
    if current['path']!=source['path'] or current['plan_id']!=source['plan_id']:
        raise ValueError('this session published a different plan; attach it explicitly')
    plan=read_plan(Path(current['path']))
    if plan['plan_id']!=current['plan_id']:raise ValueError('the published file now belongs to a different plan')
    return {'ok':True,'source':current,'plan':plan}
