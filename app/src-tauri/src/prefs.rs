use std::fs;
use tauri::{AppHandle, Manager};

fn prefs_path(app: &AppHandle) -> Result<std::path::PathBuf, String> {
    let dir = app.path().app_config_dir().map_err(|e| e.to_string())?;
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir.join("prefs.json"))
}

/// Preferences are one JSON document that the frontend owns.
#[tauri::command]
pub fn load_prefs(app: AppHandle) -> Result<String, String> {
    match fs::read_to_string(prefs_path(&app)?) {
        Ok(text) => Ok(text),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok("{}".into()),
        Err(e) => Err(e.to_string()),
    }
}

#[tauri::command]
pub fn save_prefs(app: AppHandle, json: String) -> Result<(), String> {
    let path = prefs_path(&app)?;
    crate::fs::write_text(path.to_string_lossy().into_owned(), json).map(|_| ())
}
