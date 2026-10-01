# Daptastic — icon brief

Prompts for generating Daptastic's icons with an image model (e.g. ChatGPT). Paste the
**Shared style** block first, then one prompt per image.

## What the app is

Daptastic is a macOS menu-bar app that copies a person's favourite music — the albums and
tracks they've starred in their own music server — onto a portable digital audio player (a
"DAP"), lossless, over USB. Plug the player in, and your favourites are on it. The audience is
audiophiles who self-host their music. The name is playful; the icon should be warm and
friendly, not technical.

**The idea to get across:** *your favourites, carried to your player* — a **star** (favourites)
and a **portable music player**.

## Shared style (paste before every prompt)

> Design a macOS app icon in the modern Apple style: a single bold, simple object centred on a
> rounded-square ("squircle") background, flat shapes with soft, subtle depth, generous margins,
> no text, no letters, no outlines thinner than 4% of the icon width. It must still be
> recognisable at 16×16 pixels.
>
> Palette:
> - Background: warm gradient from amber `#FFB347` (top) to deep orange `#FF6A3D` (bottom).
> - Player body: warm cream `#FFF4E2`, with a slightly darker cream `#F2E2C6` for its side or
>   controls.
> - Player screen: deep navy `#1F2340`.
> - Star: gold `#FFC93C`, with a lighter highlight `#FFE08A` on its top facets.
>
> Avoid: any existing logo or brand (no Apple Music look — no red/pink music note; no
> Navidrome, HiBy, TempoTec, iPod or Sony styling), photorealism, text, busy detail, thin lines,
> drop shadows outside the squircle.

## Images to generate

### 1. App icon — concept A: player with a star (preferred)

`daptastic-icon-A-1024.png` — 1024×1024 PNG.

> A chunky, friendly portable music player, seen straight on and slightly tilted (about 8°),
> filling about 60% of the squircle. Rounded rectangular cream body, taller than it is wide,
> with a large navy screen on the upper two-thirds and a single round control wheel below it in
> the darker cream. On the screen, a big five-pointed gold star fills most of the screen,
> slightly glowing. Minimal, iconic, readable at small sizes.

### 2. App icon — concept B: memory card with a star

`daptastic-icon-B-1024.png` — 1024×1024 PNG.

> A microSD-style memory card shown large and upright, in cream, with its characteristic
> notched outline (one corner cut, a small step on one side) and simplified gold contact strips
> at the bottom drawn as three or four thick bars. A big gold five-pointed star sits in the
> middle of the card. Minimal, iconic, readable at small sizes.

### 3. App icon — concept C: star dropping into a player

`daptastic-icon-C-1024.png` — 1024×1024 PNG.

> A gold five-pointed star falling into the top of a chunky cream portable music player (navy
> screen, one round control wheel), as if being loaded into it. Two or three short, thick
> motion lines above the star show it moving down. The player sits in the lower half of the
> squircle, the star overlaps its top edge. Minimal, readable at small sizes.

### 4. Size check (for whichever concept is chosen)

`daptastic-icon-<A|B|C>-sizes.png` — one image.

> Show the same icon at 512, 128, 32 and 16 pixels side by side on a white background, then
> again on a dark grey `#1E1E1E` background, so legibility at small sizes can be judged.

If the star or the player's shape disappears at 16 px, ask for a simplified version: fewer
details, bigger star, thicker shapes.

### 5. Layers for Icon Composer (chosen concept only)

macOS 26 and later builds icons from separate layers in Xcode's **Icon Composer**, which adds
the glass depth and generates the dark and tinted variants itself. So the chosen design is also
needed as **flat layers**, each 1024×1024, aligned to each other:

| File | Contents |
|---|---|
| `layer-0-background.png` | Just the amber→orange gradient, filling the whole square (no rounded corners — Icon Composer applies the shape). |
| `layer-1-body.png` | The player (or card) body only, flat colours, **transparent background**, no shadow. |
| `layer-2-star.png` | The star only, flat gold, **transparent background**, no glow or shadow. |

> Recreate the chosen icon as three separate, perfectly aligned 1024×1024 PNG layers: (1) the
> background gradient alone, filling the whole square with no rounded corners; (2) the player
> body alone on a transparent background; (3) the star alone on a transparent background. Flat
> colours only: no shadows, glows, glass effects or highlights — those are added later.

### 6. Menu-bar icon (template glyph)

The menu bar needs a tiny **monochrome** glyph that macOS tints for light and dark menu bars.
Ask for **SVG code** rather than an image, so it stays crisp:

> Write SVG code for a macOS menu-bar template icon: pure black shapes on a transparent
> background, `viewBox="0 0 18 18"`, no colours, no gradients, no text, strokes at least
> 1.5 units thick (or filled shapes). Show a simple portable music player outline (rounded
> rectangle, a screen area, one round control) with a small solid star on the screen — the same
> idea as the app icon, reduced to its essentials. Provide three variants as separate SVGs:
> 1. `menubar-idle.svg` — the glyph as described.
> 2. `menubar-syncing.svg` — the star replaced by two curved arrows forming a circle (sync).
> 3. `menubar-attention.svg` — the idle glyph with a small solid dot at the top-right corner,
>    cut out from the outline so it reads clearly.

## Bring back

- The 1024 PNG of each concept (1–3), and the size-check image for the favourite (4).
- For the chosen concept: the three layer PNGs (5).
- The three menu-bar SVGs (6).

These go into the Xcode project: the layers into an Icon Composer `.icon` file (with the
1024 PNG as a fallback `AppIcon`), and the SVGs into an asset catalog as template images, wired
to the app's idle, syncing and needs-attention states.
