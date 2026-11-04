# nx2_lower

Switch 2 (SM86) shader code to Maxwell code, for `nx2_split.py`. `shader_recompiler/frontend/ampere/` holds `lower_to_maxwell.h` and `program_capture.h` from [Eglantine](https://github.com/djihads80/eglantine) (`src/shader_recompiler/frontend/ampere/`, GPL-3.0-or-later; see the headers), so a host or tool built with them is under the GPL, not this repository's MIT licence. switch2mac changed `lower_to_maxwell.h` (GPL-3.0-or-later like the original): SM86 opcodes 0x59f (SURED, surface reduction), 0x2bf (UPOPC) and the task / mesh stage-memory loads and stores 0x923 / 0x927 (lowered to shared-memory LDS / STS windows that the translator turns into Metal object / mesh I/O), and a `-Wshadow` pragma on line 1. `common/common_types.h` stands in for Eden's.

```
clang++ -std=c++20 -O2 -w -Wno-c++11-narrowing -I. nx2_lower.cpp -o nx2_lower
```
