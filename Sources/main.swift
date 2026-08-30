import AppKit

final class DiskNode {
    let url: URL?
    let name: String
    let isDirectory: Bool
    let isFreeSpace: Bool
    var size: Int64
    var children: [DiskNode] = []
    weak var parent: DiskNode?

    init(url: URL?, name: String, size: Int64 = 0, isDirectory: Bool, isFreeSpace: Bool = false) {
        self.url = url
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.isFreeSpace = isFreeSpace
    }
}

struct ScanResult {
    let root: DiskNode
    let itemCount: Int
    let skippedCount: Int
    let volumeTotal: Int64
    let volumeFree: Int64
    let isVolumeRoot: Bool
}

final class DiskScanner {
    private let manager = FileManager.default
    private var itemCount = 0
    private var skippedCount = 0
    private var volumeURL: URL?
    private let progress: (Int, Int64) -> Void

    init(progress: @escaping (Int, Int64) -> Void) {
        self.progress = progress
    }

    func scan(_ requestedURL: URL) -> ScanResult {
        let url = requestedURL.standardizedFileURL
        let volumeValues = try? url.resourceValues(forKeys: [
            .volumeURLKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey
        ])
        volumeURL = (volumeValues?.allValues[.volumeURLKey] as? URL)?.standardizedFileURL
        let root = visit(url) ?? DiskNode(url: url, name: url.lastPathComponent, isDirectory: true)
        let total = Int64(volumeValues?.volumeTotalCapacity ?? 0)
        let free = Int64(volumeValues?.volumeAvailableCapacity ?? 0)
        let isRoot = volumeURL?.path == url.path
        return ScanResult(root: root, itemCount: itemCount, skippedCount: skippedCount,
                          volumeTotal: total, volumeFree: free, isVolumeRoot: isRoot)
    }

    private func visit(_ url: URL) -> DiskNode? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .volumeURLKey
        ]
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
        } catch {
            skippedCount += 1
            return nil
        }

        if values.isSymbolicLink == true { return nil }
        if let itemVolume = (values.allValues[.volumeURLKey] as? URL)?.standardizedFileURL,
           let volumeURL, itemVolume.path != volumeURL.path { return nil }

        itemCount += 1
        let isDirectory = values.isDirectory == true
        let displayName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        let node = DiskNode(url: url, name: displayName, isDirectory: isDirectory)

        if !isDirectory {
            node.size = Int64(values.totalFileAllocatedSize
                              ?? values.fileAllocatedSize
                              ?? values.fileSize
                              ?? 0)
            if itemCount.isMultiple(of: 2_000) { progress(itemCount, node.size) }
            return node
        }

        let urls: [URL]
        do {
            urls = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
        } catch {
            skippedCount += 1
            return node
        }

        var total: Int64 = 0
        for childURL in urls {
            if let child = visit(childURL) {
                child.parent = node
                node.children.append(child)
                total += child.size
            }
        }
        node.children.sort { $0.size > $1.size }
        node.size = total
        if itemCount.isMultiple(of: 2_000) { progress(itemCount, total) }
        return node
    }
}

private let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    return formatter
}()

private func sizeText(_ bytes: Int64) -> String {
    byteFormatter.string(fromByteCount: bytes)
}

private struct HitRegion {
    let node: DiskNode
    let rect: NSRect
}

