import SwiftUI

struct TreeSettingsView: View {
    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Board Library", value: "WindowBoard Tree")
                LabeledContent("Sharing", value: "Separate from WindowBoard")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
