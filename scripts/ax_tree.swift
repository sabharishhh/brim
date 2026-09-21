// Dumps a running app's real accessibility tree, with no depth limit.
//
// Written because a claim was made on the strength of an automation tool
// that walks only a few levels: it reported seventeen elements for a window
// full of rows, and the app was blamed for what the tool could not see. The
// real tree had seventy-seven. Reading the tree directly is the only way to
// tell an app defect from a tool limitation, and the defects it did find
// were real ones: rows arriving as a dozen unrelated fragments, a path
// exposed twice, and combined elements with no role at all.
//
//   swiftc -o /tmp/ax_tree scripts/ax_tree.swift && /tmp/ax_tree
//
// Needs Accessibility permission for whatever runs it, which is a different
// grant from Full Disk Access and is given in
// System Settings > Privacy & Security > Accessibility.
//
// What to look for:
//   AXUnknown            a combined element with no role, which reads as
//                        nothing and cannot be navigated to by type
//   repeated text        textSelection adds a child, so the same string is
//                        spoken twice
//   a pile of AXStaticText under one row
//                        the row was never composed, so a reader is handed
//                        fragments with nothing connecting them
//   AXCheckBox with no desc
//                        Toggle("") exposes nothing to press

import Foundation
import ApplicationServices
import AppKit

func attr(_ element: AXUIElement, _ name: String) -> Any? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func str(_ element: AXUIElement, _ name: String) -> String? {
    attr(element, name) as? String
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attr(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

var counts: [String: Int] = [:]
var total = 0

func walk(_ element: AXUIElement, depth: Int, limit: Int) {
    let role = str(element, kAXRoleAttribute as String) ?? "?"
    total += 1
    counts[role, default: 0] += 1

    let title = str(element, kAXTitleAttribute as String)
    let label = str(element, kAXDescriptionAttribute as String)
    let value = attr(element, kAXValueAttribute as String)
    let acts = actions(element).filter { $0 != "AXShowMenu" }

    var line = String(repeating: "  ", count: depth) + role
    if let title, !title.isEmpty { line += " title=\"\(title.prefix(60))\"" }
    if let label, !label.isEmpty { line += " desc=\"\(label.prefix(60))\"" }
    if let value = value as? String, !value.isEmpty { line += " value=\"\(value.prefix(40))\"" }
    if let value = value as? Int { line += " value=\(value)" }
    if !acts.isEmpty { line += " actions=\(acts)" }
    print(line)

    guard depth < limit else {
        print(String(repeating: "  ", count: depth + 1) + "… (depth limit)")
        return
    }
    for child in children(element) { walk(child, depth: depth + 1, limit: limit) }
}

guard AXIsProcessTrusted() else {
    print("NOT TRUSTED: this process lacks Accessibility permission, so the tree is unreadable.")
    exit(2)
}

// Any app, by a fragment of its bundle identifier. Defaults to Brim.
let wanted = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "brim"
let apps = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier?.localizedCaseInsensitiveContains(wanted) == true
}
guard let app = apps.first else { print("No running app matches \(wanted)"); exit(1) }
print("\(app.bundleIdentifier ?? wanted) pid \(app.processIdentifier)")

let axApp = AXUIElementCreateApplication(app.processIdentifier)
let windows = (attr(axApp, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
for window in windows {
    walk(window, depth: 0, limit: 30)
}
print("---- TOTAL ELEMENTS: \(total)")
for (role, count) in counts.sorted(by: { $0.value > $1.value }) { print("  \(role): \(count)") }
