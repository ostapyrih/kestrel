"""Shared harness for the device-group spike: spawn local RNS agents, talk to them, collect events.

Everything runs on 127.0.0.1 with throwaway config dirs; nothing touches the public network.
"""
import json, os, shutil, socket, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT = os.path.join(HERE, "agent.py")


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


class Agent:
    def __init__(self, net, name, role="node", **kw):
        self.net, self.name, self.events, self._cid, self._rets = net, name, [], 0, {}
        self.dir = os.path.join(net.root, name)
        cmd = [sys.executable, "-u", AGENT, "--dir", self.dir, "--role", role, "--name", name]
        for k, v in kw.items():
            if v is None: continue
            for x in (v if isinstance(v, list) else [v]):
                cmd += ["--" + k.replace("_", "-"), str(x)]
        self.log = open(os.path.join(net.root, name + ".stdout.log"), "w")
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  text=True, bufsize=1)
        self.cv = threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()
        if not self.wait(lambda e: e["ev"] == "ready", 60):
            raise RuntimeError("agent %s did not start; see %s" % (name, self.log.name))

    def _read(self):
        for line in self.p.stdout:
            self.log.write(line); self.log.flush()
            if line.startswith("@@"):
                e = json.loads(line[2:])
                with self.cv:
                    if e["ev"] == "ret": self._rets[e["cid"]] = e
                    else: self.events.append(e)
                    self.cv.notify_all()

    def call(self, cmd, timeout=30, **kw):
        self._cid += 1; cid = self._cid
        self.p.stdin.write(json.dumps(dict(cmd=cmd, cid=cid, **kw)) + "\n"); self.p.stdin.flush()
        end = time.time() + timeout
        with self.cv:
            while cid not in self._rets:
                if time.time() > end: raise TimeoutError("%s.%s" % (self.name, cmd))
                self.cv.wait(0.2)
            e = self._rets.pop(cid)
        if "err" in e: raise RuntimeError("%s.%s: %s\n%s" % (self.name, cmd, e["err"], e.get("tb")))
        return e["r"]

    def wait(self, pred, timeout=30, since=0):
        end = time.time() + timeout
        with self.cv:
            while True:
                for e in self.events:
                    if e["t"] >= since and pred(e): return e
                if time.time() > end: return None
                self.cv.wait(0.2)

    def evs(self, ev, since=0, **match):
        return [e for e in list(self.events) if e["ev"] == ev and e["t"] >= since
                and all(e.get(k) == v for k, v in match.items())]

    def kill(self): self.p.kill()

    def stop(self):
        try: self.p.kill()
        except Exception: pass


class Net:
    """Temp dir + a transport node on 127.0.0.1. Use as a context manager."""
    def __init__(self, serve_mode="full", n_ports=1, keep=False):
        self.root = tempfile.mkdtemp(prefix="kestrel-spike-"); keep = keep or bool(os.environ.get("SPIKE_KEEP"))
        self.keep, self.agents = keep, []
        self.ports = [free_port() for _ in range(n_ports)]
        self.port = self.ports[0]
        self.transport = self.add("transport", role="transport", serve=self.ports, serve_mode=serve_mode)

    def key(self, name):
        import RNS
        path = os.path.join(self.root, name + ".key")
        if not os.path.exists(path): RNS.Identity().to_file(path)
        return path

    def add(self, name, role="node", **kw):
        if role in ("node", "pn") and "connect" not in kw: kw["connect"] = self.port
        a = Agent(self, name, role, **kw); self.agents.append(a); return a

    def __enter__(self): return self

    def __exit__(self, *a):
        for x in self.agents: x.stop()
        time.sleep(0.5)
        if not self.keep: shutil.rmtree(self.root, ignore_errors=True)


def dest_of(net, keyname):
    """lxmf.delivery destination hash + public key (hex) of an identity file, no RNS instance needed."""
    import RNS
    ident = RNS.Identity.from_file(net.key(keyname))
    return (RNS.Destination.hash_from_name_and_identity("lxmf.delivery", ident).hex(),
            ident.get_public_key().hex())


def hdr(s): print("\n=== " + s + " ===", flush=True)
def row(*a): print("  " + " | ".join(str(x) for x in a), flush=True)


def load_ratchet_file(path, ident):
    """Read + verify a .ratchets file (msgpack {signature, ratchets(packed list of 32-byte X25519 private keys)})."""
    import RNS.vendor.umsgpack as mp
    d = mp.unpackb(open(path, "rb").read())
    if not ident.validate(d["signature"], d["ratchets"]): raise ValueError("bad ratchet file signature")
    return mp.unpackb(d["ratchets"])


def write_ratchet_file(path, ident, ratchets):
    import RNS.vendor.umsgpack as mp
    packed = mp.packb(list(ratchets))
    tmp = path + ".tmp"
    with open(tmp, "wb") as f: f.write(mp.packb({"signature": ident.sign(packed), "ratchets": packed}))
    os.replace(tmp, path)


def merge_ratchet_files(paths, keyfile, out):
    """Union of ratchet lists (first path has priority for ordering), re-signed with identity A. Returns merged length."""
    import RNS
    ident = RNS.Identity.from_file(keyfile)
    merged = []
    for p in paths:
        for r in load_ratchet_file(p, ident):
            if r not in merged: merged.append(r)
    write_ratchet_file(out, ident, merged[:512])
    return len(merged[:512])
