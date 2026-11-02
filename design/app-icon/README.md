# KaChat Chess app icon

A game controller in KaChat teal with the Kaspa mark (the backward K) cut into its middle, a
D-pad on the left and four buttons on the right. The backward K is traced from the KaChat app's
icon (`k_mark`), so the two match.
`python3 make_chess_icon.py` writes `kachat-chess-light.svg`, `kachat-chess-dark.svg` and
`kachat-chess-tinted.svg`. Render each at 1024x1024 and save it opaque (no alpha) into
`KaChatChess/Resources/Assets.xcassets/AppIcon.appiconset` (`white.png`, `dark.png`,
`Icon-iOS-TintedDark-1024x1024@1x.png`). On a Mac without other tools:

```bash
python3 make_chess_icon.py && qlmanage -t -s 1024 -o . kachat-chess-light.svg
sips -s format jpeg kachat-chess-light.svg.png --out t.jpg && sips -s format png t.jpg --out white.png
```

`KaChatChessLogo.imageset` (the sign-in screen's logo, next to "KaChat Chess", and the privacy
screen's) is the light icon at 512 px, with the dark icon at 512 px as its dark-mode version.

`ControllerTabIcon.imageset` (the dock's Play icon) is `kachat-chess-tab.svg`, the same controller as
one path with the D-pad, buttons and K as holes, rendered as a template so the tab bar tints it.
`python3 make_chess_icon.py tab` writes it; copy it in as `ControllerTabIcon.svg`.
