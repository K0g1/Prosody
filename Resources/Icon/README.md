# Prosody icon assets

`Prosody.svg` is the editable app icon. `Prosody.png` is a transparent 1024-pixel export, and `Prosody.icns` is the macOS bundle icon.

The menu bar uses [ProsodyMenuBar.svg](../../Sources/ProsodyCore/Resources/ProsodyMenuBar.svg), an AppKit template image with the same path geometry and a tighter view box for small sizes. Update both SVGs when changing the mark.

The original concept used an image generation tool; the final icon was redrawn as SVG.

After editing the app icon source, run `./script/build_icon.sh` to regenerate the exports.
