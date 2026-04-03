import AppKit
import SwiftUI

struct SymbolImage: View {
    let name: String
    let fallback: String
    
    var body: some View {
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            Image(nsImage: img)
        } else if let img = NSImage(systemSymbolName: fallback, accessibilityDescription: nil) {
            Image(nsImage: img)
        } else if let img = NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil) {
            Image(nsImage: img)
        } else {
            Image(systemName: "questionmark")
        }
    }
}

