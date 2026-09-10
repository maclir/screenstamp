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
    let rel_space: Int?         // relative to desktop (0 = desktop)
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
    var rawProfiles: [(dir: String, name: String, matches: [String])] = []
    let localStatePath = ("~/Library/Application Support/Google/Chrome/Local State" as NSString).expandingTildeInPath
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: localStatePath)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let profileObj = json["profile"] as? [String: Any],
          let infoCache = profileObj["info_cache"] as? [String: [String: Any]] else {
        return rawProfiles
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
        rawProfiles.append((dir: dirName, name: dispName, matches: names))
    }

    // Discard any match terms shared across multiple profiles (e.g. user's first/last name)
    var termCounts: [String: Int] = [:]
    for p in rawProfiles {
        var seenInProf = Set<String>()
        for m in p.matches {
            let low = m.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if low.count >= 3 && !seenInProf.contains(low) {
                seenInProf.insert(low)
                termCounts[low, default: 0] += 1
            }
        }
    }

    var filteredProfiles: [(dir: String, name: String, matches: [String])] = []
    for p in rawProfiles {
        var uniqueMatches: [String] = []
        for m in p.matches {
            let low = m.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if low.count >= 3 && termCounts[low] == 1 && !uniqueMatches.contains(low) {
                uniqueMatches.append(low)
            }
        }
        filteredProfiles.append((dir: p.dir, name: p.name, matches: uniqueMatches))
    }
    return filteredProfiles
}

func scoreChromeProfile(title: String, allText: String, profile: (dir: String, name: String, matches: [String])) -> Int {
    let lowerTitle = title.lowercased()
    let lowerText = allText.lowercased()
    var score = 0

    if lowerTitle.contains("(\(profile.name.lowercased()))") ||
       lowerTitle.contains("- \(profile.name.lowercased())") {
        score += 100
    }

    for term in profile.matches {
        if lowerText.contains(term) {
            let weight = (term.contains("@") || term.contains(".")) ? 50 : 10
            score += weight
        }
    }
    return score
}

