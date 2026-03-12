import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum SearchDirection {
    case forward
    case backward
}

enum ZoomAction {
    case inStep
    case outStep
    case actualSize
    case fitWidth
    case fitPage
}

struct SearchRequest: Equatable {
    let id = UUID()
    let query: String
    let direction: SearchDirection
}

struct ZoomRequest: Equatable {
    let id = UUID()
    let action: ZoomAction
}

struct PendingStamp: Equatable {
    let id = UUID()
    let text: String
}

private enum StampStyle {
    static let subject = "HyeonsPDFViewerStamp"
    static let markerKey = PDFAnnotationKey(rawValue: "HyeonsStampMarker")
    static let fontSize: CGFloat = 14
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    static let minWidth: CGFloat = 96
    static let minHeight: CGFloat = 24

    static func font() -> NSFont {
        NSFont.systemFont(ofSize: fontSize, weight: .regular)
    }

    static func bounds(for text: String, at point: CGPoint, within pageBounds: CGRect) -> CGRect {
        let textSize = (text as NSString).size(withAttributes: [.font: font()])
        let width = min(
            max(minWidth, textSize.width + (horizontalPadding * 2)),
            max(pageBounds.width, minWidth)
        )
        let height = min(
            max(minHeight, textSize.height + (verticalPadding * 2)),
            max(pageBounds.height, minHeight)
        )

        let maxX = max(pageBounds.minX, pageBounds.maxX - width)
        let maxY = max(pageBounds.minY, pageBounds.maxY - height)
        let originX = min(max(point.x, pageBounds.minX), maxX)
        let originY = min(max(point.y - height, pageBounds.minY), maxY)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    static func movedBounds(
        for annotation: PDFAnnotation,
        anchorPoint: CGPoint,
        dragOffset: CGPoint,
        within pageBounds: CGRect
    ) -> CGRect {
        let size = annotation.bounds.size
        let maxX = max(pageBounds.minX, pageBounds.maxX - size.width)
        let maxY = max(pageBounds.minY, pageBounds.maxY - size.height)
        let originX = min(max(anchorPoint.x - dragOffset.x, pageBounds.minX), maxX)
        let originY = min(max(anchorPoint.y - dragOffset.y, pageBounds.minY), maxY)
        return CGRect(x: originX, y: originY, width: size.width, height: size.height)
    }

    static func isManaged(annotation: PDFAnnotation) -> Bool {
        if (annotation.value(forAnnotationKey: markerKey) as? String) == subject {
            return true
        }

        // Backward compatibility for stamps created before marker support.
        let isLegacyFreeText = annotation.type == PDFAnnotationSubtype.freeText.rawValue
        let hasTransparentBackground = annotation.color.alphaComponent <= 0.01
        return isLegacyFreeText && annotation.isReadOnly && hasTransparentBackground
    }
}

struct RecentFileItem: Equatable, Identifiable {
    let url: URL

    var id: String {
        url.path
    }

    var displayName: String {
        url.lastPathComponent
    }
}

private enum PersistedKeys {
    static let lastDocumentBookmark = "lastDocumentBookmark"
    static let lastDocumentPath = "lastDocumentPath"
    static let lastPageIndex = "lastPageIndex"
    static let recentFilePaths = "recentFilePaths"
    static let showsThumbnails = "showsThumbnails"
    static let thumbnailPaneWidth = "thumbnailPaneWidth"
    static let zoomScaleFactor = "zoomScaleFactor"
    static let zoomUsesAutoScale = "zoomUsesAutoScale"
    static let isFocusMode = "isFocusMode"
    static let searchQuery = "searchQuery"
    static let signerName = "signerName"
    static let windowFrame = "windowFrame"
}

@main
struct SimplePDFViewerApp: App {
    @StateObject private var model = PDFDocumentModel()
    @NSApplicationDelegateAdaptor(AppFileOpenDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Hyeon's PDF Viewer") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 620)
                .onAppear {
                    appDelegate.setModel(model)
                }
        }
        .commands {
            ViewerCommands(model: model)
        }
    }
}

@MainActor
final class AppFileOpenDelegate: NSObject, NSApplicationDelegate {
    private weak var model: PDFDocumentModel?
    private var pendingFileURLs: [URL] = []
    private var hasScannedLaunchArguments = false

    func setModel(_ model: PDFDocumentModel) {
        self.model = model
        enqueueLaunchArgumentFilesIfNeeded()
        flushPendingFilesIfNeeded()
    }

