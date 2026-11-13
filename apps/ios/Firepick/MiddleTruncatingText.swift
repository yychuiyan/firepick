import SwiftUI
import UIKit

/// Single-line text that truncates in the middle (keeps head + tail).
struct MiddleTruncatingText: UIViewRepresentable {
  var text: String
  var font: UIFont = .preferredFont(forTextStyle: .body)
  var textColor: UIColor = .label

  func makeUIView(context: Context) -> UILabel {
    let label = UILabel()
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingMiddle
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return label
  }

  func updateUIView(_ label: UILabel, context: Context) {
    label.text = text
    label.font = font
    label.textColor = textColor
  }
}
