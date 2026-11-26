import Foundation
import Testing

@testable import ScrollockKit

// MARK: - Instagram

@Test func instagramTopsearchParsesUsersInRankOrder() throws {
  let json = """
    {"users":[
      {"position":1,"user":{"pk":"2","username":"nikerunning","full_name":"Nike Running","is_verified":true,"profile_pic_url":"https://scontent.cdninstagram.com/b.jpg"}},
      {"position":0,"user":{"pk":"1","username":"nike","full_name":"Nike","is_verified":true,"profile_pic_url":"https://scontent.cdninstagram.com/a.jpg"}},
      {"position":2,"user":{"pk":"3","username":"panaderia.nike","full_name":"","is_verified":false}}
    ],"places":[],"hashtags":[],"status":"ok"}
    """
  let results = try ProfileSearch.instagram(Data(json.utf8))
  #expect(results.map(\.username) == ["nike", "nikerunning", "panaderia.nike"])
  #expect(results[0].displayName == "Nike")
  #expect(results[0].isVerified)
  #expect(results[0].avatarURL == URL(string: "https://scontent.cdninstagram.com/a.jpg"))
  #expect(results[0].url == URL(string: "https://www.instagram.com/nike/"))
  #expect(results[2].avatarURL == nil)
  #expect(results.allSatisfy { $0.site == .instagram })
}

@Test func instagramGraphQLTopsearchConnectionParses() throws {
  let json = """
    {"data":{"xdt_api__v1__fbsearch__topsearch_connection":{"users":[
      {"position":0,"user":{"username":"cafe_martinez","full_name":"Café Martínez","is_verified":false,"profile_pic_url":"https://x/a.jpg"}},
      {"position":1,"user":{"username":"cafe_martinez","full_name":"duplicate"}}
    ]}},"status":"ok"}
    """
  let results = try ProfileSearch.instagram(Data(json.utf8))
  #expect(results.map(\.username) == ["cafe_martinez"])
  #expect(results[0].displayName == "Café Martínez")
}

@Test func instagramEmptyResultsAreNotAnError() throws {
  #expect(try ProfileSearch.instagram(Data(#"{"users":[],"places":[],"status":"ok"}"#.utf8)).isEmpty)
}

@Test func instagramLoginRequiredMeansSignedOut() {
  let json = #"{"message":"login_required","require_login":true,"status":"fail"}"#
  #expect(throws: ProfileSearchError.signedOut) { try ProfileSearch.instagram(Data(json.utf8)) }
}

@Test func instagramHTMLOrUnknownJSONIsUnexpected() {
  #expect(throws: ProfileSearchError.unexpectedResponse) {
    try ProfileSearch.instagram(Data("<!DOCTYPE html><html>Page Not Found</html>".utf8))
  }
  #expect(throws: ProfileSearchError.unexpectedResponse) { try ProfileSearch.instagram(Data(#"{"status":"ok"}"#.utf8)) }
}

// MARK: - X

@Test func xTypeaheadParsesUsers() throws {
  let json = """
    {"num_results":2,"users":[
      {"id_str":"1","name":"Nike","screen_name":"Nike","verified":false,"is_blue_verified":true,
       "profile_image_url_https":"https://pbs.twimg.com/profile_images/1/abc_normal.jpg"},
      {"id_str":"2","name":"Nike Store","screen_name":"nikestore","verified":false,"ext_is_blue_verified":false,
       "profile_image_url_https":"https://pbs.twimg.com/profile_images/2/def_normal.png"}
    ],"topics":[],"events":[],"lists":[]}
    """
  let results = try ProfileSearch.x(Data(json.utf8))
  #expect(results.map(\.username) == ["Nike", "nikestore"])
  #expect(results[0].isVerified)
  #expect(!results[1].isVerified)
  #expect(results[0].avatarURL == URL(string: "https://pbs.twimg.com/profile_images/1/abc_200x200.jpg"))
  #expect(results[1].url == URL(string: "https://x.com/nikestore"))
  #expect(results.allSatisfy { $0.site == .x })
}

@Test func xAuthErrorsMeanSignedOut() {
  for code in [32, 89, 215, 353] {
    let json = #"{"errors":[{"code":\#(code),"message":"Could not authenticate you."}]}"#
    #expect(throws: ProfileSearchError.signedOut) { try ProfileSearch.x(Data(json.utf8)) }
  }
}

