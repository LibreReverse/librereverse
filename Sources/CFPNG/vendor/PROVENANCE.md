# FPNG upstream provenance

- Upstream: https://github.com/richgel999/fpng
- Revision: `925796543b9d26b8edfcdcecd94c1dac280f29fc`
- Source version: 1.0.6
- `fpng.cpp` SHA-256: `b2b953f53f4b472b427bfb04a0ee1839ba66e8f32a02580e7a09d31313edd975`
- `fpng.h` SHA-256: `604c7e3757dba53b32f7e2523927c7e02ad90939d631a76f94f0690efa2c1fc9`
- License: public domain / Unlicense, preserved in UNLICENSE and upstream source.

These two files are unmodified upstream copies, verified identical to the
sources used in synthetic CPU and power experiments. CFPNG.cpp is the separate
LibreReverse wrapper: it validates opaque BGRA input, swizzles with NEON on
arm64 (scalar elsewhere), contains exceptions, and adds an sRGB PNG chunk.
SwiftPM sets FPNG_NO_SSE=1, FPNG_NO_STDIO=1 and -fno-strict-aliasing. The wrapper
uses upstream CRC; no libdeflate, Homebrew, or dynamic-library dependency is added.
