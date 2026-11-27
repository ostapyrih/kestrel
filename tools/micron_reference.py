#!/usr/bin/env python3
"""Reference Micron parse using NomadNet's own MicronParser.py.

Usage: micron_reference.py <nomadnet-checkout> <page.mu> [out.json]

Loads ``nomadnet/ui/textui/MicronParser.py`` from a NomadNet checkout
(https://github.com/markqvist/NomadNet) with the UI-only dependencies stubbed
and dumps, for every output row, the list of text parts with their resolved
fg / bg / bold / underline / italic. Colours are the raw Micron values (3-hex,
``gNN`` or 6-hex) so they can be compared 1:1 with Kestrel's parser.

Needs ``urwid`` and ``RNS`` importable (``pip install urwid rns``).
"""
import importlib.util
import json
import sys
import types
from pathlib import Path


def load(nn_root: Path):
    for name in ("nomadnet", "nomadnet.ui", "nomadnet.ui.textui"):
        m = types.ModuleType(name)
        m.__path__ = []
        sys.modules[name] = m
    # nomadnet.util is plain Python: load it from the checkout.
    spec = importlib.util.spec_from_file_location(
        "nomadnet.util", nn_root / "nomadnet" / "util.py")
    util = importlib.util.module_from_spec(spec)
    sys.modules["nomadnet.util"] = util
    spec.loader.exec_module(util)
    stub = types.ModuleType("nomadnet.ui.textui.ReadlineEdit")
    stub.ReadlineEdit = type("ReadlineEdit", (), {})
    sys.modules["nomadnet.ui.textui.ReadlineEdit"] = stub
    # Optional image support and the markdown helper are not needed.
    for n, attr in (("RNS.Utilities.rngit", None),):
        pass
    try:
        import RNS.Utilities.rngit.util  # noqa: F401
    except Exception:
        for n in ("RNS.Utilities.rngit", "RNS.Utilities.rngit.util"):
            sys.modules[n] = types.ModuleType(n)
        sys.modules["RNS.Utilities.rngit.util"].MarkdownToMicron = None
    spec = importlib.util.spec_from_file_location(
        "nomadnet.ui.textui.MicronParser",
        nn_root / "nomadnet" / "ui" / "textui" / "MicronParser.py",
        submodule_search_locations=None)
    mp = importlib.util.module_from_spec(spec)
    mp.__package__ = "nomadnet.ui.textui"
    sys.modules[spec.name] = mp
    spec.loader.exec_module(mp)
    return mp


def dump(nn_root: Path, markup: str):
    mp = load(nn_root)
    # Replace palette registration with a plain, inspectable style name.
    def make_style(state):
        f = state["formatting"]
        return "|".join([
            str(state["fg_color"]), str(state["bg_color"]),
            "b" if f["bold"] else "", "u" if f["underline"] else "",
            "i" if f["italic"] else ""])
    mp.make_style = make_style
    import collections
    mp.SYNTH_SPECS = collections.defaultdict(lambda: [None] * 5)
    sys.modules["nomadnet"].ui = sys.modules["nomadnet.ui"]
    sys.modules["nomadnet.ui"].TextUI = types.SimpleNamespace(
        THEME_DARK="dark", THEME_LIGHT="light")
    app = types.SimpleNamespace(ui=types.SimpleNamespace(colormode=256, glyphs={}), config={"textui": {"theme": "dark"}})
    sys.modules["nomadnet"].NomadNetworkApp = types.SimpleNamespace(
        get_shared_instance=lambda: app)
    maps = mp.markup_to_attrmaps(markup, url_delegate=None)
    rows = []
    for am in maps:
        w = am.original_widget
        while hasattr(w, "original_widget"):
            w = w.original_widget
        parts = []
        if hasattr(w, "get_text"):
            text, attrs = w.get_text()
            # urwid keeps (attr, length) runs; re-slice text by encoded run.
            pos = 0
            enc = text
            for attr, n in attrs:
                seg = enc[pos:pos + n]
                pos += n
                parts.append({"text": seg, "style": attr})
            if not attrs and text:
                parts.append({"text": text, "style": None})
        rows.append(parts)
    return rows


def main():
    nn_root, page = Path(sys.argv[1]), Path(sys.argv[2])
    rows = dump(nn_root, page.read_text(encoding="utf-8"))
    out = json.dumps(rows, ensure_ascii=False, indent=1)
    if len(sys.argv) > 3:
        Path(sys.argv[3]).write_text(out + "\n", encoding="utf-8")
    else:
        print(out)


if __name__ == "__main__":
    main()