    nonisolated func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            self.enqueueIncomingFiles(urls)
        }
    }

    nonisolated func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        Task { @MainActor in
            self.enqueueIncomingFiles([URL(fileURLWithPath: filename)])
        }
        return true
    }

    nonisolated func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        Task { @MainActor in
            self.enqueueIncomingFiles(urls)
            sender.reply(toOpenOrPrint: .success)
        }
    }

    private func enqueueIncomingFiles(_ urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else {
            return
        }

        if let model {
            openMostRecentFile(from: fileURLs, with: model)
        } else {
            pendingFileURLs.append(contentsOf: fileURLs)
        }
    }

    private func flushPendingFilesIfNeeded() {
        guard let model, !pendingFileURLs.isEmpty else {
            return
        }

        let queuedFiles = pendingFileURLs
        pendingFileURLs.removeAll()
        openMostRecentFile(from: queuedFiles, with: model)
    }

    private func openMostRecentFile(from urls: [URL], with model: PDFDocumentModel) {
        guard let targetURL = urls.last else {
            return
        }

        model.openDocument(at: targetURL, restorePage: false)
        normalizeMainWindow()
    }

    private func enqueueLaunchArgumentFilesIfNeeded() {
        guard !hasScannedLaunchArguments else {
            return
        }
        hasScannedLaunchArguments = true

        let arguments = ProcessInfo.processInfo.arguments.dropFirst()
        guard !arguments.isEmpty else {
            return
        }

        let candidateURLs = arguments.compactMap { arg -> URL? in
            if arg.hasPrefix("-psn_") {
                return nil
            }
            let expanded = NSString(string: arg).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            if url.pathExtension.lowercased() == "pdf" {
                return url
            }
            return nil
        }

        if !candidateURLs.isEmpty {
            enqueueIncomingFiles(candidateURLs)
        }
    }

    private func normalizeMainWindow() {
        let candidateWindows = NSApp.windows.filter { window in
            window.canBecomeMain &&
            !window.isExcludedFromWindowsMenu &&
            window.sheetParent == nil
        }

        guard let primaryWindow = candidateWindows.first else {
            return
        }

        for window in candidateWindows.dropFirst() {
            window.close()
        }

        primaryWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ViewerCommands: Commands {
    @ObservedObject var model: PDFDocumentModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Hyeon's PDF Viewer") {
                model.showAboutPanel()
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                _ = model.saveDocument()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!model.hasDocument)

            Button("Save As...") {
                model.saveDocumentAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!model.hasDocument)
        }

        CommandGroup(after: .newItem) {
            Menu("Open Recent") {
                if model.recentFiles.isEmpty {
                    Button("No Recent Files") {}
                        .disabled(true)
                } else {
                    ForEach(model.recentFiles) { item in
                        Button(item.displayName) {
                            model.openRecentFile(item.url)
                        }
                    }
                    Divider()
                    Button("Clear Menu") {
                        model.clearRecentFiles()
                    }
                }
            }
        }

        CommandMenu("Stamp") {
            Button("Stamp Name") {
                model.queueNameStamp()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(!model.hasDocument)

            Button("Stamp Date") {
                model.queueDateStamp()
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(!model.hasDocument)

            Divider()

            Button("Cancel Stamp") {
                model.cancelStampPlacement()
            }
            .disabled(model.pendingStamp == nil)

            Button("Delete Selected Stamp") {
                model.requestDeleteSelectedStamp()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!model.hasSelectedStamp)
        }

        CommandMenu("Find") {
            Button("Find") {
                model.requestSearchFieldFocus()
            }
            .keyboardShortcut("f", modifiers: [.command])

            Button("Find Next") {
                model.findNext()
            }
            .keyboardShortcut("g", modifiers: [.command])
            .disabled(!model.hasDocument)

            Button("Find Previous") {
                model.findPrevious()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!model.hasDocument)
        }

        CommandMenu("Reader") {
            Button(model.isFocusMode ? "Exit Focus Mode" : "Enter Focus Mode") {
                model.toggleFocusMode()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button(model.showsThumbnails ? "Hide Thumbnails" : "Show Thumbnails") {
                model.toggleThumbnails()
            }
            .disabled(!model.hasDocument)
        }

        CommandMenu("Zoom") {
            Button("Zoom In") {
                model.zoomIn()
            }
            .keyboardShortcut("=", modifiers: [.command])
            .disabled(!model.hasDocument)

            Button("Zoom Out") {
                model.zoomOut()
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(!model.hasDocument)

            Button("Actual Size") {
                model.zoomActualSize()
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(!model.hasDocument)

            Divider()

            Button("Fit Width") {
                model.zoomFitWidth()
            }
            .disabled(!model.hasDocument)

            Button("Fit Page") {
                model.zoomFitPage()
            }
            .disabled(!model.hasDocument)
        }
    }
}

@MainActor
final class PDFDocumentModel: ObservableObject {
    let minThumbnailPaneWidth: CGFloat = 120
    let maxThumbnailPaneWidth: CGFloat = 420
    let defaultThumbnailPaneWidth: CGFloat = 180

    @Published var document: PDFDocument?
    @Published var recentFiles: [RecentFileItem] = []
    @Published var currentPageIndex = 0 {
        didSet {
            persistCurrentPageIndex()
        }
    }
    @Published var searchQuery = "" {
        didSet {
            defaults.set(searchQuery, forKey: PersistedKeys.searchQuery)
        }
    }
    @Published var searchFieldFocusRequestID = UUID()
    @Published var searchRequest: SearchRequest?
    @Published var zoomRequest: ZoomRequest?
    @Published var deleteSelectedStampRequest: UUID?
    @Published var pendingStamp: PendingStamp?
    @Published var hasSelectedStamp = false
    @Published var searchStatus: String?
    @Published var hasUnsavedChanges = false
    @Published var showsThumbnails = false {
        didSet {
            defaults.set(showsThumbnails, forKey: PersistedKeys.showsThumbnails)
        }
    }
    @Published var thumbnailPaneWidth: CGFloat = 180 {
        didSet {
            let clamped = clampedThumbnailWidth(thumbnailPaneWidth)
            if clamped != thumbnailPaneWidth {
                thumbnailPaneWidth = clamped
                return
            }
            defaults.set(Double(clamped), forKey: PersistedKeys.thumbnailPaneWidth)
        }
    }
    @Published var persistedZoomScaleFactor: CGFloat = 1.0 {
        didSet {
            defaults.set(Double(persistedZoomScaleFactor), forKey: PersistedKeys.zoomScaleFactor)
        }
    }
    @Published var persistedZoomUsesAutoScale = true {
        didSet {
            defaults.set(persistedZoomUsesAutoScale, forKey: PersistedKeys.zoomUsesAutoScale)
        }
    }
    @Published var isFocusMode = false {
        didSet {
            defaults.set(isFocusMode, forKey: PersistedKeys.isFocusMode)
        }
    }
    @Published var signerName = NSFullUserName() {
        didSet {
            defaults.set(signerName, forKey: PersistedKeys.signerName)
        }
    }

    private let defaults = UserDefaults.standard
    private weak var observedWindow: NSWindow?
    private var windowFrameObserver: WindowFrameObserver?
    private var windowDelegateProxy: UnsavedChangesWindowDelegate?
    private var hasAppliedSavedWindowFrame = false
    private var currentDocumentURL: URL?
    private static let stampDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    init() {
        showsThumbnails = defaults.bool(forKey: PersistedKeys.showsThumbnails)
        recentFiles = loadRecentFiles()
        let storedPaneWidth = defaults.double(forKey: PersistedKeys.thumbnailPaneWidth)
        if storedPaneWidth > 0 {
            thumbnailPaneWidth = clampedThumbnailWidth(CGFloat(storedPaneWidth))
        } else {
            thumbnailPaneWidth = defaultThumbnailPaneWidth
        }
        if defaults.object(forKey: PersistedKeys.zoomScaleFactor) != nil {
            persistedZoomScaleFactor = max(CGFloat(defaults.double(forKey: PersistedKeys.zoomScaleFactor)), 0.1)
        }
        if defaults.object(forKey: PersistedKeys.zoomUsesAutoScale) != nil {
            persistedZoomUsesAutoScale = defaults.bool(forKey: PersistedKeys.zoomUsesAutoScale)
        }
        isFocusMode = defaults.bool(forKey: PersistedKeys.isFocusMode)
        searchQuery = defaults.string(forKey: PersistedKeys.searchQuery) ?? ""
        if let storedSignerName = defaults.string(forKey: PersistedKeys.signerName),
           !storedSignerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            signerName = storedSignerName
        }
        restoreLastDocumentIfPossible()
    }

    var pageCount: Int {
        document?.pageCount ?? 0
    }

    var hasDocument: Bool {
        document != nil
    }

    var canGoToPreviousPage: Bool {
        currentPageIndex > 0
    }

    var canGoToNextPage: Bool {
        currentPageIndex < max(pageCount - 1, 0)
    }

    func showAboutPanel() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info["CFBundleVersion"] as? String ?? "Unknown"

        let credits = NSAttributedString(
            string: "Lightweight macOS PDF viewer for fast reading and simple signing.\n(c) 2026 Hyeon Yu"
        )

        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Hyeon's PDF Viewer",
            .applicationVersion: version,
            .version: "Build \(build)",
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open PDF"

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        openDocument(at: selectedURL, restorePage: false)
    }

    func openDocument(at url: URL, restorePage: Bool, shouldPromptForUnsavedChanges: Bool = true) {
        if shouldPromptForUnsavedChanges && !confirmDocumentTransitionIfNeeded(reason: .openAnotherDocument) {
            return
        }

        guard let loadedDocument = PDFDocument(url: url) else {
            searchStatus = "Could not open file."
            return
        }

        currentDocumentURL = url
        document = loadedDocument
        let savedPage = defaults.integer(forKey: PersistedKeys.lastPageIndex)
        currentPageIndex = restorePage ? clampedPageIndex(savedPage, pageCount: loadedDocument.pageCount) : 0
        searchRequest = nil
        pendingStamp = nil
        searchStatus = nil
        hasUnsavedChanges = false
        persistLastDocument(url)
        registerRecentFile(url)
    }

    func openRecentFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            removeRecentFile(url)
            searchStatus = "Recent file not found."
            return
        }
        openDocument(at: url, restorePage: false)
    }

    func clearRecentFiles() {
        persistRecentFiles([])
    }

    func goToPreviousPage() {
        guard canGoToPreviousPage else {
            return
        }
        currentPageIndex -= 1
    }

    func goToNextPage() {
        guard canGoToNextPage else {
            return
        }
        currentPageIndex += 1
    }

    func toggleThumbnails() {
        showsThumbnails.toggle()
    }

    func toggleFocusMode() {
        isFocusMode.toggle()
    }

    func findNext() {
        triggerSearch(.forward)
    }

    func findPrevious() {
        triggerSearch(.backward)
    }

    func requestSearchFieldFocus() {
        if isFocusMode {
            isFocusMode = false
        }
        searchFieldFocusRequestID = UUID()
    }

    func zoomIn() {
        triggerZoom(.inStep)
    }

    func zoomOut() {
        triggerZoom(.outStep)
    }

    func zoomActualSize() {
        triggerZoom(.actualSize)
    }

    func zoomFitWidth() {
        triggerZoom(.fitWidth)
    }

    func zoomFitPage() {
        triggerZoom(.fitPage)
    }

    func queueNameStamp() {
        guard hasDocument else {
            return
        }

        let trimmedName = signerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            searchStatus = "Enter your name, then use Stamp Name."
            return
        }

        pendingStamp = PendingStamp(text: trimmedName)
        searchStatus = "Move cursor to position the dashed preview, then click to place the name."
    }

    func queueDateStamp() {
        guard hasDocument else {
            return
        }

        let dateText = Self.stampDateFormatter.string(from: Date())
        pendingStamp = PendingStamp(text: dateText)
        searchStatus = "Move cursor to position the dashed preview, then click to place the date."
    }

    func cancelStampPlacement() {
        pendingStamp = nil
    }

    func requestDeleteSelectedStamp() {
        guard hasDocument else {
            return
        }
        deleteSelectedStampRequest = UUID()
    }

    @discardableResult
    func saveDocument() -> Bool {
        guard let document else {
            return false
        }

        guard let currentDocumentURL else {
            return saveDocumentAs()
        }

        if document.write(to: currentDocumentURL) {
            hasUnsavedChanges = false
            searchStatus = "Saved \(currentDocumentURL.lastPathComponent)."
            return true
        }

        searchStatus = "Could not save PDF."
        return false
    }

    @discardableResult
    func saveDocumentAs() -> Bool {
        guard let document else {
            return false
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.title = "Save PDF As"
        panel.nameFieldStringValue = proposedSaveFilename()

        if let currentDocumentURL {
            panel.directoryURL = currentDocumentURL.deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let saveURL = panel.url else {
            return false
        }

        if document.write(to: saveURL) {
            currentDocumentURL = saveURL
            persistLastDocument(saveURL)
            registerRecentFile(saveURL)
            hasUnsavedChanges = false
            searchStatus = "Saved as \(saveURL.lastPathComponent)."
            return true
        } else {
            searchStatus = "Could not save PDF."
            return false
        }
    }

    private func triggerSearch(_ direction: SearchDirection) {
        guard hasDocument else {
            return
        }

        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchStatus = "Type text to search."
            return
        }

        searchRequest = SearchRequest(query: trimmed, direction: direction)
    }

    private func triggerZoom(_ action: ZoomAction) {
        guard hasDocument else {
            return
        }
        zoomRequest = ZoomRequest(action: action)
    }

    func attachWindow(_ window: NSWindow) {
        guard observedWindow !== window else {
            return
        }

        if let observer = windowFrameObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        observedWindow = window
        applySavedWindowFrame(to: window)
        let proxy = UnsavedChangesWindowDelegate(
            model: self,
            forwardingDelegate: window.delegate
        )
        windowDelegateProxy = proxy
        window.delegate = proxy

        let center = NotificationCenter.default
        let observer = WindowFrameObserver { [weak self] frame in
            self?.persistWindowFrame(frame)
        }
        windowFrameObserver = observer
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
        ]

        for name in names {
            center.addObserver(
                observer,
                selector: #selector(WindowFrameObserver.windowDidChangeFrame(_:)),
                name: name,
                object: window
            )
        }
    }

    private func persistLastDocument(_ url: URL) {
        defaults.set(url.path, forKey: PersistedKeys.lastDocumentPath)

        if let bookmark = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(bookmark, forKey: PersistedKeys.lastDocumentBookmark)
        }
    }

    private func restoreLastDocumentIfPossible() {
        guard let url = restoredLastDocumentURL() else {
            return
        }
        openDocument(at: url, restorePage: true, shouldPromptForUnsavedChanges: false)
    }

    private func restoredLastDocumentURL() -> URL? {
        if let data = defaults.data(forKey: PersistedKeys.lastDocumentBookmark) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ),
            FileManager.default.fileExists(atPath: url.path) {
                if isStale {
                    persistLastDocument(url)
                }
                return url
            }
        }

        if let path = defaults.string(forKey: PersistedKeys.lastDocumentPath),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private func persistCurrentPageIndex() {
        guard hasDocument else {
            return
        }
        defaults.set(max(currentPageIndex, 0), forKey: PersistedKeys.lastPageIndex)
    }

    private func proposedSaveFilename() -> String {
        let baseName: String
        if let currentDocumentURL {
            baseName = currentDocumentURL.deletingPathExtension().lastPathComponent
        } else {
            baseName = "Document"
        }

        if baseName.hasSuffix(" signed") {
            return "\(baseName).pdf"
        }
        return "\(baseName) signed.pdf"
    }

    fileprivate func confirmWindowCloseIfNeeded() -> Bool {
        confirmDocumentTransitionIfNeeded(reason: .closeWindow)
    }

    private enum DocumentTransitionReason {
        case openAnotherDocument
        case closeWindow
    }

    private func confirmDocumentTransitionIfNeeded(reason: DocumentTransitionReason) -> Bool {
        guard hasUnsavedChanges, document != nil else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save changes to this PDF?"
        switch reason {
        case .openAnotherDocument:
            alert.informativeText = "Your stamp changes will be lost if you open another file without saving."
        case .closeWindow:
            alert.informativeText = "Your stamp changes will be lost if you close this window without saving."
        }

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return saveDocument()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func clampedPageIndex(_ value: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else {
            return 0
        }
        return min(max(value, 0), pageCount - 1)
    }

    private func applySavedWindowFrame(to window: NSWindow) {
        guard !hasAppliedSavedWindowFrame else {
            return
        }
        hasAppliedSavedWindowFrame = true

        guard let frameString = defaults.string(forKey: PersistedKeys.windowFrame) else {
            return
        }

        let frame = NSRectFromString(frameString)
        guard frame.width >= 300, frame.height >= 300 else {
            return
        }

        window.setFrame(frame, display: true)
    }

    private func persistWindowFrame(_ frame: NSRect) {
        defaults.set(NSStringFromRect(frame), forKey: PersistedKeys.windowFrame)
    }

    private func clampedThumbnailWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minThumbnailPaneWidth), maxThumbnailPaneWidth)
    }

    private func loadRecentFiles() -> [RecentFileItem] {
        let paths = defaults.stringArray(forKey: PersistedKeys.recentFilePaths) ?? []
        let urls = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        var seenPaths = Set<String>()
        var orderedUnique: [URL] = []
        for url in urls {
            if !seenPaths.contains(url.path) {
                seenPaths.insert(url.path)
                orderedUnique.append(url)
            }
        }

        let trimmed = Array(orderedUnique.prefix(10))
        if trimmed.map(\.path) != paths {
            persistRecentFiles(trimmed)
        }
        return trimmed.map { RecentFileItem(url: $0) }
    }

    private func persistRecentFiles(_ urls: [URL]) {
        defaults.set(urls.map(\.path), forKey: PersistedKeys.recentFilePaths)
        recentFiles = urls.map { RecentFileItem(url: $0) }
    }

    private func registerRecentFile(_ url: URL) {
        var urls = recentFiles.map(\.url)
        urls.removeAll { $0.path == url.path }
        urls.insert(url, at: 0)
        if urls.count > 10 {
            urls = Array(urls.prefix(10))
        }
        persistRecentFiles(urls)
    }

    private func removeRecentFile(_ url: URL) {
        var urls = recentFiles.map(\.url)
        urls.removeAll { $0.path == url.path }
        persistRecentFiles(urls)
    }
}

