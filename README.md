# Daptastic

A macOS menu-bar app that copies your [Navidrome](https://www.navidrome.org) favourites to a
digital audio player over USB. Plug in the player, click **Sync Now**, and your starred
albums, starred tracks and playlists land on its card, bit-for-bit, with the playlists
showing up as real playlists on the device.

Built and tested with a **TempoTec Variations V1** (HiBy OS). Other HiBy OS players that
read playlists from `playlist_data/` will probably work too.

## What it does

- **Syncs** every starred album (all tracks), every starred track, and every playlist.
  Starred *artists* are skipped on purpose: one star could pull in hundreds of albums.
- **Lossless:** files are the server's originals via the Subsonic `download` endpoint,
  never transcoded.
- **Playlists:** one `.m3u8` per Navidrome playlist, plus *Starred Tracks*, in the format
  HiBy OS actually reads (UTF-8, entries relative to the playlist file).
- **Mirrors, carefully:** un-starring an album removes it from the card on the next sync —
  but only files Daptastic wrote itself (tracked in `.daptastic/manifest.json` on the card).
  Music you copied yourself is never touched. If the synced set suddenly shrinks by more
  than 30% or becomes empty, it asks before deleting anything.
- **Checks space first:** if it won't fit, it tells you how much is missing and which
  albums are largest, before copying a single byte.
- **Survives interruptions:** files are written under a temporary name and renamed when
  complete; cancel or unplug mid-sync and the next sync resumes where it stopped.
- **Notifies you:** connect the player and a notification offers **Sync Now**; when the sync
  finishes, another summarises what changed. Optionally opens at login.

## Requirements

- macOS 15 or later, Xcode 26 or later to build.
- A Navidrome server (developed against 0.58) reachable from the Mac.
- A library laid out as `Artist/YYYY - Album/NN - Title.ext` (with `CD NN/` for multi-disc
  albums) and free of characters exFAT rejects (`: ? * < > | " \`). The card mirrors it.

## Setup

1. **Build and install:** `scripts/install-app.sh` builds a Release copy and installs it
   to `/Applications`.
   - To sign with your own Apple Development certificate (so the Keychain doesn't ask for
     access after every rebuild), copy `Config/Signing.xcconfig.example` to
     `Config/Signing.xcconfig` and set your team ID. Without it, builds are ad-hoc signed.
2. **Setup** opens on first launch:
   - **Connect to Navidrome** with your server, username and password (kept in the
     Keychain). Daptastic needs real file paths to mirror your library, so it turns on
     **Report Real Path** for its own player (`daptastic [Daptastic]`) in Navidrome. If it
     can't, it explains how to do it in Navidrome's Settings → Players.
   - **Plug in your player** in USB storage mode (or insert its card) and choose it. Music
     goes at the card root unless you set a music folder. Spotlight indexing a card while
     it is being written can cut sync speed to a third, so Daptastic tells Spotlight to
     skip the card and offers to remount it (it stays plugged in) so that takes effect
     straight away.
   - **Open at login**, so plugging in the player offers to sync.

## Command line

`scripts/build-cli.sh` builds `daptastic`, which shares the app's settings and Keychain
item. `daptastic plan /Volumes/CARD` shows what a sync would do without changing
anything; `daptastic sync /Volumes/CARD` runs it.

## Development

- `Sources/DaptasticCore/` holds all sync logic; `swift test` runs its tests.
- `App/` is the SwiftUI menu-bar app; open `Daptastic.xcodeproj`.
- `CLAUDE.md` documents the conventions and the device/server quirks found along the way.
- `scripts/make-dmg.sh` builds `dist/Daptastic.dmg` for drag-to-install testing
  (`--quarantine` makes Gatekeeper treat it as downloaded); `scripts/reset-for-testing.sh`
  uninstalls the app and its settings and saved password, to test first-run setup again.

## License

[MIT](LICENSE)
