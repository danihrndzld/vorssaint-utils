// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine

/// What the settings page, the panel and the shortcut share: the browsers,
/// which one opens links now, and a switch that is never run twice at once,
/// since each one waits on a macOS confirmation.
final class DefaultBrowserService: ObservableObject {
    static let shared = DefaultBrowserService()

    @Published private(set) var browsers: [DefaultBrowserSupport.Browser] = []
    @Published private(set) var current: URL?
    @Published private(set) var changing = false
    @Published private(set) var failure: String?
    @Published private(set) var shortcutRegistrationFailed = false

    private let hotkey = QuickToolHotkey(id: 81)

    private init() {
        hotkey.onPress = { [weak self] in self?.switchToNext() }
    }

    func syncWithPreferences() {
        let enabled = AppFeature.defaultBrowser.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.defaultBrowserShortcutEnabled)
        let shortcut = GlobalShortcut.saved(for: DefaultsKey.defaultBrowserShortcut,
                                            fallback: .defaultBrowserDefault)
        shortcutRegistrationFailed = !hotkey.sync(enabled: enabled, shortcut: shortcut,
                                                  storageKey: DefaultsKey.defaultBrowserShortcut)
    }

    func reload() {
        guard !changing else { return }
        browsers = DefaultBrowserSupport.installed()
        current = DefaultBrowserSupport.current
    }

    /// Launch Services records the default by bundle id, so another copy of
    /// the same browser already counts as the default.
    func isCurrent(_ browser: DefaultBrowserSupport.Browser) -> Bool {
        guard let current else { return false }
        return Bundle(url: current)?.bundleIdentifier == browser.bundleID
            || current.standardizedFileURL == browser.url
    }

    func switchToNext() {
        guard AppFeature.defaultBrowser.isAvailable else { return }
        reload()
        let chosen = UserDefaults.standard.stringArray(forKey: DefaultsKey.defaultBrowserRotation) ?? []
        let currentID = current.flatMap { Bundle(url: $0)?.bundleIdentifier }
        guard let nextID = DefaultBrowserSupport.next(after: currentID, chosen: chosen,
                                                      installed: browsers.map(\.bundleID)),
              let browser = browsers.first(where: { $0.bundleID == nextID }) else {
            NSSound.beep()
            return
        }
        makeDefault(browser)
    }

    func makeDefault(_ browser: DefaultBrowserSupport.Browser) {
        guard !changing else { return }
        changing = true
        failure = nil
        Task { @MainActor in
            do {
                try await DefaultBrowserSupport.makeDefault(browser.url)
                // Right after a change Launch Services can still answer this
                // process with the previous browser, so it is not read back.
                current = browser.url
                changing = false
            } catch {
                if !DefaultBrowserSupport.isCancellation(error) { failure = error.localizedDescription }
                changing = false
                // http may have changed before https was declined.
                reload()
            }
        }
    }
}
