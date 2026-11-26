"""Per-device cursors, read state and origin device (protocol v2)."""
import asyncio

from kestrel_bridge import errors
from kestrel_bridge.service import Ctx
from tests.fake_meshchatx import conversation
from tests.helpers import PEER, PHONE_ID, RealDevice
from tests.test_service import ServiceBase

A, B, C = "aa" * 16, "bb" * 16, "cc" * 16


class MultiDeviceBase(ServiceBase):
    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.d1 = Ctx(device_id=PHONE_ID, transport="link")
        self.other = RealDevice()
        self.registry.add(self.other.public_key, "tablet", "ios", [], PHONE_ID)
        self.d2 = Ctx(device_id=self.other.device_id, transport="link")
        self.published.clear()

    async def sync(self, ctx, cursor, **kw):
        r = await self.call("/sync_chats", {"cursor": cursor, **kw}, ctx)
        self.assertTrue(r["ok"], r)
        return r["result"]

    async def drain(self, ctx, cursor, limit=100):
        """What a client does: call /sync_chats until more=false. Returns (peer -> entry, final cursor)."""
        seen, pages = {}, 0
        while True:
            r = await self.sync(ctx, cursor, limit=limit)
            for c in r["lxmf"]:
                seen.setdefault(c["peer"], []).append(c)
            cursor, pages = r["cursor"], pages + 1
            if not r["more"]:
                return seen, cursor, pages

    def touch(self, peer, ts, unread=False):
        self.clock.advance(2)          # the conversation index is refreshed at most once per second
        for c in self.fake.conversations:
            if c["destination_hash"] == peer:
                c["latest_message_created_at"], c["is_unread"] = ts, unread
                return
        self.fake.conversations.append(conversation(peer, peer[:2], ts, unread))


