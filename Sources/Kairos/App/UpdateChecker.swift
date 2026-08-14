import Foundation

/// 轻量更新检查：调 GitHub API 拿最新 release 的 tag，和当前版本号比较。
/// 只做「检查 + 打开下载页」，不自动下载安装——ad-hoc 签名下自动更新会被
/// Gatekeeper 拦，等有 Apple Developer 账号 + 公证后换 Sparkle，这里先占位。
enum UpdateChecker {
    static let repoURL = URL(string: "https://api.github.com/repos/lodrg/kairos/releases/latest")!

    /// 当前版本号（Info.plist 的 CFBundleShortVersionString；裸二进制运行时拿不到
    /// bundle 信息会退回 0.0.0，打包成 .app 后正常）
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// 查最新 release 版本号；网络失败 / 非 200 / 解析失败返回 nil
    static func latestVersion() async -> String? {
        var request = URLRequest(url: repoURL)
        request.setValue("Kairos/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// 版本号数字比较（major.minor.patch），a > b 返回 true
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").compactMap { Int($0) } }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 某版本的 GitHub Release 下载页 URL
    static func downloadPageURL(for version: String) -> URL {
        URL(string: "https://github.com/lodrg/kairos/releases/tag/v\(version)")!
    }
}
