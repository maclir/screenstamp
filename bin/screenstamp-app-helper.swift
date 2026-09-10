#!/usr/bin/env swift

import Cocoa
import ApplicationServices

// MARK: - Models

struct DisplayGeom: Codable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

struct WindowEntry: Codable {
    let type: String            // "app", "pwa", "chrome_profile"
    let bundle_id: String
    let app_name: String
    let app_path: String?
    let profile_dir: String?    // e.g. "Profile 1", "Default"
    let profile_name: String?   // e.g. "Work", "Alireza"
    let display_role: String    // e.g. "builtin-1", "external-1"
    let fullscreen: Bool
    let rel_x: Double
    let rel_y: Double
    let rel_w: Double
    let rel_h: Double
}

// MARK: - Permissions Helper

func checkAccessibility(prompt: Bool = false) -> Bool {
    let trusted = AXIsProcessTrusted()
    if !trusted && prompt {
        printErr("screenstamp: Accessibility permission required.")
        printErr("screenstamp: Opening System Settings > Privacy & Security > Accessibility...")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    return trusted
}

// MARK: - Helpers

func printErr(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

func parseDisplays(from path: String) -> [String: DisplayGeom] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let displays = try? JSONDecoder().decode([String: DisplayGeom].self, from: data) else {
        printErr("screenstamp: could not parse displays JSON from \(path)")
        exit(1)
    }
    return displays
}

func loadChromeProfiles() -> [(dir: String, name: String, matches: [String])] {
    var profiles: [(dir: String, name: String, matches: [String])] = []
    let localStatePath = ("~/Library/Application Support/Google/Chrome/Local State" as NSString).expandingTildeInPath
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: localStatePath)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let profileObj = json["profile"] as? [String: Any],
          let infoCache = profileObj["info_cache"] as? [String: [String: Any]] else {
        return profiles
    }

    for (dirName, info) in infoCache {
        var names: [String] = []
        if let n = info["name"] as? String { names.append(n) }
        if let gn = info["gaia_given_name"] as? String { names.append(gn) }
        if let gnFull = info["gaia_name"] as? String { names.append(gnFull) }
        if let un = info["user_name"] as? String {
            names.append(un)
            if let atIdx = un.firstIndex(of: "@") {
                let domain = String(un[un.index(after: atIdx)...])
                names.append(domain)
                if let dotIdx = domain.firstIndex(of: ".") {
                    names.append(String(domain[..<dotIdx]))
                }
            }
        }
        if let hd = info["hosted_domain"] as? String, hd != "NO_HOSTED_DOMAIN" {
            names.append(hd)
            if let dotIdx = hd.firstIndex(of: ".") {
                names.append(String(hd[..<dotIdx]))
            }
        }
        let dispName = (info["name"] as? String) ?? (info["gaia_given_name"] as? String) ?? dirName
        profiles.append((dir: dirName, name: dispName, matches: names))
    }
    return profiles
}

func resolveChromeProfile(text: String, profiles: [(dir: String, name: String, matches: [String])]) -> (dir: String, name: String) {
    var bestMatch: (dir: String, name: String)? = nil
    var bestScore = 0

    for prof in profiles {
        var score = 0
        for m in prof.matches {
            let trimmed = m.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 3 && text.localizedCaseInsensitiveContains(trimmed) {
                score += trimmed.count
            }
        }
        if score > bestScore {
            bestScore = score
            bestMatch = (dir: prof.dir, name: prof.name)
        }
    }

    if let match = bestMatch, bestScore > 0 {
        return match
    }

    if let def = profiles.first(where: { $0.dir == "Default" }) {
        return (dir: def.dir, name: def.name)
    }
    return (dir: "Default", name: "Personal")
}

func findStandardWindow(in windows: [AXUIElement]) -> AXUIElement? {
    for win in windows {
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = (subroleRef as? String) ?? ""
        if subrole == "AXStandardWindow" {
            var sizeRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)
            var sz = CGSize.zero
            if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
            if sz.width >= 200 && sz.height >= 150 {
                return win
            }
        }
    }
    for win in windows {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""
        if role == "AXScrollArea" { continue }

        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)
        var sz = CGSize.zero
        if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
        if sz.width >= 200 && sz.height >= 150 {
            return win
        }
    }
    return windows.first
}

