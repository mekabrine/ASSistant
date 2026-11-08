import SwiftUI
import UIKit

/// UITextView-based composer that sizes to content on iOS 16, grows until it
/// reaches a sensible maximum, then scrolls internally without clipping text.
struct GrowingMessageInput: UIViewRepresentable {
    @Binding var text: String
    var maximumHeight: CGFloat = 210

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 10, left: 7, bottom: 10, right: 7)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.keyboardDismissMode = .interactive
        view.autocorrectionType = .yes
        view.smartInsertDeleteType = .yes
        view.accessibilityLabel = "Message"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
        uiView.font = UIFont.preferredFont(forTextStyle: .body)
        let width = max(120, uiView.bounds.width)
        let ideal = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        let scrolling = ideal > maximumHeight
        if uiView.isScrollEnabled != scrolling { uiView.isScrollEnabled = scrolling }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView,
                      context: Context) -> CGSize? {
        let width = max(120, proposal.width ?? 260)
        let ideal = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        return CGSize(width: width, height: min(maximumHeight, max(44, ideal)))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            if text != textView.text { text = textView.text }
            textView.invalidateIntrinsicContentSize()
        }
    }
}
