import asyncio
import tempfile
import unittest
from pathlib import Path
from uuid import uuid4
from unittest.mock import patch

import aiohttp
from aiohttp import web

from usage_service.listener import BoundedSite
from usage_service.protocol import Authority, ServiceError, encode
from usage_service.security import Security, ensure_certificate, secret, tls_context
from usage_service.server import Companion, EXPORT_FIELDS


def snapshot():
    return {"version":3,"publisher":"synthetic","as_of_ms":1234,"readings":[
        {"id":"synthetic-agent","provider":"openai","provider_label":"OpenAI","source_label":"Synthetic source",
         "usage_source":"headless","windows":[{"key":"session","pool":"all","used":75,"remaining":25,"observed_at_ms":1200}]}]}


class ServerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name)/"source"
        self.companion=Companion(self.root,{"build":"synthetic","protocol":1,"schema":1,"lock_digest":"0"*64,"source_digest":"1"*64})
        self.local_runner=web.AppRunner(self.companion.local_app(),access_log=None)
        await self.local_runner.setup()
        local=BoundedSite(self.local_runner,"127.0.0.1",0)
        await local.start()
        self.local=local.name
        self.companion.expected_host=self.local.removeprefix("http://")
        self.peer_runner=web.AppRunner(self.companion.peer_app(),access_log=None)
        await self.peer_runner.setup()
        peer=BoundedSite(self.peer_runner,"127.0.0.1",0,ssl_context=tls_context(self.root))
        await peer.start()
        self.peer=peer.name
        self.fingerprint=aiohttp.Fingerprint(bytes.fromhex(ensure_certificate(self.root)["fingerprint"]))
        self.client=aiohttp.ClientSession(trust_env=False)

    async def asyncTearDown(self):
        await self.client.close()
        await self.peer_runner.cleanup()
        await self.local_runner.cleanup()
        await self.companion.close()
        self.temp.cleanup()

    async def rpc(self,operation,payload=None,headers=None):
        supplied={"Authorization":"Bearer "+self.companion.security.local_token}
        if headers is not None:
            supplied=headers
        async with self.client.post(self.local+"/rpc",json={"operation":operation,"payload":payload or {}},headers=supplied) as response:
            return response.status,await response.json()

    def pair_credential(self):
        invitation=self.companion.security.offer(self.peer,self.companion.store.identity()["group_id"])
        member=str(uuid4())
        return member,self.companion.security.consume(invitation["secret"],member)["credential"]

    def owner(self):
        identity=self.companion.store.identity()
        return Authority(identity["device_id"],identity["group_id"],role="owner",local=True)

    async def test_every_owner_operation_requires_private_authority(self):
        operations=("register_client","diagnostics","configure","pair_offer","pair_accept","unpair","shutdown",
                    "display","setup_state","usage_refresh","usage_status","usage_preferences","usage_results","usage_publish",
                    "capacity","binding_candidates")
        for operation in operations:
            with self.subTest(operation=operation):
                status,body=await self.rpc(operation,headers={})
                self.assertIn(status,(401,429))
                self.assertFalse(body["ok"])
        self.assertFalse(self.companion.stop_event.is_set())
        self.assertEqual(self.companion.store.local_records(),[])
        self.assertEqual(self.companion.store.peers(),[])

    async def test_wrong_stale_cross_root_and_peer_tokens_fail_locally(self):
        old=self.companion.security.local_token
        self.companion.security=Security(self.companion.store,self.root)
        _,peer_token=self.pair_credential()
        other=Companion(Path(self.temp.name)/"other",self.companion.stamp)
        try:
            for token in (secret(),old,peer_token,other.security.local_token):
                status,body=await self.rpc("setup_state",headers={"Authorization":"Bearer "+token})
                self.assertEqual(status,401)
                self.assertNotIn(token,str(body))
            status,body=await self.rpc("diagnostics")
            self.assertEqual(status,200)
            self.assertEqual(body["device_id"],self.companion.store.identity()["device_id"])
        finally:
            await other.close()

    async def test_browser_origin_wrong_host_and_duplicate_headers_fail(self):
        authorization="Bearer "+self.companion.security.local_token
        for headers in (
            {"Authorization":authorization,"Origin":"https://attacker.invalid"},
            {"Authorization":authorization,"Origin":""},
            {"Authorization":authorization,"Host":"attacker.invalid"},
            [("Authorization",authorization),("Authorization",authorization)],
        ):
            async with self.client.get(self.local+"/health",headers=headers) as response:
                self.assertEqual(response.status,401)
        async with self.client.get(self.local+"/health",headers={"Authorization":authorization}) as response:
            self.assertEqual(response.status,200)
            self.assertEqual((await response.json())["protocol"],1)

    async def test_peer_listener_has_no_admin_route_or_local_token_access(self):
        _,token=self.pair_credential()
        for path in ("/rpc","/health","/display","/setup_state","/configure","/uploads","/collection/claim",
                     "/collection/release","/collection/profiles"):
            async with self.client.post(self.peer+path,json={"operation":"shutdown","payload":{}},ssl=self.fingerprint,
                                        headers={"Authorization":"Bearer "+token}) as response:
                self.assertEqual(response.status,404)
        async with self.client.get(self.peer+"/aggregate",ssl=self.fingerprint,
                                   headers={"Authorization":"Bearer "+self.companion.security.local_token}) as response:
            self.assertEqual(response.status,401)
        self.assertFalse(self.companion.stop_event.is_set())

    async def test_export_and_metadata_have_separate_explicit_consent(self):
        group=self.companion.store.identity()["group_id"]
        status,_=await self.rpc("configure",{"changes":{"export_enabled":True}})
        self.assertEqual(status,403)
        status,_=await self.rpc("configure",{"changes":{"metadata_enabled":True},"consent":{"export":True,"recipient_group":group,"fields":EXPORT_FIELDS}})
        self.assertEqual(status,403)
        status,_=await self.rpc("configure",{"changes":{"metadata_enabled":True},"consent":{"metadata":True}})
        self.assertEqual(status,200)
        self.assertFalse(self.companion.store.settings()["export_enabled"])
        status,_=await self.rpc("configure",{"changes":{"export_enabled":True},"consent":{"export":True,"recipient_group":group,"fields":EXPORT_FIELDS}})
        self.assertEqual(status,200)
        self.assertTrue(self.companion.store.settings()["metadata_enabled"])

    async def test_view_only_peer_cannot_receive_owner_readings_without_export(self):
        self.companion.store.local_publish("source",snapshot())
        _,token=self.pair_credential()
        headers={"Authorization":"Bearer "+token}
        async with self.client.get(self.peer+"/aggregate",ssl=self.fingerprint,headers=headers) as response:
            value=await response.json()
        self.assertEqual(value["records"],[])
        self.assertEqual(value["inventory"],[])
        self.companion.store.configure({"export_enabled":True})
        async with self.client.get(self.peer+"/aggregate",ssl=self.fingerprint,headers=headers) as response:
            value=await response.json()
        self.assertEqual(value["records"][0]["snapshot"]["readings"][0]["windows"][0]["used"],75)
        self.assertNotIn("cached_snapshots",value)

    async def test_removed_operations_are_not_found(self):
        for operation in ("publish","aggregate","inventory","claim_collection","release_collection","source_state",
                          "collection_profiles","source_cache","profile_inventory","profile_metadata"):
            with self.subTest(operation=operation):
                status,body=await self.rpc(operation)
                self.assertEqual(status,404)
                self.assertFalse(body["ok"])
        for key in ("source_policy","source_binding","source_cache","profile_action","aliases","host_bindings"):
            with self.subTest(key=key):
                self.assertEqual((await self.rpc("configure",{key:{}}))[0],400)
        self.assertEqual((await self.rpc("register_client",{"client_id":"setup:x","kind":"setup"}))[0],400)
        self.assertEqual((await self.rpc("register_client",{"client_id":"window:x","kind":"window","ttl_seconds":91}))[0],400)
        status,body=await self.rpc("register_client",{"client_id":"window:x","kind":"window"})
        self.assertEqual((status,body["duration_ms"]),(200,90_000))

    async def test_failed_local_tokens_never_lock_out_the_owner(self):
        for _ in range(32):
            self.assertEqual((await self.rpc("diagnostics",headers={"Authorization":"Bearer "+secret()}))[0],401)
        self.assertEqual((await self.rpc("diagnostics"))[0],200)

    async def test_own_records_from_hub_are_ignored_in_favor_of_local_snapshots(self):
        store=self.companion.store
        identity=store.identity()
        publication={"protocol":1,"observer_device_id":identity["device_id"],"subject_source_id":identity["device_id"],
            "publisher":identity["device_id"]+":window","epoch":str(uuid4()),"sequence":1,
            "generation":identity["generation"],"profile_generation":0,"kind":"passive","snapshot":snapshot()}
        publication["snapshot"]["publisher"]=publication["publisher"]
        source={"source_id":identity["device_id"],"status":"stale","last_received_ms":1500,"clock_skew":False,
                "inventory":[{"publisher":publication["publisher"],"observer_device_id":identity["device_id"],
                              "last_received_ms":1500,"reading":publication["snapshot"]["readings"][0]}]}
        store.replace_remote(str(uuid4()),"r1",[publication],[source])
        aggregate=store.aggregate(self.owner())
        self.assertEqual((aggregate["records"],aggregate["inventory"]),([],[]))

    async def test_connection_limit_includes_idle_sockets_and_releases_capacity(self):
        runner=web.AppRunner(self.companion.local_app(),access_log=None)
        await runner.setup()
        site=BoundedSite(runner,"127.0.0.1",0,max_connections=1)
        await site.start()
        self.companion.expected_host="127.0.0.1:"+str(site.port)
        _,writer=await asyncio.open_connection("127.0.0.1",site.port)
        headers={"Authorization":"Bearer "+self.companion.security.local_token}
        try:
            with self.assertRaises(TimeoutError):
                async with self.client.get(site.name+"/health",headers=headers,timeout=aiohttp.ClientTimeout(total=0.2)):
                    self.fail("a second request bypassed the accepted-socket bound")
            writer.close()
            await writer.wait_closed()
            async with self.client.get(site.name+"/health",headers=headers,timeout=aiohttp.ClientTimeout(total=5)) as response:
                self.assertEqual(response.status,200)
        finally:
            writer.close()
            await runner.cleanup()

    async def test_hub_bind_failure_keeps_local_rpc_and_setup_can_return_to_standalone(self):
        root=Path(self.temp.name)/"hub"
        hub=Companion(root,self.companion.stamp)
        # TEST-NET-1 is never assigned to a local interface: the saved LAN address is gone.
        hub.store.configure({"role":"hub","sharing_bind":"192.0.2.1","sharing_port":49_999})
        try:
            with patch("usage_service.runtime.publish_ready") as ready:
                await hub.start()
            ready.assert_called_once()
            diagnostics=hub.diagnostics()
            self.assertEqual(diagnostics["peer_listener_error"],"address_unavailable")
            self.assertIsNone(diagnostics["peer_endpoint"])
            self.assertEqual(diagnostics["role"],"hub")
            async with self.client.get("http://"+hub.expected_host+"/health",
                                       headers={"Authorization":"Bearer "+hub.security.local_token}) as response:
                self.assertEqual(response.status,200)
            # Unrelated settings need no bind consent while the saved listener is down.
            result=await hub.configure({"changes":{"metadata_enabled":True},"consent":{"metadata":True}})
            self.assertTrue(result["settings"]["metadata_enabled"])
            self.assertEqual(hub.diagnostics()["peer_listener_error"],"address_unavailable")
            # Retrying Share on the same unusable address reports the bind problem, not internal_error.
            share={"changes":{"role":"hub","sharing_bind":"192.0.2.1","sharing_port":49_999},
                   "consent":{"bind":True,"bind_address":"192.0.2.1","bind_port":49_999}}
            with self.assertRaises(ServiceError) as caught:
                await hub.configure(share)
            self.assertEqual((caught.exception.code,caught.exception.status),("address_unavailable",409))
            self.assertIsNone(hub.peer_runner)
            result=await hub.configure({"changes":{"role":"standalone"}})
            self.assertEqual(result["settings"]["role"],"standalone")
            self.assertIsNone(hub.diagnostics()["peer_listener_error"])
        finally:
            await hub.close()

    async def test_setup_state_has_revocation_targets_but_no_private_authority(self):
        member,credential=self.pair_credential()
        peer_hash=self.companion.store.peers()[0]["credential_hash"]
        hub_id=str(uuid4())
        hub_credential=secret()
        self.companion.store.set_local_state("hub_connection",{
            "device_id":hub_id,"endpoint":"https://127.0.0.1:49443","fingerprint":"a"*64,
            "credential":hub_credential,"group_id":hub_id})
        status,state=await self.rpc("setup_state")
        self.assertEqual(status,200)
        self.assertEqual(state["peers"],[{"device_id":member,"revoked":False}])
        self.assertEqual(state["hub"]["device_id"],hub_id)
        self.assertEqual(state["certificate_fingerprint"],ensure_certificate(self.root)["fingerprint"])
        public=encode(state)
        for sentinel in (credential,peer_hash,hub_credential,self.companion.security.local_token):
            self.assertNotIn(sentinel.encode(),public)
        self.companion.store.revoke_peer(member)
        self.assertTrue((await self.rpc("setup_state"))[1]["peers"][0]["revoked"])
        self.assertEqual(set(state),{"ok","source","settings","peers","hub","certificate_fingerprint"})

    async def test_role_change_requires_explicit_disconnect_and_revocation(self):
        member,_=self.pair_credential()
        self.companion.store.configure({"role":"hub"})
        self.assertEqual((await self.rpc("configure",{"changes":{"role":"standalone"}}))[0],409)
        self.assertEqual(self.companion.store.settings()["role"],"hub")
        await self.rpc("unpair",{"device_id":member})
        self.assertEqual((await self.rpc("configure",{"changes":{"role":"standalone"}}))[0],200)
        replacement_group=str(uuid4())
        self.assertEqual((await self.rpc("configure",{"changes":{"group_id":replacement_group}}))[0],200)
        self.assertEqual(self.companion.store.identity()["group_id"],replacement_group)
        self.assertEqual((await self.rpc("configure",{"changes":{"role":"member"}}))[0],409)
        self.companion.store.configure({"role":"member"})
        self.companion.store.set_local_state("hub_connection",{
            "device_id":str(uuid4()),"endpoint":"https://127.0.0.1:49443","fingerprint":"b"*64,
            "credential":secret(),"group_id":str(uuid4())})
        self.assertEqual((await self.rpc("configure",{"changes":{"role":"hub"}}))[0],409)
        with patch.object(self.companion.sync,"_request",side_effect=ServiceError("source_unreachable",503)):
            status,result=await self.rpc("unpair")
        self.assertEqual(status,200)
        self.assertFalse(result["remote_revoked"])
        self.assertIsNone(self.companion.store.local_state("hub_connection"))
        self.assertEqual(self.companion.store.settings()["role"],"standalone")

    async def test_display_normalizes_legacy_usage_source_values(self):
        legacy=snapshot()
        legacy["readings"][0]["usage_source"]="native-headless"
        self.companion.store.local_publish("host",legacy)
        status,page=await self.rpc("display")
        self.assertEqual(status,200)
        self.assertIn('"usage_source":"headless"',"".join(part["data"] for part in page["parts"]))
        self.assertNotIn("native-headless",str(page))


if __name__=="__main__":
    unittest.main()
