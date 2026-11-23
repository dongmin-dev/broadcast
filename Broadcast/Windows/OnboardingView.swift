import SwiftUI

/// Placeholder; a later task fills in the onboarding flow.
struct OnboardingView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: StatusItemRenderer.symbolName)
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Welcome to Broadcast")
                .font(.title2.bold())
            Text("Onboarding goes here.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(width: 480, height: 320)
    }
}

#Preview {
    OnboardingView()
}
