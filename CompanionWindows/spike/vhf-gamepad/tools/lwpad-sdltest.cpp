// lwpad-sdltest: checks the virtual pads through SDL3, the library most PC
// games and Steam's own input stack are built on.
//
//   lwpad-sdltest xbox        Xbox Series pad: SDL type, buttons/axes, rumble
//   lwpad-sdltest dualsense   DualSense: recognised as PS5, gyro round trip, rumble, lightbar
//
// Output lines are PASS/FAIL/INFO like lwpad-test.

#include <SDL3/SDL.h>

#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <functional>
#include <string>

#include "lwpad_client.h"

namespace {

int g_failures = 0;

void line(const char *tag, const char *name, const char *fmt, va_list args) {
  std::printf("%s %s ", tag, name);
  std::vprintf(fmt, args);
  std::printf("\n");
  std::fflush(stdout);
}
void pass(const char *name, const char *fmt, ...) {
  va_list a;
  va_start(a, fmt);
  line("PASS", name, fmt, a);
  va_end(a);
}
void fail(const char *name, const char *fmt, ...) {
  ++g_failures;
  va_list a;
  va_start(a, fmt);
  line("FAIL", name, fmt, a);
  va_end(a);
}
void info(const char *name, const char *fmt, ...) {
  va_list a;
  va_start(a, fmt);
  line("INFO", name, fmt, a);
  va_end(a);
}

bool wait_for(int timeout_ms, const std::function<bool()> &done) {
  const Uint64 start = SDL_GetTicks();
  while (SDL_GetTicks() - start < static_cast<Uint64>(timeout_ms)) {
    SDL_PumpEvents();
    SDL_UpdateGamepads();
    if (done()) return true;
    SDL_Delay(2);
  }
  return done();
}

const char *type_name(SDL_GamepadType t) {
  switch (t) {
    case SDL_GAMEPAD_TYPE_XBOX360: return "XBOX360";
    case SDL_GAMEPAD_TYPE_XBOXONE: return "XBOXONE";
    case SDL_GAMEPAD_TYPE_PS4: return "PS4";
    case SDL_GAMEPAD_TYPE_PS5: return "PS5";
    case SDL_GAMEPAD_TYPE_STANDARD: return "STANDARD";
    default: return "other";
  }
}

// SDL's GUID records which of its backends found the pad (byte 14):
// 'h' HIDAPI (SDL talks HID itself), 'x' XInput, 'w' Windows.Gaming.Input,
// 'r' Raw Input, 0 DirectInput.
char backend(SDL_JoystickID id) {
  const SDL_GUID guid = SDL_GetJoystickGUIDForID(id);
  return static_cast<char>(guid.data[14] ? guid.data[14] : 'd');
}

// Waits for a gamepad with the given VID/PID that wasn't there before.
SDL_Gamepad *open_new_gamepad(Uint16 vid, Uint16 pid, int timeout_ms) {
  SDL_Gamepad *found = nullptr;
  wait_for(timeout_ms, [&] {
    int count = 0;
    SDL_JoystickID *ids = SDL_GetGamepads(&count);
    for (int i = 0; ids && i < count && !found; ++i) {
      if (SDL_GetGamepadVendorForID(ids[i]) == vid && SDL_GetGamepadProductForID(ids[i]) == pid) {
        found = SDL_OpenGamepad(ids[i]);
      }
    }
    SDL_free(ids);
    return found != nullptr;
  });
  return found;
}

void drain(lwpad_client &client) {
  lvg::feedback_event ev {};
  while (client.poll_feedback(0, &ev)) {
  }
}

int test_xbox(lwpad_client &client) {
  if (!client.create(0, lvg::profile::xbox_series)) {
    fail("create", "error=%lu", client.last_error);
    return 1;
  }
  client.input(0, 0);
  SDL_Gamepad *pad = open_new_gamepad(0x045E, 0x0B12, 5000);
  if (!pad) {
    fail("sdl-xbox", "no SDL gamepad with 045E:0B12 within 5 s");
    return 1;
  }
  const SDL_JoystickID id = SDL_GetGamepadID(pad);
  const SDL_GamepadType type = SDL_GetGamepadType(pad);
  (type == SDL_GAMEPAD_TYPE_XBOXONE ? pass : fail)("sdl-xbox-type", "name='%s' type=%s backend=%c",
                                                   SDL_GetGamepadName(pad), type_name(type), backend(id));

  client.input(0, lvg::south | lvg::north, 32767, -32768, 0, 0, 255, 0);
  const bool ok = wait_for(1000, [&] {
    return SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_SOUTH) && SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_NORTH) &&
           SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTX) > 32000 &&
           SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTY) > 32000 &&  // SDL's Y is positive-down
           SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER) > 32000;
  });
  (ok ? pass : fail)("sdl-xbox-input", "A=%d Y=%d LX=%d LY=%d LT=%d", SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_SOUTH),
                     SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_NORTH), SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTX),
                     SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTY),
                     SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER));

  drain(client);
  SDL_RumbleGamepad(pad, 0x4000, 0xC000, 1000);
  lvg::feedback_event ev {};
  lvg::xbox_rumble_feedback fb {};
  const bool got = wait_for(1000, [&] {
    if (!client.poll_feedback(0, &ev)) return false;
    std::memcpy(&fb, ev.payload, sizeof(fb));
    return ev.type == lvg::feedback_type::xbox_rumble && fb.high_frequency > 0x8000 && fb.low_frequency > 0x2000;
  });
  (got ? pass : fail)("sdl-xbox-rumble", "driver got low=%u high=%u", fb.low_frequency, fb.high_frequency);
  SDL_CloseGamepad(pad);
  client.destroy(0);
  return 0;
}

