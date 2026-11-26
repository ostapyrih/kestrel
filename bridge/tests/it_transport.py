"""Integration helper: a Reticulum transport node standing in for MeshChatX's RNS.

A TCPServerInterface on 127.0.0.1; the bridge (standalone mode) and the phone B both connect to it as
TCP clients. The process can be killed and started again with the same config dir to simulate a MeshChatX
restart/recreate.

usage: python -m tests.it_transport <config_dir> <tcp_port>
"""
import os
import sys
import time

import RNS


def main() -> None:
    cfgdir, tcp_port = sys.argv[1:3]
    os.makedirs(cfgdir, exist_ok=True)
    with open(os.path.join(cfgdir, "config"), "w") as f:
        f.write(f"""[reticulum]
  enable_transport = Yes
  share_instance = No

[interfaces]
  [[Test TCP Server]]
    type = TCPServerInterface
    enabled = yes
    listen_ip = 127.0.0.1
    listen_port = {tcp_port}
""")
    RNS.Reticulum(configdir=cfgdir, loglevel=int(os.environ.get("IT_RNS_LOG", RNS.LOG_WARNING)))
    print("TRANSPORT_READY", flush=True)
    while True:
        time.sleep(1)


if __name__ == "__main__":
    main()
