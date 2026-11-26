import Foundation
import Observation

/// State for the home screen's profile search: what's typed, and each site's
/// results. Searches every site at once and shows each as soon as it answers.
@MainActor @Observable
public final class ProfileSearchModel {
  public enum Status: Equatable, Sendable {
    case idle, loading, loaded, signedOut, failed
  }

  public struct Section: Equatable, Identifiable, Sendable {
    public var site: Site
    public var status: Status
    /// The latest results; kept while a newer query loads so the list doesn't flicker.
    public var results: [ProfileResult]
    public var id: Site { site }
  }

  public typealias Search = @MainActor @Sendable (String, Site) async throws -> [ProfileResult]

  public var query = ""
  public private(set) var sections: [Section]
  @ObservationIgnored private let search: Search
  @ObservationIgnored private let debounce: Duration
  @ObservationIgnored private var cache: [String: [ProfileResult]] = [:]

  public init(debounce: Duration = .milliseconds(220), search: @escaping Search) {
    self.search = search
    self.debounce = debounce
    sections = ProfileSearch.sites.map { Section(site: $0, status: .idle, results: []) }
  }

  /// Usernames to open directly when the query could be one, per site. They
  /// work without a login, so the bar is useful even when search isn't.
  public var directHandles: [(site: Site, username: String)] {
    ProfileSearch.sites.compactMap { site in ProfileSearch.handle(from: query, for: site).map { (site, $0) } }
  }

  /// The best place to go for Return: the first result, else the typed handle.
  public var topURL: URL? {
    sections.lazy.compactMap { $0.status == .loaded ? $0.results.first?.url : nil }.first
      ?? directHandles.first.map { ProfileSearch.profileURL(site: $0.site, username: $0.username) }
  }

  /// Searches for the current query after a short pause. Call it from
  /// `.task(id: query)`, which cancels the previous search as typing goes on.
  public func update() async {
    guard let query = ProfileSearch.normalizedQuery(query) else {
      sections = ProfileSearch.sites.map { Section(site: $0, status: .idle, results: []) }
      return
    }
    var pending: [Site] = []
    for index in sections.indices {
      if let cached = cache[key(query, sections[index].site)] {
        sections[index].status = .loaded
        sections[index].results = cached
      } else {
        sections[index].status = .loading
        pending.append(sections[index].site)
      }
    }
    guard !pending.isEmpty else { return }
    do { try await Task.sleep(for: debounce) } catch { return }

    let search = self.search
    await withTaskGroup(of: (Site, Status, [ProfileResult]).self) { group in
      for site in pending {
        group.addTask { @MainActor in
          do {
            return (site, .loaded, try await search(query, site))
          } catch ProfileSearchError.signedOut {
            return (site, .signedOut, [])
          } catch {
            return (site, .failed, [])
          }
        }
      }
      for await (site, status, results) in group {
        // A newer query owns the list now.
        guard !Task.isCancelled else { continue }
        if status == .loaded {
          if cache.count > 100 { cache.removeAll() }
          cache[key(query, site)] = results
        }
        guard let index = sections.firstIndex(where: { $0.site == site }) else { continue }
        sections[index].status = status
        sections[index].results = results
      }
    }
  }

  private func key(_ query: String, _ site: Site) -> String { "\(site.rawValue):\(query.lowercased())" }
}
