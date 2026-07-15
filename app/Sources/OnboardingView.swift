import SwiftUI

struct OnboardingView: View {
    @Binding var onboardingCompleted: Bool
    @State private var currentPage = 0
    @State private var testServerURL: String = ""
    @State private var testStatus: ConnectionTestStatus = .untested

    enum ConnectionTestStatus: Equatable {
        case untested
        case testing
        case success
        case failure(String)
    }

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
        .onAppear {
            if testServerURL.isEmpty {
                let config = SharedConfig.load()
                testServerURL = config.servers.first ?? SharedConfig.Defaults.baseUrl
            }
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

            Text("Enter your Whisper server URL below to test the connection.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            TextField("Server URL", text: $testServerURL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 32)
                .autocorrectionDisabled()

            Button {
                testConnection()
            } label: {
                Label(testStatus == .testing ? "Testing..." : "Test Connection",
                      systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.bordered)
            .disabled(testStatus == .testing)

            if case .success = testStatus {
                Label("Connected ✓", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if case .failure(let msg) = testStatus {
                Label(msg, systemImage: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Spacer()
        }
        .tag(3)
    }

    // MARK: - Helpers

    private func testConnection() {
        let server = testServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else {
            testStatus = .failure("Please enter a server URL.")
            return
        }

        testStatus = .testing

        Task {
            let healthy = await WhisperClient.checkHealth(serverURL: server, timeout: 10)
            await MainActor.run {
                testStatus = healthy
                    ? .success
                    : .failure("Could not reach server. Check the URL and try again.")
            }
        }
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
