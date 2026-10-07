import Foundation
import Combine
import UIKit

public final class InstalledAppsScanner: ObservableObject {
    public static let shared = InstalledAppsScanner()

    @Published public private(set) var installedApps: [InstalledAppInfo] = []
    @Published public private(set) var isScanning = false

    private init() {}

    public func scanApps(includeSystem: Bool = false) {
        DispatchQueue.main.async { self.isScanning = true }
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [InstalledAppInfo] = []
            var seen = Set<String>()

            // 1. Quét qua Private API LSApplicationWorkspace
            self.scanViaWorkspace(includeSystem: includeSystem, results: &results, seen: &seen)

            // 2. Quét qua Filesystem (cho môi trường Jailbreak / Rootless / TrollStore)
            self.scanViaFileSystem(includeSystem: includeSystem, results: &results, seen: &seen)

            // 3. Quét qua URL Schemes cho các ứng dụng phổ biến (Sandbox fallback)
            self.scanViaURLSchemes(results: &results, seen: &seen)

            // 4. Đồng bộ từ TweakBridge Snapshots
            self.scanViaSnapshots(results: &results, seen: &seen)

            // 5. Thêm chính NappStore
            if let ownBundleID = Bundle.main.bundleIdentifier, seen.insert(ownBundleID).inserted {
                let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? "NappStore"
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
                results.append(InstalledAppInfo(bundleId: ownBundleID, appName: name, version: version, isSystemApp: false, hasIAPSupport: false, containerPath: nil))
            }

            results.sort { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }

            DispatchQueue.main.async {
                self.installedApps = results
                self.isScanning = false
            }
        }
    }

    private func scanViaWorkspace(includeSystem: Bool, results: inout [InstalledAppInfo], seen: inout Set<String>) {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as AnyObject as? NSObjectProtocol else { return }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard workspaceClass.responds(to: defaultSelector),
              let workspace = workspaceClass.perform(defaultSelector)?.takeUnretainedValue() as AnyObject? else { return }

        var proxies: [AnyObject] = []
        let candidateSelectors = [
            NSSelectorFromString("allApplications"),
            NSSelectorFromString("allInstalledApplications")
        ]

        for selector in candidateSelectors {
            if workspace.responds(to: selector),
               let list = workspace.perform(selector)?.takeUnretainedValue() as? [AnyObject], !list.isEmpty {
                proxies = list
                break
            }
        }

        for proxy in proxies {
            guard let bundleID = (proxy.value(forKey: "bundleIdentifier") as? String) ?? (proxy.value(forKey: "applicationIdentifier") as? String),
                  !bundleID.isEmpty else { continue }
            let name = (proxy.value(forKey: "localizedName") as? String) ?? bundleID
            let version = (proxy.value(forKey: "shortVersionString") as? String) ?? "1.0"
            let applicationType = (proxy.value(forKey: "applicationType") as? String) ?? "User"
            let system = applicationType.lowercased().contains("system")
            if system && !includeSystem { continue }
            if seen.insert(bundleID).inserted {
                let path = (proxy.value(forKey: "bundleURL") as? URL)?.path
                results.append(InstalledAppInfo(bundleId: bundleID, appName: name, version: version, isSystemApp: system, hasIAPSupport: true, containerPath: path))
            }
        }
    }

    private func scanViaFileSystem(includeSystem: Bool, results: inout [InstalledAppInfo], seen: inout Set<String>) {
        let fm = FileManager.default
        var scanDirs: [(path: String, isSystem: Bool)] = [
            ("/Applications", true),
            ("/var/jb/Applications", false),
            ("/var/containers/Bundle/Application", false)
        ]

        for (dirPath, isSys) in scanDirs {
            if isSys && !includeSystem { continue }
            guard fm.fileExists(atPath: dirPath) else { continue }

            if let items = try? fm.contentsOfDirectory(atPath: dirPath) {
                for item in items {
                    let fullPath = (dirPath as NSString).appendingPathComponent(item)
                    if item.hasSuffix(".app") {
                        parseAppBundle(at: fullPath, isSystem: isSys, results: &results, seen: &seen)
                    } else if dirPath.contains("containers") {
                        // Cấu trúc /var/containers/Bundle/Application/<UUID>/<App>.app
                        if let subItems = try? fm.contentsOfDirectory(atPath: fullPath) {
                            for sub in subItems where sub.hasSuffix(".app") {
                                parseAppBundle(at: (fullPath as NSString).appendingPathComponent(sub), isSystem: isSys, results: &results, seen: &seen)
                            }
                        }
                    }
                }
            }
        }
    }

    private func parseAppBundle(at bundlePath: String, isSystem: Bool, results: inout [InstalledAppInfo], seen: inout Set<String>) {
        let plistPath = (bundlePath as NSString).appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { return }

        guard seen.insert(bundleID).inserted else { return }
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? bundleID
        let version = (plist["CFBundleShortVersionString"] as? String) ?? "1.0"
        results.append(InstalledAppInfo(bundleId: bundleID, appName: name, version: version, isSystemApp: isSystem, hasIAPSupport: true, containerPath: bundlePath))
    }

    private func scanViaURLSchemes(results: inout [InstalledAppInfo], seen: inout Set<String>) {
        let knownProbeApps: [(bundleId: String, name: String, scheme: String)] = [
            ("com.lemon.lvoverseas", "CapCut", "capcut"),
            ("com.google.ios.youtube", "YouTube", "youtube"),
            ("com.openai.chat", "ChatGPT", "chatgpt"),
            ("com.duolingo.DuolingoMobile", "Duolingo", "duolingo"),
            ("com.canva.canva", "Canva", "canva"),
            ("ph.telegra.Telegraph", "Telegram", "tg"),
            ("com.facebook.Facebook", "Facebook", "fb"),
            ("com.facebook.Messenger", "Messenger", "fb-messenger"),
            ("com.zhiliaoapp.musically", "TikTok", "tiktok"),
            ("com.burbn.instagram", "Instagram", "instagram"),
            ("com.atebits.Tweetie2", "X (Twitter)", "twitter"),
            ("com.vng.zalo", "Zalo", "zalo"),
            ("com.spotify.client", "Spotify", "spotify"),
            ("com.netflix.Netflix", "Netflix", "netflix"),
            ("com.google.chrome.ios", "Google Chrome", "googlechrome"),
            ("com.google.Gmail", "Gmail", "googlegmail"),
            ("com.hammerandchisel.discord", "Discord", "discord"),
            ("com.reddit.Reddit", "Reddit", "reddit"),
            ("com.instagram.barcelona", "Threads", "threads"),
            ("com.beeptool.Shopee", "Shopee", "shopee"),
            ("com.mservice.momopay", "MoMo", "momo")
        ]

        var detected: [(bundleId: String, name: String)] = []
        let group = DispatchGroup()
        group.enter()

        DispatchQueue.main.async {
            for app in knownProbeApps {
                if let url = URL(string: "\(app.scheme)://"), UIApplication.shared.canOpenURL(url) {
                    detected.append((bundleId: app.bundleId, name: app.name))
                }
            }
            group.leave()
        }

        group.wait()

        for item in detected {
            if seen.insert(item.bundleId).inserted {
                results.append(InstalledAppInfo(
                    bundleId: item.bundleId,
                    appName: item.name,
                    version: "Installed",
                    isSystemApp: false,
                    hasIAPSupport: true,
                    containerPath: nil
                ))
            }
        }
    }

    private func scanViaSnapshots(results: inout [InstalledAppInfo], seen: inout Set<String>) {
        for snapshot in TweakBridge.shared.snapshots {
            if seen.insert(snapshot.bundleId).inserted {
                results.append(InstalledAppInfo(
                    bundleId: snapshot.bundleId,
                    appName: snapshot.appName.isEmpty ? snapshot.bundleId : snapshot.appName,
                    version: "Bridge",
                    isSystemApp: false,
                    hasIAPSupport: true,
                    containerPath: nil
                ))
            }
        }
    }

    public func addCustomApp(bundleId: String, appName: String) {
        let trimmed = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !installedApps.contains(where: { $0.bundleId == trimmed }) else { return }
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        installedApps.insert(
            InstalledAppInfo(bundleId: trimmed, appName: name.isEmpty ? trimmed : name, version: "Custom", isSystemApp: false, hasIAPSupport: true, containerPath: nil),
            at: 0
        )
    }

    public func launchApp(bundleId: String) {
        let knownSchemes: [String: String] = [
            "com.lemon.lvoverseas": "capcut",
            "com.openai.chat": "chatgpt",
            "com.google.ios.youtube": "youtube",
            "com.duolingo.DuolingoMobile": "duolingo",
            "com.canva.canva": "canva",
            "ph.telegra.Telegraph": "tg",
            "com.facebook.Facebook": "fb",
            "com.facebook.Messenger": "fb-messenger",
            "com.zhiliaoapp.musically": "tiktok",
            "com.burbn.instagram": "instagram",
            "com.atebits.Tweetie2": "twitter",
            "com.vng.zalo": "zalo",
            "com.spotify.client": "spotify",
            "com.netflix.Netflix": "netflix",
            "com.google.chrome.ios": "googlechrome",
            "com.google.Gmail": "googlegmail",
            "com.hammerandchisel.discord": "discord",
            "com.reddit.Reddit": "reddit",
            "com.instagram.barcelona": "threads",
            "com.beeptool.Shopee": "shopee",
            "com.mservice.momopay": "momo"
        ]

        // 1. Mở qua URL Scheme
        let scheme = knownSchemes[bundleId] ?? bundleId
        if let url = URL(string: "\(scheme)://") {
            UIApplication.shared.open(url, options: [:]) { success in
                if !success {
                    // Fallback mở qua Private API workspace nếu có
                    self.launchViaWorkspace(bundleId: bundleId)
                }
            }
            return
        }

        self.launchViaWorkspace(bundleId: bundleId)
    }

    private func launchViaWorkspace(bundleId: String) {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as AnyObject as? NSObjectProtocol else { return }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard workspaceClass.responds(to: defaultSelector),
              let workspace = workspaceClass.perform(defaultSelector)?.takeUnretainedValue() as AnyObject? else { return }

        let openSelector = NSSelectorFromString("openApplicationWithBundleID:")
        if workspace.responds(to: openSelector) {
            _ = workspace.perform(openSelector, with: bundleId)
        }
    }
}