@MainActor
final class WindowFrameObserver: NSObject {
    private let onFrameChanged: (NSRect) -> Void

    init(onFrameChanged: @escaping (NSRect) -> Void) {
        self.onFrameChanged = onFrameChanged
    }

    @objc func windowDidChangeFrame(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        onFrameChanged(window.frame)
    }
}

@MainActor
final class UnsavedChangesWindowDelegate: NSObject, NSWindowDelegate {
    weak var model: PDFDocumentModel?
    weak var forwardingDelegate: NSWindowDelegate?

    init(model: PDFDocumentModel, forwardingDelegate: NSWindowDelegate?) {
        self.model = model
        if let forwardingDelegate,
           type(of: forwardingDelegate) != UnsavedChangesWindowDelegate.self {
            self.forwardingDelegate = forwardingDelegate
        } else {
            self.forwardingDelegate = nil
        }
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let shouldClose = forwardingDelegate?.windowShouldClose?(sender), !shouldClose {
            return false
        }
        return model?.confirmWindowCloseIfNeeded() ?? true
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: PDFDocumentModel
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !model.isFocusMode {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Button("Open PDF", action: model.openPanel)
                            .keyboardShortcut("o", modifiers: [.command])

                        ControlGroup {
                            Button("Previous", action: model.goToPreviousPage)
                                .disabled(!model.canGoToPreviousPage)
                            Button("Next", action: model.goToNextPage)
                                .disabled(!model.canGoToNextPage)
                        }

                        Toggle("Thumbnail", isOn: $model.showsThumbnails)
                            .toggleStyle(.button)
                            .disabled(!model.hasDocument)

                        Button("Focus", action: model.toggleFocusMode)

                        Menu("Zoom") {
                            Button("Zoom Out", action: model.zoomOut)
                                .disabled(!model.hasDocument)
                            Button("Zoom In", action: model.zoomIn)
                                .disabled(!model.hasDocument)
                            Button("Actual Size", action: model.zoomActualSize)
                                .disabled(!model.hasDocument)
                            Divider()
                            Button("Fit Width", action: model.zoomFitWidth)
                                .disabled(!model.hasDocument)
                            Button("Fit Page", action: model.zoomFitPage)
                                .disabled(!model.hasDocument)
                        }
                        .disabled(!model.hasDocument)

                        TextField("Name", text: $model.signerName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)

                        Menu("Stamp") {
                            Button("Stamp Name", action: model.queueNameStamp)
                                .disabled(!model.hasDocument)
                            Button("Stamp Date", action: model.queueDateStamp)
                                .disabled(!model.hasDocument)
                            Divider()
                            Button("Cancel Stamp", action: model.cancelStampPlacement)
                                .disabled(model.pendingStamp == nil)
                            Button("Delete Selected Stamp", action: model.requestDeleteSelectedStamp)
                                .disabled(!model.hasSelectedStamp)
                        }
                        .disabled(!model.hasDocument)

                        Button("Delete Stamp", action: model.requestDeleteSelectedStamp)
                            .disabled(!model.hasSelectedStamp)

                        Button("Save") {
                            _ = model.saveDocument()
                        }
                            .disabled(!model.hasDocument)

                        Spacer()
                    }

                    HStack(spacing: 10) {
                        TextField("Search text", text: $model.searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 220, maxWidth: 340)
                            .focused($isSearchFieldFocused)
                            .onSubmit {
                                model.findNext()
                            }

                        Button("Find Previous", action: model.findPrevious)
                            .disabled(!model.hasDocument)

                        Button("Find Next", action: model.findNext)
                            .disabled(!model.hasDocument)

                        Spacer()

                        if model.hasDocument {
                            HStack(spacing: 10) {
                                if let stamp = model.pendingStamp {
                                    Text("Click to place: \(stamp.text)")
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                if let status = model.searchStatus {
                                    Text(status)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Text("Page \(model.currentPageIndex + 1) of \(model.pageCount)")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("No PDF loaded")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()
            }

            if let document = model.document {
                PDFKitView(
                    document: document,
                    currentPageIndex: $model.currentPageIndex,
                    showsThumbnails: model.showsThumbnails,
                    thumbnailPaneWidth: $model.thumbnailPaneWidth,
                    minThumbnailPaneWidth: model.minThumbnailPaneWidth,
                    maxThumbnailPaneWidth: model.maxThumbnailPaneWidth,
                    searchRequest: model.searchRequest,
                    zoomRequest: model.zoomRequest,
                    deleteSelectedStampRequest: model.deleteSelectedStampRequest,
                    pendingStamp: $model.pendingStamp,
                    hasSelectedStamp: $model.hasSelectedStamp,
                    hasUnsavedChanges: $model.hasUnsavedChanges,
                    persistedZoomScaleFactor: $model.persistedZoomScaleFactor,
                    persistedZoomUsesAutoScale: $model.persistedZoomUsesAutoScale,
                    searchStatus: $model.searchStatus
                )
                    .background(Color(nsColor: NSColor.textBackgroundColor))
            } else {
                VStack(spacing: 10) {
                    Text("Hyeon's PDF Viewer")
                        .font(.title2)
                    Text("Use Open PDF to choose a local file.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: NSColor.windowBackgroundColor))
            }
        }
        .background(
            WindowAccessor { window in
                model.attachWindow(window)
            }
        )
        .onChange(of: model.searchFieldFocusRequestID) { _ in
            isSearchFieldFocused = true
        }
        .overlay(alignment: .topTrailing) {
            if model.isFocusMode {
                Button("Exit Focus") {
                    model.toggleFocusMode()
                }
                .padding(12)
            }
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var currentPageIndex: Int
    let showsThumbnails: Bool
    @Binding var thumbnailPaneWidth: CGFloat
    let minThumbnailPaneWidth: CGFloat
    let maxThumbnailPaneWidth: CGFloat
    let searchRequest: SearchRequest?
    let zoomRequest: ZoomRequest?
    let deleteSelectedStampRequest: UUID?
    @Binding var pendingStamp: PendingStamp?
    @Binding var hasSelectedStamp: Bool
    @Binding var hasUnsavedChanges: Bool
    @Binding var persistedZoomScaleFactor: CGFloat
    @Binding var persistedZoomUsesAutoScale: Bool
    @Binding var searchStatus: String?

    enum StampEditAction {
        case moved
        case deleted
    }

    final class InteractivePDFView: PDFView {
        final class StampOverlayView: NSView {
            var previewRectInView: CGRect?
            var previewText = ""
            var selectedRectInView: CGRect?

            override func hitTest(_ point: NSPoint) -> NSView? {
                nil
            }

            override func draw(_ dirtyRect: NSRect) {
                super.draw(dirtyRect)

                if let previewRectInView {
                    drawOverlay(
                        in: previewRectInView,
                        text: previewText,
                        strokeColor: NSColor.systemBlue.withAlphaComponent(0.9),
                        fillColor: NSColor.systemBlue.withAlphaComponent(0.08),
                        textColor: NSColor.systemBlue.withAlphaComponent(0.9),
                        useDashedStroke: true
                    )
                }

                if let selectedRectInView {
                    drawOverlay(
                        in: selectedRectInView,
                        text: nil,
                        strokeColor: NSColor.systemOrange.withAlphaComponent(0.9),
                        fillColor: .clear,
                        textColor: nil,
                        useDashedStroke: false
                    )
                }
            }

            private func drawOverlay(
                in rect: CGRect,
                text: String?,
                strokeColor: NSColor,
                fillColor: NSColor,
                textColor: NSColor?,
                useDashedStroke: Bool
            ) {
                guard rect.width > 0, rect.height > 0 else {
                    return
                }

                let roundedRect = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                fillColor.setFill()
                roundedRect.fill()

                if useDashedStroke {
                    let dash: [CGFloat] = [5, 3]
                    roundedRect.setLineDash(dash, count: dash.count, phase: 0)
                }
                strokeColor.setStroke()
                roundedRect.lineWidth = 1.5
                roundedRect.stroke()

                if let text, let textColor {
                    let textRect = rect.insetBy(dx: StampStyle.horizontalPadding, dy: StampStyle.verticalPadding)
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: StampStyle.font(),
                        .foregroundColor: textColor,
                    ]
                    (text as NSString).draw(in: textRect, withAttributes: attributes)
                }
            }
        }

        var onPageClick: ((PDFPage, CGPoint) -> Bool)?
        var onStampEdited: ((StampEditAction) -> Void)?
        var onStampSelectionChanged: ((Bool) -> Void)?
        var pendingStampText: String? {
            didSet {
                if pendingStampText == nil {
                    previewRectInView = nil
                    previewText = ""
                    stopPreviewRefreshTimer()
                } else {
                    startPreviewRefreshTimer()
                    refreshPreviewAtCurrentMouseLocation()
                }
                refreshOverlay()
            }
        }

        private var cursorTrackingArea: NSTrackingArea?
        private var previewRectInView: CGRect?
        private var previewText = ""
        private weak var selectedStampPage: PDFPage?
        private var selectedStampAnnotation: PDFAnnotation?
        private var isDraggingStamp = false
        private var didMoveSelectedStamp = false
        private var dragOffset = CGPoint.zero
        private var localMouseMonitor: Any?
        private var previewRefreshTimer: Timer?
        private let overlayView = StampOverlayView()

        override var acceptsFirstResponder: Bool {
            true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            ensureOverlayInstalled()
            installMouseMonitorIfNeeded()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                stopPreviewRefreshTimer()
                if let localMouseMonitor {
                    NSEvent.removeMonitor(localMouseMonitor)
                    self.localMouseMonitor = nil
                }
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func layout() {
            super.layout()
            ensureOverlayInstalled()
            overlayView.frame = bounds
            refreshOverlay()
        }

        override func didAddSubview(_ subview: NSView) {
            super.didAddSubview(subview)
            if subview !== overlayView, overlayView.superview === self {
                addSubview(overlayView, positioned: .above, relativeTo: nil)
            }
        }

        override func mouseDown(with event: NSEvent) {
            let pointInView = convert(event.locationInWindow, from: nil)
            if let page = page(for: pointInView, nearest: true) {
                let pagePoint = convert(pointInView, to: page)

                if pendingStampText != nil,
                   onPageClick?(page, pagePoint) == true {
                    previewRectInView = nil
                    previewText = ""
                    clearStampSelection()
                    refreshOverlay()
                    return
                }

                if pendingStampText == nil,
                   let annotation = managedAnnotation(on: page, at: pagePoint) {
                    selectStamp(annotation, on: page)
                    dragOffset = CGPoint(
                        x: pagePoint.x - annotation.bounds.minX,
                        y: pagePoint.y - annotation.bounds.minY
                    )
                    isDraggingStamp = true
                    didMoveSelectedStamp = false
                    window?.makeFirstResponder(self)
                    refreshOverlay()
                    return
                }
            }

            clearStampSelection()
            refreshOverlay()
            super.mouseDown(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard isDraggingStamp,
                  let annotation = selectedStampAnnotation,
                  let page = selectedStampPage else {
                super.mouseDragged(with: event)
                return
            }

            let pointInView = convert(event.locationInWindow, from: nil)
            let pagePoint = convert(pointInView, to: page)
            let pageBounds = page.bounds(for: displayBox)
            let movedBounds = StampStyle.movedBounds(
                for: annotation,
                anchorPoint: pagePoint,
                dragOffset: dragOffset,
                within: pageBounds
            )

            if movedBounds != annotation.bounds {
                annotation.bounds = movedBounds
                didMoveSelectedStamp = true
                refreshOverlay()
            }
        }

        override func mouseUp(with event: NSEvent) {
            if isDraggingStamp {
                isDraggingStamp = false
                if didMoveSelectedStamp {
                    onStampEdited?(.moved)
                }
                didMoveSelectedStamp = false
                return
            }
            super.mouseUp(with: event)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 51 || event.keyCode == 117 {
                if deleteSelectedStamp() {
                    onStampEdited?(.deleted)
                }
                refreshOverlay()
                return
            }
            super.keyDown(with: event)
        }

        @discardableResult
        func deleteSelectedStamp() -> Bool {
            guard let page = selectedStampPage,
                  let annotation = selectedStampAnnotation else {
                return false
            }
            page.removeAnnotation(annotation)
            clearStampSelection()
            refreshOverlay()
            return true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let cursorTrackingArea {
                removeTrackingArea(cursorTrackingArea)
            }

            let trackingArea = NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            cursorTrackingArea = trackingArea
        }

        override func mouseMoved(with event: NSEvent) {
            guard pendingStampText != nil else {
                return
            }
            let pointInView = convert(event.locationInWindow, from: nil)
            updatePreview(at: pointInView)
        }

        override func mouseExited(with event: NSEvent) {
            guard pendingStampText != nil else {
                return
            }
            previewRectInView = nil
            previewText = ""
            refreshOverlay()
        }

        private func refreshPreviewAtCurrentMouseLocation() {
            guard let window, pendingStampText != nil else {
                return
            }
            let pointInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            updatePreview(at: pointInView)
        }

        private func updatePreview(at pointInView: CGPoint) {
            guard let stampText = pendingStampText else {
                previewRectInView = nil
                previewText = ""
                refreshOverlay()
                return
            }

            guard bounds.contains(pointInView) else {
                previewRectInView = nil
                previewText = ""
                refreshOverlay()
                return
            }

            guard let page = page(for: pointInView, nearest: true) else {
                previewRectInView = nil
                previewText = ""
                refreshOverlay()
                return
            }

            let pagePoint = convert(pointInView, to: page)
            let pageBounds = page.bounds(for: displayBox)
            let rectOnPage = StampStyle.bounds(for: stampText, at: pagePoint, within: pageBounds)
            previewRectInView = convert(rectOnPage, from: page)
            previewText = stampText
            refreshOverlay()
        }

        private func installMouseMonitorIfNeeded() {
            guard localMouseMonitor == nil else {
                return
            }

            window?.acceptsMouseMovedEvents = true
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged]
            ) { [weak self] event in
                guard let self,
                      self.pendingStampText != nil,
                      let window = self.window,
                      event.window === window else {
                    return event
                }

                let pointInView = self.convert(event.locationInWindow, from: nil)
                self.updatePreview(at: pointInView)
                return event
            }
        }

        private func startPreviewRefreshTimer() {
            guard previewRefreshTimer == nil else {
                return
            }
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.refreshPreviewAtCurrentMouseLocation()
                }
            }
            previewRefreshTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func stopPreviewRefreshTimer() {
            previewRefreshTimer?.invalidate()
            previewRefreshTimer = nil
        }

        private func managedAnnotation(on page: PDFPage, at point: CGPoint) -> PDFAnnotation? {
            if let annotation = page.annotation(at: point), StampStyle.isManaged(annotation: annotation) {
                return annotation
            }

            for annotation in page.annotations.reversed()
            where StampStyle.isManaged(annotation: annotation) && annotation.bounds.contains(point) {
                return annotation
            }
            return nil
        }

        private func selectedStampRectInView() -> CGRect? {
            guard let page = selectedStampPage,
                  let annotation = selectedStampAnnotation,
                  page.annotations.contains(where: { $0 === annotation }) else {
                return nil
            }
            return convert(annotation.bounds, from: page)
        }

        private func selectStamp(_ annotation: PDFAnnotation, on page: PDFPage) {
            let wasSelected = selectedStampAnnotation != nil
            selectedStampAnnotation = annotation
            selectedStampPage = page
            isDraggingStamp = false
            didMoveSelectedStamp = false
            if !wasSelected {
                onStampSelectionChanged?(true)
            }
        }

        private func clearStampSelection() {
            let hadSelection = selectedStampAnnotation != nil
            selectedStampAnnotation = nil
            selectedStampPage = nil
            isDraggingStamp = false
            didMoveSelectedStamp = false
            if hadSelection {
                onStampSelectionChanged?(false)
            }
        }

        private func ensureOverlayInstalled() {
            if overlayView.superview !== self {
                overlayView.frame = bounds
                overlayView.autoresizingMask = [.width, .height]
                addSubview(overlayView, positioned: .above, relativeTo: nil)
            }
        }

        private func refreshOverlay() {
            ensureOverlayInstalled()
            overlayView.previewRectInView = previewRectInView
            overlayView.previewText = previewText
            overlayView.selectedRectInView = selectedStampRectInView()
            overlayView.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> PDFWorkspaceView {
        let workspace = PDFWorkspaceView(
            minThumbnailWidth: minThumbnailPaneWidth,
            maxThumbnailWidth: maxThumbnailPaneWidth
        )
        workspace.pdfView.autoScales = true
        workspace.pdfView.displayMode = .singlePageContinuous
        workspace.pdfView.displaysPageBreaks = true
        workspace.pdfView.minScaleFactor = 0.25
        workspace.pdfView.maxScaleFactor = 8.0
        workspace.pdfView.document = document
        workspace.pdfView.pendingStampText = pendingStamp?.text
        workspace.thumbnailView.pdfView = workspace.pdfView
        workspace.setThumbnailsVisible(showsThumbnails, preferredWidth: thumbnailPaneWidth)
        let coordinator = context.coordinator
        workspace.onPDFClick = { page, pagePoint in
            coordinator.handlePageClick(on: page, at: pagePoint, pdfView: workspace.pdfView)
        }
        workspace.onStampEdited = { action in
            Task { @MainActor in
                coordinator.handleStampEdited(action)
            }
        }
        workspace.onStampSelectionChanged = { isSelected in
            Task { @MainActor in
                coordinator.handleStampSelectionChanged(isSelected)
            }
        }
        workspace.onThumbnailWidthChanged = { width in
            Task { @MainActor in
                coordinator.handleThumbnailWidthChange(width)
            }
        }

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: Notification.Name.PDFViewPageChanged,
            object: workspace.pdfView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scaleChanged),
            name: Notification.Name.PDFViewScaleChanged,
            object: workspace.pdfView
        )

        return workspace
    }

    func updateNSView(_ nsView: PDFWorkspaceView, context: Context) {
        context.coordinator.parent = self

        if nsView.pdfView.document !== document {
            nsView.pdfView.document = document
            nsView.thumbnailView.pdfView = nsView.pdfView
            context.coordinator.resetSearchState()
        }
        nsView.pdfView.pendingStampText = pendingStamp?.text

        nsView.setThumbnailsVisible(showsThumbnails, preferredWidth: thumbnailPaneWidth)

        if let page = document.page(at: currentPageIndex),
           nsView.pdfView.currentPage != page {
            nsView.pdfView.go(to: page)
        }

        context.coordinator.applyPersistedZoomIfNeeded(in: nsView.pdfView)

        if let request = searchRequest,
           context.coordinator.lastHandledSearchID != request.id {
            context.coordinator.lastHandledSearchID = request.id
            context.coordinator.performSearch(request, in: nsView.pdfView, document: document)
        }

        if let zoom = zoomRequest,
           context.coordinator.lastHandledZoomID != zoom.id {
            context.coordinator.lastHandledZoomID = zoom.id
            context.coordinator.performZoom(zoom, in: nsView.pdfView, document: document)
        }

        if let deleteRequest = deleteSelectedStampRequest,
           context.coordinator.lastHandledDeleteStampID != deleteRequest {
            context.coordinator.lastHandledDeleteStampID = deleteRequest
            context.coordinator.deleteSelectedStamp(in: nsView.pdfView)
        }
    }

    static func dismantleNSView(_ nsView: PDFWorkspaceView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(
            coordinator,
            name: Notification.Name.PDFViewPageChanged,
            object: nsView.pdfView
        )
        NotificationCenter.default.removeObserver(
            coordinator,
            name: Notification.Name.PDFViewScaleChanged,
            object: nsView.pdfView
        )
    }

    final class PDFWorkspaceView: NSView {
        let pdfView = InteractivePDFView()
        let thumbnailView = PDFThumbnailView()
        let sidebarContainer = NSView()
        var onThumbnailWidthChanged: ((CGFloat) -> Void)?
        var onPDFClick: ((PDFPage, CGPoint) -> Bool)?
        var onStampEdited: ((StampEditAction) -> Void)?
        var onStampSelectionChanged: ((Bool) -> Void)?
        private let minThumbnailWidth: CGFloat
        private let maxThumbnailWidth: CGFloat
        private let dividerView = NSView()
        private var sidebarWidthConstraint: NSLayoutConstraint!
        private var dividerWidthConstraint: NSLayoutConstraint!
        private var isApplyingProgrammaticWidth = false
        private var panStartSidebarWidth: CGFloat = 0
        private var isSidebarVisible = false

        init(minThumbnailWidth: CGFloat, maxThumbnailWidth: CGFloat) {
            self.minThumbnailWidth = minThumbnailWidth
            self.maxThumbnailWidth = maxThumbnailWidth
            super.init(frame: .zero)
            setupView()
        }

        private func setupView() {
            translatesAutoresizingMaskIntoConstraints = false

            sidebarContainer.translatesAutoresizingMaskIntoConstraints = false
            dividerView.translatesAutoresizingMaskIntoConstraints = false
            pdfView.translatesAutoresizingMaskIntoConstraints = false
            thumbnailView.translatesAutoresizingMaskIntoConstraints = false

            dividerView.wantsLayer = true
            dividerView.layer?.backgroundColor = NSColor.separatorColor.cgColor
            pdfView.onPageClick = { [weak self] page, point in
                self?.onPDFClick?(page, point) ?? false
            }
            pdfView.onStampEdited = { [weak self] action in
                self?.onStampEdited?(action)
            }
            pdfView.onStampSelectionChanged = { [weak self] isSelected in
                self?.onStampSelectionChanged?(isSelected)
            }

            sidebarContainer.addSubview(thumbnailView)
            addSubview(sidebarContainer)
            addSubview(dividerView)
            addSubview(pdfView)

            sidebarWidthConstraint = sidebarContainer.widthAnchor.constraint(equalToConstant: 0)
            dividerWidthConstraint = dividerView.widthAnchor.constraint(equalToConstant: 0)

            NSLayoutConstraint.activate([
                sidebarContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
                sidebarContainer.topAnchor.constraint(equalTo: topAnchor),
                sidebarContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
                sidebarWidthConstraint,

                dividerView.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
                dividerView.topAnchor.constraint(equalTo: topAnchor),
                dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
                dividerWidthConstraint,

                pdfView.leadingAnchor.constraint(equalTo: dividerView.trailingAnchor),
                pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
                pdfView.topAnchor.constraint(equalTo: topAnchor),
                pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),

                thumbnailView.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor, constant: 8),
                thumbnailView.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: -8),
                thumbnailView.topAnchor.constraint(equalTo: sidebarContainer.topAnchor, constant: 8),
                thumbnailView.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor, constant: -8),
            ])

            let pan = NSPanGestureRecognizer(target: self, action: #selector(handleDividerPan(_:)))
            dividerView.addGestureRecognizer(pan)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(dividerView.frame, cursor: .resizeLeftRight)
        }

        func setThumbnailsVisible(_ isVisible: Bool, preferredWidth: CGFloat) {
            if isVisible {
                if !isSidebarVisible {
                    isSidebarVisible = true
                    sidebarContainer.isHidden = false
                    dividerView.isHidden = false
                    dividerWidthConstraint.constant = 6
                    needsLayout = true
                }

                let normalizedWidth = clampedThumbnailWidth(preferredWidth)
                if bounds.width > 0 {
                    setThumbnailWidth(normalizedWidth)
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.setThumbnailWidth(normalizedWidth)
                    }
                }
            } else {
                isSidebarVisible = false
                sidebarContainer.isHidden = true
                dividerView.isHidden = true
                dividerWidthConstraint.constant = 0
                sidebarWidthConstraint.constant = 0
                needsLayout = true
            }
        }

        func setThumbnailWidth(_ width: CGFloat) {
            guard isSidebarVisible else {
                return
            }

            let clampedWidth = clampedThumbnailWidth(width)
            let appliedWidth = clampedSplitPosition(clampedWidth)

            isApplyingProgrammaticWidth = true
            sidebarWidthConstraint.constant = appliedWidth
            updateThumbnailSize(forSidebarWidth: appliedWidth)
            layoutSubtreeIfNeeded()
            isApplyingProgrammaticWidth = false
        }

        private func clampedThumbnailWidth(_ width: CGFloat) -> CGFloat {
            min(max(width, minThumbnailWidth), maxThumbnailWidth)
        }

        private func clampedSplitPosition(_ proposed: CGFloat) -> CGFloat {
            guard bounds.width > 0 else {
                return clampedThumbnailWidth(proposed)
            }
            let dividerWidth = dividerWidthConstraint.constant
            let available = bounds.width - dividerWidth - 240
            let maxAllowed: CGFloat
            if available > minThumbnailWidth {
                maxAllowed = min(maxThumbnailWidth, available)
            } else {
                maxAllowed = maxThumbnailWidth
            }
            return min(max(proposed, minThumbnailWidth), maxAllowed)
        }

        @objc private func handleDividerPan(_ recognizer: NSPanGestureRecognizer) {
            guard isSidebarVisible else {
                return
            }

            switch recognizer.state {
            case .began:
                panStartSidebarWidth = sidebarWidthConstraint.constant
            case .changed:
                let translation = recognizer.translation(in: self)
                let proposedWidth = panStartSidebarWidth + translation.x
                let clampedWidth = clampedSplitPosition(proposedWidth)
                sidebarWidthConstraint.constant = clampedWidth
                updateThumbnailSize(forSidebarWidth: clampedWidth)
                needsLayout = true
                if !isApplyingProgrammaticWidth {
                    onThumbnailWidthChanged?(clampedWidth)
                }
            default:
                break
            }
        }

        private func updateThumbnailSize(forSidebarWidth width: CGFloat) {
            let horizontalPadding: CGFloat = 16
            let targetWidth = max(64, width - horizontalPadding)
            let aspectRatio = currentDocumentPageAspectRatio()
            let targetHeight = max(84, targetWidth * aspectRatio)
            thumbnailView.thumbnailSize = NSSize(width: targetWidth, height: targetHeight)
        }

        private func currentDocumentPageAspectRatio() -> CGFloat {
            guard let page = pdfView.document?.page(at: 0) else {
                return 1.35
            }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0 else {
                return 1.35
            }
            return max(0.6, min(2.2, bounds.height / bounds.width))
        }

    }
}

extension PDFKitView {
    @MainActor
    final class Coordinator: NSObject {
        var parent: PDFKitView
        var lastQuery = ""
        var lastSelection: PDFSelection?
        var lastHandledSearchID: UUID?
        var lastHandledZoomID: UUID?
        var lastHandledDeleteStampID: UUID?
        var hasAppliedInitialZoom = false

