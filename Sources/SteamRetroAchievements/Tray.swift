#if os(Windows)
import Foundation
import Synchronization
import WinSDK

/// The notification-area icon: shows the app is running, and its menu has the status and Quit.
/// Runs its own Win32 message loop on a background thread, so the main actor keeps serving Steam.
// shortcut: the icon isn't re-added if Explorer restarts (TaskbarCreated); upgrade if people lose it
enum Tray {
    static let status = Mutex("Starting")
    static let callbackMessage = UINT(WM_APP + 1)
    static let quitCommand = 1

    static func start() {
        Thread.detachNewThread { run() }
    }

    private static func run() {
        let instance = GetModuleHandleW(nil)
        "SteamRetroAchievementsTray".withCString(encodedAs: UTF16.self) { className in
            var wc = WNDCLASSW()
            wc.lpfnWndProc = { hwnd, msg, wParam, lParam in Tray.handle(hwnd, msg, wParam, lParam) }
            wc.hInstance = instance
            wc.lpszClassName = className
            RegisterClassW(&wc)
            // A message-only window: it never shows, it only receives the icon's clicks.
            let hwnd = CreateWindowExW(0, className, nil, 0, 0, 0, 0, 0, HWND(bitPattern: -3), nil, instance, nil)

            var nid = notifyData(hwnd)
            nid.uFlags = UINT(NIF_ICON | NIF_MESSAGE | NIF_TIP)
            nid.uCallbackMessage = callbackMessage
            nid.hIcon = LoadIconW(instance, UnsafePointer<WCHAR>(bitPattern: 1))  // icon resource 1, from Resources/AppIcon.rc
            withUnsafeMutableBytes(of: &nid.szTip) { tip in
                let text = Array("Steam RetroAchievements".utf16.prefix(127))
                tip.bindMemory(to: WCHAR.self).baseAddress!.update(from: text, count: text.count)
            }
            Shell_NotifyIconW(DWORD(NIM_ADD), &nid)

            var msg = MSG()
            while GetMessageW(&msg, nil, 0, 0) {  // Swift imports BOOL as a Bool, so -1 (error) also continues
                TranslateMessage(&msg)
                DispatchMessageW(&msg)
            }
        }
    }

    private static func notifyData(_ hwnd: HWND?) -> NOTIFYICONDATAW {
        var nid = NOTIFYICONDATAW()
        nid.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        nid.hWnd = hwnd
        nid.uID = 1
        return nid
    }

    private static func handle(_ hwnd: HWND?, _ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
        if msg == UINT(WM_COMMAND), Int(wParam & 0xFFFF) == quitCommand {
            var nid = notifyData(hwnd)
            Shell_NotifyIconW(DWORD(NIM_DELETE), &nid)
            exit(0)
        }
        guard msg == callbackMessage else { return DefWindowProcW(hwnd, msg, wParam, lParam) }
        let mouse = UINT(lParam & 0xFFFF)
        if mouse == UINT(WM_RBUTTONUP) || mouse == UINT(WM_LBUTTONUP) { showMenu(hwnd) }
        return 0
    }

    private static func showMenu(_ hwnd: HWND?) {
        let menu = CreatePopupMenu()
        status.withLock { $0 }.withCString(encodedAs: UTF16.self) { _ = AppendMenuW(menu, UINT(MF_STRING | MF_GRAYED), 0, $0) }
        _ = AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
        "Quit Steam RetroAchievements".withCString(encodedAs: UTF16.self) { _ = AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(quitCommand), $0) }
        var point = POINT()
        GetCursorPos(&point)
        SetForegroundWindow(hwnd)  // otherwise the menu doesn't close when clicking elsewhere
        // The chosen item arrives as WM_COMMAND (TPM_RETURNCMD's id would be lost: Swift imports the BOOL result as a Bool).
        TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON), point.x, point.y, 0, hwnd, nil)
        DestroyMenu(menu)
    }
}
#endif
