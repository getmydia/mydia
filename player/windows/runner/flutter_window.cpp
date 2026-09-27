#include "flutter_window.h"

#include <flutter_windows.h>
#include <windowsx.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;

    case WM_NCHITTEST: {
      DWORD style = GetWindowLong(hwnd, GWL_STYLE);
      if ((style & WS_MAXIMIZEBOX) == 0 || IsIconic(hwnd)) {
        break;
      }

      POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ScreenToClient(hwnd, &pt);

      RECT client_rect;
      GetClientRect(hwnd, &client_rect);

      HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
      double scale = dpi > 0 ? (dpi / 96.0) : 1.0;

      int button_width = static_cast<int>(46 * scale);
      int button_height = static_cast<int>(40 * scale);

      // Maximize button is adjacent to the close button on the right edge:
      int max_left = client_rect.right - 2 * button_width;
      int max_right = client_rect.right - button_width;

      if (pt.x >= max_left && pt.x < max_right && pt.y >= 0 &&
          pt.y < button_height) {
        return HTMAXBUTTON;
      }
      break;
    }

    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONUP: {
      if (wparam == HTMAXBUTTON) {
        return DefWindowProc(hwnd, message, wparam, lparam);
      }
      break;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
