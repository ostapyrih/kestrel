import unittest
from types import SimpleNamespace

from kestrel_bridge import codec, errors
from kestrel_bridge.codec import LXMF_TYPE_CMD
from kestrel_bridge.lxmf_commands import (FIELD_CUSTOM_DATA, FIELD_CUSTOM_TYPE, CommandRejected,
                                          validate_command)
from tests.helpers import OTHER_KEY, PEER, PHONE_ID, PHONE_KEY, make_registry, raw_config

NOW = 1_800_000_000.0
SRC = b"\x01" * 16


def make_msg(payload=None, *, validated=True, ftype=LXMF_TYPE_CMD, raw=None):
    payload = {"v": 2, "cmd_id": "cmd-lxmf-0001", "ts": NOW, "path": "/send_lxmf",
               "args": {"to": PEER, "text": "hi"}} if payload is None else payload
    data = raw if raw is not None else codec.pack(payload)
    return SimpleNamespace(signature_validated=validated, source_hash=SRC,
                           fields={FIELD_CUSTOM_TYPE: ftype, FIELD_CUSTOM_DATA: data})


class ValidateCommandTest(unittest.TestCase):
    def setUp(self):
        cfg = raw_config()
        self.state, self.registry = make_registry(cfg)
        self.limits = cfg.limits

    def tearDown(self):
        self.state.close()

    def validate(self, msg, key=PHONE_KEY, now=NOW):
        return validate_command(msg, registry=self.registry, recall=lambda h: bytes.fromhex(key) if key else None,
                                state=self.state, now=now, limits=self.limits)

    def rejected(self, msg, **kw):
        with self.assertRaises(CommandRejected) as c:
            self.validate(msg, **kw)
        return c.exception

    def test_accepts_valid_command(self):
        phone, payload = self.validate(make_msg())
        self.assertEqual(phone, PHONE_ID)
        self.assertEqual(payload["path"], "/send_lxmf")

    def test_rejects_unvalidated_signature(self):
        e = self.rejected(make_msg(validated=False))
        self.assertEqual(e.code, errors.UNAUTHORIZED)
        self.assertIsNone(e.device_id)      # unauthenticated senders get no answer
        self.assertTrue(self.state.journal_reserve(PHONE_ID, "cmd-lxmf-0001", 1))   # cmd_id not consumed

    def test_signature_flag_must_be_exactly_true(self):
        self.assertEqual(self.rejected(make_msg(validated=1)).code, errors.UNAUTHORIZED)
        self.assertEqual(self.rejected(make_msg(validated=None)).code, errors.UNAUTHORIZED)

    def test_rejects_unknown_key(self):
        e = self.rejected(make_msg(), key=OTHER_KEY)
        self.assertEqual(e.code, errors.UNAUTHORIZED)
        self.assertIsNone(e.device_id)

    def test_rejects_unknown_identity(self):
        self.assertEqual(self.rejected(make_msg(), key=None).code, errors.UNAUTHORIZED)

    def test_rejects_replayed_cmd_id(self):
        self.validate(make_msg())
        e = self.rejected(make_msg())
        self.assertEqual(e.code, errors.REPLAY)
        self.assertEqual(e.device_id, PHONE_ID)   # authenticated: may be told about it

    def test_rejects_ts_out_of_window(self):
        window = self.limits.lxmf_ts_window
        self.assertEqual(self.rejected(make_msg(), now=NOW + window + 1).code, errors.TS_OUT_OF_WINDOW)
        self.assertEqual(self.rejected(make_msg(), now=NOW - window - 1).code, errors.TS_OUT_OF_WINDOW)
        self.validate(make_msg(), now=NOW + window - 1)     # inside the window
        # an out-of-window command must not consume its cmd_id
        p = {"v": 2, "cmd_id": "cmd-lxmf-0002", "ts": NOW, "path": "/hello", "args": {}}
        self.rejected(make_msg(p), now=NOW + window + 5)
        self.validate(make_msg(p))

    def test_malformed_payloads(self):
        base = {"v": 2, "cmd_id": "cmd-lxmf-0003", "ts": NOW, "path": "/hello"}
        cases = [
            (make_msg(raw=b"\xc1garbage"), errors.BAD_REQUEST),
            (make_msg(raw=codec.pack([1, 2])), errors.BAD_REQUEST),
            (make_msg({"v": 2, "ts": NOW, "path": "/hello"}), errors.BAD_REQUEST),     # no cmd_id
            (make_msg({k: v for k, v in base.items() if k != "ts"}), errors.BAD_REQUEST),
            (make_msg({**base, "v": 1}), errors.PROTOCOL_MISMATCH),
            (make_msg({**base, "v": 3}), errors.PROTOCOL_MISMATCH),
            (make_msg({**base, "path": "/devices/revoke"}), errors.UNSUPPORTED_TRANSPORT),   # Link only
            (make_msg({**base, "path": "/vault/put"}), errors.UNSUPPORTED_TRANSPORT),
            (make_msg({**base, "path": "/etc/passwd"}), errors.UNKNOWN_PATH),
            (make_msg({**base, "args": 5}), errors.BAD_REQUEST),
            (make_msg(ftype=b"other"), "not_command"),
        ]
        for msg, code in cases:
            self.assertEqual(self.rejected(msg).code, code)

    def test_oversize_payload(self):
        big = codec.pack({"v": 2, "cmd_id": "cmd-lxmf-0009", "ts": NOW, "path": "/hello", "args": {"x": "y" * 70000}})
        self.assertEqual(self.rejected(make_msg(raw=big)).code, errors.TOO_LARGE)


if __name__ == "__main__":
    unittest.main()
