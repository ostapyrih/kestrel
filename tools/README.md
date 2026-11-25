# tools

Python scripts using the reference `rns` / `lxmf` packages (pinned in `requirements.txt`).

- `gen_vectors.py` - deterministic golden vectors -> `packages/kestrel_rns/test/vectors/*.json`
  (CI regenerates them and fails on any diff).
- `it/rns_peer.py` - scriptable reference Reticulum peer (TCPServerInterface on loopback, JSON-lines
  stdin/stdout protocol) used by the Dart `integration` tests; see the module docstring.
- `verify_dart_output.py` - verifies random Dart-generated signatures / ciphertexts / announces /
  LXMF messages with the Python reference (driven by the Dart `python`-tagged test).

```
python -m venv tools/.venv
tools/.venv/bin/pip install -r tools/requirements.txt   # Windows: tools\.venv\Scripts\pip
tools/.venv/bin/python tools/gen_vectors.py
```
