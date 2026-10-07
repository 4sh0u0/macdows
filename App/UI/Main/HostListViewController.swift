import AppKit

/// UI-1 spec §1 / §3: the Hosts sidebar -- a source list of the host records with a state marker,
/// the name and the address, and + / − at the bottom. The system sidebar takes floating glass on
/// 26 by itself and is a standard sidebar material on 14–25; nothing here draws glass.
@MainActor
final class HostListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// The sidebar marker (UI-1 spec §4.1 last column; shape + colour + accessible text).
    enum Marker: Equatable {
        case idle
        case connecting
        case live
        case reconnecting
        case failed

        var symbol: String {
            switch self {
            case .idle: return "circle"
            case .connecting: return "circle.lefthalf.filled"
            case .live: return "circle.fill"
            case .reconnecting: return "circle.lefthalf.filled"
            case .failed: return "diamond.fill"
            }
        }

        var color: NSColor {
            switch self {
            case .idle: return .tertiaryLabelColor
            case .connecting: return .secondaryLabelColor
            case .live: return .systemGreen
            case .reconnecting: return .systemOrange
            case .failed: return .systemRed
            }
        }

        var accessibilityText: String {
            switch self {
            case .idle: return UIStrings.notConnected
            case .connecting: return UIStrings.connecting
            case .live: return UIStrings.connected
            case .reconnecting: return UIStrings.reconnecting
            case .failed: return UIStrings.connectionFailed
            }
        }
    }

    let tableView = NSTableView()
    let addButton: NSButton
    let removeButton: NSButton
    private(set) var records: [HostRecord] = []
    private var markers: [HostID: Marker] = [:]
    var onSelectionChange: ((HostID?) -> Void)?
    private var suppressSelectionCallback = false

    init(addAction: Selector, removeAction: Selector) {
        addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: UIStrings.newHost) ?? NSImage(),
                             target: nil, action: addAction)
        removeButton = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: UIStrings.removeHost) ?? NSImage(),
                                target: nil, action: removeAction)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("host"))
        column.title = UIStrings.hosts
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowHeight = 40
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.setAccessibilityLabel(UIStrings.hosts)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for button in [addButton, removeButton] {
            button.bezelStyle = .smallSquare
            button.isBordered = false
        }
        addButton.setAccessibilityLabel(UIStrings.newHost)
        removeButton.setAccessibilityLabel(UIStrings.removeHost)
        let bottom = NSStackView(views: [addButton, removeButton])
        bottom.orientation = .horizontal
        bottom.spacing = 4
        bottom.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scroll)
        root.addSubview(bottom)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -4),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        view = root
    }

    /// Replaces the rows, keeping `selected` selected when it still exists.
    func reload(records: [HostRecord], selected: HostID?) {
        self.records = records
        suppressSelectionCallback = true
        tableView.reloadData()
        if let selected, let row = records.firstIndex(where: { $0.id == selected }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        suppressSelectionCallback = false
    }

    func setMarker(_ marker: Marker, for host: HostID) {
        markers[host] = marker
        if let row = records.firstIndex(where: { $0.id == host }) {
            tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
        }
    }

    func marker(for host: HostID) -> Marker { markers[host] ?? .idle }

    func select(_ host: HostID?) {
        if let host, let row = records.firstIndex(where: { $0.id == host }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    var selectedHost: HostID? {
        let row = tableView.selectedRow
        return records.indices.contains(row) ? records[row].id : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let record = records[row]
        let marker = self.marker(for: record.id)
        let image = NSImageView(image: NSImage(systemSymbolName: marker.symbol, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = marker.color
        image.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        image.setContentHuggingPriority(.required, for: .horizontal)
        let name = NSTextField(labelWithString: record.title)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        let address = NSTextField(labelWithString: record.address)
        address.font = .systemFont(ofSize: 11)
        address.textColor = .secondaryLabelColor
        address.lineBreakMode = .byTruncatingTail
        let texts = NSStackView(views: [name, address])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        let row = NSStackView(views: [image, texts])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        let cell = NSTableCellView()
        cell.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel("\(record.title), \(record.address), \(marker.accessibilityText)")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        onSelectionChange?(selectedHost)
    }
}
