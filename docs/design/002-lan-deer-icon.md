# LAN-deer mascot & app icon

Status: **adopted** — this is the official LANdir app icon (asset +
all platform launcher icons).

> Small-size note: the antler-tip content is deliberately oversized.
> The right antler carries a directory folder (~180 units wide) and the
> left one a photo card (mountain + sun, ~150 units); both are lifted
> slightly above the upper tine tips so the mid-tip green file-nodes on
> the lower tines still read at launcher sizes. Down to roughly 48px
> the tree reads as branches holding a folder and a photo; below that
> it reduces to a deer silhouette, like any flat icon.

## The idea

"LANdir" is a near-exact homophone of **LAN-deer**. The mascot is a
goofy reindeer whose antlers fork exactly like a **directory tree**:
the tine tips carry green file-nodes (the accent green of the web
drop-zone, `#4caf50`), the upper tips end in a directory folder and a
photo card — the "dir" half of the name, drawn, along with what a LAN
directory actually holds.

Why it hangs together beyond the pun:

- Every tine tip carries content — a green file-node, and on the upper
  tips: a directory folder (right) and a photo card (left) — so both
  halves of the name are drawn: the *dir* as the folder, the things a
  *LAN directory* holds (files) riding the antlers.
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