@Test func xOtherErrorsAreUnexpected() {
  #expect(throws: ProfileSearchError.unexpectedResponse) {
    try ProfileSearch.x(Data(#"{"errors":[{"code":88,"message":"Rate limit exceeded"}]}"#.utf8))
  }
  #expect(throws: ProfileSearchError.unexpectedResponse) { try ProfileSearch.x(Data("".utf8)) }
}

// MARK: - Typed handles

@Test func handlesFromTypedText() {
  #expect(ProfileSearch.handle(from: "  @Cafe.Martinez ", for: .instagram) == "cafe.martinez")
  #expect(ProfileSearch.handle(from: "elonmusk", for: .x) == "elonmusk")
  #expect(ProfileSearch.handle(from: "@jack", for: .x) == "jack")
  #expect(ProfileSearch.handle(from: "instagram.com/nike/", for: .instagram) == "nike")
  #expect(ProfileSearch.handle(from: "https://www.instagram.com/nike?igsh=1", for: .instagram) == "nike")
  #expect(ProfileSearch.handle(from: "https://twitter.com/jack/status/20", for: .x) == "jack")
  // Periods are fine on Instagram but not on X; X handles stop at 15 characters.
  #expect(ProfileSearch.handle(from: "cafe.martinez", for: .x) == nil)
  #expect(ProfileSearch.handle(from: "averyveryverylongname", for: .x) == nil)
  #expect(ProfileSearch.handle(from: "café martínez", for: .instagram) == nil)
  #expect(ProfileSearch.handle(from: ".nike", for: .instagram) == nil)
  #expect(ProfileSearch.handle(from: "ni..ke", for: .instagram) == nil)
  #expect(ProfileSearch.handle(from: "", for: .instagram) == nil)
  #expect(ProfileSearch.handle(from: "@", for: .x) == nil)
  // A link to the other site isn't a handle here.
  #expect(ProfileSearch.handle(from: "x.com/jack", for: .instagram) == nil)
}

@Test func normalizedQueryTrimsAndDropsAt() {
  #expect(ProfileSearch.normalizedQuery("  @nike ") == "nike")
  #expect(ProfileSearch.normalizedQuery("café martínez") == "café martínez")
  #expect(ProfileSearch.normalizedQuery(" @ ") == nil)
  #expect(ProfileSearch.normalizedQuery("") == nil)
}

// MARK: - Model

private func result(_ site: Site, _ username: String) -> ProfileResult {
  ProfileResult(site: site, username: username, displayName: username, avatarURL: nil, isVerified: false)
}

@MainActor private final class SearchLog {
  var calls: [String] = []
}

@MainActor @Test func modelSearchesBothSitesAndCachesResults() async {
  let log = SearchLog()
  let model = ProfileSearchModel(debounce: .zero) { query, site in
    log.calls.append("\(site.rawValue):\(query)")
    return [result(site, "\(query)_\(site.rawValue)")]
  }
  model.query = "@nike"
  await model.update()
  #expect(Set(log.calls) == ["instagram:nike", "x:nike"])
  #expect(model.sections.map(\.site) == [.instagram, .x])
  #expect(model.sections.allSatisfy { $0.status == .loaded })
  #expect(model.sections[0].results.map(\.username) == ["nike_instagram"])
  #expect(model.topURL == URL(string: "https://www.instagram.com/nike_instagram/"))

  // Coming back to a query (e.g. after backspacing) is instant.
  model.query = "Nike"
  await model.update()
  #expect(log.calls.count == 2)
  #expect(model.sections[1].results.map(\.username) == ["nike_x"])
}

@MainActor @Test func modelFallsBackToHandlesWhenSignedOutOrFailing() async {
  let model = ProfileSearchModel(debounce: .zero) { _, site in
    if site == .x { throw ProfileSearchError.signedOut }
    throw URLError(.notConnectedToInternet)
  }
  model.query = "@cafe_martinez"
  await model.update()
  #expect(model.sections.first { $0.site == .instagram }?.status == .failed)
  #expect(model.sections.first { $0.site == .x }?.status == .signedOut)
  #expect(model.directHandles.map(\.site) == [.instagram, .x])
  #expect(model.directHandles.map(\.username) == ["cafe_martinez", "cafe_martinez"])
  // Return opens the typed handle on Instagram.
  #expect(model.topURL == URL(string: "https://www.instagram.com/cafe_martinez/"))
}

@MainActor @Test func modelOnlyOffersHandlesThatFitTheSite() {
  let model = ProfileSearchModel(debounce: .zero) { _, _ in [] }
  model.query = "cafe.martinez"
  #expect(model.directHandles.map(\.site) == [.instagram])
  model.query = "café martínez"
  #expect(model.directHandles.isEmpty)
  #expect(model.topURL == nil)
}

@MainActor @Test func modelClearsWhenQueryIsEmpty() async {
  let model = ProfileSearchModel(debounce: .zero) { _, site in [result(site, "a")] }
  model.query = "a"
  await model.update()
  model.query = "  "
  await model.update()
  #expect(model.sections.allSatisfy { $0.status == .idle && $0.results.isEmpty })
}

@MainActor @Test func cancelledSearchDoesNotOverwriteNewerResults() async {
  let model = ProfileSearchModel(debounce: .milliseconds(50)) { query, site in [result(site, query)] }
  model.query = "first"
  let stale = Task { await model.update() }
  // Typing more cancels the pending search during its debounce.
  stale.cancel()
  await stale.value
  #expect(model.sections.allSatisfy { $0.status == .loading })
  model.query = "second"
  await model.update()
  #expect(model.sections.allSatisfy { $0.results.map(\.username) == ["second"] })
}

@MainActor @Test func cancelledInFlightSearchKeepsItsResultsOutOfTheList() async {
  let model = ProfileSearchModel(debounce: .zero) { query, site in
    if query == "slow" { try await Task.sleep(for: .seconds(5)) }
    return [result(site, query)]
  }
  model.query = "slow"
  let stale = Task { await model.update() }
  try? await Task.sleep(for: .milliseconds(50))
  stale.cancel()
  await stale.value
  #expect(model.sections.allSatisfy { $0.results.isEmpty })
  model.query = "fast"
  await model.update()
  #expect(model.sections.allSatisfy { $0.status == .loaded && $0.results.map(\.username) == ["fast"] })
}