        init(_ parent: PDFKitView) {
            self.parent = parent
        }

        func handleThumbnailWidthChange(_ width: CGFloat) {
            let clamped = min(max(width, parent.minThumbnailPaneWidth), parent.maxThumbnailPaneWidth)
            if abs(parent.thumbnailPaneWidth - clamped) > 0.5 {
                parent.thumbnailPaneWidth = clamped
            }
        }

        func handleStampEdited(_ action: StampEditAction) {
            parent.hasUnsavedChanges = true
            switch action {
            case .moved:
                parent.searchStatus = "Stamp moved. Press Delete to remove selected stamp."
            case .deleted:
                parent.searchStatus = "Stamp deleted."
                parent.hasSelectedStamp = false
            }
        }

        func handleStampSelectionChanged(_ isSelected: Bool) {
            parent.hasSelectedStamp = isSelected
            if isSelected {
                parent.searchStatus = "Stamp selected. Drag to move or click Delete Stamp."
            }
        }

        func deleteSelectedStamp(in pdfView: InteractivePDFView) {
            if pdfView.deleteSelectedStamp() {
                parent.hasSelectedStamp = false
                parent.hasUnsavedChanges = true
                parent.searchStatus = "Stamp deleted."
            } else {
                parent.searchStatus = "Select a stamp first."
            }
        }

