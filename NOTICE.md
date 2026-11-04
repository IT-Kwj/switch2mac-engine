# Notices and credits

| Part | Where | Licence | Credit |
|---|---|---|---|
| nxnative (host runtime, code rewriter, shader pipeline, Mac launcher) | everything not listed below | MIT (`LICENSE`) | [seedds/nxnative](https://github.com/seedds/nxnative), forked at `6a787668` |
| Switch 2 groundwork: NVN2 entry points, Ampere-to-Maxwell lowering hookup, hid / oe / chat stubs, VP9 movies, sparse textures, the first Mario Kart World profile | throughout `dm/` | as nxnative | the 8-patch series posted by Reddit user potentialad9091 (r/macgaming), written for update 1.8.0 |
| `nx2_lower` (SM86 → Maxwell shader lowering) | `dm/gfx/tools/nx2_lower/` | GPL-3.0-or-later | [Eglantine](https://github.com/djihads80/eglantine) (Eden-based); switch2mac added opcodes 0x59f, 0x2bf, 0x923 / 0x927 |
| Ryujinx shader translator (with switch2mac's task / mesh shader support) | `dm/third_party/ryujinx/` | MIT | [Ryujinx](https://github.com/Ryujinx/Ryujinx) |
| libvpx, stb_vorbis, Vulkan headers, NVIDIA FLIP | `dm/third_party/` | their own (`dm/third_party/README.md`) | their authors |
| Performance overlay and settings panel look; shared shader list idea | `dm/host/front_mac.m`, `dm/mac/Launcher.swift`, `dm/host/s2m_share.m` | MIT | inspired by [MacNativeGames](https://github.com/ly05010419/MacNativeGames) by ly05010419 |

Nintendo, Nintendo Switch 2 and Mario Kart are trademarks of Nintendo. This project is not affiliated with or endorsed by Nintendo.
