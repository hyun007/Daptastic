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
- **Prompts on plug-in:** connect the player and Daptastic offers to sync. Optionally opens
  at login.

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
2. **Settings** open on first launch. Enter your Navidrome server and username, enter the
   password and click **Test Connection** (the password is stored in the Keychain).
3. **Connect the player** in USB storage mode and choose its card. Music goes at the card
   root unless you set a music folder.
4. **In Navidrome**, open Settings → Players, find **`daptastic [Daptastic]`** (it appears
   after the first connection) and turn on **Report Real Path**. Daptastic needs the real
   file paths to mirror your library; without it, syncing stops with an explanation.
5. **Optional but recommended:** add the card to System Settings → Spotlight → Search
   Privacy. Spotlight indexing a card while it is being written can cut sync speed to a
   third. (Daptastic also drops a `.metadata_never_index` marker on the card.)

## Command line

`scripts/build-cli.sh` builds `daptastic`, which shares the app's settings and Keychain
item. `daptastic plan /Volumes/CARD` shows what a sync would do without changing
anything; `daptastic sync /Volumes/CARD` runs it.

## Development

- `Sources/DaptasticCore/` holds all sync logic; `swift test` runs its tests.
- `App/` is the SwiftUI menu-bar app; open `Daptastic.xcodeproj`.
- `CLAUDE.md` documents the conventions and the device/server quirks found along the way.

## License

[MIT](LICENSE)
