use serde::Serialize;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

pub const MARKDOWN_EXTENSIONS: &[&str] = &["md", "markdown", "mdown", "mkd", "mkdn", "text"];
const SKIPPED_DIRS: &[&str] = &["node_modules"];

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

fn mtime_ms(meta: &fs::Metadata) -> f64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0)
}

pub fn is_markdown(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| MARKDOWN_EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()))
        .unwrap_or(false)
}

fn is_hidden(name: &str) -> bool {
    name.starts_with('.')
}

#[derive(Serialize)]
pub struct FileText {
    text: String,
    mtime: f64,
}

#[tauri::command]
pub fn read_text(path: String) -> Result<FileText, String> {
    let bytes = fs::read(&path).map_err(err)?;
    let text = String::from_utf8(bytes).map_err(|_| "The file is not UTF-8 text.".to_string())?;
    let meta = fs::metadata(&path).map_err(err)?;
    Ok(FileText { text, mtime: mtime_ms(&meta) })
}

/// Writes a temporary file next to the target, flushes it to disk, then
/// renames it over the target. A crash mid-save leaves the old file intact.
#[tauri::command]
pub fn write_text(path: String, text: String) -> Result<f64, String> {
    let mut target = PathBuf::from(&path);
    // Renaming over a symlink would replace the link itself with a file.
    if fs::symlink_metadata(&target).map(|m| m.file_type().is_symlink()).unwrap_or(false) {
        target = fs::canonicalize(&target).map_err(err)?;
    }
    let dir = target.parent().ok_or("The file has no parent folder.")?;
    let name = target.file_name().and_then(|n| n.to_str()).ok_or("The file name is not valid.")?;
    let tmp = dir.join(format!(".{name}.vireo-{}.tmp", std::process::id()));
    let result = (|| -> std::io::Result<()> {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(text.as_bytes())?;
        f.sync_all()?;
        if let Ok(meta) = fs::metadata(&target) {
            fs::set_permissions(&tmp, meta.permissions())?;
        }
        fs::rename(&tmp, &target)
    })();
    if let Err(e) = result {
        let _ = fs::remove_file(&tmp);
        return Err(err(e));
    }
    Ok(mtime_ms(&fs::metadata(&target).map_err(err)?))
}

#[derive(Serialize)]
pub struct Node {
    name: String,
    path: String,
    dir: bool,
    title: Option<String>,
    mtime: f64,
    children: Vec<Node>,
}

// A scan stops here, so a huge folder cannot hang the sidebar.
const SCAN_LIMIT: usize = 20_000;
const TITLE_BYTES: usize = 4096;

/// The workspace tree for the sidebar and quick open. Like Vireo: hidden
/// entries and symlinks are skipped, and a folder appears only if it holds
/// markdown somewhere below it or is empty.
#[tauri::command]
pub fn scan_workspace(root: String) -> Result<Vec<Node>, String> {
    let mut budget = SCAN_LIMIT;
    let root = PathBuf::from(root);
    if !root.is_dir() {
        return Err("The folder does not exist.".into());
    }
    Ok(scan(&root, &mut budget))
}

fn scan(dir: &Path, budget: &mut usize) -> Vec<Node> {
    let Ok(read) = fs::read_dir(dir) else { return Vec::new() };
    let mut nodes = Vec::new();
    for e in read.filter_map(|e| e.ok()) {
        if *budget == 0 {
            break;
        }
        let name = e.file_name().to_string_lossy().into_owned();
        let Ok(kind) = e.file_type() else { continue };
        if is_hidden(&name) || kind.is_symlink() {
            continue;
        }
        let path = e.path();
        if kind.is_dir() {
            if SKIPPED_DIRS.contains(&name.as_str()) {
                continue;
            }
            let children = scan(&path, budget);
            let empty = fs::read_dir(&path).map(|mut r| r.next().is_none()).unwrap_or(false);
            if !children.is_empty() || empty {
                nodes.push(Node { name, path: path.to_string_lossy().into_owned(), dir: true, title: None, mtime: 0.0, children });
            }
        } else if is_markdown(&path) {
            *budget -= 1;
            let mtime = e.metadata().map(|m| mtime_ms(&m)).unwrap_or(0.0);
            nodes.push(Node { title: title_of(&path), name, path: path.to_string_lossy().into_owned(), dir: false, mtime, children: Vec::new() });
        }
    }
    nodes.sort_by(|a, b| b.dir.cmp(&a.dir).then_with(|| natural_cmp(&a.name, &b.name)));
    nodes
}

