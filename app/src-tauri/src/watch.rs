use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::mpsc;
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter, State};

// Saves and checkouts arrive as bursts of events. Batching them keeps the
// frontend to one re-read per file per burst.
const DEBOUNCE: Duration = Duration::from_millis(120);

pub struct Watch {
    watcher: Mutex<Option<RecommendedWatcher>>,
    watched: Mutex<HashSet<(PathBuf, bool)>>,
}

pub fn start(app: AppHandle) -> Watch {
    let (tx, rx) = mpsc::channel::<PathBuf>();
    let watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        if let Ok(event) = res {
            for path in event.paths {
                let _ = tx.send(path);
            }
        }
    })
    .ok();
    std::thread::spawn(move || {
        while let Ok(first) = rx.recv() {
            let mut batch: HashSet<PathBuf> = HashSet::from([first]);
            while let Ok(next) = rx.recv_timeout(DEBOUNCE) {
                batch.insert(next);
            }
            // Our own atomic-save temp files are noise.
            let paths: Vec<String> = batch
                .into_iter()
                .filter(|p| {
                    let s = p.to_string_lossy();
                    !(s.contains(".vireo-") && s.ends_with(".tmp"))
                })
                .map(|p| p.to_string_lossy().into_owned())
                .collect();
            if !paths.is_empty() {
                let _ = app.emit("fs-change", paths);
            }
        }
    });
    Watch { watcher: Mutex::new(watcher), watched: Mutex::new(HashSet::new()) }
}

/// Watches the parent folder of each open file, and the workspace folder
/// recursively. Watching the parent instead of the file survives editors and
/// tools that save by replacing the file.
#[tauri::command]
pub fn watch_set(state: State<Watch>, files: Vec<String>, root: Option<String>) -> Result<(), String> {
    let mut wanted: HashSet<(PathBuf, bool)> = files
        .iter()
        .filter_map(|f| PathBuf::from(f).parent().map(|p| (p.to_path_buf(), false)))
        .collect();
    if let Some(root) = root {
        wanted.insert((PathBuf::from(root), true));
    }
    let mut guard = state.watcher.lock().map_err(|e| e.to_string())?;
    let Some(watcher) = guard.as_mut() else { return Ok(()) };
    let mut watched = state.watched.lock().map_err(|e| e.to_string())?;
    for gone in watched.difference(&wanted) {
        let _ = watcher.unwatch(&gone.0);
    }
    for new in wanted.difference(&watched) {
        let mode = if new.1 { RecursiveMode::Recursive } else { RecursiveMode::NonRecursive };
        let _ = watcher.watch(&new.0, mode);
    }
    *watched = wanted;
    Ok(())
}
