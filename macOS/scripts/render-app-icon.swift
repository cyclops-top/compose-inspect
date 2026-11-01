#!/usr/bin/env swift
import AppKit
import WebKit

// Render the SVG with WebKit so its gradients, blur filters and alpha survive.
@MainActor final class IconRenderer: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    let output: URL
    init(source: URL, output: URL) throws {
        self.output = output
        super.init()
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        let svg = try String(contentsOf: source, encoding: .utf8)
        webView.loadHTMLString("<html><head><style>html,body{margin:0;width:1024px;height:1024px;background:transparent}svg{display:block}</style></head><body>\(svg)</body></html>", baseURL: source.deletingLastPathComponent())
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
        configuration.snapshotWidth = 1024
        webView.takeSnapshot(with: configuration) { image, error in
            guard let image, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                fputs("Icon render failed: \(String(describing: error))\n", stderr)
                exit(1)
            }
            do { try png.write(to: self.output); exit(0) }
            catch { fputs("\(error)\n", stderr); exit(1) }
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: render-app-icon.swift source.svg output.png")
}
let renderer = try MainActor.assumeIsolated { try IconRenderer(source: URL(fileURLWithPath: CommandLine.arguments[1]),
                                output: URL(fileURLWithPath: CommandLine.arguments[2])) }
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { fputs("Icon render timed out\n", stderr); exit(1) }
app.run()
