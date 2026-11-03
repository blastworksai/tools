"""Bounded socket acceptance for aiohttp's public BaseSite extension point.

A semaphore is acquired before accept, including sockets still negotiating TLS.
The HTTP middleware separately bounds in-flight requests. No reverse proxy,
process, extra listener or network dependency is introduced.
"""
from __future__ import annotations

import asyncio
import ipaddress
import os
import socket
from contextlib import suppress

from aiohttp import web


class _Connection(asyncio.Protocol):
    def __init__(self,inner,closed):
        self.inner,self.closed=inner,closed

    def connection_made(self,transport):
        self.inner.connection_made(transport)

    def data_received(self,data):
        self.inner.data_received(data)

    def eof_received(self):
        return self.inner.eof_received()

    def pause_writing(self):
        self.inner.pause_writing()

    def resume_writing(self):
        self.inner.resume_writing()

    def connection_lost(self,exc):
        try:
            self.inner.connection_lost(exc)
        finally:
            if not self.closed.done():
                self.closed.set_result(None)


class BoundedSite(web.BaseSite):
    def __init__(self,runner,host,port,*,ssl_context=None,max_connections=32,backlog=32):
        super().__init__(runner,ssl_context=ssl_context,backlog=backlog)
        self.host,self.port=host,port
        self._slots=asyncio.Semaphore(max_connections)
        self._socket=None
        self._accept_task=None
        self._pending=set()
        self._connections=set()

    @property
    def name(self):
        host="["+self.host+"]" if ":" in self.host else self.host
        return ("https" if self._ssl_context else "http")+"://"+host+":"+str(self.port)

    async def start(self):
        await super().start()
        address=ipaddress.ip_address(self.host)
        self._socket=socket.socket(socket.AF_INET6 if address.version==6 else socket.AF_INET,socket.SOCK_STREAM)
        try:
            if os.name=="nt":
                self._socket.setsockopt(socket.SOL_SOCKET,socket.SO_EXCLUSIVEADDRUSE,1)
            else:
                self._socket.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
            self._socket.setblocking(False)
            self._socket.bind((self.host,self.port))
            self._socket.listen(self._backlog)
            self.port=self._socket.getsockname()[1]
            self._accept_task=asyncio.create_task(self._accept())
        except BaseException:
            self._socket.close()
            await super().stop()
            raise

    async def _accept(self):
        loop=asyncio.get_running_loop()
        while True:
            await self._slots.acquire()
            try:
                accepted,_=await loop.sock_accept(self._socket)
            except BaseException:
                self._slots.release()
                raise
            task=asyncio.create_task(self._connection(accepted))
            self._connections.add(task)
            self._pending.add(task)
            task.add_done_callback(self._connections.discard)
            task.add_done_callback(self._pending.discard)

    async def _connection(self,accepted):
        transport=None
        try:
            loop=asyncio.get_running_loop()
            closed=loop.create_future()
            options={"ssl":self._ssl_context,"ssl_handshake_timeout":5} if self._ssl_context else {}
            transport,_=await loop.connect_accepted_socket(
                lambda:_Connection(self._runner.server(),closed),accepted,**options)
            self._pending.discard(asyncio.current_task())
            await asyncio.wait_for(closed,timeout=30)
        except (OSError,TimeoutError,ConnectionError):
            # Network failures carry no diagnostic response/body into logs.
            return
        finally:
            if transport is not None:
                transport.close()
            else:
                accepted.close()
            self._slots.release()

    async def stop(self):
        if self._accept_task:
            self._accept_task.cancel()
            with suppress(asyncio.CancelledError):
                await self._accept_task
        if self._socket:
            self._socket.close()
        pending=list(self._pending)
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.gather(*pending,return_exceptions=True)
        # AppRunner now drains active aiohttp handlers and closes their transports.
        await super().stop()
