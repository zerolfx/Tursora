import AppKit

/// Tests the observed Finder disclosure baseline and explicit-choice migration
/// using an isolated preference domain; real user section choices stay intact.
enum InfoDisclosureSmokeTests {
    private static let keys = ["general", "moreInfo", "name", "comments", "openWith", "preview", "sharing"]
    private static let initiallyOpen: Set<String> = ["general", "preview"]

    static func run() {
        print("== Info disclosure defaults and memory ==")
        let suite = "com.tursora.smoke.info-disclosures." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        migration(defaults)
        sections(defaults)
        defaults.removePersistentDomain(forName: suite)
        windows(defaults)
    }

    private static func migration(_ defaults: UserDefaults) {
        for key in keys {
            let legacy = "InfoSection.\(key)"
            let explicit = InfoSection.explicitPreferenceKey(for: key)
            let expected = initiallyOpen.contains(key)
            check("\(key): missing preference uses the observed Finder baseline", InfoSection.initialExpansion(for: key, defaults: defaults) == expected)
            defaults.set(true, forKey: legacy)
            check("\(key): legacy automatic true adopts the new baseline", InfoSection.initialExpansion(for: key, defaults: defaults) == expected)
            defaults.set(false, forKey: legacy)
            check("\(key): legacy collapse remains collapsed", !InfoSection.initialExpansion(for: key, defaults: defaults))
            defaults.set(true, forKey: explicit)
            check("\(key): explicit expansion overrides legacy collapse", InfoSection.initialExpansion(for: key, defaults: defaults))
            defaults.set(true, forKey: legacy)
            defaults.set(false, forKey: explicit)
            check("\(key): explicit collapse overrides legacy expansion", !InfoSection.initialExpansion(for: key, defaults: defaults))
            defaults.removeObject(forKey: legacy)
            defaults.removeObject(forKey: explicit)
        }
    }

    private static func sections(_ defaults: UserDefaults) {
        for key in keys {
            let expected = initiallyOpen.contains(key)
            let section = InfoSection(key: key, title: key, content: NSView(), defaults: defaults)
            check("\(key): initial content visibility matches expansion", section.isExpanded == expected && section.content.isHidden != expected && section.hasChevron)
            check("\(key): constructing a section creates no preferences", defaults.object(forKey: "InfoSection.\(key)") == nil && defaults.object(forKey: InfoSection.explicitPreferenceKey(for: key)) == nil)
            var toggles = 0
            section.onToggle = { toggles += 1 }
            section.toggle()
            check("\(key): toggle updates content and records an explicit choice", section.isExpanded != expected && section.content.isHidden == expected && defaults.object(forKey: InfoSection.explicitPreferenceKey(for: key)) as? Bool == !expected && toggles == 1)
            let reopened = InfoSection(key: key, title: key, content: NSView(), defaults: defaults)
            check("\(key): a reopened section keeps the choice", reopened.isExpanded != expected)
            reopened.toggle()
            let reopenedAgain = InfoSection(key: key, title: key, content: NSView(), defaults: defaults)
            check("\(key): toggling back explicitly remembers either boolean", reopenedAgain.isExpanded == expected && defaults.object(forKey: InfoSection.explicitPreferenceKey(for: key)) as? Bool == expected)
            defaults.removeObject(forKey: InfoSection.explicitPreferenceKey(for: key))
        }
    }

    private static func windows(_ defaults: UserDefaults) {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("tursora-info-disclosures-" + UUID().uuidString)
        var controllers: [InfoWindowController] = []
        defer {
            controllers.forEach { $0.close() }
            try? FileManager.default.removeItem(at: fixture)
        }
        do {
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            let first = fixture.appendingPathComponent("First.txt"), second = fixture.appendingPathComponent("Second.txt")
            try "Info disclosure fixture".write(to: first, atomically: true, encoding: .utf8)
            try "Summary fixture".write(to: second, atomically: true, encoding: .utf8)
            func make(_ mode: InfoWindowController.Mode, _ urls: [URL]) -> InfoWindowController {
                let controller = InfoWindowController(mode: mode, urls: urls, disclosureDefaults: defaults)
                controllers.append(controller)
                return controller
            }
            let item = make(.item, [first])
            check("Info builds General, Name, Comments, Open with, Preview and Sharing", Set(["general", "name", "comments", "openWith", "preview", "sharing"]).isSubset(of: Set(item.sectionKeys)))
            check("Info applies the observed baseline to every constructed section", item.sectionKeys.allSatisfy { item.section($0)?.isExpanded == initiallyOpen.contains($0) })
            check("Info construction leaves all explicit choices absent", keys.allSatisfy { defaults.object(forKey: InfoSection.explicitPreferenceKey(for: $0)) == nil })
            item.section("comments")?.toggle()
            let inspector = make(.inspector, [first])
            check("Inspector inherits an explicit Info expansion", inspector.section("comments")?.isExpanded == true)
            check("Inspector shares the remaining baseline", inspector.section("name")?.isExpanded == false && inspector.section("general")?.isExpanded == true && inspector.section("preview")?.isExpanded == true)
            inspector.section("preview")?.toggle()
            check("already open windows retain their own visible state", item.section("preview")?.isExpanded == true && inspector.section("preview")?.isExpanded == false)
            let reopened = make(.item, [second])
            check("new Info inherits Inspector choices across items", reopened.section("preview")?.isExpanded == false && reopened.section("comments")?.isExpanded == true)
            let summary = make(.summary, [first, second])
            check("Summary initially shows only expanded General", summary.sectionKeys == ["general"] && summary.section("general")?.isExpanded == true)
            summary.section("general")?.toggle()
            let nextInspector = make(.inspector, [second])
            check("Summary disclosure memory also applies to new Inspector windows", nextInspector.section("general")?.isExpanded == false)
            check("changing General does not alter independent section choices", nextInspector.section("comments")?.isExpanded == true && nextInspector.section("preview")?.isExpanded == false && nextInspector.section("name")?.isExpanded == false)
        } catch {
            check("temporary Info fixtures can be created: \(error.localizedDescription)", false)
        }
    }

    private static func check(_ name: String, _ success: Bool) {
        print("\(success ? "ok  " : "FAIL") Info disclosures: \(name)")
        if !success { exit(1) }
    }
}
