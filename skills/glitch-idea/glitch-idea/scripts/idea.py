#!/usr/bin/env python3
"""Local idea lifecycle CLI adapter. Python 3.10+."""
import argparse
import json as _json
import math
import os
import re
import stat
from pathlib import Path
import sys

# A shared install is read-only at run time: write no bytecode beside the scripts. This runs before any
# sibling module is imported, so none of them leaves a .pyc in the shared folder.
try:
    _marker=Path(__file__).resolve().parent.parent/'.glitch-idea-install.json'
    if _json.loads(_marker.read_bytes()[:65536]).get('shared') is True: sys.dont_write_bytecode=True
except Exception:
    pass

from idea_domain import IdeaError, decode, encoded, number, require, text
from idea_store import read_bytes
from idea_service import run_legacy as run, default_workspace


class Parser(argparse.ArgumentParser):
    def error(self,message):
        raise IdeaError('usage','Invalid launcher arguments' if getattr(self,'launcher_errors',False) else message)


def parser():
    cli=Parser(description=__doc__)
    cli.add_argument('--store')
    commands=cli.add_subparsers(dest='command',required=True,parser_class=Parser)
    for name in ('capture','list','show','exploration','shape','rate','assess','propose','place','handoff','register-plan','record-execution','deliver','doctor','repair-views'):
        p=commands.add_parser(name)
        if name=='shape':
            # Retired verb: parsed only so it can answer unsupported_command, pointing at exploration.
            p.add_argument('idea_id',nargs='?')
            p.add_argument('--actor');p.add_argument('--file');p.add_argument('--expected-revision')
            continue
        if name not in ('capture','list','doctor','repair-views'):
            p.add_argument('idea_id')
        if name in ('capture','exploration','rate','assess','propose','place','register-plan','record-execution','deliver'):
            p.add_argument('--actor',required=True)
        if name=='capture':
            p.add_argument('--text-file',required=True)
        if name in ('exploration','assess'):
            p.add_argument('--file',required=True)
        if name in ('exploration','rate','assess','register-plan'):
            p.add_argument('--expected-revision',required=True,type=int)
        if name=='rate':
            p.add_argument('--urgency',required=True,type=int)
            p.add_argument('--importance',required=True,type=int)
        if name in ('propose','place'):
            p.add_argument('--position',required=True,type=int)
            p.add_argument('--reason',required=True)
            p.add_argument('--expected-backlog-revision',required=True,type=int)
        if name in ('register-plan','record-execution'):
            p.add_argument('--path',required=True)
        if name=='register-plan':
            # Both or neither: together they move the idea's living file into that workspace.
            p.add_argument('--workspace-name')
            p.add_argument('--workspace-path')
        if name=='deliver':
            p.add_argument('--ref',required=True)
        if name=='record-execution':
            p.add_argument('--plan-id',required=True)
    p=commands.add_parser('import-idea')
    p.add_argument('--from',dest='source',required=True)
    p.add_argument('--idea',dest='idea_id',required=True)
    p.add_argument('--actor',required=True)
    p.add_argument('--dry-run',action='store_true')
    p=commands.add_parser('remove-idea')
    p.add_argument('--idea',dest='idea_id',required=True)
    p.add_argument('--actor',required=True)
    p.add_argument('--confirm',action='store_true')
    p.add_argument('--runtime-root')
    for name in ('serve','session-open','browser-open'):
        p=commands.add_parser(name)
        p.launcher_errors=True
        p.add_argument('--runtime-root',required=name=='serve')
        if name != 'serve':
            p.add_argument('--runtime-python')
            p.add_argument('--readiness-timeout',type=float,default=5)
            p.add_argument('--resume')
            p.add_argument('--idea-id')
            # Both or neither: this one new session's Capture prefill (never a move).
            p.add_argument('--workspace-name')
            p.add_argument('--workspace-path')
        if name == 'browser-open':
            p.add_argument('--browser',choices=('link','orca','system','tern'))
            p.add_argument('--orca-worktree')
            p.add_argument('--orca-terminal')
            p.add_argument('--orca-host')
            p.add_argument('--reconnect')
    p=commands.add_parser('prototype-serve')
    p.launcher_errors=True
    p.add_argument('--runtime-root')
    p.add_argument('--runtime-python')
    p.add_argument('--session',required=True)
    p.add_argument('--dir',required=True)
    for name in ('sessions','session-discard'):
        p=commands.add_parser(name)
        p.launcher_errors=True
        p.add_argument('--runtime-root')
        p.add_argument('--runtime-python')
        if name=='session-discard':
            p.add_argument('--binding',required=True)
            p.add_argument('--confirm',action='store_true')
    for name in ('events','respond','fill','asset','session-close'):
        p=commands.add_parser(name)
        p.launcher_errors=True
        p.add_argument('--runtime-root')
        p.add_argument('--runtime-python')
        p.add_argument('--session',required=True)
        p.add_argument('--generation')
        if name=='events':
            p.add_argument('--after',type=int,default=0)
            p.add_argument('--timeout',type=float,default=25)
        if name in ('respond','fill'):
            p.add_argument('--request',required=True)
            p.add_argument('--payload',required=True)
        if name=='asset':
            p.add_argument('--idea',required=True)
            p.add_argument('--revision',type=int,required=True)
            p.add_argument('--request',required=True)
            p.add_argument('--file',required=True)
            p.add_argument('--type',choices=('image/png','application/zip'))
    return cli


