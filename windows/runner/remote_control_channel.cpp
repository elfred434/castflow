#include "remote_control_channel.h"

#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResult;

const EncodableValue* FindValue(const EncodableMap& map, const char* key) {
  const auto found = map.find(EncodableValue(key));
  return found == map.end() ? nullptr : &found->second;
}

double NumberValue(const EncodableValue* value, double fallback = 0.0) {
  if (value == nullptr) return fallback;
  if (const auto number = std::get_if<double>(value)) return *number;
  if (const auto number = std::get_if<int32_t>(value)) return *number;
  if (const auto number = std::get_if<int64_t>(value)) {
    return static_cast<double>(*number);
  }
  return fallback;
}

std::string StringValue(const EncodableValue* value) {
  if (value == nullptr) return {};
  const auto text = std::get_if<std::string>(value);
  return text == nullptr ? std::string() : *text;
}

void Win32Error(std::unique_ptr<MethodResult<EncodableValue>>& result,
                const char* code, const char* message) {
  result->Error(code, message,
                EncodableValue(static_cast<int64_t>(GetLastError())));
}

bool ReadArguments(const MethodCall<EncodableValue>& call,
                   const EncodableMap** arguments,
                   std::unique_ptr<MethodResult<EncodableValue>>& result) {
  if (call.arguments() == nullptr) {
    result->Error("BAD_ARGUMENTS", "Arguments manquants");
    return false;
  }
  *arguments = std::get_if<EncodableMap>(call.arguments());
  if (*arguments == nullptr) {
    result->Error("BAD_ARGUMENTS", "Arguments invalides");
    return false;
  }
  return true;
}

void CaptureFrame(const MethodCall<EncodableValue>& call,
                  std::unique_ptr<MethodResult<EncodableValue>> result) {
  const EncodableMap* arguments = nullptr;
  if (!ReadArguments(call, &arguments, result)) return;

  const int max_width = std::clamp(
      static_cast<int>(NumberValue(FindValue(*arguments, "maxWidth"), 1280)),
      320, 3840);
  const int max_height = std::clamp(
      static_cast<int>(NumberValue(FindValue(*arguments, "maxHeight"), 720)),
      240, 2160);
  const int source_x = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int source_y = GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int source_width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int source_height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (source_width <= 0 || source_height <= 0) {
    result->Error("NO_DISPLAY", "Aucun écran Windows disponible");
    return;
  }

  const double scale = std::min(
      1.0, std::min(static_cast<double>(max_width) / source_width,
                    static_cast<double>(max_height) / source_height));
  const int width = std::max(1, static_cast<int>(std::round(source_width * scale)));
  const int height =
      std::max(1, static_cast<int>(std::round(source_height * scale)));

  HDC screen_dc = GetDC(nullptr);
  if (screen_dc == nullptr) {
    Win32Error(result, "CAPTURE_DC", "Contexte écran Windows indisponible");
    return;
  }
  HDC memory_dc = CreateCompatibleDC(screen_dc);
  if (memory_dc == nullptr) {
    ReleaseDC(nullptr, screen_dc);
    Win32Error(result, "CAPTURE_DC", "Contexte mémoire Windows indisponible");
    return;
  }

  BITMAPINFO bitmap_info{};
  bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap_info.bmiHeader.biWidth = width;
  bitmap_info.bmiHeader.biHeight = -height;
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;
  bitmap_info.bmiHeader.biCompression = BI_RGB;
  void* bitmap_bits = nullptr;
  HBITMAP bitmap = CreateDIBSection(memory_dc, &bitmap_info, DIB_RGB_COLORS,
                                    &bitmap_bits, nullptr, 0);
  if (bitmap == nullptr || bitmap_bits == nullptr) {
    DeleteDC(memory_dc);
    ReleaseDC(nullptr, screen_dc);
    Win32Error(result, "CAPTURE_BITMAP", "Bitmap Windows indisponible");
    return;
  }

  HGDIOBJ previous = SelectObject(memory_dc, bitmap);
  SetStretchBltMode(memory_dc, HALFTONE);
  SetBrushOrgEx(memory_dc, 0, 0, nullptr);
  const BOOL copied = StretchBlt(
      memory_dc, 0, 0, width, height, screen_dc, source_x, source_y,
      source_width, source_height, SRCCOPY | CAPTUREBLT);
  if (copied != FALSE) GdiFlush();

  const size_t byte_count = static_cast<size_t>(width) * height * 4;
  std::vector<uint8_t> pixels;
  if (copied != FALSE) {
    pixels.resize(byte_count);
    std::memcpy(pixels.data(), bitmap_bits, byte_count);
  }

  SelectObject(memory_dc, previous);
  DeleteObject(bitmap);
  DeleteDC(memory_dc);
  ReleaseDC(nullptr, screen_dc);

  if (copied == FALSE) {
    Win32Error(result, "CAPTURE_FAILED", "Capture de l’écran Windows échouée");
    return;
  }

  EncodableMap response;
  response[EncodableValue("width")] = EncodableValue(width);
  response[EncodableValue("height")] = EncodableValue(height);
  response[EncodableValue("stride")] = EncodableValue(width * 4);
  response[EncodableValue("pixels")] = EncodableValue(pixels);
  result->Success(EncodableValue(response));
}

