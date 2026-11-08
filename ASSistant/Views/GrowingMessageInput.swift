import SwiftUI
import UIKit

/// A compact iOS 16 multiline input that grows only when its text needs
/// another line. Its height comes from measured text content, never from the
/// available parent height (which caused an empty editor to fill the screen).
struct GrowingMessageInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    var maximumHeight: CGFloat = 176

    static let minimumHeight: CGFloat = 44

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.keyboardDismissMode = .interactive
        view.autocorrectionType = .yes
        view.smartInsertDeleteType = .yes
        view.accessibilityLabel = "Message"
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        context.coordinator.maximumHeight = maximumHeight
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.maximumHeight = maximumHeight
        if uiView.text != text {
            uiView.text = text
        }
        uiView.font = UIFont.preferredFont(forTextStyle: .body)
        context.coordinator.measure(uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, measuredHeight: $measuredHeight,
                    maximumHeight: maximumHeight)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        @Binding var measuredHeight: CGFloat
        var maximumHeight: CGFloat

        init(text: Binding<String>, measuredHeight: Binding<CGFloat>,
             maximumHeight: CGFloat) {
            _text = text
            _measuredHeight = measuredHeight
            self.maximumHeight = maximumHeight
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
            measure(textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            measure(textView)
        }

        func measure(_ textView: UITextView) {
            // Don't measure when UIKit has not yet assigned a usable width.
            // Width determines wrapping and therefore the required height.
            let width = textView.bounds.width
            guard width > 80 else { return }

            let required = textView.sizeThatFits(
                CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            ).height
            let target = min(maximumHeight, max(GrowingMessageInput.minimumHeight,
                                                 ceil(required)))
            let needsScroll = required > maximumHeight + 1
            if textView.isScrollEnabled != needsScroll {
                textView.isScrollEnabled = needsScroll
            }
            if abs(measuredHeight - target) > 1 {
                // UIViewRepresentable.updateUIView must not synchronously mutate
                // SwiftUI state. Dispatching to the next main turn is intentional.
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView,
                          textView.bounds.width > 80 else { return }
                    let fresh = textView.sizeThatFits(
                        CGSize(width: textView.bounds.width,
                               height: CGFloat.greatestFiniteMagnitude)
                    ).height
                    let height = min(self.maximumHeight,
                                     max(GrowingMessageInput.minimumHeight, ceil(fresh)))
                    if abs(self.measuredHeight - height) > 1 {
                        self.measuredHeight = height
                    }
                }
            }
        }
    }
}
