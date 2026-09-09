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
        if let un = info["user_name"] as? String { names.append(un) }
        let dispName = (info["name"] as? String) ?? (info["gaia_given_name"] as? String) ?? dirName
        profiles.append((dir: dirName, name: dispName, matches: names))
    }
    return profiles
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

// MARK: - Save

func saveApps(displaysPath: String, outputPath: String) {
    if !checkAccessibility(prompt: true) {
        printErr("screenstamp: Accessibility permissions are not yet enabled. Enable them in System Settings, then retry.")
        exit(1)
    }

    let displays = parseDisplays(from: displaysPath)
    let chromeProfiles = loadChromeProfiles()
    var entries: [WindowEntry] = []

    let ignoredBundleIds: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.loginwindow",
        "com.apple.SystemUIServer",
        "com.apple.WindowManager"
    ]

    for app in NSWorkspace.shared.runningApplications {
        guard app.activationPolicy == .regular else { continue }
        guard let bundleId = app.bundleIdentifier, !ignoredBundleIds.contains(bundleId) else { continue }

        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &winRef) == .success,
              let windows = winRef as? [AXUIElement] else { continue }

        let isChrome = (bundleId == "com.google.Chrome")
        let isPwa = bundleId.hasPrefix("com.google.Chrome.app.") ||
                    (app.bundleURL?.path.contains("Chrome Apps") == true)

        for win in windows {
            var roleRef: CFTypeRef?
            var subroleRef: CFTypeRef?
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            var fullRef: CFTypeRef?
            var titleRef: CFTypeRef?

            AXUIElementCopyAttributeValue(win, kAXRoleAttribute as CFString, &roleRef)
            AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleRef)
            AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
            AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)
            AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fullRef)
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)

            let role = (roleRef as? String) ?? ""
            let subrole = (subroleRef as? String) ?? ""
            guard role == "AXWindow" else { continue }
            if subrole == "AXUnknown" && (titleRef as? String ?? "").isEmpty { continue }

            var pos = CGPoint.zero
            var size = CGSize.zero
            if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
            if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &size) }
            let isFs = (fullRef as? Bool) ?? false
            let title = (titleRef as? String) ?? ""

            // Skip tiny/invisible accessory windows
            if size.width < 100 || size.height < 100 { continue }

            guard let displayRole = findDisplayRole(x: pos.x, y: pos.y, w: size.width, h: size.height, displays: displays),
                  let geom = displays[displayRole] else { continue }

            let relX = max(0.0, min(1.0, (pos.x - geom.x) / geom.w))
            let relY = max(0.0, min(1.0, (pos.y - geom.y) / geom.h))
            let relW = max(0.05, min(1.0, size.width / geom.w))
            let relH = max(0.05, min(1.0, size.height / geom.h))

            if isPwa {
                entries.append(WindowEntry(
                    type: "pwa",
                    bundle_id: bundleId,
                    app_name: app.localizedName ?? "PWA",
                    app_path: app.bundleURL?.path,
                    profile_dir: nil,
                    profile_name: nil,
                    display_role: displayRole,
                    fullscreen: isFs,
                    rel_x: relX,
                    rel_y: relY,
                    rel_w: relW,
                    rel_h: relH
                ))
            } else if isChrome {
                // Match profile from title suffix e.g. " - Google Chrome - <ProfileName>"
                var matchedDir = "Default"
                var matchedName = "Default"

                for prof in chromeProfiles {
                    var found = false
                    for match in prof.matches {
                        if title.contains(" - \(match)") || title.contains(" - Google Chrome - \(match)") {
                            matchedDir = prof.dir
                            matchedName = prof.name
                            found = true
                            break
                        }
                    }
                    if found { break }
                }

                entries.append(WindowEntry(
                    type: "chrome_profile",
                    bundle_id: bundleId,
                    app_name: "Google Chrome",
                    app_path: app.bundleURL?.path,
                    profile_dir: matchedDir,
                    profile_name: matchedName,
                    display_role: displayRole,
                    fullscreen: isFs,
                    rel_x: relX,
                    rel_y: relY,
                    rel_w: relW,
                    rel_h: relH
                ))
            } else {
                entries.append(WindowEntry(
                    type: "app",
                    bundle_id: bundleId,
                    app_name: app.localizedName ?? bundleId,
                    app_path: app.bundleURL?.path,
                    profile_dir: nil,
                    profile_name: nil,
                    display_role: displayRole,
                    fullscreen: isFs,
                    rel_x: relX,
                    rel_y: relY,
                    rel_w: relW,
                    rel_h: relH
                ))
            }
        }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(entries) else {
        printErr("screenstamp: could not encode app entries to JSON")
        exit(1)
    }

    do {
        try data.write(to: URL(fileURLWithPath: outputPath))
        print("Saved \(entries.count) app placement(s).")
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

    // 1. Regular apps & PWAs
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
    var processedChromeWindows = Set<Int>()

    for entry in entries {
        guard let geom = displays[entry.display_role] else {
            printErr("Warning: display role '\(entry.display_role)' not found for \(entry.app_name)")
            continue
        }

        let candidateApps: [NSRunningApplication]
        if entry.type == "chrome_profile" {
            candidateApps = running.filter { $0.bundleIdentifier == "com.google.Chrome" }
        } else if entry.type == "pwa" {
            candidateApps = running.filter { $0.bundleIdentifier == entry.bundle_id }
        } else {
            candidateApps = running.filter { $0.bundleIdentifier == entry.bundle_id }
        }

        guard let targetApp = candidateApps.first else { continue }
        let appElement = AXUIElementCreateApplication(targetApp.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &winRef) == .success,
              let windows = winRef as? [AXUIElement] else { continue }

        var targetWin: AXUIElement? = nil
        for (i, win) in windows.enumerated() {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String) ?? ""

            if entry.type == "chrome_profile" {
                if processedChromeWindows.contains(i) { continue }
                let profileMatch = entry.profile_name ?? entry.profile_dir ?? ""
                if title.contains(profileMatch) || entries.filter({ $0.type == "chrome_profile" }).count == 1 {
                    targetWin = win
                    processedChromeWindows.insert(i)
                    break
                }
            } else {
                targetWin = win
                break
            }
        }

        guard let win = targetWin else { continue }

        var fullRef: CFTypeRef?
        var posRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fullRef)
        AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
        let isFs = (fullRef as? Bool) ?? false
        var curPos = CGPoint.zero
        if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &curPos) }

        if entry.fullscreen {
            let alreadyOnDisplay = isFs &&
                curPos.x >= geom.x && curPos.x < (geom.x + geom.w) &&
                curPos.y >= geom.y && curPos.y < (geom.y + geom.h)

            if alreadyOnDisplay {
                continue
            }

            if isFs {
                let falseVal: CFBoolean = kCFBooleanFalse
                AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, falseVal)
                usleep(400_000)
            }

            var targetPt = CGPoint(x: geom.x + 50.0, y: geom.y + 50.0)
            if let axPos = AXValueCreate(.cgPoint, &targetPt) {
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, axPos)
                usleep(150_000)
            }

            let trueVal: CFBoolean = kCFBooleanTrue
            AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, trueVal)
            usleep(400_000)
        } else {
            if isFs {
                let falseVal: CFBoolean = kCFBooleanFalse
                AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, falseVal)
                usleep(400_000)
            }

            let targetX = geom.x + (entry.rel_x * geom.w)
            let targetY = geom.y + (entry.rel_y * geom.h)
            let targetW = entry.rel_w * geom.w
            let targetH = entry.rel_h * geom.h

            var pt = CGPoint(x: targetX, y: targetY)
            var sz = CGSize(width: targetW, height: targetH)

            if let axPos = AXValueCreate(.cgPoint, &pt) {
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, axPos)
            }
            if let axSize = AXValueCreate(.cgSize, &sz) {
                AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, axSize)
            }
        }
    }

    print("Restored app placements.")
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