        func handlePageClick(on page: PDFPage, at point: CGPoint, pdfView: PDFView) -> Bool {
            guard let pendingStamp = parent.pendingStamp else {
                return false
            }

            addStampAnnotation(text: pendingStamp.text, on: page, at: point, pdfView: pdfView)
            parent.pendingStamp = nil
            parent.hasSelectedStamp = false
            parent.hasUnsavedChanges = true
            parent.searchStatus = "Stamp added. Drag to move, press Delete to remove."
            return true
        }

        func resetSearchState() {
            lastQuery = ""
            lastSelection = nil
            lastHandledSearchID = nil
            lastHandledZoomID = nil
            lastHandledDeleteStampID = nil
            parent.hasSelectedStamp = false
            hasAppliedInitialZoom = false
        }

        func applyPersistedZoomIfNeeded(in pdfView: PDFView) {
            guard !hasAppliedInitialZoom else {
                return
            }

            if parent.persistedZoomUsesAutoScale {
                pdfView.autoScales = true
            } else {
                pdfView.autoScales = false
                let clamped = min(
                    max(parent.persistedZoomScaleFactor, pdfView.minScaleFactor),
                    pdfView.maxScaleFactor
                )
                pdfView.scaleFactor = clamped
            }

            hasAppliedInitialZoom = true
        }

