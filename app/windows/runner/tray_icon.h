#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <string>

// The notification-area icon Kilonova shows while its window is hidden with
// wallets still syncing. Dart drives it over the "kilonova/tray" channel:
// "show" (with tooltip and menu labels) and "hide"; clicks come back as
// "open" and "quit".
class TrayIcon {
 public:
  TrayIcon(HWND window, flutter::BinaryMessenger* messenger);
  ~TrayIcon();

  // Handles the icon's messages sent to the window; returns true if
  // |message| was one of them.
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void Show();
  void Hide();
  void ShowMenu();

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool shown_ = false;
  std::wstring tooltip_ = L"Kilonova";
  std::wstring open_label_ = L"Open Kilonova";
  std::wstring quit_label_ = L"Quit";
  // Sent to every window when Explorer restarts; the icon must be added
  // again.
  UINT taskbar_created_;
};

#endif  // RUNNER_TRAY_ICON_H_