DWORD PointerButtonFlag(const std::string& kind, int buttons) {
  const bool down = kind == "pointerDown";
  if ((buttons & 2) != 0) return down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
  if ((buttons & 4) != 0) {
    return down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
  }
  return down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
}

WORD VirtualKeyFor(const std::string& key) {
  if (key == "Enter") return VK_RETURN;
  if (key == "Escape") return VK_ESCAPE;
  if (key == "Backspace") return VK_BACK;
  if (key == "Tab") return VK_TAB;
  if (key == "Space") return VK_SPACE;
  if (key == "ArrowLeft") return VK_LEFT;
  if (key == "ArrowRight") return VK_RIGHT;
  if (key == "ArrowUp") return VK_UP;
  if (key == "ArrowDown") return VK_DOWN;
  if (key == "Delete") return VK_DELETE;
  if (key == "Home") return VK_HOME;
  if (key == "End") return VK_END;
  if (key == "PageUp") return VK_PRIOR;
  if (key == "PageDown") return VK_NEXT;
  if (key == "Shift") return VK_SHIFT;
  if (key == "Control") return VK_CONTROL;
  if (key == "Alt") return VK_MENU;
  if (key.size() == 4 && key.rfind("Key", 0) == 0 && key[3] >= 'A' &&
      key[3] <= 'Z') {
    return static_cast<WORD>(key[3]);
  }
  if (key.size() == 6 && key.rfind("Digit", 0) == 0 && key[5] >= '0' &&
      key[5] <= '9') {
    return static_cast<WORD>(key[5]);
  }
  if (key.size() >= 2 && key[0] == 'F') {
    const int number = std::atoi(key.c_str() + 1);
    if (number >= 1 && number <= 24) {
      return static_cast<WORD>(VK_F1 + number - 1);
    }
  }
  return 0;
}

bool SendInputs(std::vector<INPUT>& inputs) {
  if (inputs.empty()) return false;
  const UINT sent = SendInput(static_cast<UINT>(inputs.size()), inputs.data(),
                              sizeof(INPUT));
  return sent == inputs.size();
}

bool InjectPointer(const EncodableMap& arguments, const std::string& kind) {
  const double x = NumberValue(FindValue(arguments, "x"), -1.0);
  const double y = NumberValue(FindValue(arguments, "y"), -1.0);
  if (x < 0.0 || x > 1.0 || y < 0.0 || y > 1.0) return false;

  INPUT movement{};
  movement.type = INPUT_MOUSE;
  movement.mi.dx = static_cast<LONG>(std::round(x * 65535.0));
  movement.mi.dy = static_cast<LONG>(std::round(y * 65535.0));
  movement.mi.dwFlags =
      MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
  std::vector<INPUT> inputs{movement};
  if (kind != "pointerMove") {
    INPUT button{};
    button.type = INPUT_MOUSE;
    button.mi.dwFlags = PointerButtonFlag(
        kind, static_cast<int>(NumberValue(FindValue(arguments, "buttons"))));
    inputs.push_back(button);
  }
  return SendInputs(inputs);
}