class CursorTest(MultiDeviceBase):
    async def test_cursors_are_independent_per_device(self):
        self.fake.conversations += [conversation(A, "A", "t1"), conversation(B, "B", "t1")]
        s1, c1, _ = await self.drain(self.d1, 0)
        self.assertEqual(set(s1), {A, B})
        # device 1 is up to date; device 2 never synced and still gets everything
        s2, c2, _ = await self.drain(self.d2, 0)
        self.assertEqual(set(s2), {A, B})
        self.assertEqual(c1, c2)
        # a change shows up for both, each only once
        self.touch(A, "t2")
        n1, c1b, _ = await self.drain(self.d1, c1)
        self.assertEqual(list(n1), [A])
        self.assertGreater(c1b, c1)
        n1again, _, _ = await self.drain(self.d1, c1b)
        self.assertEqual(n1again, {})
        n2, _, _ = await self.drain(self.d2, c2)           # d2's cursor was untouched by d1's syncs
        self.assertEqual(list(n2), [A])

    async def test_device_offline_for_weeks_catches_up_without_duplicates_or_gaps(self):
        peers = [f"{i:02x}" * 16 for i in range(1, 8)]
        for p in peers:
            self.fake.conversations.append(conversation(p, p[:2], "t0"))
        _, offline_cursor, _ = await self.drain(self.d2, 0)         # d2 syncs once, then goes offline
        _, live_cursor, _ = await self.drain(self.d1, 0)
        # weeks pass; d1 stays online and sees every change as it happens
        live_seen = []
        for week in range(1, 5):
            self.clock.advance(7 * 86400)
            changed = peers[week:week + 3]
            for p in changed:
                self.touch(p, f"week{week}")
            seen, live_cursor, _ = await self.drain(self.d1, live_cursor)
            live_seen.append(set(seen))
            self.assertEqual(set(seen), set(changed))
        # housekeeping ran meanwhile: it must not forget conversations or break old cursors
        self.state.journal_prune(self.cfg.limits.journal_ttl)
        self.state.pending_prune(self.cfg.limits.journal_ttl)
        # d2 comes back with its month-old cursor, small pages
        caught, new_cursor, pages = await self.drain(self.d2, offline_cursor, limit=2)
        union = set().union(*live_seen)
        self.assertEqual(set(caught), union)                         # nothing missed
        for peer, entries in caught.items():
            self.assertEqual(len(entries), 1, peer)                  # nothing delivered twice
        self.assertGreater(pages, 1)
        self.assertEqual(new_cursor, live_cursor)                    # both devices converge on the same cursor
        # and the latest state of each conversation is what d2 sees
        self.assertTrue(all(e[0]["last_ts"].startswith("week") for e in caught.values()))
        quiet, _, _ = await self.drain(self.d2, new_cursor)
        self.assertEqual(quiet, {})

    async def test_cursor_is_monotonic_and_a_page_cursor_never_skips(self):
        for i in range(1, 6):
            self.fake.conversations.append(conversation(f"{i:02x}" * 16, "x", "t0"))
        cursor, collected, cursors = 0, [], []
        while True:
            r = await self.sync(self.d1, cursor, limit=2)
            collected += [c["peer"] for c in r["lxmf"]]
            self.assertGreaterEqual(r["cursor"], cursor)
            cursors.append(r["cursor"])
            cursor = r["cursor"]
            if not r["more"]:
                break
            # new activity between two pages: the paging cursor must not jump over the pending rows
            if len(cursors) == 1:
                self.touch("ee" * 16, "new")
        self.assertEqual(cursors, sorted(cursors))
        self.assertEqual(len(collected), len(set(collected)))              # nothing twice
        self.assertEqual(set(collected), {f"{i:02x}" * 16 for i in range(1, 6)} | {"ee" * 16})

    async def test_state_id_mismatch_forces_a_full_snapshot(self):
        self.fake.conversations += [conversation(A, "A", "t1"), conversation(B, "B", "t1")]
        r = await self.sync(self.d1, 0)
        sid, cursor = r["state_id"], r["cursor"]
        self.assertEqual(len(sid), 16)
        r = await self.sync(self.d1, cursor, state_id=sid)
        self.assertEqual((r["reset"], r["lxmf"]), (False, []))
        r = await self.sync(self.d1, cursor, state_id="0" * 16)     # the bridge state was recreated
        self.assertTrue(r["reset"])
        self.assertEqual(len(r["lxmf"]), 2)
        bad = await self.call("/sync_chats", {"state_id": 5}, self.d1)
        self.assertEqual(bad["error"]["code"], errors.BAD_REQUEST)

    async def test_a_cursor_newer_than_the_server_resets(self):
        self.fake.conversations.append(conversation(A, "A", "t1"))
        r = await self.sync(self.d1, 10_000)
        self.assertTrue(r["reset"])
        self.assertEqual(len(r["lxmf"]), 1)

    async def test_hello_carries_state_id_and_cursor(self):
        r = (await self.call("/hello", {"protocol_version": 2}, self.d1))["result"]
        self.assertEqual(r["state_id"], self.state.state_id())
        self.assertEqual(r["cursor"], self.state.cursor())
        self.assertEqual(r["device"]["device_id"], PHONE_ID)
        self.assertEqual((r["min_protocol_version"], r["max_protocol_version"]), (2, 2))
        for cap in ("devices", "pairing", "vault", "read_state", "origin_device"):
            self.assertIn(cap, r["capabilities"])

    async def test_message_cursors_per_device_do_not_miss_or_repeat(self):
        for i in range(25):
            self.fake.add_message(PEER, f"m{i}")
        mine, other = 0, 0                                    # each device keeps its own last id
        got1, got2 = [], []
        # d1 reads in pages of 10, d2 in pages of 7, interleaved, while new messages arrive
        for step in range(10):
            r = (await self.call("/get_messages", {"peer": PEER, "limit": 10, "after_id": mine}, self.d1))["result"]
            got1 += [m["id"] for m in r["messages"]]
            mine = r["messages"][-1]["id"] if r["messages"] else mine
            r = (await self.call("/get_messages", {"peer": PEER, "limit": 7, "after_id": other}, self.d2))["result"]
            got2 += [m["id"] for m in r["messages"]]
            other = r["messages"][-1]["id"] if r["messages"] else other
            if step == 1:
                for i in range(5):
                    self.fake.add_message(PEER, f"late{i}")
        self.assertEqual(got1, list(range(1, 31)))
        self.assertEqual(got2, list(range(1, 31)))


