// A plug-in's window on Windows: a tool window owned by the game's (so it stays in front of it, and goes with it when it
// is minimised), which hides rather than closes when its close button is pressed. The plug-in's editor is a child of
// it. Its messages go through the game's own message loop, as every window on the game's thread does.

#include "plugin_window.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <algorithm>
#include <string>

namespace sr {
namespace {

const wchar_t* const kClassName = L"SoundRoomPluginWindow";

std::wstring wide(const std::string& utf8) {
    if (utf8.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), int(utf8.size()), nullptr, 0);
    std::wstring out(size_t(std::max(n, 0)), L'\0');
    if (n > 0) MultiByteToWideChar(CP_UTF8, 0, utf8.data(), int(utf8.size()), out.data(), n);
    return out;
}

LRESULT CALLBACK windowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_CLOSE) {  // its close button hides it: the plug-in, and its editor, stay
        ShowWindow(hwnd, SW_HIDE);
        return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

void registerClass() {
    static bool registered = false;
    if (registered) return;
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = windowProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
    wc.lpszClassName = kClassName;
    registered = RegisterClassExW(&wc) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
}

// The game's window: the visible top-level window of this thread that isn't one of the plug-ins'.
HWND gameWindow() {
    struct Found {
        HWND hwnd = nullptr;
    } found;
    EnumThreadWindows(
        GetCurrentThreadId(),
        [](HWND hwnd, LPARAM data) -> BOOL {
            wchar_t name[64] = {};
            GetClassNameW(hwnd, name, 64);
            if (IsWindowVisible(hwnd) && std::wstring(name) != kClassName && GetWindow(hwnd, GW_OWNER) == nullptr) {
                reinterpret_cast<Found*>(data)->hwnd = hwnd;
                return FALSE;
            }
            return TRUE;
        },
        reinterpret_cast<LPARAM>(&found));
    return found.hwnd;
}

const DWORD kStyle = WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_CLIPCHILDREN;
const DWORD kExStyle = WS_EX_TOOLWINDOW;

class WinPluginWindow final : public PluginWindow {
public:
    WinPluginWindow(int width, int height) {
        registerClass();
        RECT r{0, 0, std::max(width, 120), std::max(height, 60)};
        AdjustWindowRectEx(&r, kStyle, FALSE, kExStyle);
        hwnd_ = CreateWindowExW(kExStyle, kClassName, L"Plug-in", kStyle, CW_USEDEFAULT, CW_USEDEFAULT, r.right - r.left,
                                r.bottom - r.top, gameWindow(), nullptr, GetModuleHandleW(nullptr), nullptr);
    }

    ~WinPluginWindow() override {
        if (hwnd_) DestroyWindow(hwnd_);
    }

    bool ok() const { return hwnd_ != nullptr; }
    void* nativeView() override { return hwnd_; }

    void setContentSize(int width, int height) override {
        RECT r{0, 0, std::max(width, 60), std::max(height, 30)};
        AdjustWindowRectEx(&r, kStyle, FALSE, kExStyle);
        SetWindowPos(hwnd_, nullptr, 0, 0, r.right - r.left, r.bottom - r.top, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    void show(const std::string& title) override {
        SetWindowTextW(hwnd_, wide(title.empty() ? std::string("Plug-in") : title).c_str());
        ShowWindow(hwnd_, SW_SHOWNOACTIVATE);  // in front, leaving the keyboard with the game
    }

    void hide() override { ShowWindow(hwnd_, SW_HIDE); }
    bool visible() const override { return IsWindowVisible(hwnd_) != FALSE; }

    double scale() const override {
        HDC dc = GetDC(hwnd_);
        const double dpi = dc ? GetDeviceCaps(dc, LOGPIXELSX) : 96.0;
        if (dc) ReleaseDC(hwnd_, dc);
        return dpi / 96.0;
    }

    void place(double above_bottom) override {
        HWND game = GetWindow(hwnd_, GW_OWNER);
        if (!game) return;
        RECT content{}, mine{};
        GetClientRect(game, &content);
        MapWindowPoints(game, nullptr, reinterpret_cast<POINT*>(&content), 2);
        GetWindowRect(hwnd_, &mine);
        const int w = mine.right - mine.left, h = mine.bottom - mine.top;
        int x = (content.left + content.right) / 2 - w / 2;
        int y = content.bottom - int((content.bottom - content.top) * std::clamp(above_bottom, 0.0, 1.0)) - h;
        MONITORINFO monitor{};
        monitor.cbSize = sizeof(monitor);
        if (GetMonitorInfoW(MonitorFromWindow(game, MONITOR_DEFAULTTONEAREST), &monitor)) {
            const RECT& work = monitor.rcWork;
            x = std::max<int>(std::min<int>(x, work.right - w), work.left);
            y = std::max<int>(std::min<int>(y, work.bottom - h), work.top);
        }
        SetWindowPos(hwnd_, nullptr, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

private:
    HWND hwnd_ = nullptr;
};

}  // namespace

std::unique_ptr<PluginWindow> PluginWindow::make(int width, int height) {
    auto window = std::make_unique<WinPluginWindow>(width, height);
    if (!window->ok()) return nullptr;
    return window;
}

const char* PluginWindow::platformType() { return "HWND"; }

}  // namespace sr