_SOURCE_CACHE=None  # set only while main() runs, so one invocation reads its configuration (and registry) once


def _configuration_source():
    if _SOURCE_CACHE is None: return _read_configuration_source()
    if 'value' not in _SOURCE_CACHE: _SOURCE_CACHE['value']=_read_configuration_source()
    return _SOURCE_CACHE['value']


def _read_configuration_source():
    skill_dir=Path(__file__).resolve().parent.parent
    installed=(skill_dir/'.glitch-idea-install.json').exists()
    require(not installed or (skill_dir/'config.json').is_file(),'Installed skill config.json is missing; restore its durable store and validator configuration','invalid_config')
    candidates=(skill_dir/'config.json',skill_dir.parent/'config.json')
    path=next((p for p in candidates if p.exists()),None)
    value=decode(read_bytes(path)) if path else {}
    require(isinstance(value,dict),'Configuration must be an object','invalid_config')
    require(not installed or (isinstance(value.get('store_path'),str) and bool(value['store_path'].strip())),'Installed configuration must preserve explicit store_path','invalid_config')
    argv=value.get('plan_validator_argv')
    require(argv is None or (isinstance(argv,list) and 0<len(argv)<=32 and all(isinstance(a,str) and a and '\x00' not in a for a in argv)),'plan_validator_argv must be a fixed list of arguments','invalid_config')
    timeout=value.get('validator_timeout_seconds',30)
    number(timeout,'validator_timeout_seconds',1,120)
    base=path.parent if path else skill_dir.parent
    value=_with_account_ports(value)
    return value,base,skill_dir,installed,argv,timeout


ACCOUNT_PORTS_LIMIT=65536


class PortsError(IdeaError):
    """An account-registry fault. Its message is built here from the registry path and the account name only (both checked
    as clean text first), so launcher verbs may show it; every other error stays reduced to its code there."""
    def __init__(self,message): super().__init__('invalid_config',message)


def _shown(exc):
    """What a launcher-facing verb says: the code, or the registry diagnostic that is safe by construction."""
    return str(exc) if isinstance(exc,PortsError) else exc.code


def _clean_text(value,limit=4096):
    return (type(value) is str and bool(value.strip()) and len(value)<=limit
            and all(32<=ord(c)!=127 and not 0xD800<=ord(c)<=0xDFFF for c in value))


def _account_name():
    """The OS account this process runs as; the registry row key. Tests replace this to act as another account."""
    if os.name!='posix': raise PortsError('account_ports_file is not supported on Windows')
    import pwd
    try: return pwd.getpwuid(os.getuid()).pw_name
    except KeyError: raise PortsError('This account has no name the ports registry can be looked up by') from None


