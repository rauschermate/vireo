// Posts one key press with Command to a process, without activating it.
// Usage: swift scripts/presskey.swift <pid> <keycode>
import ApplicationServices
let pid = pid_t(CommandLine.arguments[1])!
let code = CGKeyCode(CommandLine.arguments[2])!
let source = CGEventSource(stateID: .hidSystemState)
for down in [true, false] {
    let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
    e.flags = .maskCommand
    e.postToPid(pid)
    usleep(30_000)
}
