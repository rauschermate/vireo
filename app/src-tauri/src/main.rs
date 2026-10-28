mod bench;
mod fs;
mod prefs;
mod watch;
mod window;

use std::path::Path;
use std::sync::Mutex;
use tauri::{Emitter, Manager, State};

/// Files and folders from Finder or the command line, waiting for the page
/// to take them. A launch can deliver them before the page listens.
struct PendingOpens(Mutex<Vec<String>>);

#[tauri::command]
fn take_pending_opens(state: State<PendingOpens>) -> Vec<String> {
    std::mem::take(&mut *state.0.lock().unwrap())
}

fn main() {
    let cli: Vec<String> = std::env::args()
        .skip(1)
        .filter(|a| !a.starts_with('-'))
        .filter_map(|a| std::fs::canonicalize(&a).ok())
        .map(|p| p.to_string_lossy().into_owned())
        .collect();

    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(PendingOpens(Mutex::new(cli)))
        .setup(|app| {
            app.manage(watch::start(app.handle().clone()));
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            fs::read_text,
            fs::write_text,
            fs::scan_workspace,
            fs::create_file,
            fs::create_dir,
            fs::rename_path,
            fs::trash_path,
            fs::reveal_path,
            fs::open_in_terminal,
            fs::path_exists,
            prefs::load_prefs,
            prefs::save_prefs,
            watch::watch_set,
            window::set_document_edited,
            window::set_represented_file,
            window::quit_app,
            take_pending_opens,
            bench::fixture_path,
            bench::read_file,
            bench::bench_mode,
            bench::startup_file,
            bench::scenario,
            bench::bench_report,
        ])
        .build(tauri::generate_context!())
        .expect("failed to build the Tauri app");

    app.run(|handle, event| {
        #[cfg(target_os = "macos")]
        if let tauri::RunEvent::Opened { urls } = event {
            let paths: Vec<String> = urls
                .into_iter()
                .filter_map(|u| u.to_file_path().ok())
                .filter(|p| Path::new(p).exists())
                .map(|p| p.to_string_lossy().into_owned())
                .collect();
            handle.state::<PendingOpens>().0.lock().unwrap().extend(paths);
            let _ = handle.emit("open-files", ());
        }
    });
}