def _account_registry(path):
    """Read and validate the registry once: {account: (browser_port, prototype_port)}; every fault is invalid_config naming the file."""
    try: registry=decode(read_bytes(path,limit=ACCOUNT_PORTS_LIMIT))
    except (IdeaError,OSError) as exc:
        raise PortsError('account_ports_file %s cannot be read: %s'%(path,exc.code if isinstance(exc,IdeaError) else exc.strerror or 'io_error')) from None
    problem=None
    seats={}
    if type(registry) is not dict or type(registry.get('schema')) is not int or registry['schema']!=1: problem='it is not schema 1'
    elif type(registry.get('seats')) is not dict: problem='seats must be an object'
    else:
        used={}
        if not all(_clean_text(account,256) for account in registry['seats']):
            raise PortsError('account_ports_file %s is invalid: an account name is not clean text'%path)
        for account,row in registry['seats'].items():
            if type(row) is not dict or set(row)!={'browser_port','prototype_port'} or not account:
                problem='the row for "%s" is malformed'%account;break
            for key in ('browser_port','prototype_port'):
                port=row[key]
                if type(port) is not int or not 1024<=port<=65535: problem='%s of "%s" must be an integer from 1024 to 65535'%(key,account);break
                if port in used: problem='port %d is used twice ("%s" and "%s")'%(port,used[port],account);break
                used[port]=account
            if problem: break
            seats[account]=(row['browser_port'],row['prototype_port'])
    if problem is not None: raise PortsError('account_ports_file %s is invalid: %s'%(path,problem))
    return seats


def _with_account_ports(value):
    """With account_ports_file set, this account's two ports come from its registry row, as if written in config.json."""
    registry=value.get('account_ports_file')
    if registry is None: return value
    if not (_clean_text(registry) and os.path.isabs(registry)): raise PortsError('account_ports_file must be an absolute path of clean text')
    if os.name!='posix': raise PortsError('account_ports_file is not supported on Windows')
    if 'browser_port' in value or 'prototype_port' in value:
        raise PortsError('account_ports_file and browser_port or prototype_port are two sources of one fact; remove the ports from the configuration')
    account=_account_name()
    if not _clean_text(account,256): raise PortsError('This account has no name the ports registry can be looked up by')
    seats=_account_registry(registry)
    if account not in seats: raise PortsError('account_ports_file %s has no row for account "%s"'%(registry,account))
    return dict(value,browser_port=seats[account][0],prototype_port=seats[account][1])


def _fixed_ports(value):
    # prototype_port and browser_mode stay out of the launch config, whose allow-list refuses them.
    ports={}
    for key in ('browser_port','prototype_port'):
        port=value.get(key)
        require(port is None or (type(port) is int and 1024<=port<=65535),'Invalid '+key.replace('_',' '),'invalid_config')
        ports[key]=port
    # Retired ssh mode: ssh_client and ssh_server_port are ignored and browser_mode "ssh" reads as unset, so a seat that
    # has not been reinstalled still starts.
    mode=value.get('browser_mode')
    if mode=='ssh': mode=None
    require(mode is None or mode in ('link','system','tern'),'Invalid browser mode','invalid_config')
    require(ports['browser_port'] is None or ports['browser_port']!=ports['prototype_port'],
            'browser_port and prototype_port must differ','invalid_config')
    return ports['browser_port'],ports['prototype_port'],mode


def configuration():
    value,base,skill_dir,installed,argv,timeout=_configuration_source()
    # store_path already supports durable storage outside the installed package.
    store_path=value.get('store_path',str(base/'ideas'))
    text(store_path,'store_path',4096)
    resolved=Path(store_path).expanduser()
    if not resolved.is_absolute():
        resolved=base/resolved
    result=dict(store_path=str(resolved.resolve()),plan_validator_argv=argv,validator_timeout_seconds=timeout)
    workspace=default_workspace(value.get('default_workspace'))
    if workspace is not None:
        result['default_workspace']=workspace  # key present only when configured
    return result


LAUNCH_COMMANDS=frozenset(('serve','session-open','browser-open'))
AGENT_COMMANDS=frozenset(('events','respond','fill','asset','session-close'))
PROTOTYPE_COMMANDS=frozenset(('prototype-serve',))
SESSION_COMMANDS=frozenset(('sessions','session-discard'))
DISCARD_WARNING='This session is still open: its browser tab and terminal agent will stop working. Run again with --confirm to discard it.'


