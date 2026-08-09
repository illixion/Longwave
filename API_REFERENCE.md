# Longwave API Reference

## RoyalVNCKit API Quick Reference

- **Connection:** `VNCConnection(settings:)`, `.connect()`, `.disconnect()`
- **Settings:** `VNCConnection.Settings(hostname:port:isShared:colorDepth:frameEncodings:...)`
- **Color depths:** `.depth8Bit` (broken — palettized, most servers reject), `.depth16Bit`, `.depth24Bit`
- **Frame encodings:** `[VNCFrameEncodingType].default` → [tight, zlib, zrle, hextile, coRRE, rre]
- **Auth types:** `VNCAuthenticationType` — `.vnc` (password only), `.appleRemoteDesktop` (username+password), `.ultraVNCMSLogonII`
- **Credentials:** `VNCPasswordCredential(password:)`, `VNCUsernamePasswordCredential(username:password:)`
- **Framebuffer:** `VNCFramebuffer` — `.cgImage`, `.cgSize`
- **Mouse:** `.mouseMove(x:y:)`, `.mouseButtonDown/Up(_:x:y:)`, `.mouseWheel(_:x:y:steps:)`
- **Keyboard:** `.keyDown(_:)`, `.keyUp(_:)` with `VNCKeyCode` (X11 KeySymbols)
- **Key codes:** `VNCKeyCode.withCharacter(_:)` for printable chars, static constants for special keys (`.shift`, `.control`, `.option`, `.command`, `.return`, `.escape`, `.f1`–`.f19`, etc.)
- **Compression/JPEG quality:** Configurable per connection via the local patch — `Settings(jpegQualityLevel:compressionLevel:)` (upstream hardcodes level 6)
- **Framebuffer pause:** `pauseFramebufferUpdates()` / `resumeFramebufferUpdates()` — local patch additions

## moonlight-common-c API Quick Reference

- **Session:** `LiStartConnection()` / `LiStopConnection()` — takes `SERVER_INFORMATION`, `STREAM_CONFIGURATION`, and callback structs
- **Callbacks:** `CONNECTION_LISTENER_CALLBACKS` (stage/connection events), `DECODER_RENDERER_CALLBACKS` (video), `AUDIO_RENDERER_CALLBACKS` (audio)
- **Video callback:** `drSubmitDecodeUnit(DECODE_UNIT*)` — linked list of `LENTRY` buffers containing Annex B H.264/HEVC NAL units or AV1 OBUs
- **Audio callback:** `arDecodeAndPlaySample(sampleData, sampleLength)` — Opus-encoded audio packets
- **Mouse:** `LiSendMouseMoveEvent(deltaX, deltaY)`, `LiSendMousePositionEvent(x, y, refWidth, refHeight)`, `LiSendMouseButtonEvent(action, button)`, `LiSendScrollEvent(direction)`
- **Keyboard:** `LiSendKeyboardEvent(keyAction, keyCode, modifiers)` — uses Windows VK codes, actions `KEY_ACTION_DOWN` (0x0801) / `KEY_ACTION_UP` (0x0802)
- **Gamepad:** `LiSendMultiControllerEvent(controllerNumber, activeGamepadMask, buttonFlags, leftTrigger, rightTrigger, leftStickX, leftStickY, rightStickX, rightStickY)`
- **Stats:** `LiGetEstimatedRttInfo()` for network RTT; frame counts and decode timing tracked in `MoonlightVideoRenderer`
- **HDR:** `LiGetHdrMetadata(PSS_HDR_METADATA)` — retrieves mastering display and content light level info; `LiRequestIdrFrame()` — requests key frame after HDR mode change
- **Stage names:** STAGE_RTSP_HANDSHAKE, STAGE_CONTROL_STREAM, STAGE_VIDEO_STREAM, STAGE_AUDIO_STREAM, STAGE_INPUT_STREAM — surfaced via `LiGetStageName()`
