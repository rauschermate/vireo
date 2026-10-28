use tauri::{AppHandle, WebviewWindow};

/// The dot in the close button that marks unsaved edits.
#[tauri::command]
pub fn set_document_edited(window: WebviewWindow, edited: bool) {
    with_ns_window(&window, move |ns| ns.setDocumentEdited(edited));
}

/// The proxy icon in the title bar, which Finder can drag.
#[tauri::command]
pub fn set_represented_file(window: WebviewWindow, path: Option<String>) {
    with_ns_window(&window, move |ns| {
        let name = objc2_foundation::NSString::from_str(path.as_deref().unwrap_or(""));
        ns.setRepresentedFilename(&name);
    });
}

#[tauri::command]
pub fn quit_app(app: AppHandle) {
    app.exit(0);
}

#[cfg(target_os = "macos")]
fn with_ns_window(window: &WebviewWindow, f: impl FnOnce(&objc2_app_kit::NSWindow) + Send + 'static) {
    let w = window.clone();
    let _ = window.run_on_main_thread(move || {
        if let Ok(ptr) = w.ns_window() {
            // SAFETY: Tauri hands out the live NSWindow, and AppKit is only
            // touched here on the main thread.
            let ns = unsafe { &*(ptr as *const objc2_app_kit::NSWindow) };
            f(ns);
        }
    });
}

#[cfg(not(target_os = "macos"))]
fn with_ns_window(_window: &WebviewWindow, _f: impl FnOnce(&()) + Send + 'static) {}