def _launcher_requested(argv):
    # Only global --store precedes the verb; do not classify its path as a verb.
    index=0
    while index < len(argv):
        value=argv[index]
        if value=='--store': index+=2; continue
        if value.startswith('--store='): index+=1; continue
        return value in LAUNCH_COMMANDS | AGENT_COMMANDS | PROTOTYPE_COMMANDS | SESSION_COMMANDS
    return False


def _launch_path(value,base=None,*,absolute=False):
    text(value,'launcher path',4096)
    require('\x00' not in value,'Invalid launcher path','invalid_config')
    path=Path(value).expanduser()
    if absolute:
        require(path.is_absolute(),'Launcher path must be absolute','invalid_config')
    elif not path.is_absolute():
        path=(Path.cwd() if base is None else base)/path
    # Inspect the original path, including components before '..', before any
    # lexical normalization or resolve could hide an existing symlink.
    current=Path(path.anchor)
    for part in path.parts[1:]:
        current=current/part
        require(not current.is_symlink(),'Launcher path contains a symlink','runtime_not_private')
    return Path(os.path.abspath(path))


def _private_home():
    if os.name=='posix':
        import pwd
        return Path(pwd.getpwuid(os.getuid()).pw_dir)
    return Path.home()


def _default_runtime_root():
    """Home first; when its chain is not private, the OS runtime dir by itself. Returns (path, fallback or None)."""
    home_default=_private_home()/'.local/state/glitch-idea'
    if os.name!='posix': return home_default,None
    try:
        from idea_runtime import RuntimeError as OwnerError,_open_chain
        probe=home_default
        while not probe.exists() and probe!=probe.parent: probe=probe.parent
        try: os.close(_open_chain(probe,create=False,private_leaf=probe==home_default))
        except OwnerError as exc:
            if exc.code!='runtime_not_private': return home_default,None
        else: return home_default,None
        xdg=os.environ.get('XDG_RUNTIME_DIR')
        if not xdg or not os.path.isabs(xdg): return home_default,None
        info=os.lstat(xdg)
        if not (stat.S_ISDIR(info.st_mode) and info.st_uid==os.getuid() and stat.S_IMODE(info.st_mode)==0o700):
            return home_default,None
        target=Path(xdg)/'glitch-idea'
        return target,{'from':str(home_default),'to':str(target),'reason':'home_not_private'}
    except Exception:
        return home_default,None


def _launcher_paths(args):
    """Store and runtime root exactly as the launcher resolves them (flag, then config, then the default)."""
    value,base,skill_dir,installed,argv,timeout=_configuration_source()
    store_value=args.store if args.store is not None else value.get('store_path',str(base/'ideas'))
    store=_launch_path(store_value,None if args.store is not None else base)
    args.runtime_root_fallback=None
    if args.runtime_root is not None: root_value=args.runtime_root
    elif 'runtime_root' in value: root_value=value['runtime_root']
    else:
        default,args.runtime_root_fallback=_default_runtime_root()
        root_value=str(default)
    runtime=_launch_path(root_value,absolute=True)
    require(runtime!=skill_dir and skill_dir not in runtime.parents and runtime not in skill_dir.parents,
            'Runtime must be outside the skill package','invalid_config')
    return store,runtime,value,installed,argv,timeout


def launcher_configuration(args):
    store,runtime,value,installed,argv,timeout=_launcher_paths(args)
    configured_python=getattr(args,'runtime_python',None)
    if configured_python is None: configured_python=value.get('runtime_python')
    require(not installed or configured_python is not None,
            'Installed launch requires explicit absolute runtime_python; runtime setup is pending','runtime_python_required')
    from idea_launch import source_python
    executable=source_python(configured_python)
    if installed and args.command in {'serve'} | AGENT_COMMANDS | SESSION_COMMANDS:
        # Resolved base executables cannot identify a venv's dependency context.
        require(os.path.abspath(sys.executable)==os.path.abspath(executable),
                'Run with the configured runtime_python','runtime_interpreter_mismatch')
    config=dict(store_path=str(store),plan_validator_argv=argv,validator_timeout_seconds=timeout)
    workspace=default_workspace(value.get('default_workspace'))  # a bad value is a plain config error here too
    if workspace is not None: config['default_workspace']=workspace
    browser_port,_,_=_fixed_ports(value)
    if browser_port is not None: config['browser_port']=browser_port
    return store,runtime,config,executable


