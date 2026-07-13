import SwiftUI

struct OnboardingView: View {
    @Binding var onboardingCompleted: Bool
    @State private var currentPage = 0
    @State private var showTestAlert = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentPage) {
                welcomePage.tag(0)
                addKeyboardPage.tag(1)
                fullAccessPage.tag(2)
                configurePage.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Spacer(minLength: 0)

            bottomBar
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .alert("Test Connection", isPresented: $showTestAlert) {
            Button("OK") {}
        } message: {
            Text("Connection testing will be implemented in a future update.")
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            if currentPage < 3 {
                Button("Skip") {
                    onboardingCompleted = true
                }
                .foregroundColor(.secondary)
            } else {
                Spacer()
            }

            Spacer()

            if currentPage < 3 {
                Button("Continue") {
                    withAnimation {
                        currentPage += 1
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Get Started") {
                    onboardingCompleted = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Page 0: Welcome

    private var welcomePage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)

            Text("Welcome to Ritoras")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Ritoras is a voice-to-text keyboard. It records your speech and sends it to your Whisper server for transcription. Everything stays on your infrastructure.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
        .tag(0)
    }

    // MARK: - Page 1: Add Keyboard

    private var addKeyboardPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "keyboard")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)

            Text("Add the Keyboard")
                .font(.largeTitle)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 12) {
                stepRow(number: 1, text: "Open Settings on your iPhone")
                stepRow(number: 2, text: "Go to General → Keyboard → Keyboards")
                stepRow(number: 3, text: "Tap 'Add New Keyboard…'")
                stepRow(number: 4, text: "Select Ritoras under 'Third-Party Keyboards'")
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .tag(1)
    }

    // MARK: - Page 2: Full Access

    private var fullAccessPage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "hand.raised.fill")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)

            Text("Enable Full Access")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Full Access allows the keyboard to access the microphone and network. Your audio never leaves your own server.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 12) {
                stepRow(number: 1, text: "Tap Ritoras in the keyboard list")
                stepRow(number: 2, text: "Toggle 'Allow Full Access' to ON")
            }
            .padding(.horizontal, 32)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Settings", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .tag(2)
    }

    // MARK: - Page 3: Configure

    private var configurePage: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "gearshape.fill")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)

            Text("Configure Your Server")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Enter your Whisper server details in the Settings screen. You'll need your server URL and optionally an API key.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                showTestAlert = true
            } label: {
                Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .tag(3)
    }

    // MARK: - Step Row Helper

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))

            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    OnboardingView(onboardingCompleted: .constant(false))
}
