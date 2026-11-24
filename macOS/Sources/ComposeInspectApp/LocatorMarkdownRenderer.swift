import AppKit
import Foundation

/// Uses Foundation's Markdown parser; presentation stays local and never loads remote content.
enum LocatorMarkdownRenderer {
    static func render(_ source: String) -> NSAttributedString {
        guard let markdown = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return NSAttributedString(string: source, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        let output = NSMutableAttributedString(string: "")
        var previous: PresentationIntent?
        var codeBlock: NSTextTableBlock?
        for run in markdown.runs {
            let intent = run.presentationIntent
            let newBlock = intent != previous
            if newBlock {
                if output.length > 0 {
                    let separator = codeBlock != nil && output.string.hasSuffix("\n") ? "\n" : "\n\n"
                    output.append(NSAttributedString(string: separator))
                }
                codeBlock = nil
            }
            var font = NSFont.systemFont(ofSize: 12)
            var prefix = ""
            for component in intent?.components ?? [] {
                switch component.kind {
                case .header(let level): font = .systemFont(ofSize: level == 1 ? 18 : 15, weight: .semibold)
                case .codeBlock:
                    if codeBlock == nil { codeBlock = makeCodeBlock() }
                case .listItem(let ordinal):
                    let ordered = intent?.components.contains { if case .orderedList = $0.kind { return true }; return false } ?? false
                    prefix = ordered ? "\(ordinal). " : "• "
                default: break
                }
            }
            let inline = run.inlinePresentationIntent ?? []
            if codeBlock != nil || inline.contains(.code) { font = .monospacedSystemFont(ofSize: 11, weight: .regular) }
            if inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            if let codeBlock { paragraph.textBlocks = [codeBlock] }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            if codeBlock == nil && inline.contains(.code) { attributes[.backgroundColor] = NSColor.quaternaryLabelColor }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            output.append(NSAttributedString(string: (newBlock ? prefix : "") + String(markdown[run.range].characters), attributes: attributes))
            previous = intent
        }
        return output
    }

    private static func makeCodeBlock() -> NSTextTableBlock {
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.setValue(100, type: .percentageValueType, for: .width)
        let cell = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        cell.backgroundColor = .quaternaryLabelColor
        cell.setWidth(6, type: .absoluteValueType, for: .padding)
        return cell
    }
}
