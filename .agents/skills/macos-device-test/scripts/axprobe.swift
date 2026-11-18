// axprobe.swift — the only code of the Finder UI driver that calls the Accessibility API. It reads and acts on
// exactly the element it is told to, and decides nothing: finderui.py decides from the JSON it prints.
// Harvested from the AX helpers the independent device tester compiled during runs i5/i13/i22 (2026-11-17), which
// saw Finder's context menu where System Events (the removed finder-menu.sh / axdump.sh) did not.
// finderdrive.py compiles it once per source hash with `xcrun swiftc` into $TMPDIR (never into the repo).
//
// usage:
//   axprobe trusted                                   exit 0 if this process (its host terminal) is AX-trusted, else 70
//   axprobe dump PID WINDOW|all MAXDEPTH              JSON lines, one per element; path starts with the window index
//   axprobe menu-at X Y MAXDEPTH                      JSON lines of the menu under the screen point; path [] is the menu
//   axprobe act PID PATH select|press ROLE NAME       PATH like 0.3.1; verifies ROLE and NAME first, else exit 65
//   axprobe menu-session X Y MAXDEPTH                 the menu under the point: prints {"session":{"pid":N}}, its dump
//                                                     and {"end":true}, then reads ONE JSON line from stdin:
//                                                     {"abort":true}, or {"press":[i] or [i,0,j],"title":T,"sub":S|null,
//                                                     "titles":[every top-level title],"pid":N}. Before pressing it
//                                                     re-reads the menu it HOLDS: same owner pid, same top-level titles,
//                                                     item i titled T (and j titled S), else exit 65 and nothing pressed.
// exit: 0 ok, 64 usage, 65 no such element or it does not match (nothing done), 70 AX error / not trusted
import ApplicationServices
import Foundation

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(("axprobe: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}

func string(_ element: AXUIElement, _ key: String) -> String {
    (attr(element, key) as? String) ?? ""
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attr(element, "AXChildren") as? [AXUIElement]) ?? []
}

func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func frame(_ element: AXUIElement) -> [Double]? {
    guard let position = attr(element, "AXPosition"), let size = attr(element, "AXSize"),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
    return [Double(point.x), Double(point.y), Double(extent.width), Double(extent.height)]
}

func record(_ element: AXUIElement, _ path: [Int]) -> [String: Any] {
    var node: [String: Any] = [
        "path": path, "role": string(element, "AXRole"), "subrole": string(element, "AXSubrole"),
        "title": string(element, "AXTitle"), "desc": string(element, "AXDescription"),
    ]
    let value = attr(element, "AXValue")
    if let text = value as? String { node["value"] = text } else if let number = value as? NSNumber { node["value"] = number }
    else { node["value"] = NSNull() }
    node["enabled"] = (attr(element, "AXEnabled") as? Bool).map { $0 as Any } ?? NSNull()
    node["selected"] = (attr(element, "AXSelected") as? Bool).map { $0 as Any } ?? NSNull()
    node["frame"] = frame(element).map { $0 as Any } ?? NSNull()
    return node
}

func emit(_ node: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: node, options: [.withoutEscapingSlashes]),
          let line = String(data: data, encoding: .utf8) else { fail(70, "cannot encode an element") }
    print(line)
}

func walk(_ element: AXUIElement, _ path: [Int], _ depth: Int, _ maxDepth: Int) {
    emit(record(element, path))
    guard depth < maxDepth else { return }
    for (index, child) in children(element).enumerated() { walk(child, path + [index], depth + 1, maxDepth) }
}

func windows(_ pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &value)
    if result == .apiDisabled { fail(70, "Accessibility is not granted to the host terminal") }
    if result != .success && result != .noValue { fail(70, "cannot read the windows of pid \(pid): AXError \(result.rawValue)") }
    return (value as? [AXUIElement]) ?? []
}

func menu(at x: Float, _ y: Float) -> AXUIElement {
    var hit: AXUIElement?
    let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), x, y, &hit)
    if result == .apiDisabled { fail(70, "Accessibility is not granted to the host terminal") }
    guard result == .success, var current = hit else { fail(65, "no element at \(x),\(y): AXError \(result.rawValue)") }
    for _ in 0..<4 {
        if string(current, "AXRole") == "AXMenu" { return current }
        guard let parent = element(attr(current, "AXParent")) else { break }
        current = parent
    }
    fail(65, "no menu at \(x),\(y) (found \(string(hit!, "AXRole")))")
}

func path(_ text: String) -> [Int] {
    let parts = text.split(separator: ".").map { Int($0) }
    guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { fail(64, "bad path \(text)") }
    return parts.map { $0! }
}

func descend(_ root: AXUIElement, _ steps: ArraySlice<Int>) -> AXUIElement {
    var current = root
    for step in steps {
        let list = children(current)
        guard step < list.count else { fail(65, "element path no longer exists (the UI changed)") }
        current = list[step]
    }
    return current
}