def _session_check(args):
    """remove-idea: this seat's saved browser sessions are the launcher's rows; the Store cannot see them.

    Returns idea_id -> sorted binding ids that select it. Reads the bindings without a running service.
    No runtime folder means no sessions. Only this seat's runtime is visible: another seat's session on a
    shared store is not. Runs before a removal (an unreadable runtime refuses early), for the preview, and again after the commit to drop sessions.
    """
    from idea_runtime import Runtime, RuntimeError as RuntimeFailure
    store,runtime,_,_,_,_=_launcher_paths(args)
    def holders(idea_id):
        try: rows=Runtime(store,runtime).list_bindings()
        except RuntimeFailure as exc:
            if exc.code=='owner_unavailable': return []
            raise IdeaError('sessions_unreadable','The saved sessions could not be read, so the idea was not checked for use')
        return sorted(row['binding_id'] for row in rows
                      if row.get('selected_idea_id')==idea_id and re.fullmatch(r'binding_[0-9a-f]{32}',str(row.get('binding_id'))))
    return holders


DROP_NOTE='--confirm removes the idea and drops these saved sessions of this seat (an open tab on one ends); another seat\'s sessions are not visible here and are set aside at that seat\'s next start'


def _session_rows(args,ids):
    """Preview rows: binding id and whether the session is in use (None when no service runs to say)."""
    from idea_runtime import Runtime
    store,runtime,_,_,_,_=_launcher_paths(args)
    live={}
    if ids:
        try:
            for row in _safe_sessions(Runtime(store,runtime).list_sessions(timeout=5)) or []: live[row['binding_id']]=row['in_use']
        except Exception: live={}
    return [dict(binding_id=i,in_use=live.get(i)) for i in ids]


def _drop_session(args,binding_id):
    """The session-discard road when this seat's owner service runs (a live tab is ended cleanly);
    otherwise the binding record is removed directly. The session-recovery receipt stays as history."""
    from idea_runtime import Runtime, RuntimeError as RuntimeFailure
    store,runtime,_,_,_,_=_launcher_paths(args)
    try:
        Runtime(store,runtime).discard_binding(binding_id,confirm=True,timeout=5)
        return
    except RuntimeFailure as exc:
        if exc.code=='binding_not_found': return
        if exc.code!='owner_unavailable': raise
    owner=Runtime(store,runtime)
    owner.acquire_owner()
    try: owner.remove_binding(binding_id)
    except RuntimeFailure as exc:
        if exc.code!='binding_not_found': raise
    finally: owner.close()


def _drop_sessions(args,holders):
    """After the removal committed: re-scan, then drop every session that selects the idea. Never undoes the removal."""
    try: ids=holders(args.idea_id)
    except IdeaError: return dict(sessions_dropped=[],sessions_unreadable=True)
    dropped,kept=[],[]
    for binding_id in ids:
        try: _drop_session(args,binding_id); dropped.append(binding_id)
        except Exception: kept.append(binding_id)
    return dict(sessions_dropped=dropped,**(dict(sessions_not_dropped=kept) if kept else {}))


def _safe_launch_details(details):
    if type(details) is not dict: return {}
    result={}
    for key,prefix in (('binding_id','binding_'),('session_id','session_'),('selected_idea_id','idea_')):
        value=details.get(key)
        if key=='selected_idea_id' and key in details and value is None:
            result[key]=None
        elif type(value) is str and re.fullmatch(prefix+r'[0-9a-f]{32}',value):
            result[key]=value
    if type(details.get('resume_required')) is bool: result['resume_required']=details['resume_required']
    if type(details.get('port')) is int and 1 <= details['port'] <= 65535: result['port']=details['port']
    return result


def _safe_sessions(rows):
    """Fixed, typed rows only: never a credential, token, pairing code or anything the owner did not list."""
    if type(rows) is not list: return None
    result=[]
    for row in rows[:8]:
        if type(row) is not dict: return None
        binding,idea,title=row.get('binding_id'),row.get('selected_idea_id'),row.get('title')
        if not (type(binding) is str and re.fullmatch(r'binding_[0-9a-f]{32}',binding)): return None
        if not (idea is None or (type(idea) is str and re.fullmatch(r'idea_[0-9a-f]{32}',idea))): return None
        if not (title is None or type(title) is str) or type(row.get('finished')) is not bool or type(row.get('in_use')) is not bool: return None
        result.append(dict(binding_id=binding,selected_idea_id=idea,title=None if title is None else title[:80],
                           finished=row['finished'],in_use=row['in_use']))
    return result


