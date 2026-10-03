import InstalogCore
import SwiftUI
import UIKit

/// A decimal-pad text field that selects its whole value when tapped, filters what can be typed,
/// and always has a Done key above the keypad — in any host, with or without a navigation stack.
struct DecimalField: UIViewRepresentable {
    @Binding var text: String
    var textColor: Color = Palette.text
    var accessibilityLabel: String
    var fontSize: CGFloat = 15
    var isAcceptable: (String) -> Bool = QuantityInput.isAcceptableEditing
    var onEditingChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.keyboardType = .decimalPad
        field.textAlignment = .right
        field.adjustsFontForContentSizeCategory = true
        let base = UIFont(name: "GeistMono-SemiBold", size: fontSize) ?? .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        field.tintColor = UIColor(Palette.accent)
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.inputAccessoryView = context.coordinator.doneBar(for: field)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        // Programmatic changes don't fire .editingChanged, so this never loops back.
        if field.text != text { field.text = text }
        field.textColor = UIColor(textColor)
        field.accessibilityLabel = accessibilityLabel
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: UITextField, context: Context) -> CGSize? {
        let font = field.font ?? .systemFont(ofSize: 15)
        let measured = ((field.text?.isEmpty == false ? field.text! : "0") as NSString)
            .size(withAttributes: [.font: font])
        let width = min(max(ceil(measured.width) + 6, 36), fontSize * 6.4)
        return CGSize(width: width, height: max(ceil(font.lineHeight), 22))
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: DecimalField
        /// True from the moment editing starts until the whole value is selected. Typing in that
        /// window replaces the value too, so fast typing never lands next to the old digits.
        private var replacesOnNextEdit = false

        init(parent: DecimalField) { self.parent = parent }

        func doneBar(for field: UITextField) -> UIToolbar {
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            let done = UIBarButtonItem(
                title: "Done", style: .done, target: field, action: #selector(UIResponder.resignFirstResponder))
            done.tintColor = UIColor(Palette.accent)
            bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), done]
            bar.sizeToFit()
            return bar
        }

        @objc func editingChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
            field.invalidateIntrinsicContentSize()
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            parent.onEditingChanged(true)
            replacesOnNextEdit = true
            // Runs after UIKit places the caret where the user tapped, so the selection sticks.
            Task { @MainActor in
                guard self.replacesOnNextEdit else { return }
                field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
                self.replacesOnNextEdit = false
            }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            replacesOnNextEdit = false
            parent.onEditingChanged(false)
        }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if replacesOnNextEdit {
                replacesOnNextEdit = false
                if parent.isAcceptable(string) {
                    field.text = string
                    editingChanged(field)
                }
                return false
            }
            let current = (field.text ?? "") as NSString
            return parent.isAcceptable(current.replacingCharacters(in: range, with: string))
        }
    }
}
