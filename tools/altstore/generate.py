#!/usr/bin/env python3
"""Generate the AltStore / SideStore source (altstore.json) from GitHub releases.

Reads every published `app-v*` release of the repository, takes its unsigned IPA
asset and writes the source JSON (all versions, newest first). Standard library only.

Usage:
    python tools/altstore/generate.py --out site/altstore.json

Environment:
    GITHUB_TOKEN        optional, raises the API rate limit
    GITHUB_REPOSITORY   owner/name, default ostapyrih/kestrel
"""
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

DEFAULT_REPO = "ostapyrih/kestrel"
BUNDLE_ID = "com.ostapyrih.kestrel"
MIN_OS_VERSION = "15.0"  # IPHONEOS_DEPLOYMENT_TARGET of the Runner target
TINT = "0F766E"
TAG_RE = re.compile(r"^app-v(\d+)\.(\d+)\.(\d+)$")
MAX_CHANGELOG = 400
SECTIONS = ("features", "bug fixes")


def api_get(url, accept="application/vnd.github+json"):
    headers = {"Accept": accept, "User-Agent": "kestrel-altstore-generator"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read().decode("utf-8")


def fetch_releases(repo):
    releases, page = [], 1
    while True:
        url = f"https://api.github.com/repos/{repo}/releases?per_page=100&page={page}"
        batch = json.loads(api_get(url))
        releases.extend(batch)
        if len(batch) < 100:
            return releases
        page += 1


def fetch_build_number(repo, tag):
    """Build number (the part after `+`) of app/pubspec.yaml at the tag, or None."""
    url = f"https://api.github.com/repos/{repo}/contents/app/pubspec.yaml?ref={tag}"
    try:
        text = api_get(url, accept="application/vnd.github.raw+json")
    except (urllib.error.URLError, OSError):
        return None
    m = re.search(r"^version:\s*\S+?\+(\d+)\s*$", text, re.MULTILINE)
    return m.group(1) if m else None


_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
_TRAILING_REF = re.compile(r"\s*\(\[[0-9a-f]{7,40}\]\([^)]*\)\)\s*$")


def _clean_bullet(text):
    text = _TRAILING_REF.sub("", text)
    text = _LINK.sub(r"\1", text)
    text = text.replace("**", "").replace("`", "")
    text = re.sub(r"\s*\([0-9a-f]{7,40}\)\s*$", "", text)
    return re.sub(r"\s+", " ", text).strip()


def _truncate(text, limit):
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + "…"


def extract_changelog(body, limit=MAX_CHANGELOG):
    """Short changelog from a release-please body.

    Uses the bullets under "Features" and "Bug Fixes" (links and commit hashes
    stripped). Whole bullets are kept while they fit in `limit`; a first bullet
    that is too long is cut with an ellipsis. Falls back to the first paragraph.
    """
    body = (body or "").replace("\r\n", "\n")
    bullets, section = [], None
    for line in body.split("\n"):
        heading = re.match(r"^#{2,4}\s+(.*?)\s*$", line)
        if heading:
            section = heading.group(1).strip().lower()
            continue
        item = re.match(r"^\s*[*-]\s+(.*\S)\s*$", line)
        if item and section in SECTIONS:
            cleaned = _clean_bullet(item.group(1))
            if cleaned:
                bullets.append(cleaned)
    if not bullets:
        for para in re.split(r"\n\s*\n", body):
            para = para.strip()
            if para and not para.startswith(("#", "---", "```")):
                return _truncate(_clean_bullet(re.sub(r"\s*\n\s*", " ", para)), limit)
        return ""
    out = []
    for b in bullets:
        candidate = "\n".join(out + ["- " + b])
        if len(candidate) <= limit:
            out.append("- " + b)
        elif not out:
            return _truncate("- " + b, limit)
        else:
            break
    return "\n".join(out)


def version_key(version):
    return tuple(int(p) for p in version.split("."))


def build_version(release, ipa, build_number):
    tag = release["tag_name"]
    version = tag[len("app-v"):]
    entry = {
        "version": version,
        "buildVersion": build_number or version,
        "date": release["published_at"],
        "localizedDescription": extract_changelog(release.get("body")),
        "downloadURL": ipa["browser_download_url"],
        "size": ipa["size"],
        "minOSVersion": MIN_OS_VERSION,
    }
    return entry


def build_source(releases, pages_url, repo=DEFAULT_REPO, build_numbers=None):
    """Assemble the source dict. `build_numbers` maps tag -> CFBundleVersion."""
    build_numbers = build_numbers or {}
    versions = []
    for rel in releases:
        if rel.get("draft") or rel.get("prerelease"):
            continue
        if not TAG_RE.match(rel.get("tag_name", "")):
            continue
        ipa = next(
            (a for a in rel.get("assets", []) if a["name"].lower().endswith(".ipa")),
            None,
        )
        if ipa is None:
            continue
        versions.append(build_version(rel, ipa, build_numbers.get(rel["tag_name"])))
    versions.sort(key=lambda v: version_key(v["version"]), reverse=True)
    pages_url = pages_url.rstrip("/")
    return {
        "name": "Kestrel",
        "identifier": BUNDLE_ID + ".source",
        "subtitle": "Reticulum / LXMF messenger",
        "description": "Official Kestrel releases for AltStore and SideStore.",
        "iconURL": pages_url + "/icon.png",
        "website": f"https://github.com/{repo}",
        "tintColor": TINT,
        "apps": [
            {
                "name": "Kestrel",
                "bundleIdentifier": BUNDLE_ID,
                "developerName": repo.split("/")[0],
                "subtitle": "Reticulum / LXMF messenger",
                "localizedDescription": (
                    "Kestrel is a Reticulum / LXMF messenger. It connects to the "
                    "Reticulum network over TCP and sends and receives end-to-end "
                    "encrypted LXMF messages, compatible with Sideband, MeshChat "
                    "and NomadNet."
                ),
                "iconURL": pages_url + "/icon.png",
                "tintColor": TINT,
                "category": "social",
                "screenshots": [
                    pages_url + "/screenshots/chats.png",
                    pages_url + "/screenshots/chat.png",
                    pages_url + "/screenshots/settings.png",
                ],
                "appPermissions": {"entitlements": [], "privacy": {}},
                "versions": versions,
            }
        ],
        "news": [],
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", DEFAULT_REPO))
    ap.add_argument("--pages-url", default=None, help="default https://<owner>.github.io/<repo>")
    ap.add_argument("--out", default="altstore.json")
    args = ap.parse_args(argv)
    owner, name = args.repo.split("/")
    pages_url = args.pages_url or f"https://{owner.lower()}.github.io/{name}"

    releases = [r for r in fetch_releases(args.repo) if TAG_RE.match(r.get("tag_name", ""))]
    numbers = {}
    for rel in releases:
        n = fetch_build_number(args.repo, rel["tag_name"])
        if n:
            numbers[rel["tag_name"]] = n
    source = build_source(releases, pages_url, args.repo, numbers)
    if not source["apps"][0]["versions"]:
        print("error: no app-v* release with an IPA asset found", file=sys.stderr)
        return 1
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(source, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {args.out} with {len(source['apps'][0]['versions'])} version(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
