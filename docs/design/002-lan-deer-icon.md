# LAN-deer mascot & app icon

Status: **adopted** — this is the official LANdir app icon (asset +
all platform launcher icons).

> Small-size note: the file-node dots and the folder are deliberately
> oversized (r=34 tips, ~118-unit folder) so the directory tree still
> reads at launcher sizes. Down to roughly 48px the antlers read as
> tree branches with green tips and a folder; below that it reduces
> to a deer silhouette, like any flat icon.

## The idea

"LANdir" is a near-exact homophone of **LAN-deer**. The mascot is a
goofy reindeer whose antlers fork exactly like a **directory tree**:
every tine tip carries a green file-node (the accent green of the web
drop-zone, `#4caf50`), and one tine ends in a small folder — the "dir"
half of the name, drawn.

Why it hangs together beyond the pun:

- Antlers *are* forking trees — the standard "expand a directory"
  glyph — and each tip doubles as a device on the LAN.
- Santa's reindeer are the original overnight file-delivery fleet.
- The derp (one big eye, pupils askew, tongue out) keeps the tone of
  a tool you point at your friends' phones, not an enterprise suite.

## Alternatives considered

| Animal | Association | Why not |
|---|---|---|
| Salamander | fuzzy echo of "LANdir"; amphibious = phone + desktop | pun is weak |
| Hermit crab | carries its home directory around | no pun |
| Pangolin | rolls into a ball = secret-token mode | no pun |
| Mole | digs the tunnels cables go through | too subtle |

## Asset

- Source: `docs/design/lan-deer-icon.svg` (1024×1024 viewBox, rounded
  square badge).
- Palette matches the served page: drop-zone-dark green background,
  `#4caf50` accents, warm brown/tan deer.

## Adopting a change

`docs/design/lan-deer-icon.svg` is the single source; never edit the
PNGs directly.

1. Rasterize and install the base asset:

       inkscape docs/design/lan-deer-icon.svg \
         --export-type=png --export-width=1024 --export-height=1024 \
         --export-filename=app/assets/icon.png

2. Regenerate the platform icons:

       cd app && dart run flutter_launcher_icons

   (flutter_launcher_icons 0.14.4 handles Android and iOS; Linux is
   not covered, so also copy the rasterized PNG to
   `app/linux/runner/resources/app_icon.png` — used by the GTK runner
   and the AppImage packaging.)

3. Run the app test suite (`cd app && flutter test`).