final class TreemapView: NSView, NSViewToolTipOwner {
    var root: DiskNode? { didSet { focus = root; selection = nil; needsDisplay = true } }
    var focus: DiskNode? { didSet { selection = nil; needsDisplay = true } }
    var selection: DiskNode? { didSet { needsDisplay = true; selectionChanged?(selection) } }
    var freeSpace: Int64 = 0
    var showsFreeSpace = true { didSet { needsDisplay = true } }
    var selectionChanged: ((DiskNode?) -> Void)?
    var activated: ((DiskNode) -> Void)?
    var zoomOutRequested: (() -> Void)?
    var zoomFullRequested: (() -> Void)?
    var showHelpRequested: (() -> Void)?
    private var hitRegions: [HitRegion] = []
    private var toolTipRegions: [HitRegion] = []
    private var toolTipNodes: [NSView.ToolTipTag: DiskNode] = [:]
    private let freeSpaceNode = DiskNode(url: nil, name: "Free Space",
                                         isDirectory: false, isFreeSpace: true)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let node = toolTipNodes[tag] else { return "" }
        return "\(node.name)\n\(sizeText(node.size))"
    }

    private func installToolTips() {
        removeAllToolTips()
        toolTipNodes.removeAll(keepingCapacity: true)
        for region in toolTipRegions {
            let tag = addToolTip(region.rect, owner: self, userData: nil)
            toolTipNodes[tag] = region.node
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.76, alpha: 1).setFill()
        bounds.fill()
        hitRegions.removeAll(keepingCapacity: true)
        toolTipRegions.removeAll(keepingCapacity: true)

        guard let focus else {
            removeAllToolTips()
            toolTipNodes.removeAll(keepingCapacity: true)
            drawWelcome()
            return
        }

        var nodes = focus.children.filter { $0.size > 0 }
        if focus === root, showsFreeSpace, freeSpace > 0 {
            freeSpaceNode.size = freeSpace
            nodes.append(freeSpaceNode)
        }
        nodes.sort { $0.size > $1.size }
        let mapRect = bounds.insetBy(dx: 4, dy: 4)
        drawNodes(Array(nodes.prefix(320)), range: 0..<min(nodes.count, 320), in: mapRect, depth: 0)
        installToolTips()

        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focusRing = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            focusRing.lineWidth = 2
            focusRing.stroke()
        }
    }

    private func drawWelcome() {
        let heading = "Choose a folder or volume"
        let detail = "Each rectangle will show how much disk space an item uses."
        let centerY = bounds.midY - 12
        let headingAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        drawCentered(heading, y: centerY, attributes: headingAttributes)
        drawCentered(detail, y: centerY + 32, attributes: detailAttributes)
    }

    private func drawCentered(_ text: String, y: CGFloat,
                              attributes: [NSAttributedString.Key: Any]) {
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: y), withAttributes: attributes)
    }

    private func drawNodes(_ nodes: [DiskNode], range: Range<Int>, in rect: NSRect, depth: Int) {
        guard !range.isEmpty, rect.width >= 2, rect.height >= 2 else { return }
        if range.count == 1 {
            drawNode(nodes[range.lowerBound], in: rect, depth: depth)
            return
        }

        let total = range.reduce(Int64(0)) { $0 + max(1, nodes[$1].size) }
        let half = total / 2
        var firstTotal: Int64 = 0
        var split = range.lowerBound + 1
        for index in range.dropLast() {
            firstTotal += max(1, nodes[index].size)
            split = index + 1
            if firstTotal >= half { break }
        }
        let fraction = CGFloat(firstTotal) / CGFloat(max(1, total))

        if rect.width >= rect.height {
            let firstWidth = max(1, rect.width * fraction)
            let firstRect = NSRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
            let secondRect = NSRect(x: rect.minX + firstWidth, y: rect.minY,
                                    width: rect.width - firstWidth, height: rect.height)
            drawNodes(nodes, range: range.lowerBound..<split, in: firstRect, depth: depth)
            drawNodes(nodes, range: split..<range.upperBound, in: secondRect, depth: depth)
        } else {
            let firstHeight = max(1, rect.height * fraction)
            let firstRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight)
            let secondRect = NSRect(x: rect.minX, y: rect.minY + firstHeight,
                                    width: rect.width, height: rect.height - firstHeight)
            drawNodes(nodes, range: range.lowerBound..<split, in: firstRect, depth: depth)
            drawNodes(nodes, range: split..<range.upperBound, in: secondRect, depth: depth)
        }
    }

    private func drawNode(_ node: DiskNode, in outerRect: NSRect, depth: Int) {
        let rect = outerRect.insetBy(dx: 1, dy: 1)
        guard rect.width >= 1, rect.height >= 1 else { return }
        hitRegions.append(HitRegion(node: node, rect: rect))

        let visibleChildren = node.isDirectory
            ? Array(node.children.filter { $0.size > 0 }.prefix(180))
            : []
        let drawsChildren = depth < 5 && rect.width > 42 && rect.height > 38
            && !visibleChildren.isEmpty
        let titleHeight = min(18, rect.height)
        let toolTipRect = drawsChildren
            ? NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: titleHeight)
            : rect
        toolTipRegions.append(HitRegion(node: node, rect: toolTipRect))

        color(for: node, depth: depth).setFill()
        rect.fill()
        NSColor(calibratedWhite: 0.16, alpha: 0.72).setStroke()
        NSBezierPath(rect: rect).stroke()

        if selection === node {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 2, dy: 2))
            path.lineWidth = 3
            path.stroke()
        }

        guard rect.width > 28, rect.height > 15 else { return }
        let titleRect = NSRect(x: rect.minX + 3, y: rect.minY + 1,
                               width: rect.width - 6, height: titleHeight)
        let label = rect.width > 95 ? "\(node.name)  \(sizeText(node.size))" : node.name
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        label.draw(in: titleRect, withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: node.isDirectory ? .medium : .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.08, alpha: 1),
            .paragraphStyle: paragraph
        ])

        guard drawsChildren else { return }
        let content = NSRect(x: rect.minX + 2, y: rect.minY + titleHeight,
                             width: rect.width - 4, height: rect.height - titleHeight - 2)
        drawNodes(visibleChildren, range: 0..<visibleChildren.count, in: content, depth: depth + 1)
    }

    private func color(for node: DiskNode, depth: Int) -> NSColor {
        if node.isFreeSpace { return NSColor(calibratedWhite: 0.73, alpha: 1) }
        let palette = [
            NSColor(calibratedRed: 1.00, green: 0.66, blue: 0.58, alpha: 1),
            NSColor(calibratedRed: 1.00, green: 0.86, blue: 0.24, alpha: 1),
            NSColor(calibratedRed: 0.55, green: 0.92, blue: 0.48, alpha: 1),
            NSColor(calibratedRed: 0.38, green: 0.88, blue: 0.86, alpha: 1),
            NSColor(calibratedRed: 1.00, green: 0.73, blue: 0.48, alpha: 1)
        ]
        return palette[depth % palette.count]
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let node = hitRegions.reversed().first(where: { $0.rect.contains(point) })?.node else {
            selection = nil
            return
        }
        selection = node
        if event.clickCount == 2 { activated?(node) }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let controlOnly = flags.contains(.control)
            && !flags.contains(.command) && !flags.contains(.option)

        if !flags.contains(.command) && !flags.contains(.control)
            && !flags.contains(.option) && event.characters == "?" {
            showHelpRequested?()
            return
        }

        if controlOnly && event.keyCode == 34 { // Ctrl-I
            if let selection, selection.isDirectory { activated?(selection) }
            return
        }
        if controlOnly && event.keyCode == 31 { // Ctrl-O
            zoomOutRequested?()
            return
        }

        switch event.keyCode {
        case 36, 76: // Return and keypad Enter
            if let selection, selection.isDirectory { activated?(selection) }
        case 51: // Backspace
            zoomOutRequested?()
        case 53: // Escape
            zoomFullRequested?()
        case 123:
            moveSelection(dx: -1, dy: 0)
        case 124:
            moveSelection(dx: 1, dy: 0)
        case 125:
            moveSelection(dx: 0, dy: 1)
        case 126:
            moveSelection(dx: 0, dy: -1)
        default:
            let plainKey = !flags.contains(.command) && !flags.contains(.control)
                && !flags.contains(.option)
            guard plainKey, let key = event.charactersIgnoringModifiers?.lowercased() else {
                super.keyDown(with: event)
                return
            }
            switch key {
            case "h": moveSelection(dx: -1, dy: 0)
            case "l": moveSelection(dx: 1, dy: 0)
            case "j": moveSelection(dx: 0, dy: 1)
            case "k": moveSelection(dx: 0, dy: -1)
            default: super.keyDown(with: event)
            }
        }
    }

    private func moveSelection(dx: CGFloat, dy: CGFloat) {
        guard !toolTipRegions.isEmpty else { return }
        guard let selected = selection,
              let current = toolTipRegions.first(where: { $0.node === selected }) else {
            selection = toolTipRegions.first?.node
            return
        }

        let origin = NSPoint(x: current.rect.midX, y: current.rect.midY)
        var best: (node: DiskNode, score: CGFloat)?
        for candidate in toolTipRegions where candidate.node !== selected {
            let deltaX = candidate.rect.midX - origin.x
            let deltaY = candidate.rect.midY - origin.y
            let forward = deltaX * dx + deltaY * dy
            guard forward > 0.5 else { continue }
            let sideways = abs(deltaX * dy - deltaY * dx)
            let score = forward + sideways * 2.5
            if best == nil || score < best!.score {
                best = (candidate.node, score)
            }
        }
        if let best { selection = best.node }
    }
}

