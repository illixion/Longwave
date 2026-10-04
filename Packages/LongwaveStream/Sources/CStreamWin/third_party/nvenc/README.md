# nvEncodeAPI.h

NVIDIA Video Codec SDK encode API header, **version 13.0**, vendored unmodified
from FFmpeg's nv-codec-headers, tag `n13.0.19.0`
(https://github.com/FFmpeg/nv-codec-headers/blob/n13.0.19.0/include/ffnvcodec/nvEncodeAPI.h).

Licence: MIT (NVIDIA's notice at the top of the file, which applies to this
header only). Compatible with the MIT edition; list it in
`THIRD_PARTY_NOTICES.md` when the host ships.

Nothing else from the SDK is used: the encoder runtime, `nvEncodeAPI64.dll`,
ships with every NVIDIA display driver and is loaded at run time, so no NVIDIA
binary is linked or redistributed.

API 13.0 needs driver R570 or newer (January 2025). Moving to a newer header
raises that floor; `lw_encoder_create` reports a too-old driver by name.