func queryChromeWindowsAppleScript() -> [(x: Double, y: Double, w: Double, h: Double, title: String, allText: String)] {
    var result: [(x: Double, y: Double, w: Double, h: Double, title: String, allText: String)] = []
    let chromeScript = """
    tell application "Google Chrome"
        set out to ""
        repeat with w in windows
            set b to bounds of w
            set n to name of w
            if n is not "" then
                set allTabs to n & " "
                try
                    repeat with t in tabs of w
                        set allTabs to allTabs & (URL of t) & " " & (title of t) & " "
                    end repeat
                end try
                set out to out & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & "|" & n & "|" & allTabs & "\\n"
            end if
        end repeat
        return out
    end tell
    """
    if let appleScript = NSAppleScript(source: chromeScript) {
        var error: NSDictionary?
        let res = appleScript.executeAndReturnError(&error)
        if let str = res.stringValue {
            for line in str.split(separator: "\n") {
                let parts = line.split(separator: "|", omittingEmptySubsequences: false)
                if parts.count >= 2 {
                    let coords = parts[0].split(separator: ",").compactMap { Double($0) }
                    if coords.count == 4 {
                        let title = String(parts[1])
                        let allText = parts.count > 2 ? String(parts[2]) : title
                        let x = coords[0]
                        let y = coords[1]
                        let w = coords[2] - coords[0]
                        let h = coords[3] - coords[1]
                        result.append((x: x, y: y, w: w, h: h, title: title, allText: allText))
                    }
                }
            }
        }
    }
    return result
}

func findDisplayRole(x: Double, y: Double, w: Double, h: Double, displays: [String: DisplayGeom]) -> String? {
    let midX = x + w / 2.0
    let midY = y + h / 2.0

    // Check if center point falls inside display
    for (role, geom) in displays {
        if midX >= geom.x && midX < (geom.x + geom.w) &&
           midY >= geom.y && midY < (geom.y + geom.h) {
            return role
        }
    }

    // Check if origin point falls inside display
    for (role, geom) in displays {
        if x >= geom.x && x < (geom.x + geom.w) &&
           y >= geom.y && y < (geom.y + geom.h) {
            return role
        }
    }

    // Fallback: maximum overlapping area
    var bestRole: String? = nil
    var maxOverlap = 0.0
    for (role, geom) in displays {
        let xOverlap = max(0.0, min(x + w, geom.x + geom.w) - max(x, geom.x))
        let yOverlap = max(0.0, min(y + h, geom.y + geom.h) - max(y, geom.y))
        let overlap = xOverlap * yOverlap
        if overlap > maxOverlap {
            maxOverlap = overlap
            bestRole = role
        }
    }

    return bestRole
}

func printAppSummary(entries: [WindowEntry], action: String) {
    guard !entries.isEmpty else {
        print("\(action) 0 app placement(s).")
        return
    }
    print("\(action) \(entries.count) app placement(s):")

    var labels: [(name: String, target: String)] = []
    var maxNameLen = 0

    for entry in entries {
        let nameStr: String
        if entry.type == "chrome_profile" {
            let pName = entry.profile_name ?? entry.profile_dir ?? ""
            nameStr = "Google Chrome (\(pName))"
        } else if entry.type == "pwa" {
            nameStr = "\(entry.app_name) (PWA)"
        } else {
            nameStr = entry.app_name
        }

        let targetStr: String
        if entry.fullscreen {
            targetStr = "\(entry.display_role) (Fullscreen)"
        } else {
            let xStr = String(format: "%.2f", entry.rel_x)
            let yStr = String(format: "%.2f", entry.rel_y)
            targetStr = "\(entry.display_role) (Desktop side: x=\(xStr), y=\(yStr))"
        }

        if nameStr.count > maxNameLen {
            maxNameLen = nameStr.count
        }
        labels.append((name: nameStr, target: targetStr))
    }

    let colWidth = max(maxNameLen + 2, 24)
    for label in labels {
        let padded = label.name.padding(toLength: colWidth, withPad: " ", startingAt: 0)
        print("  • \(padded) -> \(label.target)")
    }
}

// MARK: - Save