final class ShortcutPanel: NSVisualEffectView {
    var dismissed: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        let title = NSTextField(labelWithString: "Keyboard Shortcuts")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center

        let shortcuts = [
            ("Move selection", "↑ ↓ ← →    H J K L"),
            ("Enter folder", "Return    ⌃I"),
            ("Move up one level", "Backspace    ⌃O"),
            ("Return to full map", "Escape"),
            ("Open folder or volume", "⌘O"),
            ("Reload", "⌘R"),
            ("Show this panel", "?"),
            ("Quit", "⌘Q")
        ]
        let rows: [[NSView]] = shortcuts.map { description, keys in
            let descriptionLabel = NSTextField(labelWithString: description)
            descriptionLabel.font = .systemFont(ofSize: 12)
            let keyLabel = NSTextField(labelWithString: keys)
            keyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            keyLabel.alignment = .right
            return [descriptionLabel, keyLabel]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 7
        grid.columnSpacing = 28
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing

        let hint = NSTextField(labelWithString: "Press any key or click to close")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center

        let stack = NSStackView(views: [title, grid, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        setAccessibilityLabel("Keyboard Shortcuts")
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func keyDown(with event: NSEvent) { dismissed?() }
    override func mouseDown(with event: NSEvent) { dismissed?() }
    override func rightMouseDown(with event: NSEvent) { dismissed?() }
    override func otherMouseDown(with event: NSEvent) { dismissed?() }
}

final class MainViewController: NSViewController {
    private let treemap = TreemapView()
    private let shortcutPanel = ShortcutPanel()
    private let statusLabel = NSTextField(labelWithString: "Choose a folder or volume to begin")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var rootURL: URL?
    private var result: ScanResult?
    private var scanNumber = 0
    private var buttons: [NSButton] = []
    private var freeButton: NSButton!
    private var shortcutMouseMonitor: Any?

    deinit {
        if let shortcutMouseMonitor { NSEvent.removeMonitor(shortcutMouseMonitor) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if shortcutPanel.isHidden { view.window?.makeFirstResponder(treemap) }
    }

    override func loadView() {
        let container = NSView()
        let bar = NSVisualEffectView()
        bar.material = .headerView
        bar.blendingMode = .withinWindow
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 6
        controls.alignment = .centerY

        let open = button("Open", symbol: "folder", action: #selector(chooseFolder))
        let reload = button("Reload", symbol: "arrow.clockwise", action: #selector(reloadScan))
        let full = button("Zoom Full", symbol: "arrow.up.left.and.arrow.down.right", action: #selector(zoomFull))
        let zoomIn = button("Zoom In", symbol: "plus.magnifyingglass", action: #selector(zoomIn))
        let zoomOut = button("Zoom Out", symbol: "minus.magnifyingglass", action: #selector(zoomOut))
        let reveal = button("Reveal", symbol: "finder", action: #selector(revealSelection))
        freeButton = button("Free Space", symbol: "square.dashed", action: #selector(toggleFreeSpace))
        open.toolTip = "Choose a folder or volume (Command-O)"
        reload.toolTip = "Scan the current location again (Command-R)"
        full.toolTip = "Return to the full map (Escape)"
        zoomIn.toolTip = "Enter the selected folder (Return or Control-I)"
        zoomOut.toolTip = "Move up one level (Backspace or Control-O)"
        reveal.toolTip = "Show the selected item in Finder"
        freeButton.setButtonType(.toggle)
        freeButton.state = .on
        buttons = [reload, full, zoomIn, zoomOut, reveal, freeButton]
        [open, reload, full, zoomIn, zoomOut, freeButton, reveal].forEach(controls.addArrangedSubview)

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        controls.addArrangedSubview(progress)

        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 12)
        controls.addArrangedSubview(statusLabel)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSVisualEffectView()
        footer.material = .headerView
        footer.blendingMode = .withinWindow
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        [bar, controls, treemap, footer, detailLabel, shortcutPanel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        container.addSubview(bar)
        bar.addSubview(controls)
        container.addSubview(treemap)
        container.addSubview(footer)
        footer.addSubview(detailLabel)
        shortcutPanel.isHidden = true
        container.addSubview(shortcutPanel)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 48),
            controls.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            controls.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            treemap.topAnchor.constraint(equalTo: bar.bottomAnchor),
            treemap.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            treemap.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            treemap.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 25),
            detailLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -8),
            detailLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            shortcutPanel.centerXAnchor.constraint(equalTo: treemap.centerXAnchor),
            shortcutPanel.centerYAnchor.constraint(equalTo: treemap.centerYAnchor),
            shortcutPanel.widthAnchor.constraint(equalToConstant: 410),
            shortcutPanel.heightAnchor.constraint(equalToConstant: 286)
        ])

        treemap.selectionChanged = { [weak self] node in self?.selectionChanged(node) }
        treemap.activated = { [weak self] node in self?.activate(node) }
        treemap.zoomOutRequested = { [weak self] in self?.zoomOut() }
        treemap.zoomFullRequested = { [weak self] in self?.zoomFull() }
        treemap.showHelpRequested = { [weak self] in self?.showShortcuts() }
        shortcutPanel.dismissed = { [weak self] in self?.hideShortcuts() }
        self.view = container
        updateButtons()
    }

    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        let button = NSButton(title: title, image: image ?? NSImage(), target: self, action: action)
        button.imagePosition = .imageLeading
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        return button
    }

    @objc func showShortcuts() {
        if !shortcutPanel.isHidden {
            hideShortcuts()
            return
        }
        shortcutPanel.isHidden = false
        view.window?.makeFirstResponder(shortcutPanel)
        shortcutMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, !self.shortcutPanel.isHidden,
                  event.window === self.view.window else { return event }
            let point = self.view.convert(event.locationInWindow, from: nil)
            let clickedPanel = self.shortcutPanel.frame.contains(point)
            self.hideShortcuts()
            return clickedPanel ? nil : event
        }
    }

    private func hideShortcuts() {
        guard !shortcutPanel.isHidden else { return }
        shortcutPanel.isHidden = true
        if let shortcutMouseMonitor {
            NSEvent.removeMonitor(shortcutMouseMonitor)
            self.shortcutMouseMonitor = nil
        }
        view.window?.makeFirstResponder(treemap)
    }

    @objc func chooseFolder() {
        hideShortcuts()
        let panel = NSOpenPanel()
        panel.title = "Choose a folder or volume to map"
        panel.prompt = "Map"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL ?? URL(fileURLWithPath: NSHomeDirectory())
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.startScan(url) }
        }
    }

    @objc func reloadScan() {
        hideShortcuts()
        if let rootURL { startScan(rootURL) }
    }

    @objc func zoomFull() {
        hideShortcuts()
        treemap.focus = treemap.root
        updateTitle()
        updateButtons()
    }

    @objc func zoomIn() {
        hideShortcuts()
        if let selected = treemap.selection, selected.isDirectory { treemap.focus = selected }
        updateTitle()
        updateButtons()
    }

    @objc func zoomOut() {
        hideShortcuts()
        if let previous = treemap.focus, let parent = previous.parent {
            treemap.focus = parent
            treemap.selection = previous
        }
        updateTitle()
        updateButtons()
    }

    @objc func toggleFreeSpace() {
        hideShortcuts()
        treemap.showsFreeSpace = freeButton.state == .on
    }

    @objc func revealSelection() {
        hideShortcuts()
        if let url = treemap.selection?.url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func startScan(_ url: URL) {
        rootURL = url.standardizedFileURL
        scanNumber += 1
        let thisScan = scanNumber
        statusLabel.stringValue = "Scanning \(url.path)…"
        detailLabel.stringValue = "Reading file sizes"
        progress.startAnimation(nil)
        buttons.forEach { $0.isEnabled = false }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scanner = DiskScanner { count, _ in
                DispatchQueue.main.async { [weak self] in
                    guard self?.scanNumber == thisScan else { return }
                    self?.detailLabel.stringValue = "Scanning… \(count.formatted()) items"
                }
            }
            let scanResult = scanner.scan(url)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanNumber == thisScan else { return }
                self.result = scanResult
                self.treemap.freeSpace = scanResult.isVolumeRoot ? scanResult.volumeFree : 0
                self.treemap.root = scanResult.root
                self.progress.stopAnimation(nil)
                self.view.window?.makeFirstResponder(self.treemap)
                self.updateTitle()
                self.updateButtons()
                let skipped = scanResult.skippedCount == 0 ? "" : " · \(scanResult.skippedCount.formatted()) inaccessible"
                self.detailLabel.stringValue = "\(scanResult.itemCount.formatted()) items · \(sizeText(scanResult.root.size)) scanned\(skipped)"
            }
        }
    }

    private func selectionChanged(_ node: DiskNode?) {
        if let node {
            let path = node.url?.path ?? node.name
            detailLabel.stringValue = "\(path) · \(sizeText(node.size))"
        } else if let result {
            detailLabel.stringValue = "\(result.itemCount.formatted()) items · \(sizeText(result.root.size)) scanned"
        }
        updateButtons()
    }

    private func activate(_ node: DiskNode) {
        if node.isDirectory {
            treemap.focus = node
            updateTitle()
            updateButtons()
        } else if let url = node.url {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateTitle() {
        guard let focus = treemap.focus else {
            statusLabel.stringValue = "Choose a folder or volume to begin"
            view.window?.title = "DiskMap"
            return
        }
        let path = focus.url?.path ?? focus.name
        statusLabel.stringValue = "\(path)  ·  \(sizeText(focus.size))"
        if let result, result.isVolumeRoot {
            view.window?.title = "\(path) — \(sizeText(result.volumeTotal)) total — \(sizeText(result.volumeFree)) free — DiskMap"
        } else {
            view.window?.title = "\(path) — DiskMap"
        }
    }

    private func updateButtons() {
        guard isViewLoaded else { return }
        let hasRoot = treemap.root != nil
        buttons[0].isEnabled = hasRoot
        buttons[1].isEnabled = hasRoot && treemap.focus !== treemap.root
        buttons[2].isEnabled = treemap.selection?.isDirectory == true
        buttons[3].isEnabled = treemap.focus?.parent != nil
        buttons[4].isEnabled = treemap.selection?.url != nil
        buttons[5].isEnabled = result?.isVolumeRoot == true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var controller: MainViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MainViewController()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 650),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "DiskMap"
        window.minSize = NSSize(width: 720, height: 440)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.center()
        makeMenu()
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window.makeKeyAndOrderFront(nil)
            self?.window.orderFrontRegardless()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func makeMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DiskMap", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DiskMap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let open = fileMenu.addItem(withTitle: "Open…", action: #selector(MainViewController.chooseFolder), keyEquivalent: "o")
        open.target = controller
        let reload = fileMenu.addItem(withTitle: "Reload", action: #selector(MainViewController.reloadScan), keyEquivalent: "r")
        reload.target = controller
        fileItem.submenu = fileMenu

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let zoomIn = viewMenu.addItem(withTitle: "Zoom In", action: #selector(MainViewController.zoomIn), keyEquivalent: "i")
        zoomIn.keyEquivalentModifierMask = [.control]
        zoomIn.target = controller
        let zoomOut = viewMenu.addItem(withTitle: "Zoom Out", action: #selector(MainViewController.zoomOut), keyEquivalent: "o")
        zoomOut.keyEquivalentModifierMask = [.control]
        zoomOut.target = controller
        let zoomFull = viewMenu.addItem(withTitle: "Zoom Full", action: #selector(MainViewController.zoomFull), keyEquivalent: "\u{1b}")
        zoomFull.keyEquivalentModifierMask = []
        zoomFull.target = controller
        viewItem.submenu = viewMenu

        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        let shortcuts = helpMenu.addItem(withTitle: "Keyboard Shortcuts",
                                         action: #selector(MainViewController.showShortcuts),
                                         keyEquivalent: "/")
        shortcuts.keyEquivalentModifierMask = [.shift]
        shortcuts.target = controller
        helpItem.submenu = helpMenu
        NSApp.mainMenu = main
        NSApp.helpMenu = helpMenu
    }
}

@main
struct DiskMapApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }
}