func resolveChromeProfile(title: String, text: String, profiles: [(dir: String, name: String, matches: [String])]) -> (dir: String, name: String) {
    var bestMatch: (dir: String, name: String)? = nil
    var bestScore = 0

    for prof in profiles {
        let score = scoreChromeProfile(title: title, allText: text, profile: prof)
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
                set out to out & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & "<#COL#>" & n & "<#COL#>" & allTabs & "<#ROW#>"
            end if
        end repeat
        return out
    end tell
    """
    if let appleScript = NSAppleScript(source: chromeScript) {
        var error: NSDictionary?
        let res = appleScript.executeAndReturnError(&error)
        if let str = res.stringValue {
            for row in str.components(separatedBy: "<#ROW#>") {
                let parts = row.components(separatedBy: "<#COL#>")
                if parts.count >= 2 {
                    let coords = parts[0].split(separator: ",").compactMap { Double($0) }
                    if coords.count == 4 {
                        let title = parts[1]
                        let allText = parts.count > 2 ? parts[2] : title
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

// MARK: - Spaces Detection Helper

typealias CGSConnectionID = Int32
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray?

struct SpacesInfo {
    var widToRelSpace: [Int: Int] = [:]
    var roleAndPidToRelSpace: [String: Int] = [:]
}

func querySpacesInfo(displays: [String: DisplayGeom]) -> SpacesInfo {
    var info = SpacesInfo()
    let cid = CGSMainConnectionID()
    guard let spacesArr = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else {
        return info
    }

    var displayCount: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &displayCount)
    var dList = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    CGGetOnlineDisplayList(displayCount, &dList, &displayCount)

    var uuidToRole: [String: String] = [:]
    for d in dList {
        guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(d)?.takeRetainedValue() else { continue }
        let uuidStr = CFUUIDCreateString(nil, uuidRef) as String
        let bounds = CGDisplayBounds(d)
        if let role = findDisplayRole(x: bounds.origin.x, y: bounds.origin.y, w: bounds.width, h: bounds.height, displays: displays) {
            uuidToRole[uuidStr] = role
        }
    }

    for d in spacesArr {
        guard let dispId = d["Display Identifier"] as? String,
              let sps = d["Spaces"] as? [[String: Any]] else { continue }
        let role = uuidToRole[dispId]
        let desktopIdx = sps.firstIndex(where: { ($0["type"] as? Int) == 0 }) ?? 0

        for (idx, sp) in sps.enumerated() {
            let rel = idx - desktopIdx
            if let fsWid = sp["fs_wid"] as? Int, fsWid > 0 {
                info.widToRelSpace[fsWid] = rel
            }
            if let pid = sp["pid"] as? Int, pid > 0, let r = role {
                info.roleAndPidToRelSpace["\(r):\(pid)"] = rel
            }
            if let tlm = sp["TileLayoutManager"] as? [String: Any],
               let tSpaces = tlm["TileSpaces"] as? [[String: Any]] {
                for ts in tSpaces {
                    if let twid = ts["TileWindowID"] as? Int, twid > 0 {
                        info.widToRelSpace[twid] = rel
                    }
                    if let fwid = ts["fs_wid"] as? Int, fwid > 0 {
                        info.widToRelSpace[fwid] = rel
                    }
                    if let tpid = ts["pid"] as? Int, tpid > 0, let r = role {
                        info.roleAndPidToRelSpace["\(r):\(tpid)"] = rel
                    }
                }
            }
        }
    }

    return info
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

        let rolePadded = entry.display_role.padding(toLength: 10, withPad: " ", startingAt: 0)
        let targetStr: String
        let sp = entry.rel_space
        if entry.fullscreen {
            if let s = sp {
                targetStr = "\(rolePadded) (Space \(s), Fullscreen)"
            } else {
                targetStr = "\(rolePadded) (Fullscreen)"
            }
        } else {
            let xStr = String(format: "%.2f", entry.rel_x)
            let yStr = String(format: "%.2f", entry.rel_y)
            if let s = sp {
                targetStr = "\(rolePadded) (Space \(s), Desktop side: x=\(xStr), y=\(yStr))"
            } else {
                targetStr = "\(rolePadded) (Desktop side: x=\(xStr), y=\(yStr))"
            }
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
    let spacesInfo = querySpacesInfo(displays: displays)
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
        let wid = w[kCGWindowNumber as String] as? Int ?? 0
        let relSpace: Int = isFs ? (spacesInfo.widToRelSpace[wid] ?? spacesInfo.roleAndPidToRelSpace["\(role):\(pid)"] ?? 1) : 0
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
                rel_space: relSpace,
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
                rel_space: relSpace,
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

    let chromeApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first
    let chromePid = chromeApp?.processIdentifier ?? 0

    // Process Chrome windows from AppleScript
    for cw in chromeWindows {
        guard let role = findDisplayRole(x: cw.x, y: cw.y, w: cw.w, h: cw.h, displays: displays),
              let geom = displays[role] else { continue }

        let isFs = fsDisplaysForChrome.contains(role) && (abs(cw.w - geom.w) <= 25.0) && (cw.h >= geom.h * 0.75)
        let (matchedDir, matchedName) = resolveChromeProfile(title: cw.title, text: cw.allText, profiles: chromeProfiles)

        if seenChromeProfiles.contains(matchedDir) { continue }
        seenChromeProfiles.insert(matchedDir)

        var chromeWid: Int? = nil
        for rw in rawWins {
            guard (rw[kCGWindowOwnerName as String] as? String) == "Google Chrome",
                  let b = rw[kCGWindowBounds as String] as? [String: Any],
                  let rx = b["X"] as? Double,
                  let ry = b["Y"] as? Double,
                  let rwId = rw[kCGWindowNumber as String] as? Int else { continue }
            if abs(rx - cw.x) < 50 && abs(ry - cw.y) < 50 {
                chromeWid = rwId
                break
            }
        }
        let chromeRelSpace: Int = isFs ? (chromeWid.flatMap { spacesInfo.widToRelSpace[$0] } ?? spacesInfo.roleAndPidToRelSpace["\(role):\(chromePid)"] ?? 1) : 0

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
            rel_space: chromeRelSpace,
            rel_x: isFs ? 0.0 : relX,
            rel_y: isFs ? 0.0 : relY,
            rel_w: relW,
            rel_h: relH
        ))
    }

    // Sort entries by display role and relative space for consistent, readable ordering
    entries.sort {
        if $0.display_role != $1.display_role {
            if $0.display_role.hasPrefix("external") && $1.display_role.hasPrefix("builtin") {
                return true
            }
            if $0.display_role.hasPrefix("builtin") && $1.display_role.hasPrefix("external") {
                return false
            }
            return $0.display_role < $1.display_role
        }
        let s0 = $0.rel_space ?? 0
        let s1 = $1.rel_space ?? 0
        if s0 != s1 {
            return s0 < s1
        }
        return $0.app_name < $1.app_name
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
    let script = """
    tell application "Google Chrome"
        set out to ""
        repeat with w in windows
            set winId to id of w
            set n to name of w
            set allTabs to n & " "
            try
                repeat with t in tabs of w
                    set allTabs to allTabs & (URL of t) & " " & (title of t) & " "
                end repeat
            end try
            set out to out & winId & "<#COL#>" & n & "<#COL#>" & allTabs & "<#ROW#>"
        end repeat
        return out
    end tell
    """

    var parsedWindows: [(winId: Int, title: String, allText: String)] = []
    if let asObj = NSAppleScript(source: script) {
        var err: NSDictionary?
        if let outStr = asObj.executeAndReturnError(&err).stringValue {
            for row in outStr.components(separatedBy: "<#ROW#>") {
                let cols = row.components(separatedBy: "<#COL#>")
                if cols.count >= 3, let wid = Int(cols[0]) {
                    parsedWindows.append((winId: wid, title: cols[1], allText: cols[2]))
                }
            }
        }
    }

    guard let targetProfile = profiles.first(where: { $0.dir == profileDir }) else {
        return (nil, nil)
    }

    var bestWinId: Int? = nil
    var bestWinTitle = ""
    var bestScore = -1

    for w in parsedWindows {
        let score = scoreChromeProfile(title: w.title, allText: w.allText, profile: targetProfile)
        if score > bestScore {
            bestScore = score
            bestWinId = w.winId
            bestWinTitle = w.title
        }
    }

    let winToActivate = (bestScore > 0 ? bestWinId : nil) ?? bestWinId ?? parsedWindows.first?.winId
    if let winId = winToActivate {
        let actScript = """
        tell application "Google Chrome"
            activate
            repeat with w in windows
                if (id of w) is \(winId) then
                    set index of w to 1
                    exit repeat
                end if
            end repeat
        end tell
        """
        if let asObj = NSAppleScript(source: actScript) {
            var err: NSDictionary?
            _ = asObj.executeAndReturnError(&err)
        }
        usleep(300_000)
    }

    let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.google.Chrome" }
    guard let chrome = apps.first else { return (nil, winToActivate) }
    let axApp = AXUIElementCreateApplication(chrome.processIdentifier)

    var candidateWindows: [AXUIElement] = []
    var seenHashes = Set<CFHashCode>()
    func addWin(_ el: AXUIElement) {
        let h = CFHash(el)
        if !seenHashes.contains(h) {
            seenHashes.insert(h)
            candidateWindows.append(el)
        }
    }

    var winsRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
       let wins = winsRef as? [AXUIElement] {
        wins.forEach { addWin($0) }
    }

    var chRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &chRef) == .success,
       let chs = chRef as? [AXUIElement] {
        for c in chs {
            var rRef: CFTypeRef?
            AXUIElementCopyAttributeValue(c, kAXRoleAttribute as CFString, &rRef)
            if (rRef as? String) == "AXWindow" {
                addWin(c)
            }
        }
    }

    var mainVal: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &mainVal) == .success,
       let m = mainVal { addWin(m as! AXUIElement) }
    var focVal: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focVal) == .success,
       let f = focVal { addWin(f as! AXUIElement) }

    // Find best candidate window matching targetProfile
    var bestAxWin: AXUIElement? = nil
    var bestAxScore = -1000

    for w in candidateWindows {
        var sVal: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sVal)
        var sz = CGSize.zero
        if let s = sVal { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
        guard sz.width >= 300 && sz.height >= 200 else { continue }

        var tVal: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &tVal)
        let title = (tVal as? String) ?? ""
        let lowerTitle = title.lowercased()

        var score = 0
        let targetNameLower = targetProfile.name.lowercased()
        if lowerTitle.contains("(\(targetNameLower))") || lowerTitle.contains("- \(targetNameLower)") {
            score += 200
        }

        for other in profiles where other.dir != targetProfile.dir {
            let otherNameLower = other.name.lowercased()
            if lowerTitle.contains("(\(otherNameLower))") || lowerTitle.contains("- \(otherNameLower)") {
                score -= 200
            }
        }

        for term in targetProfile.matches {
            if lowerTitle.contains(term) {
                score += 50
            }
        }

        if !bestWinTitle.isEmpty && (title.contains(bestWinTitle) || bestWinTitle.contains(title)) {
            score += 100
        }

        if score > bestAxScore {
            bestAxScore = score
            bestAxWin = w
        }
    }

    if let win = bestAxWin, bestAxScore > 0 {
        return (win, winToActivate)
    }

    return (candidateWindows.first, winToActivate)
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

    var sortedEntries = entries
    sortedEntries.sort {
        if $0.display_role != $1.display_role {
            if $0.display_role.hasPrefix("external") && $1.display_role.hasPrefix("builtin") {
                return true
            }
            if $0.display_role.hasPrefix("builtin") && $1.display_role.hasPrefix("external") {
                return false
            }
            return $0.display_role < $1.display_role
        }
        let s0 = $0.rel_space ?? 0
        let s1 = $1.rel_space ?? 0
        if s0 != s1 {
            return s0 < s1
        }
        return $0.app_name < $1.app_name
    }

    for entry in sortedEntries {
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
        if entry.type == "chrome_profile" {
            let res = activateChromeWindow(profileDir: entry.profile_dir ?? "Default", profiles: chromeProfiles)
            targetWin = res.win
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
                usleep(300_000)
            }

            var targetPt = CGPoint(x: geom.x + 100.0, y: geom.y + 100.0)
            if let axPos = AXValueCreate(.cgPoint, &targetPt) {
                for _ in 0..<10 {
                    let err = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, axPos)
                    if err == .success { break }
                    usleep(100_000)
                }
            }
            usleep(250_000)

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
                usleep(300_000)
            }

            var pt = CGPoint(x: targetX, y: targetY)
            var sz = CGSize(width: targetW, height: targetH)

            if let axPos = AXValueCreate(.cgPoint, &pt) {
                for _ in 0..<10 {
                    let err = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, axPos)
                    if err == .success { break }
                    usleep(100_000)
                }
            }
            if let axSize = AXValueCreate(.cgSize, &sz) {
                _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, axSize)
            }
            if let axPos = AXValueCreate(.cgPoint, &pt) {
                _ = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, axPos)
            }
        }
    }

    printAppSummary(entries: sortedEntries, action: "Restored")
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