func saveApps(displaysPath: String, outputPath: String) {
    if !checkAccessibility(prompt: true) {
        printErr("screenstamp: Accessibility permissions are not yet enabled. Enable them in System Settings, then retry.")
        exit(1)
    }

    let displays = parseDisplays(from: displaysPath)
    let chromeProfiles = loadChromeProfiles()
    let chromeWindows = queryChromeWindowsAppleScript()
    var entries: [WindowEntry] = []

    let ignoredOwners: Set<String> = [
        "Window Server", "Dock", "Spotlight", "ControlCenter", "NotificationCenter",
        "SystemUIServer", "CursorUIViewService", "AutoFill", "Wi-Fi", "loginwindow",
        "WindowManager", "AirPlay", "AirPlay Screen Mirroring", "AirPlayUIAgent",
        "GlobalProtect", "screencapture", "TextInputMenuAgent"
    ]

    // Query all on-screen and space windows via CGWindowList
    guard let rawWins = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        printErr("screenstamp: could not query window list from WindowServer")
        exit(1)
    }

    // Filter and sort by area descending so primary windows take precedence over auxiliary popups
    let sortedWins = rawWins.filter {
        let layer = $0[kCGWindowLayer as String] as? Int ?? -1
        let alpha = $0[kCGWindowAlpha as String] as? Double ?? 1.0
        return layer == 0 && alpha > 0.5
    }.sorted {
        let b1 = $0[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let b2 = $1[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let a1 = (b1["Width"] as? Double ?? 0) * (b1["Height"] as? Double ?? 0)
        let a2 = (b2["Width"] as? Double ?? 0) * (b2["Height"] as? Double ?? 0)
        return a1 > a2
    }

    var seenChromeProfiles = Set<String>()
    var seenAppBundleIds = Set<String>()

    for w in sortedWins {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        guard !ignoredOwners.contains(owner) else { continue }

        let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let x = bounds["X"] as? Double ?? 0
        let y = bounds["Y"] as? Double ?? 0
        let width = bounds["Width"] as? Double ?? 0
        let height = bounds["Height"] as? Double ?? 0

        // Skip small auxiliary floating overlays and menus
        guard width >= 250 && height >= 150 else { continue }

        let pid = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
        let app = NSRunningApplication(processIdentifier: pid)
        let bundleId = app?.bundleIdentifier ?? ""
        let appName = app?.localizedName ?? owner

        guard let role = findDisplayRole(x: x, y: y, w: width, h: height, displays: displays),
              let geom = displays[role] else { continue }

        let isFs = (abs(width - geom.w) <= 25.0) && (height >= geom.h * 0.75)
        let relX = max(0.0, min(1.0, (x - geom.x) / geom.w))
        let relY = max(0.0, min(1.0, (y - geom.y) / geom.h))
        let relW = max(0.05, min(1.0, width / geom.w))
        let relH = max(0.05, min(1.0, height / geom.h))

        let isPwa = bundleId.hasPrefix("com.google.Chrome.app.") ||
                    (app?.bundleURL?.path.contains("Chrome Apps") == true) ||
                    owner.contains("Google Calendar") ||
                    owner.contains("Google Meet")

        if isPwa {
            let key = bundleId.isEmpty ? owner : bundleId
            if seenAppBundleIds.contains(key) { continue }
            seenAppBundleIds.insert(key)

            entries.append(WindowEntry(
                type: "pwa",
                bundle_id: bundleId.isEmpty ? "com.google.Chrome.app" : bundleId,
                app_name: appName,
                app_path: app?.bundleURL?.path,
                profile_dir: nil,
                profile_name: nil,
                display_role: role,
                fullscreen: isFs,
                rel_x: relX,
                rel_y: relY,
                rel_w: relW,
                rel_h: relH
            ))
        } else if bundleId == "com.google.Chrome" || owner == "Google Chrome" {
            // Chrome browser profiles are processed directly from AppleScript windows below
            continue
        } else {
            guard let bId = app?.bundleIdentifier, !bId.isEmpty else { continue }
            if seenAppBundleIds.contains(bId) { continue }
            seenAppBundleIds.insert(bId)

            entries.append(WindowEntry(
                type: "app",
                bundle_id: bId,
                app_name: appName,
                app_path: app?.bundleURL?.path,
                profile_dir: nil,
                profile_name: nil,
                display_role: role,
                fullscreen: isFs,
                rel_x: relX,
                rel_y: relY,
                rel_w: relW,
                rel_h: relH
            ))
        }
    }

    // Detect which displays have native fullscreen Chrome windows
    var fsDisplaysForChrome = Set<String>()
    for w in sortedWins {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        guard owner == "Google Chrome" else { continue }
        let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let width = bounds["Width"] as? Double ?? 0
        let height = bounds["Height"] as? Double ?? 0
        let x = bounds["X"] as? Double ?? 0
        let y = bounds["Y"] as? Double ?? 0
        if let role = findDisplayRole(x: x, y: y, w: width, h: height, displays: displays),
           let geom = displays[role] {
            if abs(width - geom.w) <= 25.0 && height >= geom.h * 0.75 {
                fsDisplaysForChrome.insert(role)
            }
        }
    }

    // Process Chrome windows from AppleScript
    for cw in chromeWindows {
        guard let role = findDisplayRole(x: cw.x, y: cw.y, w: cw.w, h: cw.h, displays: displays),
              let geom = displays[role] else { continue }

        let isFs = fsDisplaysForChrome.contains(role) && (cw.w >= geom.w * 0.85)
        let (matchedDir, matchedName) = resolveChromeProfile(text: cw.allText, profiles: chromeProfiles)

        if seenChromeProfiles.contains(matchedDir) { continue }
        seenChromeProfiles.insert(matchedDir)

        let relX = max(0.0, min(1.0, (cw.x - geom.x) / geom.w))
        let relY = max(0.0, min(1.0, (cw.y - geom.y) / geom.h))
        let relW = isFs ? 1.0 : max(0.05, min(1.0, cw.w / geom.w))
        let relH = isFs ? 1.0 : max(0.05, min(1.0, cw.h / geom.h))

        entries.append(WindowEntry(
            type: "chrome_profile",
            bundle_id: "com.google.Chrome",
            app_name: "Google Chrome",
            app_path: "/Applications/Google Chrome.app",
            profile_dir: matchedDir,
            profile_name: matchedName,
            display_role: role,
            fullscreen: isFs,
            rel_x: isFs ? 0.0 : relX,
            rel_y: isFs ? 0.0 : relY,
            rel_w: relW,
            rel_h: relH
        ))
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(entries) else {
        printErr("screenstamp: could not encode app entries to JSON")
        exit(1)
    }

    do {
        try data.write(to: URL(fileURLWithPath: outputPath))
        printAppSummary(entries: entries, action: "Saved")
    } catch {
        printErr("screenstamp: could not write apps file: \(error)")
        exit(1)
    }
}

// MARK: - Load

func launchMissingApps(entries: [WindowEntry]) {
    let running = NSWorkspace.shared.runningApplications
    let runningBundleIds = Set(running.compactMap { $0.bundleIdentifier })
    var launchedAny = false

    for entry in entries {
        if entry.type == "app" || entry.type == "pwa" {
            if !runningBundleIds.contains(entry.bundle_id) {
                print("Launching \(entry.app_name)...")
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                if let path = entry.app_path, FileManager.default.fileExists(atPath: path) {
                    task.arguments = ["-a", path]
                } else {
                    task.arguments = ["-b", entry.bundle_id]
                }
                try? task.run()
                launchedAny = true
            }
        } else if entry.type == "chrome_profile" {
            let chromeRunning = runningBundleIds.contains("com.google.Chrome")
            if !chromeRunning {
                print("Launching Google Chrome (\(entry.profile_name ?? entry.profile_dir ?? "")...)")
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                let profDir = entry.profile_dir ?? "Default"
                task.arguments = ["-na", "Google Chrome", "--args", "--profile-directory=\(profDir)"]
                try? task.run()
                launchedAny = true
            }
        }
    }

    if launchedAny {
        usleep(1_500_000)
    }
}

func activateChromeWindow(profileDir: String, profiles: [(dir: String, name: String, matches: [String])]) -> (win: AXUIElement?, winId: Int?) {
    var targetTerms: [String] = []
    for prof in profiles where prof.dir == profileDir {
        for m in prof.matches {
            let trimmed = m.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 3 {
                targetTerms.append(trimmed)
            }
        }
    }

    var otherTerms: [String] = []
    for prof in profiles where prof.dir != profileDir {
        for m in prof.matches {
            let trimmed = m.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 3 {
                otherTerms.append(trimmed)
            }
        }
    }

    let targetChecks = targetTerms.map { term -> String in
        let escaped = term.replacingOccurrences(of: "\"", with: "\\\"")
        return "if allText contains \"\(escaped)\" then set matchesTarget to true"
    }.joined(separator: "\n                ")

    let otherChecks = otherTerms.map { term -> String in
        let escaped = term.replacingOccurrences(of: "\"", with: "\\\"")
        return "if allText contains \"\(escaped)\" then set matchesOther to true"
    }.joined(separator: "\n                ")

    let script = """
    tell application "Google Chrome"
        set targetWinId to 0
        set fallbackWinId to 0
        repeat with w in windows
            set n to name of w
            if n is not "" then
                set allText to n & " "
                try
                    repeat with t in tabs of w
                        set allText to allText & (URL of t) & " " & (title of t) & " "
                    end repeat
                end try
                
                set matchesTarget to false
                \(targetChecks)
                
                set matchesOther to false
                \(otherChecks)
                
                if matchesTarget and not matchesOther then
                    set targetWinId to (id of w)
                    set index of w to 1
                    exit repeat
                else if not matchesOther and fallbackWinId is 0 then
                    set fallbackWinId to (id of w)
                end if
            end if
        end repeat
        
        if targetWinId is 0 and fallbackWinId is not 0 then
            repeat with w in windows
                if (id of w) is fallbackWinId then
                    set index of w to 1
                    set targetWinId to fallbackWinId
                    exit repeat
                end if
            end repeat
        end if
        return targetWinId
    end tell
    """

    var matchedWinId: Int? = nil
    if let asObj = NSAppleScript(source: script) {
        var err: NSDictionary?
        let res = asObj.executeAndReturnError(&err)
        let idVal = Int(res.int32Value)
        if idVal > 0 {
            matchedWinId = idVal
            usleep(250_000)
        }
    }

    let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.google.Chrome" }
    guard let chrome = apps.first else { return (nil, matchedWinId) }
    let axApp = AXUIElementCreateApplication(chrome.processIdentifier)
    var mainVal: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &mainVal) == .success,
       let mainWin = mainVal {
        return ((mainWin as! AXUIElement), matchedWinId)
    }
    var focVal: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focVal) == .success,
       let focWin = focVal {
        return ((focWin as! AXUIElement), matchedWinId)
    }
    return (nil, matchedWinId)
}

