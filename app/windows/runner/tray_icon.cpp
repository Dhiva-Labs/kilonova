#include "tray_icon.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include "resource.h"

namespace {

constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayId = 1;
constexpr UINT kMenuOpen = 1;
constexpr UINT kMenuQuit = 2;

std::wstring Utf16FromUtf8(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         text.data(), int(text.size()),
                                         nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring out(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                      int(text.size()), out.data(), length);
  return out;
}

// Reads a string argument from the "show" call's map, if present.
void ReadString(const flutter::EncodableMap& args, const char* key,
                std::wstring* out) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) {
    return;
  }
  if (const auto* value = std::get_if<std::string>(&it->second)) {
    *out = Utf16FromUtf8(*value);
  }
}

}  // namespace

TrayIcon::TrayIcon(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window),
      taskbar_created_(RegisterWindowMessage(L"TaskbarCreated")) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "kilonova/tray",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "show") {
          if (const auto* args =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            ReadString(*args, "tooltip", &tooltip_);
            ReadString(*args, "open", &open_label_);
            ReadString(*args, "quit", &quit_label_);
          }
          Show();
          result->Success();
        } else if (call.method_name() == "hide") {
          Hide();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

TrayIcon::~TrayIcon() {
  Hide();
  channel_ = nullptr;
}

void TrayIcon::Show() {
  NOTIFYICONDATA data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kTrayId;
  data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcsncpy_s(data.szTip, tooltip_.c_str(), _TRUNCATE);
  Shell_NotifyIcon(shown_ ? NIM_MODIFY : NIM_ADD, &data);
  shown_ = true;
}

void TrayIcon::Hide() {
  if (!shown_) {
    return;
  }
  NOTIFYICONDATA data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kTrayId;
  Shell_NotifyIcon(NIM_DELETE, &data);
  shown_ = false;
}

void TrayIcon::ShowMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) {
    return;
  }
  AppendMenu(menu, MF_STRING, kMenuOpen, open_label_.c_str());
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING, kMenuQuit, quit_label_.c_str());
  POINT cursor;
  GetCursorPos(&cursor);
  // Without this the menu does not close when the owner clicks elsewhere.
  SetForegroundWindow(window_);
  const UINT chosen =
      TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
                     cursor.x, cursor.y, 0, window_, nullptr);
  DestroyMenu(menu);
  if (chosen == kMenuOpen) {
    channel_->InvokeMethod("open", nullptr);
  } else if (chosen == kMenuQuit) {
    channel_->InvokeMethod("quit", nullptr);
  }
}

bool TrayIcon::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == taskbar_created_) {
    if (shown_) {
      shown_ = false;
      Show();
    }
    return false;
  }
  if (message != kTrayMessage || wparam != kTrayId) {
    return false;
  }
  switch (LOWORD(lparam)) {
    case WM_LBUTTONUP:
      channel_->InvokeMethod("open", nullptr);
      break;
    case WM_RBUTTONUP:
    case WM_CONTEXTMENU:
      ShowMenu();
      break;
  }
  return true;
}
