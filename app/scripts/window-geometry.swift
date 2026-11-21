// Prints the window frame and the traffic-light frames of a process, via
// accessibility. Usage: swift scripts/window-geometry.swift <pid>
import ApplicationServices
let app = AXUIElementCreateApplication(pid_t(CommandLine.arguments[1])!)
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func frame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
guard let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement], let w = windows.first else { print("no window"); exit(1) }
let wf = frame(w)
print("window \(wf)")
for name in [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute] {
    if let b = attr(w, name) { let f = frame(b as! AXUIElement); print("\(name) x=\(f.minX - wf.minX) centerY=\(f.midY - wf.minY) size=\(f.size)") }
}
