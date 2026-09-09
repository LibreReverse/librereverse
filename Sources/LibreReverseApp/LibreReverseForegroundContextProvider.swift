#if os(macOS)
import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import LibreReverseCore

/// Derives capture IDs and browser context from the same ordered WindowServer
/// snapshot through the stateful accessibility provider.
@MainActor
final class LibreReverseForegroundContextProvider {
    private let browserProvider = BrowserProviderController(
        ax: SystemBrowserAX()
    )

    private(set) var lastMeetingDiagnostics: [String: Int] = [:]
    private var collectingMeetingDiagnostics = false

    // Refreshed for every WindowServer snapshot, so privacy decisions never
    // reuse an identity from an earlier scan or a recycled PID.
    private var applicationIdentities: [pid_t: RunningApplication] = [:]
    private var missingApplications: Set<pid_t> = []

    private func applicationIdentity(_ pid: pid_t) -> RunningApplication? {
        if let cached = applicationIdentities[pid] { return cached }
        if missingApplications.contains(pid) { return nil }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            missingApplications.insert(pid)
            return nil
        }
        let identity = RunningApplication(localizedName: app.localizedName,
                                          bundleIdentifier: app.bundleIdentifier)
        applicationIdentities[pid] = identity
        return identity
    }

    /// Builds both the capture-window list and its foreground context from one
    /// WindowServer snapshot. The production capture loop calls this directly
    /// so pixels and metadata cannot observe different desktop states.
    func selection(
        from rows: [[CFString: Any]],
        displayBounds: CGRect,
        privacySettings: CapturePrivacySettings,
        includeOccludedWindows: Bool = false
    ) -> WindowSelectionResult {
        applicationIdentities.removeAll(keepingCapacity: true)
        missingApplications.removeAll(keepingCapacity: true)
        let windows = rows.compactMap { row in
            DesktopWindowSelector.constructWindow(
                from: row,
                resolveApplication: { self.applicationIdentity($0) }
            )
        }
        browserProvider.resetWindowIndexes()
        return DesktopWindowSelector.select(
            windows: windows,
            displayBounds: displayBounds,
            ownBundleIdentifier: Bundle.main.bundleIdentifier,
            omittedBundleIdentifiers: privacySettings.omittedAppBundleIdentifiers,
            omittedOwnerNames: privacySettings.omittedOwnerNames,
            excludeIncognito: privacySettings.excludeIncognito,
            browserProperties: { [browserProvider] window in
                let properties = browserProvider.properties(
                    for: window,
                    frontmostBundleIdentifier: {
                        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    }
                )
                if self.collectingMeetingDiagnostics,
                   let bundle = window.appBundleIdentifier,
                   LibreReverseMeetingDetector.supportedBrowserBundleIdentifiers.contains(bundle) {
                    self.lastMeetingDiagnostics["browserWindowsExamined", default: 0] += 1
                    if !window.name.isEmpty { self.lastMeetingDiagnostics["namedBrowserWindowsExamined", default: 0] += 1 }
                    let reason = properties?.reason.map { String($0.rawValue) } ?? "none"
                    self.lastMeetingDiagnostics["browserReason_" + reason, default: 0] += 1
                    if properties?.url != nil { self.lastMeetingDiagnostics["browserURLsFound", default: 0] += 1 }
                    if properties?.url.flatMap(LibreReverseMeetingDetector.browserProvider) != nil {
                        self.lastMeetingDiagnostics["meetingURLsFoundBeforePrivacyFilter", default: 0] += 1
                    }
                }
                return properties
            },
            isFullyOccluded: { bounds, occluders in
                !includeOccludedWindows && DesktopWindowSelector.isFullyOccluded(bounds, previous: occluders)
            }
        )
    }

    /// Reuses the exact same WindowServer ordering and browser AX producer as
    /// ordinary capture, so meeting detection cannot observe a different URL
    /// or privacy state from the pixels being recorded.
    func meetingObservations(
        from visibleRows: [[CFString: Any]],
        allRows: [[CFString: Any]],
        displayBounds: CGRect,
        privacySettings: CapturePrivacySettings
    ) -> [LibreReverseMeetingWindowObservation] {
        lastMeetingDiagnostics = ["windowRows": allRows.count,
                                  "accessibilityTrusted": AXIsProcessTrusted() ? 1 : 0,
                                  "excludePrivate": privacySettings.excludeIncognito ? 1 : 0]
        collectingMeetingDiagnostics = true
        defer { collectingMeetingDiagnostics = false }
        let selectedWindows = selection(
            from: allRows,
            displayBounds: .infinite,
            privacySettings: privacySettings,
            includeOccludedWindows: true
        ).selectedWindows
        lastMeetingDiagnostics["selectedWindows"] = selectedWindows.count
        let selectedBrowserProcessIdentifiers = Set(
            selectedWindows.compactMap { window -> pid_t? in
                guard let bundleIdentifier = window.appBundleIdentifier,
                    LibreReverseMeetingDetector.browserPopOutBundleIdentifiers.contains(
                        bundleIdentifier
                    )
                else { return nil }
                return window.appProcessIdentifier
            }
        )
        let microphoneInputProcessIdentifiers = Set(
            selectedBrowserProcessIdentifiers.filter(processIsUsingMicrophoneInput)
        )
        let visible: [LibreReverseMeetingWindowObservation] = selectedWindows.compactMap {
            window -> LibreReverseMeetingWindowObservation? in
            guard let bundleIdentifier = window.appBundleIdentifier else { return nil }
            // Chromium's unnamed compositor/helper windows can resolve via
            // AX's positional fallback to the same tab as a real window. They
            // must not become duplicate candidates that block automatic start.
            if LibreReverseMeetingDetector.supportedBrowserBundleIdentifiers.contains(bundleIdentifier),
               window.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            if LibreReverseDevelopmentEnvironment.values["LIBREREVERSE_MEETING_DETECTION_PROBE_OUTPUT"] != nil,
               LibreReverseMeetingDetector.supportedBrowserBundleIdentifiers.contains(bundleIdentifier), !window.name.isEmpty {
                FileHandle.standardError.write(Data("Browser AX window=\(window.id) reason=\(String(describing: window.browserProperties?.reason)) hasURL=\(window.browserProperties?.url != nil)\n".utf8))
            }
            if LibreReverseMeetingDetector.supportedBrowserBundleIdentifiers.contains(bundleIdentifier) {
                lastMeetingDiagnostics["selectedNamedBrowserWindows", default: 0] += 1
            }
            let needsCallControls = window.browserProperties?.url.flatMap(LibreReverseMeetingDetector.browserProvider) != nil
            let labels = (!needsCallControls && LibreReverseMeetingDetector.supportedBrowserBundleIdentifiers.contains(bundleIdentifier)) ? [] : meetingAccessibilityLabels(
                processIdentifier: window.appProcessIdentifier,
                bundleIdentifier: bundleIdentifier,
                windowTitle: window.name,
                windowBounds: window.bounds,
                meetingProvider: window.browserProperties?.url.flatMap(LibreReverseMeetingDetector.browserProvider)
            )
            return LibreReverseMeetingWindowObservation(
                windowID: window.id,
                processIdentifier: window.appProcessIdentifier,
                bundleIdentifier: bundleIdentifier,
                title: window.name,
                applicationName: applicationIdentity(window.appProcessIdentifier)?.localizedName,
                url: window.browserProperties?.state == .capture
                    ? window.browserProperties?.url : nil,
                accessibilityLabels: labels,
                usesMicrophoneInput: microphoneInputProcessIdentifiers.contains(
                    window.appProcessIdentifier
                ),
                browserCallIsActive: LibreReverseMeetingDetector.browserCallActivity(
                    url: window.browserProperties?.url, accessibilityLabels: labels)
            )
        }
        let omittedBundleIdentifiers =
            DesktopWindowSelector.builtInOmittedBundleIdentifiers.union(
                privacySettings.omittedAppBundleIdentifiers
            )
        let inventory = LibreReverseMeetingDetector.privacyEligibleHiddenNativeInventory(
            allRows.compactMap(nativeMeetingInventoryItem),
            ownBundleIdentifier: Bundle.main.bundleIdentifier,
            omittedBundleIdentifiers: omittedBundleIdentifiers,
            omittedOwnerNames: privacySettings.omittedOwnerNames
        ).map { item in
            let observation = item.observation
            return LibreReverseMeetingWindowInventoryItem(
                observation: LibreReverseMeetingWindowObservation(
                    windowID: observation.windowID,
                    processIdentifier: observation.processIdentifier,
                    bundleIdentifier: observation.bundleIdentifier,
                    title: observation.title,
                    applicationName: observation.applicationName,
                    accessibilityLabels: meetingAccessibilityLabels(
                        processIdentifier: observation.processIdentifier,
                        bundleIdentifier: observation.bundleIdentifier,
                        windowTitle: observation.title
                    )
                ),
                ownerName: item.ownerName
            )
        }
        let merged = LibreReverseMeetingDetector.mergingHiddenNativeObservations(
            visible: visible,
            inventory: inventory,
            ownBundleIdentifier: Bundle.main.bundleIdentifier,
            omittedBundleIdentifiers: omittedBundleIdentifiers,
            omittedOwnerNames: privacySettings.omittedOwnerNames
        )
        lastMeetingDiagnostics["observations"] = merged.count
        return merged
    }

    /// Resolves only the selected browser's exact PID. Query failures and
    /// systems without process-level CoreAudio objects fail closed.
    private func processIsUsingMicrophoneInput(_ processIdentifier: pid_t) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableProcessIdentifier = processIdentifier
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var processObjectSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let translationStatus = withUnsafePointer(to: &mutableProcessIdentifier) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualifier,
                &processObjectSize,
                &processObject
            )
        }
        guard translationStatus == noErr, processObject != kAudioObjectUnknown else {
            return false
        }

        address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunningInput: UInt32 = 0
        var isRunningInputSize = UInt32(MemoryLayout<UInt32>.size)
        let inputStatus = AudioObjectGetPropertyData(
            processObject,
            &address,
            0,
            nil,
            &isRunningInputSize,
            &isRunningInput
        )
        return inputStatus == noErr && isRunningInput != 0
    }

    /// Meeting discovery intentionally accepts zero-sized/off-screen entries:
    /// unlike screenshot selection, it needs identity rather than pixels.
    private func nativeMeetingInventoryItem(
        from row: [CFString: Any]
    ) -> LibreReverseMeetingWindowInventoryItem? {
        guard let number = row[kCGWindowNumber] as? UInt32,
            let ownerPID = row[kCGWindowOwnerPID] as? Int32,
            let application = applicationIdentity(ownerPID),
            let ownerName = application.localizedName,
            let bundleIdentifier = application.bundleIdentifier,
            LibreReverseMeetingDetector.supportsNativeApplication(bundleIdentifier: bundleIdentifier, applicationName: ownerName)
        else { return nil }
        return LibreReverseMeetingWindowInventoryItem(
            observation: LibreReverseMeetingWindowObservation(
                windowID: number,
                processIdentifier: ownerPID,
                bundleIdentifier: bundleIdentifier,
                title: (row[kCGWindowName] as? String) ?? "",
                applicationName: ownerName
            ),
            ownerName: ownerName
        )
    }

    /// Provider probes emit canonical booleans/markers only. Raw AX strings are
    /// neither returned nor persisted, keeping detector traces content-free.
    private func meetingAccessibilityLabels(
        processIdentifier: pid_t,
        bundleIdentifier: String,
        windowTitle: String,
        windowBounds: CGRect? = nil,
        meetingProvider: LibreReverseMeetingProvider? = nil
    ) -> [String] {
        let applicationName = applicationIdentity(processIdentifier)?.localizedName
        let provider = meetingProvider ?? MeetingProviderCatalog.nativeProvider(
            bundleIdentifier: bundleIdentifier, applicationName: applicationName)
        let isNative = LibreReverseMeetingDetector.supportsNativeApplication(
            bundleIdentifier: bundleIdentifier, applicationName: applicationName)
        let isBrowser = LibreReverseMeetingDetector.supportedBrowserBundleIdentifiers.contains(bundleIdentifier)
        guard (isNative || isBrowser), AXIsProcessTrusted() else {
            return []
        }
        let application = AXUIElementCreateApplication(processIdentifier)
        var roots: [AXUIElement] = []
        var rawWindows: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
            let windows = rawWindows as? [AXUIElement]
        {
            let identities = windows.map {
                BrowserAXWindowIdentity(title: stringAttribute($0, kAXTitleAttribute),
                                        bounds: accessibilityFrame($0))
            }
            if let index = Self.meetingWindowIndex(windowTitle: windowTitle,
                windowBounds: windowBounds, identities: identities, isBrowser: isBrowser) {
                roots.append(windows[index])
            }
        }
        if LibreReverseMeetingDetector.menuBarScanBundleIdentifiers.contains(bundleIdentifier) || provider == .discord {
            var rawMenuBar: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                application,
                kAXMenuBarAttribute as CFString,
                &rawMenuBar
            ) == .success,
                let rawMenuBar,
                CFGetTypeID(rawMenuBar) == AXUIElementGetTypeID()
            {
                roots.append(unsafeBitCast(rawMenuBar, to: AXUIElement.self))
            }
        }
        let probing = LibreReverseDevelopmentEnvironment.values["LIBREREVERSE_MEETING_DETECTION_PROBE_OUTPUT"] != nil
        if probing && isBrowser { FileHandle.standardError.write(Data("Meeting AX roots=\(roots.count)\n".utf8)) }
        if isBrowser { lastMeetingDiagnostics["browserCallRoots", default: 0] += roots.count }
        guard !roots.isEmpty else { return [] }

        let markers = LibreReverseMeetingDetector.canonicalAccessibilityMarkers
        let evidenceMarkers = Set(MeetingProviderCatalog.activeCallMarkers + MeetingProviderCatalog.supportingCallMarkers + MeetingProviderCatalog.endedCallMarkers)
        var found = Set<String>()
        var queue = roots.map { ($0, 0) }
        var cursor = 0
        var visited = Set<AXUIElement>()
        while cursor < queue.count, cursor < (isBrowser ? 2_000 : 600) {
            let (element, depth) = queue[cursor]
            cursor += 1
            guard visited.insert(element).inserted else { continue }
            let role = stringAttribute(element, kAXRoleAttribute)
            for attribute in ["AXIdentifier", "AXDOMIdentifier"] {
                if let identifier = stringAttribute(element, attribute),
                   MeetingProviderCatalog.hasActiveCallIdentifier(identifier, provider: provider) {
                    found.insert(MeetingProviderCatalog.activeIdentifierMarker)
                }
            }
            for attribute in [
                kAXTitleAttribute,
                kAXDescriptionAttribute,
                kAXHelpAttribute,
                kAXValueAttribute,
            ] {
                guard let value = stringAttribute(element, attribute) else { continue }
                found.formUnion(MeetingProviderCatalog.callEvidence(label: value, role: role, provider: provider))
                for marker in markers where marker != MeetingProviderCatalog.activeIdentifierMarker
                    && !evidenceMarkers.contains(marker)
                    && value.localizedCaseInsensitiveContains(marker) {
                    found.insert(marker)
                }
            }
            if isBrowser, MeetingProviderCatalog.hasActiveCallControl(Array(found)) { break }
            guard depth < (isBrowser ? 40 : 8) else { continue }
            var rawChildren: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &rawChildren
            ) == .success,
                let children = rawChildren as? [AXUIElement]
            {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        if probing && isBrowser { FileHandle.standardError.write(Data("Meeting AX visited=\(visited.count) foundCall=\(found.contains("Leave call"))\n".utf8)) }
        if isBrowser {
            lastMeetingDiagnostics["browserCallNodesVisited", default: 0] += visited.count
            if MeetingProviderCatalog.hasActiveCallControl(Array(found)) {
                lastMeetingDiagnostics["browserCallsWithActiveControl", default: 0] += 1
            }
        }
        return markers.filter(found.contains)
    }

    /// Inspect only browser chrome, never page contents or tab URLs. An
    /// incomplete/unsupported AX tree is unknown, not evidence that a call ended.
    func browserMeetingHasEnded(_ candidate: LibreReverseMeetingCandidate) -> Bool {
        guard candidate.provider == .googleMeet,
            let pid = candidate.processIdentifier, let bundle = candidate.bundleIdentifier
        else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
            app.bundleIdentifier == bundle else { return true }
        guard bundle == "com.google.Chrome", AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw) == .success,
            let windows = raw as? [AXUIElement], !windows.isEmpty else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        var titles: [String] = []
        var visited = Set<AXUIElement>()
        for window in windows {
            var queue = [(window, 0)]
            var cursor = 0
            let previousCount = titles.count
            while cursor < queue.count {
                guard visited.count < 500, ProcessInfo.processInfo.systemUptime < deadline else { return false }
                let (element, depth) = queue[cursor]
                cursor += 1
                guard visited.insert(element).inserted else { continue }
                guard let role = stringAttribute(element, kAXRoleAttribute) else { return false }
                if role == "AXWebArea" { continue }
                if role == "AXRadioButton" || role == "AXTab" {
                    let title = [stringAttribute(element, kAXTitleAttribute),
                        stringAttribute(element, kAXDescriptionAttribute)].compactMap { $0 }.first { !$0.isEmpty } ?? ""
                    guard !title.isEmpty else { return false }
                    titles.append(title)
                    continue
                }
                var childrenValue: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
                if result == .attributeUnsupported || result == .noValue { continue }
                guard result == .success, let children = childrenValue as? [AXUIElement] else { return false }
                guard children.isEmpty || depth < 12 else { return false }
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
            // Pop-outs and dialogs cannot be classified through the tab strip.
            guard titles.count > previousCount else { return false }
        }
        return Self.meetTabIsAbsent(candidate: candidate, tabTitles: titles)
    }

    static func meetTabIsAbsent(candidate: LibreReverseMeetingCandidate, tabTitles: [String]) -> Bool {
        guard candidate.provider == .googleMeet, let url = candidate.url,
            LibreReverseMeetingDetector.browserProvider(for: url) == .googleMeet,
            let originalTitle = candidate.title, !tabTitles.isEmpty else { return false }
        let room = url.lastPathComponent.lowercased()
        // Only standard Meet titles establish a recognizable tab identity.
        guard originalTitle.lowercased().contains(room) else { return false }
        return tabTitles.allSatisfy { title in
            let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !normalized.isEmpty && !normalized.contains(room)
                && !normalized.hasPrefix("meet ") && !normalized.hasPrefix("google meet")
        }
    }

    private func accessibilityFrame(_ element: AXUIElement) -> CGRect? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPosition, let rawSize,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(rawPosition, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Call evidence and URL/privacy must refer to the same browser window.
    /// Native menu/window discovery retains its existing fallback behavior.
    static func meetingWindowIndex(windowTitle: String, windowBounds: CGRect?,
                                   identities: [BrowserAXWindowIdentity], isBrowser: Bool) -> Int? {
        if isBrowser {
            return BrowserAXWindowResolver.matchingIndex(title: windowTitle,
                bounds: windowBounds, candidates: identities)
        }
        return identities.firstIndex { identity in
            if let windowBounds, identity.bounds == windowBounds { return true }
            return identity.title.map {
                meetingWindowTitleMatches($0, windowTitle: windowTitle, isBrowser: false)
            } ?? false
        } ?? identities.indices.first
    }

    static func meetingWindowTitleMatches(_ title: String, windowTitle: String, isBrowser: Bool) -> Bool {
        // Chromium inserts capture status and profile names into the AX title.
        // Keep the complete WindowServer title as the anchor and reject unnamed
        // auxiliary windows, which must never inherit another tab's call state.
        guard !windowTitle.isEmpty else { return false }
        return title == windowTitle || (isBrowser && title.hasPrefix(windowTitle + " - "))
    }

    private func stringAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                attribute as CFString,
                &value
            ) == .success
        else { return nil }
        return value as? String
    }
}
#endif
