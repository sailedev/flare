import SwiftUI

struct OnboardingView: View {
    @State private var permissionGranted = CGPreflightScreenCaptureAccess()
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Welcome to Flare")
                .font(.title.bold())

            Text("A native screenshot tool for your menubar. Capture, beautify, annotate, and share.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                permissionRow(
                    title: "Screen Recording",
                    description: "Required to capture screenshots. Grant access in System Settings.",
                    granted: permissionGranted
                )
            }
            .padding(.horizontal)

            HStack(spacing: 16) {
                if !permissionGranted {
                    Button("Open System Settings") {
                        openScreenRecordingSettings()
                    }
                    .buttonStyle(.bordered)
                }

                Button(permissionGranted ? "Get Started" : "Continue Anyway") {
                    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 440)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionGranted = CGPreflightScreenCaptureAccess()
        }
    }

    private func permissionRow(title: String, description: String, granted: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.title2)
                .foregroundColor(granted ? .green : .orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
