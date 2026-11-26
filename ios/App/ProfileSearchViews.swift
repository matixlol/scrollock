import ScrollockKit
import SwiftUI

/// The search field pinned to the bottom of the home screen, within thumb
/// reach, plus a close button while searching.
struct ProfileSearchBar: View {
  @Bindable var search: ProfileSearchModel
  var focused: FocusState<Bool>.Binding
  let searching: Bool
  let submit: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(.secondary)
        TextField("Search Instagram and X", text: $search.query)
          .focused(focused)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.twitter)
          .submitLabel(.go)
          .onSubmit(submit)
          .accessibilityIdentifier("profileSearchField")
        if !search.query.isEmpty {
          Button {
            search.query = ""
            focused.wrappedValue = true
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear search")
        }
      }
      .padding(.horizontal, 16)
      .frame(height: 50)
      .contentShape(Capsule())
      .onTapGesture { focused.wrappedValue = true }
      .glassBackground(in: Capsule())

      if searching {
        Button {
          search.query = ""
          focused.wrappedValue = false
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 50, height: 50)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassBackground(in: Circle())
        .accessibilityLabel("Close search")
        .transition(.scale(scale: 0.6).combined(with: .opacity))
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 6)
    .padding(.bottom, 8)
    .animation(.snappy(duration: 0.25), value: searching)
  }
}

/// What the home screen shows while searching: quick links for a typed
/// handle, then matching profiles from each site.
struct ProfileSearchResults: View {
  let search: ProfileSearchModel
  let open: (URL) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      if ProfileSearch.normalizedQuery(search.query) == nil {
        Text("Find Instagram and X profiles by name or @handle, then open them here.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 4)
          .padding(.top, 8)
      } else {
        let handles = search.directHandles
        if !handles.isEmpty {
          DirectOpenRow(handles: handles, open: open)
        }
        ForEach(search.sections) { section in
          SiteResults(section: section, open: open)
        }
      }
    }
    .animation(.snappy(duration: 0.2), value: search.sections)
  }
}

/// "Open @name on Instagram / X" without waiting for search, and without a login.
private struct DirectOpenRow: View {
  let handles: [(site: Site, username: String)]
  let open: (URL) -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(handles, id: \.site) { handle in
          Button {
            open(ProfileSearch.profileURL(site: handle.site, username: handle.username))
          } label: {
            HStack(spacing: 8) {
              SiteIcon(site: handle.site, size: 20)
              Text("@\(handle.username)").font(.subheadline.weight(.semibold)).lineLimit(1)
              Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: 38)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Open @\(handle.username) on \(handle.site.displayName)")
        }
      }
    }
    .scrollClipDisabled()
  }
}

private struct SiteResults: View {
  let section: ProfileSearchModel.Section
  let open: (URL) -> Void

  private static let loginURLs: [Site: URL] = [
    .instagram: URL(string: "https://www.instagram.com/accounts/login/")!,
    .x: URL(string: "https://x.com/i/flow/login")!,
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Text(section.site.displayName).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        if section.status == .loading { ProgressView().controlSize(.mini) }
      }
      .textCase(.uppercase)
      .padding(.horizontal, 4)

      switch section.status {
      case .signedOut:
        note("Log in to \(section.site.displayName) in Scrollock to search its profiles.") {
          if let url = Self.loginURLs[section.site] {
            Button("Log in") { open(url) }.font(.footnote.weight(.semibold))
          }
        }
      case .failed:
        note("Couldn't search \(section.site.displayName) right now.") { EmptyView() }
      case .loaded where section.results.isEmpty:
        note("No profiles found.") { EmptyView() }
      case .loading where section.results.isEmpty:
        // Placeholder rows keep the layout from jumping when results land.
        VStack(spacing: 0) {
          ForEach(0..<2, id: \.self) { _ in PlaceholderRow() }
        }
        .panel()
      default:
        VStack(spacing: 0) {
          ForEach(Array(section.results.prefix(5).enumerated()), id: \.element.id) { index, result in
            if index > 0 { Divider().padding(.leading, 72) }
            Button { open(result.url) } label: { ProfileRow(result: result) }
              .buttonStyle(RowButtonStyle())
          }
        }
        .panel()
        .opacity(section.status == .loading ? 0.6 : 1)
      }
    }
  }

  private func note<Action: View>(_ text: String, @ViewBuilder action: () -> Action) -> some View {
    HStack {
      Text(text).font(.footnote).foregroundStyle(.secondary)
      Spacer(minLength: 8)
      action()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .panel()
  }
}

private struct ProfileRow: View {
  let result: ProfileResult

  var body: some View {
    HStack(spacing: 12) {
      Avatar(url: result.avatarURL)
        .frame(width: 44, height: 44)
        .overlay(alignment: .bottomTrailing) {
          SiteIcon(site: result.site, size: 17)
            .padding(1.5)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
            .offset(x: 4, y: 4)
        }
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 4) {
          Text(result.displayName.isEmpty ? result.username : result.displayName)
            .font(.body.weight(.semibold))
            .lineLimit(1)
          if result.isVerified {
            Image(systemName: "checkmark.seal.fill")
              .font(.caption)
              .foregroundStyle(.blue)
              .accessibilityLabel("Verified")
          }
        }
        Text("@\(result.username)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("profileResult.\(result.site.rawValue).\(result.username)")
  }
}

private struct Avatar: View {
  let url: URL?

  var body: some View {
    AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.15))) { phase in
      if let image = phase.image {
        image.resizable().scaledToFill()
      } else {
        ZStack {
          Color(.tertiarySystemFill)
          Image(systemName: "person.fill").foregroundStyle(.tertiary)
        }
      }
    }
    .clipShape(Circle())
  }
}

private struct PlaceholderRow: View {
  var body: some View {
    HStack(spacing: 12) {
      Circle().fill(Color(.tertiarySystemFill)).frame(width: 44, height: 44)
      VStack(alignment: .leading, spacing: 6) {
        Capsule().fill(Color(.tertiarySystemFill)).frame(width: 130, height: 12)
        Capsule().fill(Color(.quaternarySystemFill)).frame(width: 90, height: 10)
      }
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .accessibilityHidden(true)
  }
}

private struct RowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? Color(.systemFill) : .clear)
  }
}

extension View {
  fileprivate func panel() -> some View {
    frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
  }
}
