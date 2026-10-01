# Daptastic visual asset pack

Created from `docs/icon-brief.md`, with the project README and app structure as context. Concept A is the preferred design. All production art is editable SVG with exact PNG exports; the original built-in imagegen explorations and prompts are included for provenance.

## Deliverables

- `daptastic-icon-A-1024.png`, `daptastic-icon-B-1024.png`, `daptastic-icon-C-1024.png`: 1024 × 1024 RGBA app icons with transparent outer corners.
- `daptastic-icon-A-sizes.png`: actual 512, 128, 32, and 16 pixel exports, on white and #1E1E1E. View at 100% for a fair size check.
- `layers/layer-0-background.png`: opaque 1024-square amber-to-orange gradient, no rounded corners.
- `layers/layer-1-body.png`: 1024-square transparent flat player, screen, and control layer.
- `layers/layer-2-star.png`: 1024-square transparent flat gold star layer.
- `layers/alignment-preview.png`: exact composite of the three layers, for alignment inspection only.
- `menubar/menubar-idle.svg`, `menubar-syncing.svg`, `menubar-attention.svg`: black-only 18 × 18 template glyphs. Also supplied as 18 and 36 pixel PNGs.
- `Daptastic.xcassets`: importable macOS fallback AppIcon and three vector template image sets.
- `AppIcon.iconset` and `Daptastic.icns`: standard macOS sizes from 16 through 1024 pixels. ICNS comes from the successful Xcode asset catalog compilation.
- `sources/`: editable SVG masters for all concepts and all three layers.
- `concepts-preview.png` and `menubar-preview.png`: review sheets.
- `references/`: original imagegen explorations, preserved as generated, including their imperfect edge pixels. Use the production assets above for shipping.
- `PROMPTS.md`: exact image generation prompts and production design decisions.

## Icon Composer

Import the three numbered layers in that order into a new Icon Composer document. All layers share a 1024 × 1024 artboard, with body and star using exactly the same 8-degree rotation. Keep them at the same full-canvas scale and origin; do not auto-fit each visible object separately. Let Icon Composer apply the outer shape and material effects. The foreground layers have no baked lighting, shadows, or glow. Save as `Daptastic.icon` and review the platform-generated dark and tinted appearances. This pack contains the aligned source layers, not a saved native `.icon` document.

## Xcode use

The catalog has been compiled successfully with the installed Xcode asset compiler for macOS 15. Add it under `App/` and set the app icon asset name to `AppIcon` for the fallback workflow. The project uses a synchronized App folder. The SVG image sets already specify template rendering and preserve vector representation.

Use image names `MenuBarIdle`, `MenuBarSyncing`, and `MenuBarAttention`. The existing model's `preparing` and `syncing` phases map to syncing; `confirmDeletes`, `wontFit`, and `failed` map to attention; other phases map to idle. Render at 18 × 18 points using template mode. Source code and installed application were not changed by this asset delivery.

## Visual checks

Reviewed all concepts, both size-check backgrounds, the three template glyphs at actual and enlarged sizes, and the exact flat-layer composite. The 16-pixel icon preserves the navy screen and gold star; the control is intentionally secondary. Foreground layers use only their specified flat palette colors plus edge antialiasing. The background layer fills every pixel and the star fits entirely within the navy screen. Production app-icon shadows remain inside the squircle.