class ReadStateTest(MultiDeviceBase):
    async def test_mark_read_propagates_to_all_devices(self):
        self.fake.conversations.append(conversation(A, "A", "t1", unread=True))
        s, cursor, _ = await self.drain(self.d2, 0)
        self.assertTrue(s[A][0]["unread"])
        r = await self.call("/mark_read", {"peer": A}, self.d1)
        self.assertTrue(r["ok"], r)
        self.assertEqual(self.fake.marked_read, [A])
        ev = [e for e in self.published if e["event"] == "read_state"]
        self.assertEqual(len(ev), 1)
        self.assertEqual((ev[0]["data"]["peer"], ev[0]["data"]["unread"], ev[0]["data"]["by_device"]),
                         (A, False, PHONE_ID))
        # the device that was not connected sees it through the cursor
        s, _, _ = await self.drain(self.d2, cursor)
        self.assertFalse(s[A][0]["unread"])
        # marking an already read conversation is harmless and pushes nothing new
        await self.call("/mark_read", {"peer": A}, self.d2)
        self.assertEqual(len([e for e in self.published if e["event"] == "read_state"]), 1)

    async def test_read_in_the_meshchatx_web_ui_is_noticed(self):
        self.fake.conversations.append(conversation(A, "A", "t1", unread=True))
        await self.sync(self.d1, 0)
        self.fake.conversations[0]["is_unread"] = False         # somebody read it in the MeshChatX web UI
        self.clock.advance(5)
        await self.svc.refresh()
        ev = [e for e in self.published if e["event"] == "read_state"]
        self.assertEqual((ev[0]["data"]["peer"], ev[0]["data"]["by_device"]), (A, None))

    async def test_incoming_message_then_quick_read_in_the_web_ui(self):
        self.fake.conversations.append(conversation(A, "A", "t1"))
        await self.sync(self.d1, 0)
        m = {"hash": "h1", "source_hash": A, "state": "delivered", "content": "yo", "timestamp": 1.0, "fields": {}}
        await self.svc.on_event({"type": "lxmf.delivery", "remote_identity_name": "A", "lxmf_message": m})
        self.fake.conversations[0]["is_unread"] = False         # read before the next conversation refresh
        self.clock.advance(5)
        await self.svc.refresh()
        self.assertEqual([e["event"] for e in self.published if e["event"] == "read_state"], ["read_state"])

    async def test_validation_link_only_and_rate_limit(self):
        self.assertEqual((await self.call("/mark_read", {"peer": "zz"}, self.d1))["error"]["code"], errors.BAD_REQUEST)
        self.cfg.limits.mark_read_rate_per_minute = 1
        self.assertTrue((await self.call("/mark_read", {"peer": A}, self.d1))["ok"])
        r = await self.call("/mark_read", {"peer": A}, self.d1)
        self.assertEqual(r["error"]["code"], errors.RATE_LIMITED)
        r = await self.call("/mark_read", {"peer": A}, self.d2)       # the budget is per device
        self.assertTrue(r["ok"])
        # /mark_read also works over LXMF (small, idempotent)
        lx = Ctx(device_id=PHONE_ID, transport="lxmf", journal_reserved=True)
        self.clock.advance(61)
        self.assertTrue((await self.call("/mark_read", {"peer": A}, lx))["ok"])

    async def test_state_change_of_an_outgoing_message_resurfaces_the_conversation(self):
        self.fake.conversations.append(conversation(A, "A", "t1"))
        _, cursor, _ = await self.drain(self.d2, 0)
        self.state.pending_put("cmd-st-0001", PHONE_ID, "h9", A, "outbound")
        await self.svc.on_event({"type": "lxmf_message_state_updated",
                                 "lxmf_message": {"hash": "h9", "state": "delivered"}})
        seen, _, _ = await self.drain(self.d2, cursor)
        self.assertEqual(list(seen), [A])        # the client refetches the tail of A to refresh states
        # a state change of a message the bridge does not know still resurfaces its conversation
        await self.svc.on_event({"type": "lxmf_message_state_updated",
                                 "lxmf_message": {"hash": "h10", "state": "failed", "destination_hash": A.upper()}})
        seen, _, _ = await self.drain(self.d2, cursor)
        self.assertEqual(list(seen), [A])


