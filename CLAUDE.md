# CLAUDE.md

macOS menu-bar app that syncs Navidrome starred albums, starred tracks and playlists to a
HiBy OS DAP (developed against the TempoTec Variations V1) over USB mass storage.
Swift / SwiftUI, built with Xcode. Personal setup, if any, is in `CLAUDE.local.md`.

## Layout

- `Sources/DaptasticCore/` — all sync logic (SwiftPM library); `swift test` runs its tests.
- `Sources/daptastic/` — CLI harness over the same core. Build it with
  `scripts/build-cli.sh`, which signs it (if `Config/Signing.xcconfig` exists) so Keychain
  access sticks; `swift run` signs ad-hoc and hits an access prompt on every build.
- `App/` + `Daptastic.xcodeproj` — the menu-bar app. The project uses a synchronized folder,
  so new files in `App/` need no project edits. Menu-bar only (`LSUIElement`), not
  sandboxed. Signing comes from `Config/Base.xcconfig`: ad-hoc by default, or a real
  certificate via the git-ignored `Config/Signing.xcconfig` — needed for Keychain access
  to survive rebuilds. App and CLI share settings (defaults domain `cc.jofam.daptastic`) and
  the Keychain item (service `cc.jofam.daptastic.navidrome`). Install with
  `scripts/install-app.sh` (Release → `/Applications`); "Open at login" registers the
  running copy via `SMAppService`, so it must be the installed one.

## Server

- Developed against Navidrome 0.58 (Subsonic API 1.16.1, `openSubsonic: true`). Auth is
  `u` + `t` (token) + `s` (salt); there is no API-key concept, so a password is required.
- The server URL and username come from Settings only — nothing is built in.
- Endpoints used: `ping`, `getStarred2`, `getAlbum`, `getPlaylists`, `getPlaylist`,
  `download`.
- **Use `download` only, never `stream`** — `download` returns original bytes, `stream` may
  transcode. A lossy option is out of scope for now.
- **Starred artists are not synced** — one star could pull in hundreds of albums.
- **Subsonic reports failures as HTTP 200 with an `error` object in the body.** Never
  treat a 200 as success without parsing. The same goes for `download`: an XML/JSON body
  is an error, never audio.
- Credentials belong in the **Keychain**, never in a plist or in the repo.

## Library conventions

- Expected server layout is `Artist/YYYY - Album/NN - Title.ext`, with an extra `CD NN/`
  level for multi-disc albums; it is mirrored on the device.
- Real paths require **"Report Real Path"** on for the `daptastic [Daptastic]` player in
  Navidrome (Settings → Players). Navidrome keys players on client name + User-Agent, so the
  client always sends the fixed User-Agent `Daptastic`; changing it creates a new player with
  real paths off. Without it, Navidrome synthesises paths from tags (no `YYYY - `,
  unsanitised). With it, paths are **absolute under the library root** (`/music` in the
  standard container), which the API does not expose — it is configured, and any path
  outside it is an error.
- **Filenames contain non-ASCII characters** (curly quotes, accents) — playlists must be
  `.m3u8`, UTF-8. Legacy-encoded m3u will not resolve.
- The library is assumed to be free of FAT/exFAT-illegal characters (`: ? * < > | " \`);
  the author's server-side tooling sanitises. Do not add another sanitisation layer for
  library paths. Playlist *names* are free text and are sanitised.

## Device (HiBy OS; verified on the TempoTec Variations V1)

- Playlists live in `playlist_data/` at card root and appear under
  Music → List → Playlists ("Load playlist" rescans).
- Music goes at the **card root** by default; the folder is a user preference
  (`SyncSettings.musicFolder`, relative to the volume). The manifest and all synced paths
  are relative to that music root.
- Playlist entries must be **relative to the playlist file**, forward slashes, e.g.
  `../Artist/YYYY - Album/NN - Title.flac` (plus the music folder, if set). Verified:
  `#EXTM3U` + UTF-8 NFC + LF resolves, including curly quotes and `CD NN/` subfolders.
  Card-root-relative (`Artist/…`), backslash, and the device's own internal `a:\Artist\…`
  form all fail, and playlists at the card root are not listed.
- macOS's exFAT driver stores names **NFC on disk** but lists them back **NFD**. So compare
  paths normalisation- and case-insensitively (exFAT is case-insensitive too), and write
  playlist entries NFC.
- The card sustains ~15 MB/s (fsync'd) over USB. **Spotlight indexing the card cuts sync
  throughput to roughly a third** by reading new files back over the same link. Each sync
  writes `.metadata_never_index` at the card root, which disables indexing from the next
  mount; Settings also suggests excluding the card in Spotlight's Search Privacy.
- Only files recorded in the on-card manifest (`.daptastic/manifest.json`) are ever deleted;
  anything else on the card is the user's and is left alone.
- On the V1, `playlist_data/` can be created from the Mac (the HiBy R3's reported "device
  must create it" quirk does not apply). The V1 does not save its own playlists to the card.

## Conventions

- Pre-flight the disk-space check before copying; never discover a full card mid-sync.
- Never delete on the device without the shrink guard: if the desired set is empty or
  >30% smaller than at the last successful sync, ask the user to confirm before deleting.
- Write transfers to a temp name and rename on completion, so an interrupted sync
  cannot leave a truncated file that looks complete.
- Never publish personal setup (server addresses, account names, team IDs): it belongs in
  `CLAUDE.local.md` or `Config/Signing.xcconfig`, both git-ignored.