/// The front matter `title:`, else a leading `# H1`.
pub fn title_of(path: &Path) -> Option<String> {
    use std::io::Read;
    let mut head = Vec::with_capacity(TITLE_BYTES);
    fs::File::open(path).ok()?.take(TITLE_BYTES as u64).read_to_end(&mut head).ok()?;
    title_from(&String::from_utf8_lossy(&head))
}

pub fn title_from(text: &str) -> Option<String> {
    let mut lines = text.lines().peekable();
    if lines.peek().map(|l| l.trim_end() == "---").unwrap_or(false) {
        lines.next();
        for line in lines.by_ref() {
            if line.trim_end() == "---" {
                break;
            }
            if let Some(v) = line.strip_prefix("title:") {
                let v = v.trim().trim_matches(|c| c == '"' || c == '\'');
                if !v.is_empty() {
                    return Some(v.to_string());
                }
            }
        }
    }
    let first = lines.find(|l| !l.trim().is_empty())?;
    let h1 = first.strip_prefix("# ")?.trim().trim_end_matches('#').trim();
    (!h1.is_empty()).then(|| h1.to_string())
}

#[tauri::command]
pub fn create_file(path: String, text: String) -> Result<(), String> {
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .map_err(|e| if e.kind() == std::io::ErrorKind::AlreadyExists { "A file with that name already exists.".into() } else { err(e) })?;
    f.write_all(text.as_bytes()).map_err(err)
}

#[tauri::command]
pub fn create_dir(path: String) -> Result<(), String> {
    fs::create_dir(&path).map_err(err)
}

#[tauri::command]
pub fn rename_path(from: String, to: String) -> Result<(), String> {
    // A case-only rename on a case-insensitive volume sees `to` as existing.
    let same = from.to_lowercase() == to.to_lowercase();
    if Path::new(&to).exists() && !same {
        return Err("A file with that name already exists.".into());
    }
    fs::rename(&from, &to).map_err(err)
}

#[tauri::command]
pub fn trash_path(path: String) -> Result<(), String> {
    let mut ctx = trash::TrashContext::default();
    // The default asks Finder over AppleScript, which needs an Automation
    // permission and blocks on its prompt. NSFileManager needs none, and it
    // is what Vireo's FileManager.trashItem uses.
    #[cfg(target_os = "macos")]
    {
        use trash::macos::{DeleteMethod, TrashContextExtMacos};
        ctx.set_delete_method(DeleteMethod::NsFileManager);
    }
    ctx.delete(&path).map_err(err)
}

#[tauri::command]
pub fn reveal_path(path: String) -> Result<(), String> {
    std::process::Command::new("open").arg("-R").arg(&path).spawn().map(|_| ()).map_err(err)
}

#[tauri::command]
pub fn open_in_terminal(path: String) -> Result<(), String> {
    std::process::Command::new("open").args(["-a", "Terminal"]).arg(&path).spawn().map(|_| ()).map_err(err)
}

#[tauri::command]
pub fn path_exists(path: String) -> bool {
    Path::new(&path).exists()
}

