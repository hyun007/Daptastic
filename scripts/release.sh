#!/bin/sh
# One-command release:  scripts/release.sh 0.2.0 path/to/notes.md
#
# Bumps the version and build number, tests, builds dist/Daptastic.dmg, signs it with the Sparkle
# key in your login Keychain, pushes, creates the GitHub release, then adds it to the update feed
# (site/appcast.xml, published with the website). The feed entry goes in last, so the app never
# offers an update whose download doesn't exist yet. Notes are Markdown: paragraphs, "- " lists,
# **bold**.
set -eu
cd "$(dirname "$0")/.."
version="${1:?usage: scripts/release.sh VERSION NOTES.md}"
notes="${2:?usage: scripts/release.sh VERSION NOTES.md}"
project=Daptastic.xcodeproj/project.pbxproj
sparkle=.build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin

fail() { echo "release: $*" >&2; exit 1; }
[ -f "$notes" ] || fail "no notes file at $notes"
[ "$(git branch --show-current)" = main ] || fail "not on main"
[ -z "$(git status --porcelain)" ] || fail "working tree not clean"
git rev-parse -q --verify "refs/tags/v$version" >/dev/null && fail "v$version already exists"

build=$(( $(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' "$project" | head -1) + 1 ))
sed -i '' -e "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $version;/" \
          -e "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $build;/" "$project"
echo "release: $version (build $build)"

swift test
scripts/make-dmg.sh
signature="$("$sparkle/sign_update" dist/Daptastic.dmg)"  # sparkle:edSignature="…" length="…"

git commit -q -am "Release $version"
git push -q origin main
gh release create "v$version" dist/Daptastic.dmg --target main \
    --title "Daptastic $version" --notes-file "$notes"

python3 - "$version" "$build" "$signature" "$notes" <<'PY'
import html, re, sys
from email.utils import formatdate
version, build, signature, notes_path = sys.argv[1:]

def to_html(markdown):
    blocks, items = [], []
    def flush():
        if items: blocks.append("<ul>" + "".join(f"<li>{i}</li>" for i in items) + "</ul>"); items.clear()
    for line in markdown.splitlines():
        text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", html.escape(line.strip()))
        if text.startswith("- "): items.append(text[2:])
        else:
            flush()
            if text: blocks.append(f"<p>{text}</p>")
    flush()
    return "\n".join(blocks)

item = f"""    <item>
      <title>Version {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
{to_html(open(notes_path, encoding="utf-8").read())}
      ]]></description>
      <enclosure url="https://github.com/hyun007/Daptastic/releases/download/v{version}/Daptastic.dmg"
                 type="application/octet-stream" {signature} />
    </item>
"""
path = "site/appcast.xml"
feed = open(path, encoding="utf-8").read()
anchor = "    <language>en</language>\n"
assert anchor in feed, "appcast anchor missing"
open(path, "w", encoding="utf-8").write(feed.replace(anchor, anchor + item, 1))
PY
git commit -q -m "Add $version to the update feed" site/appcast.xml
git push -q origin main
echo "release: done — https://github.com/hyun007/Daptastic/releases/tag/v$version"
