import AppKit

/// A search belongs to a pane. Its directory origin remains a normal navigation
/// location; only DirectoryModel's destinationless results enter search mode.
extension BrowserViewController {
    func configureSearch() {
        searchPanel.onSearch = { [weak self] request in self?.startSearch(request) }
        searchPanel.onShowOptions = { [weak self] in self?.showSearch() }
        searchPanel.onFocusName = { [weak self] in
            guard let self else { return }
            self.onFocus?()
            self.host?.focusSearch(in: self)
        }
        searchPanel.onClear = { [weak self] in
            guard let self else { return }
            self.nameFilter = ""
            self.searchReloadCompletions = []
            self.searchSelection = []
            self.searchSession.clear()
        }
        searchPanel.onCancel = { [weak self] in self?.searchSession.cancel() }
        searchPanel.onClose = { [weak self] in self?.closeSearch() }
        searchSession.onChange = { [weak self] in
            guard let self, self.isSearching else { return }
            let selected = self.fileView.selectedItems.map(\.url)
            self.model.replaceSearchResults(self.searchSession.results)
            self.fileView.select(urls: self.searchSelection.isEmpty ? selected : self.searchSelection)
            let status = self.searchSession.status
            let failed: Bool
            if case .failed = status { failed = true } else { failed = false }
            let message = self.searchSession.request?.usesSpotlight == true && !status.message.contains("Content uses Spotlight")
                ? status.message + " " + SearchRequest.contentLimitMessage : status.message
            self.searchPanel.update(status: message, resultCount: self.model.items.count,
                                    isRunning: status.isSearching, isError: failed)
            if !status.isSearching {
                self.searchSelection = []
                let completions = self.searchReloadCompletions
                self.searchReloadCompletions = []
                completions.forEach { $0() }
            }
        }
        model.onReloadResults = { [weak self] completion in
            self?.restartSearch(completion: completion)
        }
    }

    @objc func showSearchAction(_ sender: Any?) { showSearch() }
    @objc func closeSearchAction(_ sender: Any?) { closeSearch() }

    /// The toolbar is window-owned; its value always comes from this pane.
    var searchFieldText: String {
        searchPanel.isShowingOptions ? searchPanel.nameField.stringValue : nameFilter
    }

    func applySearchFieldText(_ text: String, scheduleSearch: Bool = true) {
        if searchPanel.isShowingOptions {
            searchPanel.setNameQuery(text, scheduleSearch: scheduleSearch)
            if !scheduleSearch { searchPanel.cancelPendingSearch() }
        } else {
            nameFilter = text
            updateFilterSearchHint()
        }
    }

    func updateFilterSearchHint() {
        guard !searchPanel.isShowingOptions else { return }
        _ = view
        let show = !nameFilter.isEmpty && currentURL != nil && !isBrowsingArchive && !isPreparingArchive
        if show, let currentURL {
            searchPanel.configure(rootURL: currentURL)
            searchPanel.setNameQuery(nameFilter, scheduleSearch: false)
        }
        searchPanel.view.isHidden = !show
        searchPanelHeight?.isActive = !show
    }

    /// Explicit entry into recursive search. Automatic query updates never
    /// call this focus-changing method.
    func showSearch() {
        guard let currentURL, !isBrowsingArchive, !isPreparingArchive else { return }
        _ = view
        let entering = !searchPanel.isShowingOptions
        if entering {
            let query = nameFilter
            searchPanel.configure(rootURL: currentURL)
            searchPanel.present(request: SearchRequest(rootURL: currentURL, name: query))
            searchPanel.setShowsOptions(true)
        }
        searchPanel.view.isHidden = false
        searchPanelHeight?.isActive = false
        onLocationChanged?(currentURL)
        searchPanel.focusName()
        if entering, !searchPanel.currentRequest.trimmedName.isEmpty { searchPanel.scheduleSearch() }
    }

    func startSearch(_ request: SearchRequest) {
        guard !isBrowsingArchive, !isPreparingArchive else { return }
        _ = view
        searchPanel.setShowsOptions(true)
        searchPanel.view.isHidden = false
        searchPanelHeight?.isActive = false
        guard !ArchiveWorkspace.shared.containsArchiveLocation(request.effectiveRootURL),
              ArchiveWorkspace.shared.archiveURL(containing: request.effectiveRootURL) == nil else {
            searchSession.cancel()
            searchPanel.update(status: "ZIP contents cannot be searched. Choose an ordinary folder.",
                               resultCount: 0, isRunning: false, isError: true)
            return
        }
        prepareSearchDisplay()
        nameFilter = ""
        searchReloadCompletions = []
        searchSelection = []
        isSearching = true
        model.beginSearchResults()
        searchPanel.present(request: request)
        searchSession.start(request)
        if let currentURL { onLocationChanged?(currentURL) }
    }

    func restartSearch(completion: (() -> Void)? = nil) {
        guard isSearching, let request = searchSession.request else { completion?(); return }
        if searchSelection.isEmpty { searchSelection = fileView.selectedItems.map(\.url) }
        if let completion { searchReloadCompletions.append(completion) }
        searchSession.start(request)
    }

    func leaveSearchContext() {
        guard isSearching || (isViewLoaded && !searchPanel.view.isHidden) else { return }
        isSearching = false
        searchSession.clear()
        searchPanel.cancelPendingSearch()
        searchPanel.setShowsOptions(false)
        searchPanel.update(status: "", resultCount: 0, isRunning: false)
        searchReloadCompletions = []
        searchSelection = []
        searchPanel.view.isHidden = true
        searchPanelHeight?.isActive = true
    }

    func closeSearch() {
        guard let currentURL else { return }
        leaveSearchContext()
        nameFilter = ""
        navigate(to: currentURL)
        view.window?.makeFirstResponder(focusView)
    }

    func reloadSelectingURLs(_ urls: [URL]) {
        if isSearching {
            searchSelection = urls
            restartSearch()
        } else {
            model.reload { [weak self] in self?.fileView.select(urls: urls) }
        }
    }

    func revealSearchResult(_ url: URL) {
        guard isSearching else { return }
        navigate(to: url.deletingLastPathComponent())
        // A reload completion is tied to the directory model's load generation.
        model.reload { [weak self] in
            guard let self, self.currentURL?.standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL else { return }
            self.fileView.select(urls: [url])
        }
    }
}