func restoreApps(displaysPath: String, inputPath: String) {
    if !checkAccessibility(prompt: true) {
        printErr("screenstamp: Accessibility permissions are not yet enabled. Enable them in System Settings, then retry.")
        exit(1)
    }

    let displays = parseDisplays(from: displaysPath)
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: inputPath)),
          let entries = try? JSONDecoder().decode([WindowEntry].self, from: data) else {
        printErr("screenstamp: could not read apps file from \(inputPath)")
        exit(1)
    }

    launchMissingApps(entries: entries)

    let running = NSWorkspace.shared.runningApplications
    let chromeProfiles = loadChromeProfiles()

    for entry in entries {
        guard let geom = displays[entry.display_role] else {
            printErr("Warning: display role '\(entry.display_role)' not found for \(entry.app_name)")
            continue
        }

        let candidateApps: [NSRunningApplication]
        if entry.type == "chrome_profile" {
            candidateApps = running.filter { $0.bundleIdentifier == "com.google.Chrome" }
        } else if entry.type == "pwa" {
            candidateApps = running.filter { $0.bundleIdentifier == entry.bundle_id || $0.localizedName == entry.app_name }
        } else {
            candidateApps = running.filter { $0.bundleIdentifier == entry.bundle_id }
        }

        guard let targetApp = candidateApps.first else { continue }

        var targetWin: AXUIElement? = nil
        var targetWinId: Int? = nil
        if entry.type == "chrome_profile" {
            let res = activateChromeWindow(profileDir: entry.profile_dir ?? "Default", profiles: chromeProfiles)
            targetWin = res.win
            targetWinId = res.winId
        } else {
            let appElement = AXUIElementCreateApplication(targetApp.processIdentifier)
            var windows: [AXUIElement] = []

            // Check main and focused window first (avoids activating/space-jumping if already active)
            var mainRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainRef) == .success,
               let main = mainRef {
                windows = [main as! AXUIElement]
            } else {
                var winRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &winRef) == .success,
                   let wins = winRef as? [AXUIElement], !wins.isEmpty {
                    windows = wins
                }
            }

            // If still no window found, activate app and retry
            if windows.isEmpty {
                targetApp.activate()
                for _ in 0..<8 {
                    usleep(100_000)
                    var mRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mRef) == .success,
                       let m = mRef {
                        windows = [m as! AXUIElement]
                        break
                    }
                    var wRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &wRef) == .success,
                       let wins = wRef as? [AXUIElement], !wins.isEmpty {
                        windows = wins
                        break
                    }
                }
            }

            guard !windows.isEmpty else { continue }
            targetWin = findStandardWindow(in: windows) ?? windows.first
        }

        guard let win = targetWin else { continue }

        var fullRef: CFTypeRef?
        var posRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fullRef)
        AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
        let isFs = (fullRef as? Bool) ?? false
        var curPos = CGPoint.zero
        if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &curPos) }

        let onDisplay = curPos.x >= geom.x && curPos.x < (geom.x + geom.w) &&
                        curPos.y >= geom.y && curPos.y < (geom.y + geom.h)

        if entry.fullscreen {
            if isFs && onDisplay {
                continue
            }

            targetApp.activate()

            if isFs {
                let falseVal: CFBoolean = kCFBooleanFalse
                AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, falseVal)
                for _ in 0..<20 {
                    usleep(100_000)
                    var checkFs: CFTypeRef?
                    AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &checkFs)
                    if (checkFs as? Bool) == false { break }
                }
                usleep(250_000)
            }

            var targetPt = CGPoint(x: geom.x + 100.0, y: geom.y + 100.0)
            if let axPos = AXValueCreate(.cgPoint, &targetPt) {
                for _ in 0..<5 {
                    let err = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, axPos)
                    if err == .success { break }
                    usleep(100_000)
                }
            }

            if entry.type == "chrome_profile", let winId = targetWinId {
                let asScript = """
                tell application "Google Chrome"
                    set bounds of window id \(winId) to {\(Int(geom.x + 100)), \(Int(geom.y + 100)), \(Int(geom.x + 1100)), \(Int(geom.y + 800))}
                end tell
                """
                if let asObj = NSAppleScript(source: asScript) {
                    var err: NSDictionary?
                    _ = asObj.executeAndReturnError(&err)
                }
            }
            usleep(200_000)

            let trueVal: CFBoolean = kCFBooleanTrue
            AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, trueVal)
            usleep(300_000)
        } else {
            let targetX = geom.x + (entry.rel_x * geom.w)
            let targetY = geom.y + (entry.rel_y * geom.h)
            let targetW = entry.rel_w * geom.w
            let targetH = entry.rel_h * geom.h

            let alreadyThere = !isFs && onDisplay &&
                abs(curPos.x - targetX) < 25 && abs(curPos.y - targetY) < 25
            if alreadyThere {
                continue
            }

            targetApp.activate()

            if isFs {
                let falseVal: CFBoolean = kCFBooleanFalse
                AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, falseVal)
                for _ in 0..<20 {
                    usleep(100_000)
                    var checkFs: CFTypeRef?
                    AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &checkFs)
                    if (checkFs as? Bool) == false { break }
                }
                usleep(250_000)
            }

            var pt = CGPoint(x: targetX, y: targetY)
            var sz = CGSize(width: targetW, height: targetH)

            if let axPos = AXValueCreate(.cgPoint, &pt) {
                for _ in 0..<5 {
                    let err = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, axPos)
                    if err == .success { break }
                    usleep(100_000)
                }
            }
            if let axSize = AXValueCreate(.cgSize, &sz) {
                _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, axSize)
            }

            if entry.type == "chrome_profile", let winId = targetWinId {
                let asScript = """
                tell application "Google Chrome"
                    set bounds of window id \(winId) to {\(Int(targetX)), \(Int(targetY)), \(Int(targetX + targetW)), \(Int(targetY + targetH))}
                end tell
                """
                if let asObj = NSAppleScript(source: asScript) {
                    var err: NSDictionary?
                    _ = asObj.executeAndReturnError(&err)
                }
            }
        }
    }

    printAppSummary(entries: entries, action: "Restored")
}

// MARK: - Main

let args = CommandLine.arguments

guard args.count >= 2 else {
    printErr("Usage:")
    printErr("  screenstamp-app-helper permissions")
    printErr("  screenstamp-app-helper save <displays.json> <output.apps>")
    printErr("  screenstamp-app-helper load <displays.json> <input.apps>")
    exit(2)
}

let mode = args[1]

switch mode {
case "permissions":
    if checkAccessibility(prompt: true) {
        print("Accessibility permissions: OK")
        exit(0)
    } else {
        exit(1)
    }
case "save":
    guard args.count >= 4 else {
        printErr("Usage: screenstamp-app-helper save <displays.json> <output.apps>")
        exit(2)
    }
    saveApps(displaysPath: args[2], outputPath: args[3])
case "load":
    guard args.count >= 4 else {
        printErr("Usage: screenstamp-app-helper load <displays.json> <input.apps>")
        exit(2)
    }
    restoreApps(displaysPath: args[2], inputPath: args[3])
default:
    printErr("unknown mode: \(mode)")
    exit(2)
}
