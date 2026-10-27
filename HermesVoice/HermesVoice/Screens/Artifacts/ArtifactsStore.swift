import SwiftUI
import UIKit

/// The Artifacts page's index (`ArtifactsView.refreshArtifacts`): the 30 most recently active sessions, scanned one
/// transcript page at a time.
@MainActor
final class ArtifactsStore: ObservableObject {
    let client: DashboardClient
    /// The sessions' profile, or `SidebarOptions.allProfiles` (the desktop always indexes every profile).
    let profile: String

    @Published private(set) var artifacts: [ArtifactRecord]?
    @Published private(set) var refreshing = false
    @Published var failure: String?
    /// Sessions skipped while indexing, said once per refresh.
    @Published var warning: String?

    init(client: DashboardClient, profile: String) {
        self.client = client
        self.profile = profile
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let sessions = try await client.artifactSessions(profile: profile)
            let client = client
            let result = await ArtifactIndex.load(sessions) { session, offset in
                try await client.artifactMessagePage(session, offset: offset)
            }
            artifacts = result.artifacts
            if result.skipped > 0 {
                var detail = "Skipped \(result.skipped) of \(sessions.count) recent sessions while indexing artifacts."
                if result.tooLarge > 0 { detail += " \(result.tooLarge) exceeded the safe transcript load limit." }
                warning = detail
            }
        } catch {
            guard !error.isCancellation else { return }
            failure = "Artifacts failed to load. \(error.dashboardMessage)"
            if artifacts == nil { artifacts = [] }
        }
    }

    func count(_ filter: ArtifactFilter) -> Int {
        (artifacts ?? []).filter { filter.includes($0.kind) }.count
    }

    func visible(_ filter: ArtifactFilter, query: String) -> [ArtifactRecord] {
        (artifacts ?? []).filter { filter.includes($0.kind) && $0.matches(query) }
    }
}

/// Decoded thumbnails, kept while the app runs.
enum ArtifactImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        return cache
    }()

    static func image(_ id: String) -> UIImage? { cache.object(forKey: id as NSString) }
    static func store(_ image: UIImage, _ id: String) { cache.setObject(image, forKey: id as NSString) }
}

extension DashboardClient {
    /// An image artifact's bytes: inline `data:` URLs decode here, web images load directly, and host files come
    /// through the dashboard.
    func artifactImageData(_ artifact: ArtifactRecord) async throws -> Data {
        if artifact.value.hasPrefix("data:") {
            guard let data = Self.decodeDataURL(artifact.value) else { throw DashboardError.rpc("The image can't be read.") }
            return data
        }
        if let url = artifact.url {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw DashboardError.http(http.statusCode, "")
            }
            return data
        }
        return try await hostImageData(artifact)
    }

    /// A downscaled image for a grid card.
    func artifactThumbnail(_ artifact: ArtifactRecord, maxPixel: CGFloat = 480) async throws -> UIImage {
        if let cached = ArtifactImageCache.image(artifact.id) { return cached }
        let data = try await artifactImageData(artifact)
        guard let image = UIImage(data: data) else { throw DashboardError.rpc("The image can't be shown.") }
        let thumbnail = await image.byPreparingThumbnail(ofSize: Self.fit(image.size, maxPixel: maxPixel)) ?? image
        ArtifactImageCache.store(thumbnail, artifact.id)
        return thumbnail
    }

    private static func fit(_ size: CGSize, maxPixel: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maxPixel, longest > 0 else { return size }
        let scale = maxPixel / longest
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