        func performSearch(_ request: SearchRequest, in pdfView: PDFView, document: PDFDocument) {
            if request.query != lastQuery {
                lastQuery = request.query
                lastSelection = nil
            }

            let options = compareOptions(for: request.direction)
            if let selection = document.findString(request.query, fromSelection: lastSelection, withOptions: options) {
                applySelection(selection, in: pdfView)
                searchStatus(for: request, didWrap: false)
                return
            }

            if let wrappedSelection = document.findString(request.query, fromSelection: nil, withOptions: options) {
                applySelection(wrappedSelection, in: pdfView)
                searchStatus(for: request, didWrap: true)
                return
            }

            parent.searchStatus = "No matches for \"\(request.query)\"."
        }

        func performZoom(_ request: ZoomRequest, in pdfView: PDFView, document: PDFDocument) {
            switch request.action {
            case .inStep:
                pdfView.autoScales = false
                pdfView.zoomIn(nil)
            case .outStep:
                pdfView.autoScales = false
                pdfView.zoomOut(nil)
            case .actualSize:
                pdfView.autoScales = false
                pdfView.scaleFactor = min(max(1.0, pdfView.minScaleFactor), pdfView.maxScaleFactor)
            case .fitWidth:
                fitToWidth(pdfView, document: document)
            case .fitPage:
                fitToPage(pdfView, document: document)
            }

            persistZoomState(from: pdfView)
        }

