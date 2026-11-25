"""Integration helper: an rnsd-like shared instance with a TCPServerInterface on 127.0.0.1.

usage: python -m tests.it_shared_instance <config_dir> <data_port> <control_port> <tcp_port> <rpc_key_hex>
"""
import os
import sys
import time

import RNS


def main() -> None:
    cfgdir, data_port, ctl_port, tcp_port, rpc_key = sys.argv[1:6]
    os.makedirs(cfgdir, exist_ok=True)
    with open(os.path.join(cfgdir, "config"), "w") as f:
        f.write(f"""[reticulum]
  enable_transport = Yes
  share_instance = Yes
  shared_instance_type = tcp
  shared_instance_port = {data_port}
  instance_control_port = {ctl_port}
  rpc_key = {rpc_key}

[interfaces]
  [[Test TCP Server]]
    type = TCPServerInterface
    enabled = yes
    listen_ip = 127.0.0.1
    listen_port = {tcp_port}
""")
    RNS.Reticulum(configdir=cfgdir, loglevel=int(os.environ.get("IT_RNS_LOG", RNS.LOG_WARNING)))
    print("SHARED_READY", flush=True)
    while True:
        time.sleep(1)


if __name__ == "__main__":
    main()