/// Case-insensitive compare that orders digit runs by value, like Finder.
pub fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let (mut a, mut b) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return std::cmp::Ordering::Equal,
            (None, _) => return std::cmp::Ordering::Less,
            (_, None) => return std::cmp::Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let mut nx = String::new();
                while let Some(c) = a.peek().copied().filter(|c| c.is_ascii_digit()) {
                    nx.push(c);
                    a.next();
                }
                let mut ny = String::new();
                while let Some(c) = b.peek().copied().filter(|c| c.is_ascii_digit()) {
                    ny.push(c);
                    b.next();
                }
                let (tx, ty) = (nx.trim_start_matches('0'), ny.trim_start_matches('0'));
                let ord = tx.len().cmp(&ty.len()).then_with(|| tx.cmp(ty));
                if ord != std::cmp::Ordering::Equal {
                    return ord;
                }
            }
            (Some(x), Some(y)) => {
                let ord = x.to_lowercase().cmp(y.to_lowercase());
                if ord != std::cmp::Ordering::Equal {
                    return ord;
                }
                a.next();
                b.next();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("vireo-fs-test-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn natural_order() {
        let mut names = vec!["Note 10.md", "note 2.md", "Note 1.md", "b.md", "A.md"];
        names.sort_by(|a, b| natural_cmp(a, b));
        assert_eq!(names, vec!["A.md", "b.md", "Note 1.md", "note 2.md", "Note 10.md"]);
    }

    #[test]
    fn atomic_write_replaces_content_and_keeps_no_temp() {
        let dir = temp_dir("write");
        let file = dir.join("a.md");
        fs::write(&file, "old").unwrap();
        write_text(file.to_string_lossy().into(), "new text".into()).unwrap();
        assert_eq!(fs::read_to_string(&file).unwrap(), "new text");
        let leftovers: Vec<_> = fs::read_dir(&dir).unwrap().filter_map(|e| e.ok()).filter(|e| e.file_name().to_string_lossy().ends_with(".tmp")).collect();
        assert!(leftovers.is_empty());
    }

    #[test]
    fn write_through_a_symlink_keeps_the_link() {
        let dir = temp_dir("symlink");
        let real = dir.join("real.md");
        let link = dir.join("link.md");
        fs::write(&real, "old").unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();
        write_text(link.to_string_lossy().into(), "new".into()).unwrap();
        assert!(fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
        assert_eq!(fs::read_to_string(&real).unwrap(), "new");
    }

    #[test]
    fn scan_prunes_and_sorts() {
        let dir = temp_dir("scan");
        for d in ["zeta", ".git", "node_modules", "images", "empty"] {
            fs::create_dir(dir.join(d)).unwrap();
        }
        fs::write(dir.join("zeta/note.md"), "# Zeta note\n").unwrap();
        fs::write(dir.join("images/a.png"), "").unwrap();
        for f in ["b.md", "a.markdown", "img.png", ".hidden.md"] {
            fs::write(dir.join(f), "").unwrap();
        }
        std::os::unix::fs::symlink(dir.join("b.md"), dir.join("link.md")).unwrap();
        let nodes = scan_workspace(dir.to_string_lossy().into()).unwrap();
        let names: Vec<&str> = nodes.iter().map(|n| n.name.as_str()).collect();
        assert_eq!(names, vec!["empty", "zeta", "a.markdown", "b.md"]);
        assert_eq!(nodes[1].children[0].title.as_deref(), Some("Zeta note"));
    }

    #[test]
    fn titles() {
        assert_eq!(title_from("---\ntitle: \"Front\"\n---\n# H1\n").as_deref(), Some("Front"));
        assert_eq!(title_from("\n\n# Heading ##\nbody").as_deref(), Some("Heading"));
        assert_eq!(title_from("Intro\n# Later").as_deref(), None);
        assert_eq!(title_from("## Two").as_deref(), None);
    }

    #[test]
    fn trash_moves_the_file_out() {
        let dir = temp_dir("trash");
        let file = dir.join("gone.md");
        fs::write(&file, "x").unwrap();
        trash_path(file.to_string_lossy().into()).unwrap();
        assert!(!file.exists());
    }

    #[test]
    fn create_file_refuses_to_overwrite() {
        let dir = temp_dir("create");
        let file = dir.join("x.md").to_string_lossy().into_owned();
        create_file(file.clone(), "one".into()).unwrap();
        assert!(create_file(file, "two".into()).is_err());
    }
}
