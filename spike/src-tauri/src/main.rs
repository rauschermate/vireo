use std::path::PathBuf;

fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../fixtures")
}

#[tauri::command]
fn fixture_path(name: String) -> String {
    fixtures_dir().join(name).to_string_lossy().into_owned()
}

#[tauri::command]
fn read_file(path: String) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|e| e.to_string())
}

#[tauri::command]
fn bench_mode() -> bool {
    std::env::var_os("VIREO_BENCH").is_some()
}

#[tauri::command]
fn startup_file() -> Option<String> {
    std::env::var("VIREO_OPEN").ok()
}

#[tauri::command]
fn scenario() -> Option<String> {
    std::env::var("VIREO_SCENARIO").ok()
}

#[tauri::command]
fn bench_report(app: tauri::AppHandle, report: String) {
    println!("{report}");
    let out = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../results/bench-wkwebview.txt");
    let _ = std::fs::write(out, &report);
    if bench_mode() {
        app.exit(0);
    }
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![fixture_path, read_file, bench_mode, startup_file, scenario, bench_report])
        .run(tauri::generate_context!())
        .expect("failed to run the Tauri app");
}
