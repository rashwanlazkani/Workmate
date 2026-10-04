import AppKit
import SwiftUI

/// The macOS time editor, without the old stepper bezel.
struct NativeTimeField: NSViewRepresentable {
    @Binding var date: Date
    var timezone: TimeZone
    var label: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textField
        picker.datePickerElements = [.hourMinute]
        picker.isBezeled = false; picker.isBordered = false; picker.drawsBackground = false
        picker.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        picker.textColor = .white
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        picker.setAccessibilityLabel(label)
        picker.dateValue = date; picker.timeZone = timezone
        return picker
    }
    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        picker.timeZone = timezone
        if picker.dateValue != date { picker.dateValue = date }
    }
    final class Coordinator: NSObject {
        var parent: NativeTimeField
        init(_ parent: NativeTimeField) { self.parent = parent }
        @objc func changed(_ picker: NSDatePicker) { parent.date = picker.dateValue }
    }
}
