import SwiftUI

/// Placeholder; a later task fills in the settings.
struct SettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Settings go here.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(width: 460, height: 300)
    }
}

#Preview {
    SettingsView()
}
