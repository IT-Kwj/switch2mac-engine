# Mario Kart World (`0400C3F00006E000`)

Version 1.0.0 (title version 0), SDK 19.3.3, on NVN2 (Switch 2). Tested on the Mac (M1 Max, 64 GB): title, menus, Grand Prix, free roam and traffic all render and play, about 58 fps in races with Performance mode on. Later updates are **untested**: [`game.tsv`](game.tsv) names only 1.0.0's build IDs.

This profile started from the 1.8.0 patch series by Reddit user potentialad9091 and was moved to 1.0.0 and finished in switch2mac. The full story is in [docs/mario-kart-world.md](../../../../docs/mario-kart-world.md).

## What it needs

| Setting | Where | Why |
|---|---|---|
| `device_api 231.39` | [`game.tsv`](game.tsv) | the game's own check; with 55.15 it leaves NVN setup silently and crashes on a null global |
| `render_cond on` | `game.tsv` | the 3D scene was black: its clears are conditional, as on Tears of the Kingdom |
| `tex_flush_upload on`, `tex_dirty_upload on` | `game.tsv` | the terrain height tiles are filled by the CPU, some before their texture exists: without these the near ground was flat or invisible |
| 20 GB guest layout, `app_pool 0x263000000` | `game.tsv` | the game is told 9.55 GiB and plans all of it |

Shaders come from `dm/gfx/tools/nx2_split.py` (SM86 lowered to Maxwell by `nx2_lower`, GPL-3.0-or-later, see its README), then `dmsh_build.py`, then `nx2_res.py` and `nx2_reflect.py`. About 290 of them (all the mesh and task programs among them) exist only at run time: the app saves them while you play and `switch2mac.py refresh` builds them in. [`mesh_pairs.tsv`](mesh_pairs.tsv) pairs each mesh shader with its pixel shader, for the per-primitive outputs.

## Still open

- Lamp lights shine through walls at night (local-light shadows).
- One environment-reflection chain (pixel shader `83ea368cd702b9de`) costs about 4 ms a frame on the Mac; Performance mode skips it (`DM_NVN_SKIP_FS`).
- The game's own frame-rate controller drops to 30 fps pacing whenever a frame takes more than 16.7 ms.
- `PushGraphicsConstants` and `SetGeometryProcessingMode` do nothing (5 full-screen shaders read push constants).
