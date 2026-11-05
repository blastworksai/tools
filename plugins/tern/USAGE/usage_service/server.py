"""Separate owner-local control and pinned peer sync listeners.

Only private local RPC admits display, source publication and setup. Headless
acquisition resolves accounts from SPAWN; peers can request
refresh/status/preferences but cannot submit source commands or selectors.
Display pages contain validated snapshots, not raw acquisition output or a
second account reducer.
"""
from __future__ import annotations

import asyncio
import errno
import ipaddress
import logging
import signal
import time
from pathlib import Path

from aiohttp import web

from .listener import BoundedSite

from .protocol import Authority, CLIENT_LEASE_SECONDS, MAX_BODY, ServiceError, decode, encode, identifier, integer, text
from .capacity import Capacity
from .display import Display
from .refresh import Refresh, validate_preferences
from .security import Security, bearer, ensure_certificate, tls_context, validate_invitation
from .store import Store
from .sync import PeerSync

# These are the projected fields that setup must disclose before export consent.
EXPORT_FIELDS = ["provider", "principal/account identity", "organization/workspace/tenant scope",
                 "account label", "subscription", "quota windows", "reset/observation times", "source/agent label"]
MAX_CONCURRENT = 16
AUTHORITY = web.RequestKey("authority", Authority)


def _object(value):
    if not isinstance(value,dict):
        raise ServiceError("invalid_request")
    return value


def _response(value=None, status=200):
    value={} if value is None else value
    body=encode({"ok":True,**_object(value)})
    if len(body)>MAX_BODY:
        raise ServiceError("capacity",413)
    return web.Response(body=body,status=status,content_type="application/json",headers={"Cache-Control":"no-store"})


def _receipt(result):
    publication=result["publication"]
    return _response({"accepted":True,"idempotent":result["idempotent"],
        "publisher":publication["publisher"],"sequence":publication["sequence"]})


async def _json(request):
    if request.content_type != "application/json":
        raise ServiceError("invalid_request",415)
    raw=await request.read()
    return _object(decode(raw))


def _headers(request):
    for name in ("Host","Authorization","Origin"):
        if len(request.headers.getall(name,[]))>1:
            raise ServiceError("unauthorized",401)
    if "Origin" in request.headers:
        raise ServiceError("unauthorized",401)


def _bind_error(exc):
    if isinstance(exc,ServiceError):
        return exc.code
    return {errno.EADDRINUSE:"address_in_use",errno.EADDRNOTAVAIL:"address_unavailable"}.get(exc.errno,"bind_failed")