def run_launcher(args):
    # Separate boundary: fixed redacted errors; legacy result/error path is intact.
    try:
        from idea_launch import LaunchError, open_browser_session, open_session, reconnect_browser_session, serve
        from idea_native import NativeError, OrcaBinding
        from idea_runtime import RuntimeError
        from idea_bridge import BridgeError
    except Exception:
        return dict(ok=False,error=dict(code='launcher_failed',message='launcher_failed'))
    try:
        if args.command!='serve':
            require(type(args.readiness_timeout) in (int,float) and math.isfinite(args.readiness_timeout)
                    and 0 < args.readiness_timeout <= 5,'Invalid readiness budget','invalid_input')
            require(args.resume is None or (type(args.resume) is str and re.fullmatch(r'binding_[0-9a-f]{32}',args.resume)),
                    'Invalid binding ID','invalid_input')
            require(args.idea_id is None or (type(args.idea_id) is str and re.fullmatch(r'idea_[0-9a-f]{32}',args.idea_id)),
                    'Invalid idea ID','invalid_input')
        prefill=None
        if args.command!='serve':
            name,wpath=getattr(args,'workspace_name',None),getattr(args,'workspace_path',None)
            require((name is None)==(wpath is None),'--workspace-name and --workspace-path must be given together or not at all','usage')
            if name is not None:
                require(args.resume is None and getattr(args,'reconnect',None) is None,
                        'A session workspace only goes with a new session, not --resume or --reconnect','usage')
                prefill=dict(name=name,path=wpath)
        orcabinding=None
        if args.command=='browser-open':
            # Effective mode first: the flag, else the configured browser_mode (validated by _fixed_ports),
            # else pane mode when this process sits in a Tern pane (a default only: the plugin's claim is the proof).
            if args.browser is None: args.browser=_fixed_ports(_configuration_source()[0])[2]
            if args.browser is None:
                import idea_tern
                if idea_tern.default_is_tern(): args.browser='tern'
            require(args.browser is not None,'Browser mode is required: pass --browser or set browser_mode','browser_mode_required')
        reconnect=getattr(args,'reconnect',None)
        if reconnect is not None:
            # Re-pair the recorded Orca page in place; never with a resume, an idea choice or the system browser.
            require(args.browser=='orca' and args.resume is None and args.idea_id is None,
                    'Reconnect re-pairs the recorded Orca tab only','usage')
            require(type(reconnect) is str and re.fullmatch(r'binding_[0-9a-f]{32}',reconnect),'Invalid binding ID','invalid_input')
        if args.command=='browser-open':
            selectors=(args.orca_worktree,args.orca_terminal,args.orca_host)
            require(args.browser=='orca' or not any(value is not None for value in selectors),
                    'Only Orca mode accepts Orca selectors','usage')
            if args.browser=='orca':
                require(args.orca_worktree is not None and args.orca_terminal is not None,
                        'Orca requires originating worktree and terminal','origin_missing')
                orcabinding=OrcaBinding(*selectors)
        store,runtime,config,executable=launcher_configuration(args)
        if args.command=='serve':
            try: serve(store,runtime,config)
            except KeyboardInterrupt: pass  # serve's finally drains owned work.
            return dict(ok=True,code='stopped',**({'runtime_root_fallback':args.runtime_root_fallback} if args.runtime_root_fallback else {}))
        options=dict(binding_id=args.resume,selected_idea_id=args.idea_id,runtime_python=executable,
                     readiness_timeout=args.readiness_timeout)
        if prefill is not None: options['session_workspace']=prefill  # only when given: other calls stay as they were
        # Keep released open_session's five-second mutation timeout; probes remain
        # <=1s within readiness budget. Never retry an ambiguous NEW here.
        if args.command=='session-open': result=open_session(store,runtime,config,**options)
        elif reconnect is not None:
            result=reconnect_browser_session(store,runtime,config,binding_id=reconnect,orcabinding=orcabinding,
                                             runtime_python=executable,readiness_timeout=args.readiness_timeout)
        elif args.browser=='tern':
            import idea_tern
            result=idea_tern.open_tern_session(store,runtime,config,terminal=idea_tern.find_terminal(),**options)
        else: result=open_browser_session(store,runtime,config,mode=args.browser,orcabinding=orcabinding,**options)
        if args.runtime_root_fallback: result=dict(result,runtime_root_fallback=args.runtime_root_fallback)
        return dict(ok=True,**result)
    except (LaunchError,NativeError,RuntimeError,BridgeError,IdeaError) as exc:
        result=dict(ok=False,error=dict(code=exc.code,message=_shown(exc)),
                    **_safe_launch_details(getattr(exc,'details',{})))
        sessions=_safe_sessions(getattr(exc,'sessions',None)) if exc.code=='binding_capacity' else None
        if sessions is not None: result['sessions']=sessions
        return result
    except Exception:
        return dict(ok=False,error=dict(code='launcher_failed',message='launcher_failed'))


