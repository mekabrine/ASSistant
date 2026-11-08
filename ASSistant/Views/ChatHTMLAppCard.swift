import SwiftUI

struct ChatHTMLAppCard: View {
    let app: GeneratedApp
    var onEdit: () -> Void
    var onPublish: () -> Void
    @State private var previewExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "app.gift.fill")
                    .foregroundStyle(.cyan).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.title).font(.headline)
                    Text("HTMLApp · version \(app.version) · \(app.html.utf8.count) bytes")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { previewExpanded.toggle() }
                } label: {
                    Image(systemName: previewExpanded ? "chevron.up" : "chevron.down")
                }
            }
            if previewExpanded {
                HTMLPreview(html: app.html)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(.secondary.opacity(0.18)))
                Text("Interactive preview uses an isolated web session; HTMLApp-only native APIs are available after import.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(action: onPublish) {
                    Label(app.sourceURL == nil ? "Publish & install" : "Open HTMLApp",
                          systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.cyan.opacity(0.25)))
        .padding(.vertical, 7)
    }
}
