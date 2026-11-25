use parking_lot::Mutex;

/// Activation can arrive before the webview has installed its listeners.
#[derive(Default)]
pub struct OpenRequests(Mutex<Vec<String>>);

#[tauri::command]
pub fn take_open_files(requests: tauri::State<'_, OpenRequests>) -> Vec<String> {
    std::mem::take(&mut *requests.0.lock())
}

#[cfg(windows)]
pub fn queue_open_files(
    app: &tauri::AppHandle,
    args: impl IntoIterator<Item = impl AsRef<std::path::Path>>,
    cwd: &std::path::Path,
) {
    use tauri::{Emitter, Manager};

    let paths: Vec<String> = args
        .into_iter()
        .map(|arg| cwd.join(arg.as_ref()))
        // The single-instance callback runs on the window thread. Let mpv
        // validate the path so network shares cannot block activation.
        .filter(|path| path.is_absolute() && path.file_name().is_some())
        .filter_map(|path| path.into_os_string().into_string().ok())
        .collect();
    if !paths.is_empty() {
        app.state::<OpenRequests>().0.lock().extend(paths);
        let _ = app.emit("system-open-files", ());
    }
}

#[tauri::command]
pub fn open_default_apps() -> Result<(), String> {
    #[cfg(windows)]
    {
        tauri_plugin_opener::open_url(
            "ms-settings:defaultapps?registeredAppMachine=BrushLLM%20Player",
            None::<&str>,
        )
        .map_err(|error| error.to_string())
    }
    #[cfg(not(windows))]
    Err("Windows Default Apps is unavailable on this platform".to_string())
}
