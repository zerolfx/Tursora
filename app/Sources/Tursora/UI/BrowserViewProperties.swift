import AppKit

extension BrowserViewController {
    /// Virtual locations never acquire a key, including physical ZIP snapshots.
    static func persistenceKey(for url: URL) -> String? {
        let workspace = ArchiveWorkspace.shared
        return DirectoryViewPropertiesStore.directoryKey(
            for: url, isVirtual: workspace.containsArchiveLocation(url) || workspace.archiveURL(containing: url) != nil)
    }

    var currentViewProperties: DirectoryViewProperties {
        var properties = rememberedViewProperties
        properties.viewMode = viewMode
        properties.setZoomIndex(zoomIndex, for: viewMode)
        properties.sortKey = model.sortKey
        properties.ascending = model.ascending
        properties.groupKey = model.groupKey
        properties.showHidden = model.showHidden
        properties.showPreviews = showsPreviews
        return properties
    }

    /// Search keeps its originating URL for navigation, but its temporary view
    /// must never overwrite that folder or react to folder-policy broadcasts.
    var canPersistViewProperties: Bool {
        viewPropertiesKey != nil && !isPreparingArchive && !isSearching && !model.isSearchResults
    }

    func persistViewProperties() {
        guard !isApplyingViewProperties, canPersistViewProperties,
              let key = viewPropertiesKey else { return }
        let properties = currentViewProperties
        guard properties != lastAppliedViewProperties else { return }
        lastAppliedViewProperties = properties
        viewPropertiesStore.save(properties, forKey: key)
    }

    /// Read from the in-memory library before listing begins. No asynchronous
    /// property callback can race a newer navigation or mutate its history.
    func restoreViewProperties() {
        let properties = viewPropertiesStore.properties(forKey: viewPropertiesKey)
        isApplyingViewProperties = true
        let selected = fileView.selectedItems.map(\.url)
        let offset = fileView.scrollOffset
        let listHorizontalOffset = fileList.scrollView.contentView.bounds.minX
        rememberedViewProperties = properties
        // Arrange the final model before mounting a previously inactive list.
        // Expanding obsolete groups can otherwise scroll its name column away.
        model.showHidden = properties.showHidden
        model.groupKey = properties.groupKey
        fileList.setSort(key: properties.sortKey, ascending: properties.ascending)
        setViewMode(properties.viewMode)
        setZoomIndex(properties.zoomIndex(for: properties.viewMode))
        setShowsPreviews(properties.showPreviews)
        fileView.select(urls: selected)
        fileView.scrollOffset = offset
        if viewMode == .details {
            view.layoutSubtreeIfNeeded()
            let clip = fileList.scrollView.contentView
            var proposed = clip.bounds
            proposed.origin.x = listHorizontalOffset
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
            fileList.scrollView.reflectScrolledClipView(clip)
        }
        lastAppliedViewProperties = properties
        isApplyingViewProperties = false
        host?.viewModeDidChange(in: self)
    }

    func observeViewProperties() {
        viewPropertiesObserver = NotificationCenter.default.addObserver(
            forName: DirectoryViewPropertiesStore.didChange, object: viewPropertiesStore, queue: .main
        ) { [weak self] notification in
            guard let self, self.canPersistViewProperties, let key = self.viewPropertiesKey else { return }
            switch notification.userInfo?["reason"] as? String {
            case "writeStatus": return
            case "reset":
                guard notification.userInfo?["key"] as? String == key else { return }
            case "default":
                guard self.viewPropertiesStore.policy == .unified || !self.viewPropertiesStore.hasOverride(forKey: key) else { return }
            default: break
            }
            self.restoreViewProperties()
        }
    }

    func setViewPropertiesPolicy(_ policy: DirectoryViewPropertiesStore.Policy) {
        viewPropertiesStore.setPolicy(policy)
    }

    func useCurrentViewAsDefault() {
        guard canPersistViewProperties else { return }
        viewPropertiesStore.setDefault(currentViewProperties)
    }

    func restoreDirectoryViewDefaults() {
        guard canPersistViewProperties, let key = viewPropertiesKey else { return }
        viewPropertiesStore.reset(key: key)
        restoreViewProperties()
    }
}

extension MainWindowController {
    @objc func rememberFolderViews(_ sender: Any?) { browser.setViewPropertiesPolicy(.perDirectory) }
    @objc func useUnifiedFolderView(_ sender: Any?) { browser.setViewPropertiesPolicy(.unified) }
    @objc func useCurrentViewAsDefault(_ sender: Any?) { browser.useCurrentViewAsDefault() }
    @objc func restoreFolderViewDefaults(_ sender: Any?) { browser.restoreDirectoryViewDefaults() }

    func validateViewPropertiesMenuItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(rememberFolderViews(_:)):
            item.state = browser.viewPropertiesStore.policy == .perDirectory ? .on : .off
            return true
        case #selector(useUnifiedFolderView(_:)):
            item.state = browser.viewPropertiesStore.policy == .unified ? .on : .off
            return true
        case #selector(useCurrentViewAsDefault(_:)):
            return browser.canPersistViewProperties
        case #selector(restoreFolderViewDefaults(_:)):
            return browser.canPersistViewProperties && browser.viewPropertiesStore.policy == .perDirectory
        default: return nil
        }
    }
}