        private func fitToWidth(_ pdfView: PDFView, document: PDFDocument) {
            guard let page = pdfView.currentPage ?? document.page(at: parent.currentPageIndex) else {
                return
            }

            let pageBounds = page.bounds(for: pdfView.displayBox)
            let horizontalPadding: CGFloat = 24
            let availableWidth = max(pdfView.bounds.width - horizontalPadding, 1)
            let targetScale = availableWidth / pageBounds.width
            let clampedScale = min(max(targetScale, pdfView.minScaleFactor), pdfView.maxScaleFactor)

            pdfView.autoScales = false
            pdfView.scaleFactor = clampedScale
        }

        private func fitToPage(_ pdfView: PDFView, document: PDFDocument) {
            guard let page = pdfView.currentPage ?? document.page(at: parent.currentPageIndex) else {
                return
            }

            let pageBounds = page.bounds(for: pdfView.displayBox)
            let horizontalPadding: CGFloat = 24
            let verticalPadding: CGFloat = 24
            let availableWidth = max(pdfView.bounds.width - horizontalPadding, 1)
            let availableHeight = max(pdfView.bounds.height - verticalPadding, 1)

            let widthScale = availableWidth / pageBounds.width
            let heightScale = availableHeight / pageBounds.height
            let targetScale = min(widthScale, heightScale)
            let clampedScale = min(max(targetScale, pdfView.minScaleFactor), pdfView.maxScaleFactor)

            pdfView.autoScales = false
            pdfView.scaleFactor = clampedScale
        }

