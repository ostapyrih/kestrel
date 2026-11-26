import unittest

import generate

BODY = """# Kestrel 0.3.0 - Desktop

Summary paragraph.

---

## [0.3.0](https://github.com/o/r/compare/a...b) (2026-11-26)


### Features

* **app:** add Windows, macOS and Linux platform scaffolding ([9f352ea](https://github.com/o/r/commit/9f352ea3c8a8a441454b6ebef5d90e4f398e4a97))
* **app:** run on desktop with two-pane layout and device name ([3a60150](https://github.com/o/r/commit/3a601500ccc8ef8b6b026c7ed1eca7caf9078259))

### Bug Fixes

* fix a thing with [a link](https://example.com) ([abcdef1](https://github.com/o/r/commit/abcdef1))

### How to install the IPA

* not a changelog bullet
"""


def release(tag, assets=None, body=BODY, **kw):
    rel = {
        "tag_name": tag,
        "published_at": "2026-11-26T13:41:41Z",
        "body": body,
        "draft": False,
        "prerelease": False,
        "assets": assets
        if assets is not None
        else [
            {
                "name": f"kestrel-{tag[5:]}-unsigned.ipa",
                "size": 123,
                "browser_download_url": f"https://example.com/{tag}.ipa",
            }
        ],
    }
    rel.update(kw)
    return rel


class ChangelogTest(unittest.TestCase):
    def test_extracts_features_and_fixes_without_links_or_hashes(self):
        out = generate.extract_changelog(BODY)
        self.assertEqual(
            out.split("\n"),
            [
                "- app: add Windows, macOS and Linux platform scaffolding",
                "- app: run on desktop with two-pane layout and device name",
                "- fix a thing with a link",
            ],
        )
        self.assertNotIn("http", out)
        self.assertNotIn("not a changelog", out)

    def test_limit(self):
        body = "### Features\n\n" + "\n".join(f"* **app:** item number {i} " + "x" * 60 for i in range(20))
        out = generate.extract_changelog(body)
        self.assertLessEqual(len(out), 400)
        self.assertTrue(out.startswith("- app: item number 0"))
        self.assertEqual(out.count("\n") + 1, len(out.split("\n")))

    def test_long_single_bullet_is_cut(self):
        out = generate.extract_changelog("### Features\n\n* " + "word " * 200)
        self.assertLessEqual(len(out), 400)
        self.assertTrue(out.endswith("…"))

    def test_fallback_to_first_paragraph(self):
        self.assertEqual(generate.extract_changelog("# T\n\nHello [x](http://a) world\n"), "Hello x world")
        self.assertEqual(generate.extract_changelog(""), "")


class SourceTest(unittest.TestCase):
    def test_shape_and_order(self):
        rels = [
            release("app-v0.2.0"),
            release("app-v0.10.0"),
            release("app-v0.3.0"),
            release("bridge-v0.3.0"),
            release("app-v0.4.0", assets=[]),
            release("app-v0.5.0", draft=True),
        ]
        src = generate.build_source(rels, "https://x.github.io/kestrel//", build_numbers={"app-v0.3.0": "3"})
        self.assertEqual(src["identifier"], "com.ostapyrih.kestrel.source")
        self.assertEqual(src["iconURL"], "https://x.github.io/kestrel/icon.png")
        app = src["apps"][0]
        self.assertEqual(app["bundleIdentifier"], "com.ostapyrih.kestrel")
        self.assertEqual(app["appPermissions"], {"entitlements": [], "privacy": {}})
        vs = app["versions"]
        self.assertEqual([v["version"] for v in vs], ["0.10.0", "0.3.0", "0.2.0"])
        v = vs[1]
        self.assertEqual(v["buildVersion"], "3")
        self.assertEqual(v["size"], 123)
        self.assertEqual(v["minOSVersion"], "15.0")
        self.assertEqual(v["downloadURL"], "https://example.com/app-v0.3.0.ipa")
        self.assertEqual(v["date"], "2026-11-26T13:41:41Z")
        self.assertEqual(vs[2]["buildVersion"], "0.2.0")

    def test_deterministic(self):
        rels = [release("app-v0.2.0"), release("app-v0.3.0")]
        a = generate.build_source(rels, "https://x/y")
        b = generate.build_source(list(reversed(rels)), "https://x/y")
        self.assertEqual(a, b)


if __name__ == "__main__":
    unittest.main()
