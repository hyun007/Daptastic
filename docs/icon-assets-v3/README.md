# Daptastic assets — revision 3

Selected concept: B, the star on a memory card.

The upper and lower portions of the left edge now align at x=280 on the 1024-pixel artboard. The side notch remains, as does the clipped upper-right corner. Star, contacts, palette, and overall dimensions are unchanged.

- `daptastic-icon-B-1024.png`: revised selected icon.
- `daptastic-icon-B-sizes.png`: actual 512, 128, 32 and 16 pixel checks on white and dark grey.
- `layers/`: perfectly aligned 1024-pixel background, flat card-with-contacts, and flat star PNGs, plus a composite preview.
- `sources/`: editable SVG masters for each concept and layer.
- `Daptastic.xcassets`, `AppIcon.iconset`, `Daptastic.icns`: updated to concept B. Catalog compiled successfully with Xcode for macOS 15.
- `menubar/`: concept B SD-card template glyphs for idle (star), syncing (circular arrows), and attention (star plus isolated dot). Pure black SVGs with 18 × 18 viewBox, plus 18 and 36 pixel PNGs. The asset catalog contains these same updated SVGs.
- `concepts-preview.png`: comparison with the corrected card.

Import the three numbered PNG layers into Icon Composer at matching full-canvas size and origin. Save a native `.icon` document after reviewing its material effects and appearances. No native `.icon` document or app source changes are included in this delivery.

Revision 1 and its original imagegen explorations remain available separately. This revision directly edits the existing vector source and corrects the menu-bar concept mismatch.
