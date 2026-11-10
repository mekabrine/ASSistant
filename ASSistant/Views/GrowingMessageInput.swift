import SwiftUI
import UIKit

/// Compact multiline composer: 1 line initially, grows through 4 visual lines,
/// then keeps its height and scrolls vertically. It always wraps horizontally.
struct GrowingMessageInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat

    static let verticalInset: CGFloat = 9
    static let minimumHeight: CGFloat = 42

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(
            top: Self.verticalInset, left: 7,
            bottom: Self.verticalInset, right: 7
        )
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.textContainer.heightTracksTextView = false
        view.isScrollEnabled = false
        view.alwaysBounceVertical = false
        view.alwaysBounceHorizontal = false
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = true
        view.keyboardDismissMode = .interactive
        view.autocorrectionType = .yes
        view.smartInsertDeleteType = .yes
        view.accessibilityLabel = "Message"

        // Critical: the editor must yield its horizontal intrinsic width inside
        // the HStack so text wraps instead of pushing the send button offscreen.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
        uiView.font = UIFont.preferredFont(forTextStyle: .body)
        context.coordinator.measure(uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, measuredHeight: $measuredHeight)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        @Binding var measuredHeight: CGFloat

        init(text: Binding<String>, measuredHeight: Binding<CGFloat>) {
            _text = text
            _measuredHeight = measuredHeight
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
            measure(textView)
            if textView.isScrollEnabled {
                let end = NSRange(location: max(0, textView.text.utf16.count), length: 0)
                textView.scrollRangeToVisible(end)
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.isScrollEnabled {
                textView.scrollRangeToVisible(textView.selectedRange)
            }
        }

        func measure(_ textView: UITextView) {
            let width = textView.bounds.width
            guard width.isFinite, width > 80 else { return }

            let font = textView.font ?? UIFont.preferredFont(forTextStyle: .body)
            let lineHeight = ceil(font.lineHeight)
            let minHeight = max(GrowingMessageInput.minimumHeight,
                                lineHeight + GrowingMessageInput.verticalInset * 2)
            let maxHeight = lineHeight * 4 + GrowingMessageInput.verticalInset * 2

            let fitting = textView.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            guard fitting.isFinite else { return }

            let target = min(maxHeight, max(minHeight, ceil(fitting)))
            let shouldScroll = fitting > maxHeight + 0.5

            if textView.isScrollEnabled != shouldScroll {
                textView.isScrollEnabled = shouldScroll
                textView.alwaysBounceVertical = shouldScroll
            }

            guard abs(measuredHeight - target) > 0.5 else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                let width = textView.bounds.width
                guard width.isFinite, width > 80 else { return }
                let fresh = textView.sizeThatFits(
                    CGSize(width: width, height: .greatestFiniteMagnitude)
                ).height
                guard fresh.isFinite else { return }
                let font = textView.font ?? UIFont.preferredFont(forTextStyle: .body)
                let lineHeight = ceil(font.lineHeight)
                let minHeight = max(GrowingMessageInput.minimumHeight,
                                    lineHeight + GrowingMessageInput.verticalInset * 2)
                let maxHeight = lineHeight * 4 + GrowingMessageInput.verticalInset * 2
                let next = min(maxHeight, max(minHeight, ceil(fresh)))
                if abs(self.measuredHeight - next) > 0.5 {
                    self.measuredHeight = next
                }
            }
        }
    }
}
