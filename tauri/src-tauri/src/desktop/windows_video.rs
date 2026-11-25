use std::cell::Cell;
use tauri::{AppHandle, Emitter, Manager, WebviewWindow};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::Graphics::Gdi::ScreenToClient;
use windows::Win32::UI::Controls::WM_MOUSELEAVE;
use windows::Win32::UI::Input::KeyboardAndMouse::{TrackMouseEvent, TME_LEAVE, TRACKMOUSEEVENT};
use windows::Win32::UI::Shell::{DragAcceptFiles, DragFinish, DragQueryFileW, HDROP};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, GetParent, GetWindowLongPtrW, LoadCursorW, RegisterClassW,
    SetWindowLongPtrW, CS_DBLCLKS, GWLP_HINSTANCE, GWLP_USERDATA, HMENU, IDC_ARROW, WINDOW_EX_STYLE,
    WM_CONTEXTMENU, WM_DROPFILES, WM_LBUTTONDBLCLK, WM_MOUSEMOVE, WM_NCDESTROY, WM_SIZE, WNDCLASSW,
    WS_CHILD, WS_CLIPCHILDREN, WS_CLIPSIBLINGS,
};

struct VideoEvents {
    app: AppHandle,
    height: Cell<i32>,
    near_bottom_edge: Cell<bool>,
}

pub fn create(window: &WebviewWindow) -> Result<isize, String> {
    let parent = HWND(window.hwnd().map_err(|error| error.to_string())?.0);
    unsafe {
        let instance = HINSTANCE(GetWindowLongPtrW(parent, GWLP_HINSTANCE) as _);
        let class = WNDCLASSW {
            hInstance: instance,
            lpszClassName: w!("BrushLLMPlayerVideoSurface"),
            lpfnWndProc: Some(handle_message),
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            style: CS_DBLCLKS,
            ..Default::default()
        };
        if RegisterClassW(&class) == 0 {
            return Err(windows::core::Error::from_win32().to_string());
        }
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            class.lpszClassName,
            PCWSTR::null(),
            WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
            0,
            0,
            1,
            1,
            parent,
            HMENU::default(),
            instance,
            None,
        )
        .map_err(|error| error.to_string())?;
        // The parent window owns the child. The child owns the event target
        // until WM_NCDESTROY, including while mpv restarts its video output.
        let target = Box::into_raw(Box::new(VideoEvents {
            app: window.app_handle().clone(),
            height: Cell::new(1),
            near_bottom_edge: Cell::new(false),
        }));
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, target as isize);
        DragAcceptFiles(hwnd, true);
        Ok(hwnd.0 as isize)
    }
}

unsafe extern "system" fn handle_message(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    // mpv disables its video child in --wid mode. Its parent receives clicks
    // and shell drops in the rectangle above the webview.
    let target = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut VideoEvents;
    match message {
        WM_LBUTTONDBLCLK => {
            if let Some(target) = target.as_ref() {
                let _ = target.app.emit("video-toggle-fullscreen", ());
            }
            LRESULT(0)
        }
        WM_CONTEXTMENU => {
            if let Some(target) = target.as_ref() {
                let _ = target.app.emit("video-context-menu", context_menu_position(hwnd, lparam));
            }
            LRESULT(0)
        }
        WM_SIZE => {
            if let Some(target) = target.as_ref() {
                target.height.set((lparam.0 >> 16) as u16 as i32);
                target.near_bottom_edge.set(false);
            }
            DefWindowProcW(hwnd, message, wparam, lparam)
        }
        WM_MOUSEMOVE => {
            if let Some(target) = target.as_ref() {
                let y = (lparam.0 >> 16) as i16 as i32;
                let near = (1..=12).contains(&(target.height.get() - y));
                // Send one event on entering the edge instead of relaying mouse motion.
                if !target.near_bottom_edge.replace(near) && near {
                    let mut tracking = TRACKMOUSEEVENT {
                        cbSize: std::mem::size_of::<TRACKMOUSEEVENT>() as u32,
                        dwFlags: TME_LEAVE,
                        hwndTrack: hwnd,
                        dwHoverTime: 0,
                    };
                    let _ = TrackMouseEvent(&mut tracking);
                    let _ = target.app.emit("video-bottom-edge", ());
                }
            }
            DefWindowProcW(hwnd, message, wparam, lparam)
        }
        WM_MOUSELEAVE => {
            if let Some(target) = target.as_ref() {
                target.near_bottom_edge.set(false);
            }
            LRESULT(0)
        }
        WM_DROPFILES => {
            let drop = HDROP(wparam.0 as _);
            let count = DragQueryFileW(drop, u32::MAX, None);
            let mut paths = Vec::new();
            for index in 0..count {
                let length = DragQueryFileW(drop, index, None) as usize;
                let mut buffer = vec![0; length + 1];
                let written = DragQueryFileW(drop, index, Some(&mut buffer)) as usize;
                if let Some(path) = buffer.get(..written).filter(|path| !path.is_empty()) {
                    paths.push(String::from_utf16_lossy(path));
                }
            }
            DragFinish(drop);
            if let Some(target) = target.as_ref() {
                let _ = target.app.emit("video-files-dropped", paths);
            }
            LRESULT(0)
        }
        WM_NCDESTROY if !target.is_null() => {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            drop(Box::from_raw(target));
            DefWindowProcW(hwnd, message, wparam, lparam)
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

unsafe fn context_menu_position(hwnd: HWND, lparam: LPARAM) -> Option<[i32; 2]> {
    // Windows supplies signed screen coordinates or -1 for a keyboard request.
    if lparam.0 == -1 {
        return None;
    }
    let parent = GetParent(hwnd).ok()?;
    let mut point = POINT {
        x: lparam.0 as i16 as i32,
        y: (lparam.0 >> 16) as i16 as i32,
    };
    ScreenToClient(parent, &mut point).as_bool().then_some([point.x, point.y])
}