func names(_ element: AXUIElement, _ depth: Int) -> [String] {
    var found = [string(element, "AXTitle"), (attr(element, "AXValue") as? String) ?? "", string(element, "AXDescription")]
    if depth > 0 { for child in children(element) { found += names(child, depth - 1) } }
    return found.filter { !$0.isEmpty }
}

func same(_ a: String, _ b: String) -> Bool {
    a.precomposedStringWithCanonicalMapping == b.precomposedStringWithCanonicalMapping
}

func perform(_ target: AXUIElement, _ action: String) {
    let result: AXError
    switch action {
    case "select": result = AXUIElementSetAttributeValue(target, "AXSelected" as CFString, kCFBooleanTrue)
    case "press": result = AXUIElementPerformAction(target, "AXPress" as CFString)
    default: fail(64, "unknown action \(action)")
    }
    guard result == .success else { fail(70, "\(action) failed: AXError \(result.rawValue)") }
    print("\(action) ok")
}

let arguments = CommandLine.arguments
func argument(_ index: Int) -> String {
    guard index < arguments.count else { fail(64, "missing argument; see the usage at the top of axprobe.swift") }
    return arguments[index]
}
func number(_ index: Int) -> Int {
    guard let value = Int(argument(index)) else { fail(64, "argument \(index) must be a whole number") }
    return value
}

switch argument(1) {
case "trusted":
    if AXIsProcessTrusted() { print("true"); exit(0) }
    print("false"); exit(70)
case "dump":
    let all = windows(pid_t(number(2)))
    let which = argument(3)
    let indexes = which == "all" ? Array(all.indices) : [number(3)]
    for index in indexes {
        guard index < all.count else { fail(65, "no window \(index) (the process has \(all.count))") }
        walk(all[index], [index], 0, number(4))
    }
case "menu-at":
    walk(menu(at: Float(number(2)), Float(number(3))), [], 0, number(4))
case "act":
    let steps = path(argument(3))
    let all = windows(pid_t(number(2)))
    guard steps[0] < all.count else { fail(65, "no window \(steps[0])") }
    let target = descend(all[steps[0]], steps.dropFirst())
    guard string(target, "AXRole") == argument(5) else { fail(65, "element is \(string(target, "AXRole")), not \(argument(5))") }
    guard names(target, 3).contains(where: { same($0, argument(6)) }) else { fail(65, "element does not show \(argument(6))") }
    perform(target, argument(4))
case "menu-session":
    let root = menu(at: Float(number(2)), Float(number(3)))
    var owner: pid_t = 0
    guard AXUIElementGetPid(root, &owner) == .success else { fail(70, "cannot read the menu's owner pid") }
    emit(["session": ["pid": Int(owner)]])
    walk(root, [], 0, number(4))
    emit(["end": true])
    fflush(stdout)
    guard let line = readLine(), let data = line.data(using: .utf8),
          let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        fail(65, "no decision from the driver: nothing pressed")
    }
    if request["abort"] != nil { print("aborted"); exit(0) }
    guard let steps = request["press"] as? [Int], !steps.isEmpty, steps.allSatisfy({ $0 >= 0 }),
          let title = request["title"] as? String, let titles = request["titles"] as? [String],
          let want = request["pid"] as? Int else { fail(64, "malformed press request") }
    var now: pid_t = 0
    guard AXUIElementGetPid(root, &now) == .success, Int(now) == want else {
        fail(65, "the menu's owner changed since it was verified: nothing pressed")
    }
    let current = children(root).map { string($0, "AXTitle") }
    guard current.count == titles.count, zip(current, titles).allSatisfy({ same($0.0, $0.1) }) else {
        fail(65, "the menu changed since it was verified: nothing pressed")
    }
    let item = descend(root, steps.prefix(1))
    guard same(string(item, "AXTitle"), title) else { fail(65, "menu item is \(string(item, "AXTitle")), not \(title): nothing pressed") }
    if steps.count == 1 {
        perform(item, "press")
    } else {
        guard steps.count == 3, steps[1] == 0, let subtitle = request["sub"] as? String else { fail(64, "submenu path must be i.0.j with a sub title") }
        let sub = descend(item, steps.dropFirst())
        guard same(string(sub, "AXTitle"), subtitle) else { fail(65, "submenu item is \(string(sub, "AXTitle")), not \(subtitle): nothing pressed") }
        perform(item, "press")  // opens the submenu, as the tester's press helper did
        usleep(600_000)
        guard same(string(sub, "AXTitle"), subtitle) else { fail(65, "the submenu changed after it opened: nothing pressed") }
        perform(sub, "press")
    }
default:
    fail(64, "unknown command \(argument(1))")
}