def run_sessions(args):
    """Owner-control verbs: list the retained sessions, or discard one. Needs a running service."""
    try:
        from idea_runtime import Runtime, RuntimeError
    except Exception:
        return dict(ok=False,error=dict(code='launcher_failed',message='launcher_failed'))
    try:
        if args.command=='session-discard':
            require(type(args.binding) is str and re.fullmatch(r'binding_[0-9a-f]{32}',args.binding),'Invalid binding ID','invalid_input')
        store,runtime,_,_=launcher_configuration(args)
        client=Runtime(store,runtime)
        if args.command=='sessions':
            rows=_safe_sessions(client.list_sessions(timeout=5))
            require(rows is not None,'Unreadable session list','launcher_failed')
            return dict(ok=True,sessions=rows)
        try:
            value=client.discard_binding(args.binding,confirm=args.confirm,timeout=5)
        except RuntimeError as exc:
            if exc.code!='session_in_use': raise
            return dict(ok=False,error=dict(code='session_in_use',message='session_in_use'),warning=DISCARD_WARNING)
        return dict(ok=True,binding_id=value['binding_id'],was_in_use=value['was_in_use'])
    except (RuntimeError,IdeaError) as exc:
        return dict(ok=False,error=dict(code=exc.code,message=_shown(exc)))
    except Exception:
        return dict(ok=False,error=dict(code='launcher_failed',message='launcher_failed'))


def run_prototype(args):
    """Sealed prototype server on its own loopback port; prints one JSON line when ready."""
    try:
        from idea_prototype import serve_prototype
        from idea_runtime import RuntimeError
    except Exception:
        return dict(ok=False,error=dict(code='launcher_failed',message='launcher_failed'))
    try:
        store,runtime,_,_=launcher_configuration(args)
        _,prototype_port,_=_fixed_ports(_configuration_source()[0])
        extra={} if prototype_port is None else dict(port=prototype_port)
        return serve_prototype(args.session,args.dir,store,runtime,**extra)
    except (RuntimeError,IdeaError) as exc:
        return dict(ok=False,error=dict(code=exc.code,message=_shown(exc)))
    except Exception:
        return dict(ok=False,error=dict(code='launcher_failed',message='launcher_failed'))