bool InjectScroll(const EncodableMap& arguments) {
  const double raw_delta = NumberValue(FindValue(arguments, "deltaY"));
  if (!std::isfinite(raw_delta) || raw_delta == 0.0) return false;
  const LONG delta = static_cast<LONG>(
      std::clamp(std::round(raw_delta * WHEEL_DELTA), -1200.0, 1200.0));
  INPUT input{};
  input.type = INPUT_MOUSE;
  input.mi.mouseData = static_cast<DWORD>(delta);
  input.mi.dwFlags = MOUSEEVENTF_WHEEL;
  std::vector<INPUT> inputs{input};
  return SendInputs(inputs);
}

bool InjectKey(const EncodableMap& arguments, bool down) {
  const WORD key = VirtualKeyFor(StringValue(FindValue(arguments, "key")));
  if (key == 0) return false;
  INPUT input{};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = key;
  input.ki.dwFlags = down ? 0 : KEYEVENTF_KEYUP;
  std::vector<INPUT> inputs{input};
  return SendInputs(inputs);
}

bool InjectText(const EncodableMap& arguments) {
  const std::string utf8 = StringValue(FindValue(arguments, "text"));
  if (utf8.empty()) return false;
  const int utf16_length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(), static_cast<int>(utf8.size()),
      nullptr, 0);
  if (utf16_length <= 0 || utf16_length > 4096) return false;
  std::wstring utf16(static_cast<size_t>(utf16_length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                          static_cast<int>(utf8.size()), utf16.data(),
                          utf16_length) <= 0) {
    return false;
  }
  std::vector<INPUT> inputs;
  inputs.reserve(utf16.size() * 2);
  for (const wchar_t character : utf16) {
    INPUT down{};
    down.type = INPUT_KEYBOARD;
    down.ki.wScan = character;
    down.ki.dwFlags = KEYEVENTF_UNICODE;
    INPUT up = down;
    up.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
    inputs.push_back(down);
    inputs.push_back(up);
  }
  return SendInputs(inputs);
}

void InjectInput(const MethodCall<EncodableValue>& call,
                 std::unique_ptr<MethodResult<EncodableValue>> result) {
  const EncodableMap* arguments = nullptr;
  if (!ReadArguments(call, &arguments, result)) return;
  const std::string kind = StringValue(FindValue(*arguments, "kind"));
  bool injected = false;
  if (kind == "pointerDown" || kind == "pointerMove" ||
      kind == "pointerUp") {
    injected = InjectPointer(*arguments, kind);
  } else if (kind == "scroll") {
    injected = InjectScroll(*arguments);
  } else if (kind == "keyDown" || kind == "keyUp") {
    injected = InjectKey(*arguments, kind == "keyDown");
  } else if (kind == "text") {
    injected = InjectText(*arguments);
  } else {
    result->Error("UNSUPPORTED_INPUT", "Entrée Windows non supportée");
    return;
  }
  if (!injected) {
    Win32Error(result, "INPUT_REJECTED",
               "Windows a refusé l’injection de l’entrée");
    return;
  }
  result->Success(EncodableValue(true));
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterRemoteControlChannel(flutter::BinaryMessenger* messenger) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "castflow/windows_remote",
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const MethodCall<EncodableValue>& call,
         std::unique_ptr<MethodResult<EncodableValue>> result) {
        if (call.method_name() == "isAvailable") {
          result->Success(EncodableValue(true));
          return;
        }
        if (call.method_name() == "getCapabilities") {
          EncodableList values;
          values.emplace_back("screenCapture");
          values.emplace_back("pointer");
          values.emplace_back("keyboard");
          values.emplace_back("textInput");
          EncodableMap capabilities;
          capabilities[EncodableValue("values")] = EncodableValue(values);
          capabilities[EncodableValue("maxWidth")] = EncodableValue(1280);
          capabilities[EncodableValue("maxHeight")] = EncodableValue(720);
          capabilities[EncodableValue("maxFps")] = EncodableValue(15);
          capabilities[EncodableValue("codecs")] =
              EncodableValue(EncodableList{EncodableValue("bgra")});
          result->Success(EncodableValue(capabilities));
          return;
        }
        if (call.method_name() == "captureFrame") {
          CaptureFrame(call, std::move(result));
          return;
        }
        if (call.method_name() == "injectInput") {
          InjectInput(call, std::move(result));
          return;
        }
        result->NotImplemented();
      });
  return channel;
}
