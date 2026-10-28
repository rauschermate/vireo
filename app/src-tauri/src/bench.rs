// Commands for the dev bench page (bench.html). Not used by the app.
use std::path::PathBuf;

#[tauri::command]
pub fn fixture_path(name: String) -> String {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../fixtures").join(name).to_string_lossy().into_owned()
}

#[tauri::command]
pub fn read_file(path: String) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn bench_mode() -> bool {
    std::env::var_os("VIREO_BENCH").is_some()
}

#[tauri::command]
pub fn startup_file() -> Option<String> {
    std::env::var("VIREO_OPEN").ok()
}

#[tauri::command]
pub fn scenario() -> Option<String> {
    std::env::var("VIREO_SCENARIO").ok()
}

#[tauri::command]
pub fn bench_report(app: tauri::AppHandle, report: String) {
    println!("{report}");
    let out = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../results/bench-wkwebview.txt");
    let _ = std::fs::write(out, &report);
    if bench_mode() {
        app.exit(0);
    }
}