int test_dualsense(lwpad_client &client) {
  if (!client.create(0, lvg::profile::dualsense)) {
    fail("create", "error=%lu", client.last_error);
    return 1;
  }
  client.input(0, 0);
  SDL_Gamepad *pad = open_new_gamepad(0x054C, 0x0CE6, 5000);
  if (!pad) {
    fail("sdl-ds5", "no SDL gamepad with 054C:0CE6 within 5 s");
    return 1;
  }
  const SDL_JoystickID id = SDL_GetGamepadID(pad);
  const SDL_GamepadType type = SDL_GetGamepadType(pad);
  (type == SDL_GAMEPAD_TYPE_PS5 ? pass : fail)("sdl-ds5-type", "name='%s' type=%s backend=%c", SDL_GetGamepadName(pad),
                                               type_name(type), backend(id));

  client.input(0, lvg::east | lvg::touchpad, -32768, 0, 0, 32767, 0, 255);
  const bool ok = wait_for(1000, [&] {
    return SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_EAST) && SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTX) < -32000 &&
           SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHTY) < -32000 &&
           SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) > 32000;
  });
  (ok ? pass : fail)("sdl-ds5-input", "Circle=%d touchpad-click=%d LX=%d RY=%d RT=%d",
                     SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_EAST),
                     SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_TOUCHPAD),
                     SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTX), SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHTY),
                     SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER));

  // Gyro: 90 deg/s about one axis at a time should read ~pi/2 rad/s in SDL.
  if (!SDL_GamepadHasSensor(pad, SDL_SENSOR_GYRO)) {
    fail("sdl-ds5-gyro", "SDL reports no gyro");
  } else {
    SDL_SetGamepadSensorEnabled(pad, SDL_SENSOR_GYRO, true);
    SDL_SetGamepadSensorEnabled(pad, SDL_SENSOR_ACCEL, true);
    // Each driver axis must land on exactly one SDL axis (others ~0), and the
    // three must land on three different SDL axes.
    int mapped[3] = {-1, -1, -1};
    for (int axis = 0; axis < 3; ++axis) {
      std::int32_t v[3] = {0, 0, 0};
      v[axis] = 90000;
      float data[3] = {};
      // Start from rest, so a reading left over from the previous axis can't pass.
      wait_for(1500, [&] {
        client.motion(0, lvg::motion_kind::gyroscope, 0, 0, 0);
        client.input(0, 0);
        SDL_GetGamepadSensorData(pad, SDL_SENSOR_GYRO, data, 3);
        return std::fabs(data[0]) + std::fabs(data[1]) + std::fabs(data[2]) < 0.05f;
      });
      const bool got = wait_for(1500, [&] {
        client.motion(0, lvg::motion_kind::gyroscope, v[0], v[1], v[2]);
        client.input(0, 0);
        SDL_GetGamepadSensorData(pad, SDL_SENSOR_GYRO, data, 3);
        int hits = 0, zeros = 0;
        for (int i = 0; i < 3; ++i) {
          if (std::fabs(std::fabs(data[i]) - 1.5708f) < 0.16f) {
            ++hits;
            mapped[axis] = i;
          } else if (std::fabs(data[i]) < 0.05f) {
            ++zeros;
          }
        }
        return hits == 1 && zeros == 2;
      });
      (got ? pass : fail)("sdl-ds5-gyro", "driver axis %d at 90 deg/s -> SDL rad/s [%.3f %.3f %.3f] (SDL axis %d)", axis,
                          data[0], data[1], data[2], mapped[axis]);
    }
    const bool distinct = mapped[0] >= 0 && mapped[1] >= 0 && mapped[2] >= 0 && mapped[0] != mapped[1] &&
                          mapped[1] != mapped[2] && mapped[0] != mapped[2];
    (distinct ? pass : fail)("sdl-ds5-gyro-axes", "driver x,y,z -> SDL axes %d,%d,%d", mapped[0], mapped[1], mapped[2]);
    client.motion(0, lvg::motion_kind::gyroscope, 0, 0, 0);
    float accel[3] = {};
    wait_for(300, [&] {
      client.input(0, 0);
      SDL_GetGamepadSensorData(pad, SDL_SENSOR_ACCEL, accel, 3);
      return false;
    });
    info("sdl-ds5-accel", "at rest m/s^2 [%.2f %.2f %.2f] (expect ~9.8 on one axis)", accel[0], accel[1], accel[2]);
  }

  drain(client);
  SDL_RumbleGamepad(pad, 0xFFFF, 0x8000, 1000);
  lvg::feedback_event ev {};
  lvg::playstation_output_feedback fb {};
  bool got = wait_for(1000, [&] {
    if (!client.poll_feedback(0, &ev)) return false;
    std::memcpy(&fb, ev.payload, sizeof(fb));
    return ev.type == lvg::feedback_type::playstation_output && fb.low_frequency > 0xF000 && fb.high_frequency > 0x7000;
  });
  (got ? pass : fail)("sdl-ds5-rumble", "driver got low=%u high=%u", fb.low_frequency, fb.high_frequency);

  drain(client);
  SDL_SetGamepadLED(pad, 255, 0, 128);
  got = wait_for(1000, [&] {
    if (!client.poll_feedback(0, &ev)) return false;
    std::memcpy(&fb, ev.payload, sizeof(fb));
    return (fb.valid & lvg::ps_output_lightbar_valid) && fb.red == 255 && fb.green == 0 && fb.blue == 128;
  });
  (got ? pass : fail)("sdl-ds5-lightbar", "driver got rgb=%u,%u,%u valid=0x%x", fb.red, fb.green, fb.blue, fb.valid);

  SDL_CloseGamepad(pad);
  client.destroy(0);
  return 0;
}

}  // namespace

int main(int argc, char **argv) {
  const std::string which = argc > 1 ? argv[1] : "";
  if (which != "xbox" && which != "dualsense") {
    std::fprintf(stderr, "usage: lwpad-sdltest xbox|dualsense\n");
    return 2;
  }
  if (!SDL_Init(SDL_INIT_GAMEPAD)) {
    std::printf("FAIL sdl-init %s\n", SDL_GetError());
    return 1;
  }
  info("sdl", "version %d.%d.%d", SDL_MAJOR_VERSION, SDL_MINOR_VERSION, SDL_MICRO_VERSION);
  lwpad_client client;
  if (!client.open()) {
    std::printf("FAIL open-driver error=%lu\n", client.last_error);
    return 1;
  }
  which == "xbox" ? test_xbox(client) : test_dualsense(client);
  SDL_Quit();
  return g_failures ? 1 : 0;
}
