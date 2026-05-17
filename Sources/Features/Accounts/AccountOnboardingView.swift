import CoreImage.CIFilterBuiltins
import SwiftUI

struct AccountOnboardingView: View {

    let request: OnboardingRequest

    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel = AccountOnboardingViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var draftName: String = "My WhatsApp"

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [WATheme.Colors.accentDark, WATheme.Colors.accent],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                header
                card
                Spacer(minLength: 0)
                footer
            }
            .padding(28)
        }
        .accessibilityIdentifier("AccountOnboardingView")
        .task {
            await viewModel.startSession(
                displayName: draftName,
                storage: environment.storage,
                clientProvider: { environment.client(for: $0) }
            )
            if case .completed = viewModel.phase {
                await environment.reloadAccounts()
                dismiss()
            }
        }
        .onChange(of: viewModel.phase) { _, newValue in
            if case .completed = newValue {
                Task {
                    await environment.reloadAccounts()
                    dismiss()
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(.white.opacity(0.15)).frame(width: 64, height: 64)
                Image(systemName: "infinity.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
            }
            Text("Link a WhatsApp Account")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("On your phone: Settings → Linked Devices → Link a Device")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
        }
    }

    private var card: some View {
        VStack(spacing: 16) {
            content
        }
        .padding(24)
        .frame(minWidth: 320, minHeight: 320)
        .background(WATheme.Colors.incomingBubble, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .preparing:
            VStack(spacing: 12) {
                ProgressView()
                Text("Preparing helper…").foregroundStyle(.secondary)
            }
            .frame(minWidth: 240, minHeight: 240)
        case .awaitingQR(let code):
            qrSection(code: code)
        case .pairing:
            VStack(spacing: 12) {
                ProgressView()
                Text("Linking device…").foregroundStyle(.secondary)
            }
            .frame(minWidth: 240, minHeight: 240)
        case .completed:
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(WATheme.Colors.accent)
                Text("Linked!").font(.headline)
            }
            .frame(minWidth: 240, minHeight: 240)
        case .failed(let reason):
            VStack(spacing: 10) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.title)
                Text(reason)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task {
                        await viewModel.startSession(
                            displayName: draftName,
                            storage: environment.storage,
                            clientProvider: { environment.client(for: $0) }
                        )
                    }
                }
                .controlSize(.large)
            }
        }
    }

    private func qrSection(code: String) -> some View {
        VStack(spacing: 14) {
            QRCodeImage(text: code)
                .frame(width: 220, height: 220)
                .padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.06)))

            VStack(alignment: .leading, spacing: 8) {
                Text("Account label").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("My WhatsApp", text: $draftName)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: 240)

            Text("The code refreshes automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("OnboardingQRSection")
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                let draftID = viewModel.draftAccountID
                viewModel.cancel()
                if let draftID {
                    Task { await environment.discardOnboardingDraft(accountID: draftID) }
                }
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .tint(.white)
            Spacer()
            Text("End-to-end encryption by WhatsApp")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

private struct QRCodeImage: View {

    let text: String

    var body: some View {
        if let cgImage = makeImage() {
            Image(decorative: cgImage, scale: 1)
                .resizable()
                .interpolation(.none)
        } else {
            ContentUnavailableView("QR unavailable", systemImage: "qrcode")
        }
    }

    private func makeImage() -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "Q"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else {
            return nil
        }
        let context = CIContext()
        return context.createCGImage(output, from: output.extent)
    }
}
