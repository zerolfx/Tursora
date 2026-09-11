import AppKit

extension NSView {
    /// Pin a subview to all four edges of the receiver.
    func pinToEdges(_ subview: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subview)
        NSLayoutConstraint.activate([
            subview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            subview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            subview.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            subview.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }
}

extension NSTableCellView {
    /// A cell with an optional 16pt leading icon and a single-line label,
    /// laid out the way system table views expect (label baseline-aligned,
    /// icon vertically centred).
    static func make(identifier: NSUserInterfaceItemIdentifier, withIcon: Bool,
                     alignment: NSTextAlignment = .natural, iconSize: CGFloat = 16) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.alignment = alignment
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        var leading: NSLayoutXAxisAnchor = cell.leadingAnchor
        var leadingInset: CGFloat = 4
        if withIcon {
            let icon = NSImageView()
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: iconSize),
                icon.heightAnchor.constraint(equalToConstant: iconSize),
            ])
            leading = icon.trailingAnchor
            leadingInset = 6
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leading, constant: leadingInset),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
