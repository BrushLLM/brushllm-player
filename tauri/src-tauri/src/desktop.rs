use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use tauri::{LogicalSize, PhysicalPosition, PhysicalSize, State, WebviewWindow};

#[cfg(windows)]
mod windows_video;

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ViewingMode {
    Windowed,
    Fullscreen,
    Mini,
}

struct WindowedFrame {
    size: PhysicalSize<u32>,
    origin: PhysicalPosition<i32>,
    maximized: bool,
}

#[derive(Default)]
pub struct ViewingState(Mutex<Option<WindowedFrame>>);

fn restore_window(
    window: &WebviewWindow,
    frame: &WindowedFrame,
    on_top: bool,
) -> tauri::Result<()> {
    if window.is_maximized()? {
        window.unmaximize()?;
    }
    window.set_min_size(Some(LogicalSize::new(640, 340)))?;
    window.set_size(frame.size)?;
    window.set_position(frame.origin)?;
    window.set_always_on_top(on_top)?;
    if frame.maximized {
        window.maximize()?;
    }
    Ok(())
}

#[tauri::command]
pub fn set_viewing_mode(
    window: WebviewWindow,
    state: State<'_, ViewingState>,
    mode: ViewingMode,
    on_top: bool,
) -> Result<(), String> {
    change_viewing_mode(&window, &mut state.0.lock(), mode, on_top)
        .map_err(|error| error.to_string())
}

fn change_viewing_mode(
    window: &WebviewWindow,
    mini_frame: &mut Option<WindowedFrame>,
    mode: ViewingMode,
    on_top: bool,
) -> tauri::Result<()> {
    if matches!(mode, ViewingMode::Fullscreen) {
        if let Some(frame) = mini_frame.as_ref() {
            restore_window(window, frame, on_top)?;
            *mini_frame = None;
        }
        return window.set_fullscreen(true);
    }

    if window.is_fullscreen()? {
        window.set_fullscreen(false)?;
    }

    match mode {
        ViewingMode::Mini if mini_frame.is_none() => {
            let maximized = window.is_maximized()?;
            if maximized {
                window.unmaximize()?;
            }
            let bounds = window.inner_size().and_then(|size| {
                Ok(WindowedFrame {
                    size,
                    origin: window.outer_position()?,
                    maximized,
                })
            });
            let frame = match bounds {
                Ok(frame) => frame,
                Err(error) => {
                    if maximized {
                        let _ = window.maximize();
                    }
                    return Err(error);
                }
            };
            let resize = || {
                window.set_min_size(Some(LogicalSize::new(320, 200)))?;
                window.set_size(LogicalSize::new(420, 280))?;
                window.set_always_on_top(true)
            };
            if let Err(error) = resize() {
                if let Err(restore_error) = restore_window(window, &frame, on_top) {
                    log::warn!("Could not restore the player window: {restore_error}");
                }
                return Err(error);
            }
            *mini_frame = Some(frame);
        }
        ViewingMode::Windowed => {
            if let Some(frame) = mini_frame.as_ref() {
                restore_window(window, frame, on_top)?;
                *mini_frame = None;
            }
        }
        _ => {}
    }
    Ok(())
}

#[derive(Serialize)]
#[serde(rename_all = "lowercase")]
pub enum VideoOutput {
    #[cfg(windows)]
    Embedded,
    #[cfg(windows)]
    Detached,
    #[cfg(not(windows))]
    Headless,
}

#[derive(Deserialize)]
pub struct VideoBounds {
    #[cfg(windows)]
    left: i32,
    #[cfg(windows)]
    top: i32,
    #[cfg(windows)]
    right: i32,
    #[cfg(windows)]
    bottom: i32,
}

#[derive(Default)]
pub struct VideoSurface {
    #[cfg(windows)]
    hwnd: Option<isize>,
}

impl VideoSurface {
    #[cfg(windows)]
    pub fn create(window: &WebviewWindow) -> Result<Self, String> {
        Ok(Self {
            hwnd: Some(windows_video::create(window)?),
        })
    }

    #[cfg(windows)]
    pub fn window_id(&self) -> Option<u32> {
        // mpv's Win32 wid expects an unsigned 32-bit handle.
        self.hwnd.map(|handle| handle as u32)
    }
}

#[tauri::command]
pub fn video_output(surface: State<'_, VideoSurface>) -> VideoOutput {
    #[cfg(windows)]
    {
        if surface.window_id().is_some() {
            VideoOutput::Embedded
        } else {
            VideoOutput::Detached
        }
    }
    #[cfg(not(windows))]
    {
        let _ = surface;
        VideoOutput::Headless
    }
}

#[tauri::command]
pub fn place_video_surface(
    window: WebviewWindow,
    surface: State<'_, VideoSurface>,
    bounds: VideoBounds,
    visible: bool,
) -> Result<(), String> {
    #[cfg(windows)]
    {
        use windows::Win32::Foundation::{HWND, RECT};
        use windows::Win32::UI::WindowsAndMessaging::{
            GetClientRect, SetWindowPos, ShowWindow, HWND_TOP, SWP_HIDEWINDOW, SWP_NOACTIVATE,
            SWP_SHOWWINDOW, SW_HIDE,
        };

        let Some(handle) = surface.hwnd else {
            return Ok(());
        };
        let hwnd = HWND(handle as _);
        let parent = window.hwnd().map_err(|error| error.to_string())?;
        let mut client = RECT::default();
        unsafe { GetClientRect(HWND(parent.0), &mut client) }.map_err(|error| error.to_string())?;
        let x = bounds.left.clamp(0, client.right);
        let y = bounds.top.clamp(0, client.bottom);
        let width = bounds.right.clamp(x, client.right) - x;
        let height = bounds.bottom.clamp(y, client.bottom) - y;
        if width > 0 && height > 0 {
            let visibility = if visible {
                SWP_SHOWWINDOW
            } else {
                SWP_HIDEWINDOW
            };
            return unsafe {
                SetWindowPos(
                    hwnd,
                    HWND_TOP,
                    x,
                    y,
                    width,
                    height,
                    SWP_NOACTIVATE | visibility,
                )
            }
            .map_err(|error| error.to_string());
        }
        let _ = unsafe { ShowWindow(hwnd, SW_HIDE) };
    }
    #[cfg(not(windows))]
    let _ = (window, surface, bounds, visible);

    Ok(())
}
