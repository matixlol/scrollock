import ScrollockKit
import SwiftUI

/// The home screen: setup progress, then one icon per feed. Tapping a feed
/// browses it without the feed; breaks, locking and app choices are in each
/// feed's menu. Everything else is behind the gear.
struct HomeScreen: View {
  let model: AppModel
  let browse: (Site) -> Void
  @State private var showingSettings = false
  @State private var picking: Site?
  @AppStorage("automationSetUp") private var automationSetUp = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
          let progress = model.setupProgress(automationSetUp: automationSetUp)
          if !progress.isComplete {
            SetupBanner(progress: progress) { showingSettings = true }
          }
          IconsPanel(model: model, browse: browse) { picking = $0 }
          BreakList(model: model)
          Text("Tap a feed to browse it without the feed. Touch and hold for breaks and apps.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }
        .padding(.horizontal)
        .padding(.bottom)
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle("Scrollock")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Settings", systemImage: "gearshape") { showingSettings = true }
        }
      }
      .sheet(isPresented: $showingSettings) {
        NavigationStack {
          SettingsForm(model: model)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
              ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSettings = false } }
            }
        }
      }
      .appPicker(model: model, site: $picking)
      .onChange(of: model.breakSite) { _, site in
        if site != nil { showingSettings = false }
      }
    }
  }
}

/// The actions for one feed, for context menus.
struct FeedActions: View {
  let model: AppModel
  let site: Site
  let browse: (Site) -> Void
  let pick: (Site) -> Void

  var body: some View {
    Button("Browse without feed", systemImage: "safari") { browse(site) }
    if model.activeLease(for: site) != nil {
      Button("Open \(site.displayName) app", systemImage: "arrow.up.forward.app") { model.returnToFeed(site) }
      Button("Lock now", systemImage: "lock") { Task { await model.lockNow(site) } }
    } else if model.selectedCount(for: site) > 0 {
      Button("Take a break…", systemImage: "timer") { model.requestBreak(site) }
    }
    Button("Choose apps", systemImage: "apps.iphone") { pick(site) }
  }
}

private struct SetupBanner: View {
  let progress: SetupProgress
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      HStack(spacing: 14) {
        ZStack {
          Circle().stroke(.white.opacity(0.3), lineWidth: 4)
          Circle().trim(from: 0, to: CGFloat(progress.done) / CGFloat(progress.total))
            .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .rotationEffect(.degrees(-90))
          Text("\(progress.done)/\(progress.total)").font(.caption2.weight(.bold))
        }
        .frame(width: 40, height: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text("Finish setup").font(.headline)
          if let next = progress.next { Text("Next: \(next)").font(.subheadline).opacity(0.85) }
        }
        Spacer()
        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
      }
      .foregroundStyle(.white)
      .padding(16)
      .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}

/// "Locked", the time left on a break, or "Not locked".
private struct ShortStatus: View {
  let model: AppModel
  let site: Site

  var body: some View {
    if let lease = model.activeLease(for: site) {
      Text(timerInterval: Date.now...lease.expiresAt, countsDown: true)
        .monospacedDigit()
        .foregroundStyle(.orange)
    } else {
      Text(model.selectedCount(for: site) > 0 ? "Locked" : "Not locked").foregroundStyle(.secondary)
    }
  }
}

/// A feed's app icon with a lock or timer badge.
private struct BadgedIcon: View {
  let model: AppModel
  let site: Site
  var size: CGFloat = 72

  var body: some View {
    let onBreak = model.activeLease(for: site) != nil
    SiteIcon(site: site, size: size)
      .overlay(alignment: .bottomTrailing) {
        Image(systemName: onBreak ? "timer" : "lock.fill")
          .font(.system(size: size * 0.15, weight: .bold))
          .foregroundStyle(onBreak ? .orange : .secondary)
          .frame(width: size * 0.36, height: size * 0.36)
          .background(Color(.systemBackground), in: Circle())
          .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
          .offset(x: size * 0.08, y: size * 0.08)
          .opacity(model.selectedCount(for: site) > 0 ? 1 : 0)
      }
  }
}

private struct Panel<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .padding(.vertical, 20)
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
  }
}

private struct IconsPanel: View {
  let model: AppModel
  let browse: (Site) -> Void
  let pick: (Site) -> Void

  var body: some View {
    Panel {
      HStack(alignment: .top) {
        ForEach(Site.allCases) { site in
          Button { browse(site) } label: {
            VStack(spacing: 6) {
              BadgedIcon(model: model, site: site).padding(.bottom, 4)
              Text(site.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
              ShortStatus(model: model, site: site).font(.caption)
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.plain)
          .contextMenu { FeedActions(model: model, site: site, browse: browse, pick: pick) }
        }
      }
    }
  }
}

/// Breaks in progress, with a way to end them early.
private struct BreakList: View {
  let model: AppModel

  var body: some View {
    ForEach(Site.allCases.filter { model.activeLease(for: $0) != nil }) { site in
      HStack(spacing: 12) {
        SiteIcon(site: site, size: 36)
        VStack(alignment: .leading, spacing: 2) {
          Text("\(site.displayName) break").font(.headline)
          if let lease = model.activeLease(for: site) {
            (Text("Relocks in ") + Text(timerInterval: Date.now...lease.expiresAt, countsDown: true))
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button("Lock now") { Task { await model.lockNow(site) } }
          .buttonStyle(.bordered)
          .tint(.orange)
      }
      .padding(14)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
  }
}