class OriginDeviceTest(MultiDeviceBase):
    async def test_sent_messages_record_origin_device_and_cmd_id(self):
        r1 = await self.call("/send_lxmf", {"cmd_id": "cmd-org-0001", "to": PEER, "text": "from d1"}, self.d1)
        r2 = await self.call("/send_lxmf", {"cmd_id": "cmd-org-0002", "to": PEER, "text": "from d2"}, self.d2)
        self.fake.add_message(PEER, "typed in the MeshChatX web UI", incoming=False)
        self.fake.add_message(PEER, "hello from the peer", incoming=True)
        # every device sees the same attribution
        for ctx in (self.d1, self.d2):
            msgs = (await self.call("/get_messages", {"peer": PEER, "limit": 10}, ctx))["result"]["messages"]
            self.assertEqual([(m["text"], m["origin_device"], m["cmd_id"]) for m in msgs], [
                ("from d1", PHONE_ID, "cmd-org-0001"),
                ("from d2", self.other.device_id, "cmd-org-0002"),
                ("typed in the MeshChatX web UI", None, None),        # null = MeshChatX itself
                ("hello from the peer", None, None)])                  # incoming: null
        self.assertEqual(r1["result"]["lxmf_hash"], msgs[0]["hash"])
        self.assertEqual(r2["result"]["lxmf_hash"], msgs[1]["hash"])
        # also in the before_id / after_id modes
        r = (await self.call("/get_messages", {"peer": PEER, "after_id": 1, "limit": 10}, self.d2))["result"]
        self.assertEqual(r["messages"][0]["origin_device"], self.other.device_id)

    async def test_origin_survives_pruning_of_the_pending_table(self):
        r = await self.call("/send_lxmf", {"cmd_id": "cmd-org-0003", "to": PEER, "text": "x"}, self.d2)
        self.clock.advance(30 * 86400)
        self.state.pending_prune(0)
        self.state.journal_prune(0)
        m = (await self.call("/get_messages", {"peer": PEER}, self.d1))["result"]["messages"][0]
        self.assertEqual((m["hash"], m["origin_device"]), (r["result"]["lxmf_hash"], self.other.device_id))

    async def test_push_events_carry_the_origin(self):
        r = await self.call("/send_lxmf", {"cmd_id": "cmd-org-0004", "to": PEER, "text": "pushed"}, self.d2)
        h = r["result"]["lxmf_hash"]
        created = {"type": "lxmf_message_created", "lxmf_message": {
            "hash": h, "destination_hash": PEER, "state": "outbound", "content": "pushed", "timestamp": 1.0,
            "fields": {}}}
        await self.svc.on_event(created)
        ev = self.published[-1]["data"]
        self.assertEqual((ev["incoming"], ev["origin_device"], ev["cmd_id"]), (False, self.other.device_id, "cmd-org-0004"))
        # a message typed in the MeshChatX UI: no origin
        await self.svc.on_event({"type": "lxmf_message_created", "lxmf_message": {
            **created["lxmf_message"], "hash": "ee" * 16}})
        ev = self.published[-1]["data"]
        self.assertEqual((ev["origin_device"], ev["cmd_id"]), (None, None))
        await self.svc.on_event({"type": "lxmf.delivery", "remote_identity_name": "P", "lxmf_message": {
            "hash": "dd" * 16, "source_hash": PEER, "state": "delivered", "content": "in", "timestamp": 1.0,
            "fields": {}}})
        ev = self.published[-1]["data"]
        self.assertEqual((ev["incoming"], ev["origin_device"]), (True, None))

    async def test_created_event_that_races_the_send_response_still_gets_its_origin(self):
        gate = asyncio.get_running_loop().create_future()
        self.svc._inflight[PEER].append(gate)                       # a send to PEER is in flight
        ev = {"type": "lxmf_message_created", "lxmf_message": {
            "hash": "ab" * 16, "destination_hash": PEER, "state": "outbound", "content": "x", "timestamp": 1.0,
            "fields": {}}}
        task = asyncio.create_task(self.svc.on_event(ev))
        await asyncio.sleep(0.05)
        self.assertEqual(self.published, [])                        # waiting for the send to finish
        self.state.outbound_put("ab" * 16, self.other.device_id, "cmd-org-0005", PEER)
        gate.set_result(None)
        await task
        self.assertEqual(self.published[-1]["data"]["origin_device"], self.other.device_id)

    async def test_stalled_send_does_not_block_events_forever(self):
        gate = asyncio.get_running_loop().create_future()
        self.svc._inflight[PEER].append(gate)
        ev = {"type": "lxmf_message_created", "lxmf_message": {
            "hash": "ab" * 16, "destination_hash": PEER, "state": "outbound", "content": "x", "timestamp": 1.0,
            "fields": {}}}
        await asyncio.wait_for(self.svc.on_event(ev), 5)
        self.assertEqual(self.published[-1]["data"]["origin_device"], None)
        gate.cancel()
