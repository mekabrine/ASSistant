import SwiftUI
import WebKit
import UIKit

struct AssistantChoices: Decodable {
    var question: String
    var options: [String]
}

enum MessagePart {
    case prose(String)
    case code(String, String)
    case preview(String)
    case table([String], [[String]])
    case choices(AssistantChoices)
}

enum MessageFormatter {
    static let fence = String(repeating: String(UnicodeScalar(96)!), count: 3)

    static func parse(_ source: String) -> [MessagePart] {
        let lines = source.components(separatedBy: "\n")
        var sections: [MessagePart] = []
        var current: [String] = []

        func flush() {
            if !current.isEmpty {
                sections.append(.prose(current.joined(separator: "\n")))
                current.removeAll()
            }
        }
        func cells(_ line: String) -> [String] {
            let value = line.trimmingCharacters(in: .whitespaces)
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                flush()
                let language = line.trimmingCharacters(in: .whitespaces)
                    .dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                i += 1
                var code: [String] = []
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                let raw = code.joined(separator: "\n")
                sections.append(language == "html-preview" ? .preview(raw) : .code(String(language), raw))
                i += 1
                continue
            }
            if line.contains("<assistant_choices>"),
               let start = line.range(of: "<assistant_choices>"),
               let end = line.range(of: "</assistant_choices>"),
               start.upperBound <= end.lowerBound {
                let json = String(line[start.upperBound..<end.lowerBound])
                if let data = json.data(using: .utf8),
                   let choice = try? JSONDecoder().decode(AssistantChoices.self, from: data),
                   (2...6).contains(choice.options.count),
                   choice.options.allSatisfy({ $0.count < 180 }) {
                    flush()
                    sections.append(.choices(choice))
                    i += 1
                    continue
                }
            }
            if line.contains("|"), i + 1 < lines.count {
                let header = cells(line), separator = cells(lines[i + 1])
                let isSeparator = separator.count == header.count && header.count >= 2
                    && separator.allSatisfy { segment in
                        let clean = segment.replacingOccurrences(of: ":", with: "")
                            .replacingOccurrences(of: "-", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        return clean.isEmpty && segment.contains("-")
                    }
                if isSeparator {
                    flush()
                    i += 2
                    var rows: [[String]] = []
                    while i < lines.count && lines[i].contains("|") && rows.count < 50 {
                        let row = cells(lines[i])
                        guard row.count == header.count else { break }
                        rows.append(row)
                        i += 1
                    }
                    sections.append(.table(header, rows))
                    continue
                }
            }
            current.append(line)
            i += 1
        }
        flush()
        return sections
    }

    static func allowedPreview(_ html: String) -> Bool {
        guard html.count < 12000 else { return false }
        let lowered = html.lowercased()
        return !["<script", "<iframe", "<form", "<object", "<embed",
                 "<link", "http:", "https:", "url(", "@import",
                 "javascript:", "data:", "onload=", "onclick=",
                 "onerror=", "src=", "href="].contains(where: lowered.contains)
    }
}

struct RichMessageView: View {
    let content: String
    var onChoice: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MessageFormatter.parse(content).enumerated()), id: \.offset) { part in
                let section = part.element
                switch section {
                case .prose(let text):
                    Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                        .font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let language, let code):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(language.isEmpty ? "Code" : language)
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy") { UIPasteboard.general.string = code }
                                .font(.caption)
                        }
                        ScrollView(.horizontal) {
                            Text(code)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(11)
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(Color.primary)
                case .preview(let html):
                    if MessageFormatter.allowedPreview(html) {
                        VStack(alignment: .leading, spacing: 7) {
                            Label("Static HTML preview", systemImage: "rectangle.on.rectangle")
                                .font(.caption).foregroundStyle(.secondary)
                            StaticHTMLPreview(html: html)
                                .frame(height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    } else {
                        Text("HTML preview blocked: unsafe or remote content. Review the code instead.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                case .table(let columns, let rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            GridRow {
                                ForEach(Array(columns.enumerated()), id: \.offset) { column in
                                    let label = column.element
                                    Text(label).font(.caption).fontWeight(.bold)
                                }
                            }
                            Divider()
                            ForEach(Array(rows.enumerated()), id: \.offset) { item in
                                let row = item.element
                                GridRow {
                                    ForEach(Array(row.enumerated()), id: \.offset) { item in
                                        let cell = item.element
                                        Text(cell).font(.caption).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        .padding(12)
                    }
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(Color.primary)
                case .choices(let choice):
                    VStack(alignment: .leading, spacing: 9) {
                        Text(choice.question).font(.headline)
                        ForEach(choice.options, id: \.self) { answer in
                            Button {
                                onChoice?(answer)
                            } label: {
                                Label(answer, systemImage: "circle")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 5)
                            }
                            .buttonStyle(.bordered)
                            .disabled(onChoice == nil)
                        }
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(Color.primary)
                }
            }
        }
    }
}

private struct StaticHTMLPreview: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: nil)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.allow); return }
            decisionHandler(url.scheme == "about" ? .allow : .cancel)
        }
    }
}
