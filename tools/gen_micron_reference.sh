#!/usr/bin/env sh
# Regenerates app/test/fixtures/micron/*.ref.json with NomadNet's MicronParser.
# Needs: python3 with `pip install urwid rns` and a NomadNet checkout:
#   git clone https://github.com/markqvist/NomadNet /tmp/NomadNet
set -eu
NN="${1:-/tmp/NomadNet}"
cd "$(dirname "$0")/.."
for f in app/test/fixtures/micron/*.mu; do
  python3 tools/micron_reference.py "$NN" "$f" "${f%.mu}.ref.json"
done