        private func persistZoomState(from pdfView: PDFView) {
            parent.persistedZoomUsesAutoScale = pdfView.autoScales
            parent.persistedZoomScaleFactor = pdfView.scaleFactor
        }

        private func addStampAnnotation(text: String, on page: PDFPage, at point: CGPoint, pdfView: PDFView) {
            let pageBounds = page.bounds(for: pdfView.displayBox)
            let bounds = StampStyle.bounds(for: text, at: point, within: pageBounds)
            let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            annotation.font = StampStyle.font()
            annotation.fontColor = .black
            annotation.color = .clear
            annotation.alignment = .left
            annotation.contents = text
            annotation.isReadOnly = true
            annotation.shouldPrint = true
            annotation.setValue(StampStyle.subject, forAnnotationKey: StampStyle.markerKey)
            page.addAnnotation(annotation)
        }

        private func compareOptions(for direction: SearchDirection) -> NSString.CompareOptions {
            switch direction {
            case .forward:
                return [.caseInsensitive]
            case .backward:
                return [.caseInsensitive, .backwards]
            }
        }

        private func applySelection(_ selection: PDFSelection, in pdfView: PDFView) {
            lastSelection = selection
            pdfView.setCurrentSelection(selection, animate: true)
            pdfView.highlightedSelections = [selection]
            pdfView.go(to: selection)
        }

        private func searchStatus(for request: SearchRequest, didWrap: Bool) {
            if didWrap {
                switch request.direction {
                case .forward:
                    parent.searchStatus = "Wrapped to start."
                case .backward:
                    parent.searchStatus = "Wrapped to end."
                }
            } else {
                parent.searchStatus = "Match found."
            }
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let page = pdfView.currentPage,
                  let pdfDocument = pdfView.document else {
                return
            }

            let newIndex = pdfDocument.index(for: page)
            if parent.currentPageIndex != newIndex {
                parent.currentPageIndex = newIndex
            }
        }

        @objc func scaleChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView else {
                return
            }
            persistZoomState(from: pdfView)
        }
    }
}
