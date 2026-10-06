import Foundation

/// A release as GitHub's API describes it, with the parts an updater needs.
public struct ReleaseInfo: Equatable {
    public struct Asset: Equatable {
        public let name: String
        public let url: URL
        /// Hex SHA-256, when GitHub reports one.
        public let sha256: String?
    }

    public let version: String
    public let notes: String
    public let pageURL: URL
    public let assets: [Asset]

    /// The Windows package for an architecture: `Termsie-<version>-windows-<arch>.zip`.
    public func windowsZip(arch: String) -> Asset? {
        assets.first { $0.name == "\(AppInfo.name)-\(version)-windows-\(arch).zip" }
            ?? assets.first { $0.name.lowercased().hasSuffix("-windows-\(arch).zip") }
    }

    public func asset(named name: String) -> Asset? {
        assets.first { $0.name == name }
    }
}

public enum ReleaseFeed {
    public struct FeedError: LocalizedError {
        public let errorDescription: String?
        public init(_ message: String) { errorDescription = message }
    }

    /// Parses the body of `GET /repos/{owner}/{repo}/releases/latest`.
    public static func parse(_ data: Data) throws -> ReleaseInfo {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadUrl: URL
                let digest: String?
            }
            let tagName: String
            let htmlUrl: URL
            let body: String?
            let assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            throw FeedError("The release information could not be read.")
        }
        let version = payload.tagName.hasPrefix("v") ? String(payload.tagName.dropFirst()) : payload.tagName
        let assets = payload.assets.map { a in
            ReleaseInfo.Asset(name: a.name, url: a.browserDownloadUrl,
                              sha256: a.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil })
        }
        return ReleaseInfo(version: version, notes: payload.body ?? "", pageURL: payload.htmlUrl, assets: assets)
    }

    /// Numeric, component-wise, so 0.10.0 is newer than 0.9.0. Missing components count as zero.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let trimmed = s.hasPrefix("v") ? s.dropFirst() : Substring(s)
            return trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Hex text of a digest, lowercase.
    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
