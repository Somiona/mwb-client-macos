import Foundation

@MainActor
@Observable
final class VersionChecker {
    static let shared = VersionChecker()

    enum CheckState {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String, url: URL)
        case failed
    }

    private(set) var state: CheckState = .idle

    private init() {}

    var latestVersion: String? {
        if case .updateAvailable(let v, _) = state { return v }
        return nil
    }

    var releaseURL: URL? {
        if case .updateAvailable(_, let u) = state { return u }
        return nil
    }

    var isUpdateAvailable: Bool {
        if case .updateAvailable = state { return true }
        return false
    }

    var hasFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    func checkIfNeeded() {
        switch state {
        case .idle, .failed:
            break
        case .checking, .upToDate, .updateAvailable:
            return
        }

        state = .checking

        Task {
            guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
                mwbWarning(MWBLog.coordinator, "Version check: could not read current version from bundle")
                state = .failed
                return
            }

            mwbInfo(MWBLog.coordinator, "Version check: current version is \(current), fetching latest from GitHub")

            let url = URL(string: "https://api.github.com/repos/Somiona/mwb-client-macos/releases")!
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                mwbWarning(MWBLog.coordinator, "Version check: network request failed — \(error.localizedDescription)")
                state = .failed
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                mwbWarning(MWBLog.coordinator, "Version check: unexpected response type")
                state = .failed
                return
            }

            guard httpResponse.statusCode == 200 else {
                mwbWarning(MWBLog.coordinator, "Version check: HTTP \(httpResponse.statusCode)")
                state = .failed
                return
            }

            struct GitHubRelease: Decodable {
                let tagName: String
                let htmlURL: String

                enum CodingKeys: String, CodingKey {
                    case tagName = "tag_name"
                    case htmlURL = "html_url"
                }
            }

            let releases: [GitHubRelease]
            do {
                releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            } catch {
                mwbWarning(MWBLog.coordinator, "Version check: failed to decode response — \(error.localizedDescription)")
                state = .failed
                return
            }

            guard let latest = releases.first else {
                mwbInfo(MWBLog.coordinator, "Version check: no releases found")
                state = .upToDate
                return
            }

            let latestVersion = latest.tagName.hasPrefix("v") ? String(latest.tagName.dropFirst()) : latest.tagName

            if isNewer(current: current, latest: latestVersion) {
                guard let releaseURL = URL(string: latest.htmlURL) else {
                    mwbWarning(MWBLog.coordinator, "Version check: invalid release URL")
                    state = .failed
                    return
                }
                mwbInfo(MWBLog.coordinator, "Version check: update available — \(latestVersion) (current: \(current))")
                state = .updateAvailable(version: latestVersion, url: releaseURL)
            } else {
                mwbInfo(MWBLog.coordinator, "Version check: up to date (\(current))")
                state = .upToDate
            }
        }
    }

    private func isNewer(current: String, latest: String) -> Bool {
        let c = parseVersion(current)
        let l = parseVersion(latest)
        if c.isBeta != l.isBeta {
            return !l.isBeta
        }
        if l.major != c.major { return l.major > c.major }
        if l.minor != c.minor { return l.minor > c.minor }
        return l.patch > c.patch
    }

    private func parseVersion(_ v: String) -> (isBeta: Bool, major: Int, minor: Int, patch: Int) {
        let trimmed = v.hasPrefix("b") ? String(v.dropFirst()) : v
        let parts = trimmed.split(separator: ".").compactMap { Int($0) }
        let isBeta = v.hasPrefix("b")
        return (
            isBeta: isBeta,
            major: parts.count > 0 ? parts[0] : 0,
            minor: parts.count > 1 ? parts[1] : 0,
            patch: parts.count > 2 ? parts[2] : 0
        )
    }
}
