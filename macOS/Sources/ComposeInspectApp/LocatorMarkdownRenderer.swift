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
        for run in markdown.runs {
            let intent = run.presentationIntent
            let newBlock = intent != previous
            if newBlock && output.length > 0 { output.append(NSAttributedString(string: "\n\n")) }
            var font = NSFont.systemFont(ofSize: 12)
            var code = false
            var prefix = ""
            for component in intent?.components ?? [] {
                switch component.kind {
                case .header(let level): font = .systemFont(ofSize: level == 1 ? 18 : 15, weight: .semibold)
                case .codeBlock: code = true
                case .listItem(let ordinal):
                    let ordered = intent?.components.contains { if case .orderedList = $0.kind { return true }; return false } ?? false
                    prefix = ordered ? "\(ordinal). " : "• "
                default: break
                }
            }
            let inline = run.inlinePresentationIntent ?? []
            if code || inline.contains(.code) { font = .monospacedSystemFont(ofSize: 11, weight: .regular) }
            if inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            if code || inline.contains(.code) { attributes[.backgroundColor] = NSColor.quaternaryLabelColor }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            output.append(NSAttributedString(string: (newBlock ? prefix : "") + String(markdown[run.range].characters), attributes: attributes))
            previous = intent
        }
        return output
    }
}
