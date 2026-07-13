import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: WindowBoardAppState

    var body: some View {
        Form {
            Section("Board") {
                modePicker(
                    title: "Board Click Action",
                    selection: enumBinding(rawValue: $appState.boardClickActionRawValue, defaultValue: .none),
                    values: BoardClickAction.allCases
                )
            }

            Section("Attached Behavior") {
                modePicker(
                    title: "Follow Mode",
                    selection: enumBinding(rawValue: $appState.followModeRawValue, defaultValue: .none),
                    values: FollowMode.allCases
                )
                modePicker(
                    title: "Position Update",
                    selection: enumBinding(rawValue: $appState.positionUpdateModeRawValue, defaultValue: .manual),
                    values: PositionUpdateMode.allCases
                )
                modePicker(
                    title: "Auto Front",
                    selection: enumBinding(rawValue: $appState.autoFrontModeRawValue, defaultValue: .off),
                    values: AutoFrontMode.allCases
                )
            }

        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
    }

    private func modePicker<Value: Identifiable & Hashable>(
        title: String,
        selection: Binding<Value>,
        values: [Value]
    ) -> some View where Value.ID == String, Value: RawRepresentable, Value.RawValue == String {
        Picker(title, selection: selection) {
            ForEach(values) { value in
                Text(value.rawValue).tag(value)
            }
        }
        .pickerStyle(.segmented)
    }

    private func enumBinding<Value>(
        rawValue: Binding<String>,
        defaultValue: Value
    ) -> Binding<Value> where Value: RawRepresentable, Value.RawValue == String {
        Binding(
            get: {
                Value(rawValue: rawValue.wrappedValue) ?? defaultValue
            },
            set: { newValue in
                rawValue.wrappedValue = newValue.rawValue
            }
        )
    }
}
