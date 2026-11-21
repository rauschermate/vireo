use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::{AppHandle, Emitter, State};

// Saves and checkouts arrive as bursts of events. Batching them keeps the
// frontend to one re-read per file per burst.
const DEBOUNCE: Duration = Duration::from_millis(120);

/// A watched folder: the path the app knows it by, and where it really is.
#[derive(Clone, PartialEq, Eq, Hash)]
struct Watched {
    path: PathBuf,
    real: PathBuf,
    recursive: bool,
}

pub struct Watch {
    watcher: Mutex<Option<RecommendedWatcher>>,
    watched: Arc<Mutex<HashSet<Watched>>>,
}

// FSEvents reports resolved paths: /var/folders/… arrives as
// /private/var/folders/…, and a symlinked folder as its target. Map each
// event back to the path the app opened, or the tab never hears about it.
fn to_app_path(event: PathBuf, watched: &HashSet<Watched>) -> PathBuf {
    for w in watched {
        if w.real != w.path {
            if let Ok(rest) = event.strip_prefix(&w.real) {
                return w.path.join(rest);
            }
        }
    }
    event
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
    let watched: Arc<Mutex<HashSet<Watched>>> = Arc::default();
    let shared = watched.clone();
    std::thread::spawn(move || {
        while let Ok(first) = rx.recv() {
            let mut batch: HashSet<PathBuf> = HashSet::from([first]);
            while let Ok(next) = rx.recv_timeout(DEBOUNCE) {
                batch.insert(next);
            }
            let known = shared.lock().map(|w| w.clone()).unwrap_or_default();
            // Our own atomic-save temp files are noise.
            let paths: Vec<String> = batch
                .into_iter()
                .filter(|p| {
                    let s = p.to_string_lossy();
                    !(s.contains(".vireo-") && s.ends_with(".tmp"))
                })
                .map(|p| to_app_path(p, &known).to_string_lossy().into_owned())
                .collect();
            if !paths.is_empty() {
                let _ = app.emit("fs-change", paths);
            }
        }
    });
    Watch { watcher: Mutex::new(watcher), watched }
}

/// Watches the parent folder of each open file, and the workspace folder
/// recursively. Watching the parent instead of the file survives editors and
/// tools that save by replacing the file.
#[tauri::command]
pub fn watch_set(state: State<Watch>, files: Vec<String>, root: Option<String>) -> Result<(), String> {
    let entry = |path: PathBuf, recursive: bool| {
        let real = std::fs::canonicalize(&path).unwrap_or_else(|_| path.clone());
        Watched { path, real, recursive }
    };
    let mut wanted: HashSet<Watched> = files
        .iter()
        .filter_map(|f| PathBuf::from(f).parent().map(|p| entry(p.to_path_buf(), false)))
        .collect();
    if let Some(root) = root {
        wanted.insert(entry(PathBuf::from(root), true));
    }
    let mut guard = state.watcher.lock().map_err(|e| e.to_string())?;
    let Some(watcher) = guard.as_mut() else { return Ok(()) };
    let mut watched = state.watched.lock().map_err(|e| e.to_string())?;
    for gone in watched.difference(&wanted) {
        let _ = watcher.unwatch(&gone.path);
    }
    for new in wanted.difference(&watched) {
        let mode = if new.recursive { RecursiveMode::Recursive } else { RecursiveMode::NonRecursive };
        let _ = watcher.watch(&new.path, mode);
    }
    *watched = wanted;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn events_map_back_to_the_opened_path() {
        let watched = HashSet::from([Watched { path: "/var/folders/x".into(), real: "/private/var/folders/x".into(), recursive: false }]);
        assert_eq!(to_app_path("/private/var/folders/x/a.md".into(), &watched), PathBuf::from("/var/folders/x/a.md"));
        assert_eq!(to_app_path("/elsewhere/b.md".into(), &watched), PathBuf::from("/elsewhere/b.md"));
    }
}