def run_agent(args):
    """Native-only thin adapter; fixed client owns transport and secret handling."""
    try:
        from idea_agent_client import AgentClient, AgentClientError
        from idea_runtime import Runtime, RuntimeError
        from idea_bridge import BridgeError, decode_json
        from idea_proposals import CORRELATION, LIMIT
    except Exception:
        return dict(ok=False,error=dict(code='agent_failed',message='agent_failed'))
    try:
        require(type(args.session) is str and re.fullmatch(r'session_[0-9a-f]{32}',args.session),
                'Invalid agent session','invalid_agent_input')
        require(args.generation is None or (type(args.generation) is str and
                re.fullmatch(r'agent_[0-9a-f]{32}',args.generation)),
                'Invalid agent generation','invalid_agent_input')
        payload=None
        if args.command=='events':
            require(type(args.after) is int and 0 <= args.after <= 10**12 and
                    type(args.timeout) in (int,float) and math.isfinite(args.timeout) and 0 <= args.timeout <= 25,
                    'Invalid event wait','invalid_agent_input')
        elif args.command in ('respond','fill'):
            require(type(args.request) is str and
                    re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}',args.request),
                    'Invalid request ID','invalid_agent_input')
            payload=decode_json(read_bytes(args.payload,limit=LIMIT))
            require(type(payload) is dict and set(payload)==CORRELATION | {'proposal' if args.command=='respond' else 'fields'} and
                    payload['request_id']==args.request and payload['session_id']==args.session,
                    'Response correlation mismatch','invalid_agent_input')
        asset=None
        if args.command=='asset':
            from idea_asset_evidence import MAX_FILE
            require(type(args.request) is str and
                    re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}',args.request),
                    'Invalid request ID','invalid_agent_input')
            kinds={'.png':'image/png','.zip':'application/zip'}
            mime=args.type or kinds.get(Path(args.file).suffix.lower())
            require(mime in kinds.values(),'Asset type must be image/png or application/zip','invalid_agent_input')
            asset=dict(idea_id=args.idea,revision=args.revision,request_id=args.request,
                       name=Path(args.file).name,mime=mime,data=read_bytes(args.file,limit=MAX_FILE))
        store,runtime,_,_=launcher_configuration(args)
        # The full 5 s control budget: an owner busy finishing the browser's own write (the page
        # saves each terminal fill at once) is live, and must not read as owner_unavailable.
        client=AgentClient(Runtime(store,runtime),args.session,expected_generation=args.generation,timeout=5)
        if args.command=='events': return client.events(args.after,args.timeout)
        if args.command=='respond': return client.respond(payload)
        if args.command=='fill': return client.fill(payload)
        if args.command=='asset': return client.asset(**asset)
        return client.session_close()
    except (AgentClientError,RuntimeError,BridgeError,IdeaError) as exc:
        result=dict(ok=False,error=dict(code=exc.code,message=_shown(exc)))
        state=getattr(exc,'write_state',None)
        if type(state) is str and state in ('not_applied','committed_uncertain'):
            result['write_state']=state
        return result
    except Exception:
        return dict(ok=False,error=dict(code='agent_failed',message='agent_failed'))


def main(argv=None):
    global _SOURCE_CACHE
    _SOURCE_CACHE={}
    try: return _main(argv)
    finally: _SOURCE_CACHE=None


def _main(argv=None):
    values=sys.argv[1:] if argv is None else list(argv)
    launching=_launcher_requested(values)
    try:
        cli=parser();cli.launcher_errors=launching
        args=cli.parse_args(values)
        if args.command in LAUNCH_COMMANDS: result=run_launcher(args)
        elif args.command in AGENT_COMMANDS: result=run_agent(args)
        elif args.command in SESSION_COMMANDS: result=run_sessions(args)
        elif args.command in PROTOTYPE_COMMANDS: result=run_prototype(args)
        else:
            if args.command=='remove-idea':
                valid=type(args.idea_id) is str and re.fullmatch(r'idea_[0-9a-f]{32}',args.idea_id)
                holders=_session_check(args)
                early=holders(args.idea_id) if valid else []  # unreadable sessions refuse before anything is touched
                result=dict(ok=True,**run(args,configuration()))
                if not args.confirm:
                    if valid:
                        result=dict(result,sessions_to_drop=_session_rows(args,early),**(dict(sessions_note=DROP_NOTE) if early else {}))
                elif valid and result.get('removed'):
                    result=dict(result,**_drop_sessions(args,holders))
            else:
                result=dict(ok=True,**run(args,configuration()))
    except IdeaError as exc:
        result=dict(ok=False,error=dict(code=exc.code,message=_shown(exc) if launching else str(exc)),
                    **({} if launching else exc.details))
    except (OSError,UnicodeError,ValueError,RecursionError) as exc:
        result=dict(ok=False,error=dict(code='launcher_failed' if launching else 'io_error',
                    message='launcher_failed' if launching else str(exc)))
    fallback=result.get('runtime_root_fallback') if launching else None
    if type(fallback) is dict:
        sys.stderr.write('Runtime folder: the home folder is shared on this account, so Glitch idea uses %s for this login.\n'%fallback['to'])
    sys.stdout.buffer.write(encoded(result))
    return 0 if result['ok'] else 1


if __name__=='__main__':
    sys.exit(main())
