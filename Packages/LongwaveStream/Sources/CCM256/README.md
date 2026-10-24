# CCM256: vendored cm256

[cm256](https://github.com/catid/cm256) by Christopher A. Taylor, BSD-3-Clause (`LICENSE`).
It is the Cauchy Reed–Solomon codec over GF(2^8) that `StreamFEC` wraps
(`NATIVE_V3_PROTOCOL.md` §4.2 and §7.1).

Upstream commit: `634d1e36b095dbba937586a7e9843d828762dae4` (2024-10-17). Only
`src/cm256.cpp`, `src/gf256.cpp`, `include/cm256.h`, `include/gf256.h` and `LICENSE` are
copied, all flat in this directory. Upstream's unit test and build files are left out.

**Upstream's headers are private here.** `cm256.h` includes `gf256.h`, which includes
`<cstring>`, and Swift imports a C target's public headers in C mode. So the two sit beside the
`.cpp` files, and the public header is `include/longwave_cm256.h`. It repeats the two structs and
three functions StreamFEC calls, with the same layout, and `CM256_VERSION`. Keep it in step with
`cm256.h`.

## Local changes

Both are marked `Longwave:` in the source.

1. **`include/gf256.h`: arm64 outside Linux takes the `IOS` path.** Upstream treats any ARM
   target that doesn't define `IOS` as `LINUX_ARM`. That path includes `<linux/auxvec.h>` to
   probe for NEON, so macOS, visionOS and Windows on ARM wouldn't build. Every 64-bit ARM
   CPU has NEON, and the `IOS` path assumes it without probing.
2. **`gf256.cpp`: SSSE3 target attribute on x86-64 without `__SSSE3__`.** Under clang, a
   function that calls `_mm_shuffle_epi8` has to target SSSE3. SwiftPM can't pass flags per
   architecture, so the file pushes `target("ssse3")` itself. macOS's x86-64 baseline already
   has SSSE3, so in practice this applies to Windows x64.

   With the attribute on, the compiler may use SSSE3 even in the scalar fallback, which
   upstream picks at runtime when `cpuid` reports no SSSE3. Every x86-64 CPU that runs
   Windows 11 has SSSE3, so this is accepted.

To update from upstream, copy those five files, apply both changes again, and check
`include/longwave_cm256.h` against the new `cm256.h`. `StreamFECTests.testGoldenParity` fails
if the codec's matrix changed, which would break interop with any host built from the old
copy.

These were checked 2026-10-24: `clang++ -Wall -Wextra` for arm64 macOS, visionOS, x86-64 macOS
and x86-64 with `-mno-ssse3` (the Windows baseline). The only warning is upstream's unused
`CpuHasNeon64` on arm64. `StreamFECTests` pass on arm64 and as x86-64 under Rosetta. The
Windows clang build hasn't been run yet.