class Companion:
    def __init__(self,root:Path,stamp:dict):
        self.root,self.stamp=Path(root),stamp
        self.store=Store(self.root)
        self.security=Security(self.store,self.root)
        self.sync=PeerSync(self.store,self.security)
        self.refresh=Refresh(self.store,self.root)
        self.capacity=Capacity(self.store,configuration=lambda:self.refresh.configuration()[2])
        self.display=Display(self.store)
        self.stop_event=asyncio.Event()
        self.expected_host=""
        self.local_runner=None
        self.peer_runner=None
        self.peer_endpoint=None
        self.peer_binding=None
        self.peer_listener_error=None
        self.certificate_fingerprint=None
        self.active_requests=0
        self.last_error=None
        self.started=time.monotonic()

    def middleware(self,local):
        @web.middleware
        async def boundary(request,handler):
            admitted=False
            try:
                if self.stop_event.is_set():
                    raise ServiceError("companion_unavailable",503)
                if self.active_requests>=MAX_CONCURRENT:
                    raise ServiceError("capacity",429)
                self.active_requests+=1
                admitted=True
                _headers(request)
                if local:
                    authority=self.security.authenticate_local(request.headers.get("Host",""),None,
                        request.headers.get("Authorization"),self.expected_host)
                elif request.path=="/pair" and request.method=="POST":
                    authority=None
                else:
                    authority=self.security.authenticate(bearer(request.headers.get("Authorization")),remote=request.remote or "unknown")
                if authority is not None:
                    request[AUTHORITY]=authority
                async with asyncio.timeout(20):
                    return await handler(request)
            except ServiceError as exc:
                self.last_error=exc.code
                return web.Response(body=encode(exc.public()),status=exc.status,content_type="application/json",headers={"Cache-Control":"no-store"})
            except web.HTTPException as exc:
                code="snapshot_too_large" if exc.status==413 else "not_found" if exc.status==404 else "invalid_request"
                error=ServiceError(code,exc.status)
                return web.Response(body=encode(error.public()),status=exc.status,content_type="application/json")
            except (TimeoutError,ConnectionError):
                error=ServiceError("source_unreachable",503)
                self.last_error=error.code
                return web.Response(body=encode(error.public()),status=error.status,content_type="application/json")
            except Exception:
                # A real error boundary, not a fake success or replacement reading.
                self.last_error="internal_error"
                error=ServiceError("internal_error",500)
                return web.Response(body=encode(error.public()),status=500,content_type="application/json")
            finally:
                if admitted:
                    self.active_requests-=1
        return boundary

    def local_app(self):
        app=web.Application(client_max_size=MAX_BODY,middlewares=[self.middleware(True)])
        app.router.add_get("/health",self.health)
        app.router.add_post("/rpc",self.rpc)
        return app

    def peer_app(self):
        app=web.Application(client_max_size=MAX_BODY,middlewares=[self.middleware(False)])
        app.router.add_post("/pair",self.pair)
        app.router.add_post("/pair/revoke",self.revoke_self)
        app.router.add_post("/publish",self.peer_publish)
        app.router.add_get("/aggregate",self.peer_aggregate)
        app.router.add_post("/policy",self.peer_policy)
        app.router.add_post("/usage/{operation}",self.peer_usage)
        return app

    async def health(self,request):
        return _response({**self.stamp,"device_id":self.store.identity()["device_id"]})

    async def rpc(self,request):
        body=await _json(request)
        operation=body.get("operation")
        payload=_object(body.get("payload",{}))
        authority=request[AUTHORITY]
        if operation=="register_client":
            client_id=text(payload.get("client_id"),256)
            kind=payload.get("kind")
            if kind not in ("host","window"):
                raise ServiceError("invalid_request")
            result=self.store.register_client(client_id,kind,payload.get("ttl_seconds",CLIENT_LEASE_SECONDS))
            return _response({"registered":True,"duration_ms":result["duration_ms"]})
        if operation in {"usage_refresh","usage_status","usage_preferences"}:
            return _response(await self.usage_operation(operation,payload))
        if operation=="usage_results":
            if payload:
                raise ServiceError("invalid_request")
            return _response(self.refresh.results())
        if operation=="usage_publish":
            return _response(self.refresh.publish(payload))
        if operation=="display":
            return _response(self.display.page(authority,payload))
        if operation=="capacity":
            return _response(self.capacity.request(authority,payload))
        if operation=="binding_candidates":
            if payload:
                raise ServiceError("invalid_request")
            return _response(self.refresh.binding_candidates())
        if operation=="setup_state":
            if payload:
                raise ServiceError("invalid_request")
            return _response(self.setup_state())
        if operation=="diagnostics":
            return _response(self.diagnostics())
        if operation=="configure":
            return _response(await self.configure(payload))
        if operation=="pair_offer":
            if self.peer_endpoint is None or self.store.settings()["role"]!="hub" or not self.store.settings()["export_enabled"]:
                raise ServiceError("setup_required",409)
            invitation=self.security.offer(self.peer_endpoint,self.store.identity()["group_id"])
            return _response({"invitation":invitation})
        if operation=="pair_accept":
            if self.store.settings()["role"]!="standalone" or any(not peer["revoked"] for peer in self.store.peers()):
                raise ServiceError("conflict",409)
            invite=validate_invitation(payload.get("invitation"))
            consent=_object(payload.get("consent"))
            confirmation=_object(consent.get("pair_confirmation"))
            if confirmation.get("device_id")!=invite["device_id"] or confirmation.get("fingerprint")!=invite["fingerprint"] or consent.get("recipient_group")!=invite["group_id"]:
                raise ServiceError("forbidden",403)
            if consent.get("export") is True:
                self.export_consent(consent,invite["group_id"])
            result=await self.sync.accept(invite)
            self.store.configure({"export_enabled":consent.get("export") is True})
            if self.peer_runner is not None:
                await self.peer_runner.cleanup()
            self.peer_runner,self.peer_endpoint,self.peer_binding,self.peer_listener_error=None,None,None,None
            return _response(result)
        if operation=="unpair":
            device=payload.get("device_id")
            if device is None or self.store.settings()["role"]=="member":
                return _response(await self.sync.unpair())
            else:
                self.store.revoke_peer(identifier(device))
            return _response({"unpaired":True,"notice":"Already received data cannot be recalled from other installations."})
        if operation=="shutdown":
            asyncio.get_running_loop().call_soon(self.stop_event.set)
            return _response({"stopping":True})
        raise ServiceError("not_found",404)

    async def usage_operation(self,operation,payload,*,peer=False):
        if operation not in {"usage_refresh","usage_status","usage_preferences"}:
            raise ServiceError("not_found",404)
        if operation=="usage_preferences":
            validate_preferences(payload)
        elif payload:
            raise ServiceError("invalid_request")
        if self.store.settings()["role"]=="member":
            if peer:
                raise ServiceError("forbidden",403)
            return await self.sync.usage_operation(operation,payload)
        if operation=="usage_preferences":
            return self.refresh.preferences(payload)
        return self.refresh.request() if operation=="usage_refresh" else self.refresh.status()

    async def peer_usage(self,request):
        if self.store.settings()["role"]!="hub" or not self.store.settings()["export_enabled"]:
            raise ServiceError("forbidden",403)
        # Existing pinned peer authentication is the sole authorization boundary.
        return _response(await self.usage_operation(request.match_info["operation"],await _json(request),peer=True))

    def export_consent(self,consent,group):
        if consent.get("export") is not True or consent.get("recipient_group")!=group or consent.get("fields")!=EXPORT_FIELDS:
            raise ServiceError("forbidden",403)

    def source(self):
        identity=self.store.identity()
        return {key:identity[key] for key in ("device_id","generation","profile_generation")} | {"label":"Tern source"}

    def setup_state(self):
        connection=self.store.local_state("hub_connection")
        if self.certificate_fingerprint is None:
            self.certificate_fingerprint=ensure_certificate(self.root)["fingerprint"]
        return {"source":self.source(),"settings":self.store.settings(),
                "peers":[{"device_id":peer["device_id"],"revoked":bool(peer["revoked"])} for peer in self.store.peers()],
                "hub":{key:connection[key] for key in ("device_id","endpoint","fingerprint")} if connection else None,
                "certificate_fingerprint":self.certificate_fingerprint}

    async def configure(self,payload):
        if set(payload)-{"changes","consent","binding_action"}:
            raise ServiceError("invalid_request")
        changes=_object(payload.get("changes",{}))
        consent=_object(payload.get("consent",{}))
        if "binding_action" in payload:
            # Account bindings live in companion state, never in settings.
            if changes:
                raise ServiceError("invalid_request")
            return self.refresh.binding_action(payload["binding_action"],consent)
        current=self.store.settings()
        desired={**current,**changes}
        if desired["role"]!=current["role"]:
            if (self.store.local_state("hub_connection") or desired["role"]=="member"
                    or (desired["role"]=="standalone" and any(not peer["revoked"] for peer in self.store.peers()))):
                raise ServiceError("conflict",409)
        if "group_id" in changes and changes["group_id"]!=current["group_id"] and any(not peer["revoked"] for peer in self.store.peers()):
            raise ServiceError("conflict",409)
        if changes.get("export_enabled") is True:
            self.export_consent(consent,desired["group_id"])
        if changes.get("metadata_enabled") is True and consent.get("metadata") is not True:
            raise ServiceError("forbidden",403)
        if changes.get("capacity_enabled") is True and consent.get("capacity") is not True:
            raise ServiceError("forbidden",403)
        binding=(desired.get("sharing_bind"),desired.get("sharing_port")) if desired.get("role")=="hub" else None
        old_binding=self.peer_binding
        # Only sharing changes (re)bind; a hub whose saved listener failed at start
        # can still change unrelated settings without bind consent.
        rebind=binding!=old_binding and bool({"role","sharing_bind","sharing_port"}&changes.keys())
        if binding is not None and rebind:
            address,port=binding
            try:
                parsed=ipaddress.ip_address(address)
                if parsed.is_unspecified or parsed.is_multicast:
                    raise ValueError()
                integer(port,1024,65535)
            except (ValueError,TypeError):
                raise ServiceError("invalid_request") from None
            if consent.get("bind") is not True or consent.get("bind_address")!=address or consent.get("bind_port")!=port:
                raise ServiceError("forbidden",403)
        prepared=None
        if binding is not None and rebind:
            try:
                prepared=await self.prepare_peer_listener(*binding)
            except OSError as exc:
                raise ServiceError(_bind_error(exc),409) from None
        try:
            with self.store.transaction():
                configured=self.store.configure(changes)
                self.store.set_local_state("setup_consent",{
                    "export":configured["export_enabled"],"recipient_group":configured["group_id"],
                    "fields":EXPORT_FIELDS if configured["export_enabled"] else [],
                    "metadata":configured["metadata_enabled"],"capacity":configured["capacity_enabled"]})
        except BaseException:
            if prepared is not None:
                await prepared[0].cleanup()
            raise
        if rebind:
            previous=self.peer_runner
            if prepared:
                self.peer_runner,self.peer_endpoint=prepared
                self.peer_binding=binding
            else:
                self.peer_runner,self.peer_endpoint,self.peer_binding=None,None,None
            if previous:
                await previous.cleanup()
        if rebind or binding is None:
            self.peer_listener_error=None
        return {"settings":configured,"export_fields":EXPORT_FIELDS,"peer_endpoint":self.peer_endpoint,"source":self.source()}

    async def pair(self,request):
        payload=await _json(request)
        return _response(self.security.consume(payload.get("secret"),payload.get("device_id"),remote=request.remote or "unknown"))

    async def revoke_self(self,request):
        await _json(request)
        self.store.revoke_peer(request[AUTHORITY].device_id)
        return _response({"unpaired":True})

    async def peer_publish(self,request):
        return _receipt(self.store.publish(request[AUTHORITY],await _json(request)))

    async def peer_aggregate(self,request):
        return _response(self.store.aggregate(request[AUTHORITY],request.query.get("cursor")))

    async def peer_policy(self,request):
        result=self.store.set_source_policy(request[AUTHORITY],await _json(request))
        return _response({key:result[key] for key in ("source_id","generation","profile_generation")})

    def diagnostics(self):
        identity=self.store.identity()
        return {**self.stamp,"device_id":identity["device_id"],"generation":identity["generation"],
            "profile_generation":identity["profile_generation"],"group_id":identity["group_id"],
            "role":self.store.settings()["role"],"peer_endpoint":self.peer_endpoint,
            "peer_listener_error":self.peer_listener_error,
            "export_enabled":self.store.settings()["export_enabled"],"metadata_enabled":self.store.settings()["metadata_enabled"],
            "export_fields":EXPORT_FIELDS,"storage":self.store.diagnostics(),"sync":self.sync.diagnostics(),"last_error":self.last_error}

    async def prepare_peer_listener(self,address,port):
        runner=web.AppRunner(self.peer_app(),access_log=None,keepalive_timeout=10,shutdown_timeout=5)
        await runner.setup()
        try:
            site=BoundedSite(runner,address,port,ssl_context=tls_context(self.root))
            await site.start()
        except BaseException:
            await runner.cleanup()
            raise
        host="["+address+"]" if ":" in address else address
        return runner,"https://"+host+":"+str(port)

    async def start(self):
        from .runtime import publish_ready
        # Parser/access logging must not serialize untrusted paths or request bodies.
        for name in ("aiohttp.access","aiohttp.server","aiohttp.client"):
            logger=logging.getLogger(name)
            logger.handlers=[logging.NullHandler()]
            logger.propagate=False
        self.local_runner=web.AppRunner(self.local_app(),access_log=None,keepalive_timeout=10,shutdown_timeout=5)
        await self.local_runner.setup()
        site=BoundedSite(self.local_runner,"127.0.0.1",0)
        await site.start()
        self.expected_host="127.0.0.1:"+str(site.port)
        settings=self.store.settings()
        if settings["role"]=="hub":
            binding=(settings["sharing_bind"],settings["sharing_port"])
            try:
                self.peer_runner,self.peer_endpoint=await self.prepare_peer_listener(*binding)
            except (OSError,ServiceError) as exc:
                # The saved LAN address may be gone or the port taken. Local RPC keeps
                # working so Setup can rebind or return to standalone.
                self.peer_listener_error=_bind_error(exc)
            else:
                self.peer_binding=binding
        await self.sync.start()
        await self.refresh.start()
        publish_ready(self.root,"http://"+self.expected_host,self.store.identity()["device_id"],self.stamp)

    async def close(self):
        self.stop_event.set()
        await self.refresh.close()
        await self.sync.close()
        if self.peer_runner:
            await self.peer_runner.cleanup()
        if self.local_runner:
            await self.local_runner.cleanup()
        self.store.close()


async def serve(root:Path,stamp:dict):
    companion=Companion(root,stamp)
    loop=asyncio.get_running_loop()
    signals=[]
    for signum in (signal.SIGTERM,signal.SIGINT):
        try:
            loop.add_signal_handler(signum,companion.stop_event.set)
            signals.append(signum)
        except (NotImplementedError,RuntimeError):
            # Windows/non-main-thread embedding retains its own signal owner.
            break
    try:
        await companion.start()
        while not companion.stop_event.is_set():
            try:
                await asyncio.wait_for(companion.stop_event.wait(),timeout=5)
            except TimeoutError:
                companion.store.expire_clients()
                if time.monotonic()-companion.started>=90 and not companion.store.has_live_clients():
                    companion.stop_event.set()
    finally:
        await companion.close()
        for signum in signals:
            loop.remove_signal_handler(signum)
