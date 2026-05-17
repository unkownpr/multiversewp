import CoreImage.CIFilterBuiltins
import SwiftUI

struct AccountOnboardingView: View {

    let request: OnboardingRequest

    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel = AccountOnboardingViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var draftName: String = "My WhatsApp"

    var body: some View {
        VStack(spacing: 20) {
            header
            divider
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        VStack(spacing: 6) {
            Text("Link a WhatsApp Account")
                .font(.title2.bold())
            Text("Open WhatsApp on your phone → Settings → Linked Devices → Link a Device")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var divider: some View {
        Divider().padding(.vertical, 4)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .preparing:
            VStack(spacing: 12) {
                ProgressView()
                Text("Preparing helper…")
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 280, minHeight: 280)
        case .awaitingQR(let code):
            qrSection(code: code)
        case .pairing:
            VStack(spacing: 12) {
                ProgressView()
                Text("Linking device…")
            }
        case .completed:
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").imageScale(.large).foregroundStyle(.green)
                Text("Linked!").font(.headline)
            }
        case .failed(let reason):
            VStack(spacing: 10) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(reason).multilineTextAlignment(.center)
                Button("Try Again") {
                    Task {
                        await viewModel.startSession(
                            displayName: draftName,
                            storage: environment.storage,
                            clientProvider: { environment.client(for: $0) }
                        )
                    }
                }
            }
        }
    }

    private func qrSection(code: String) -> some View {
        VStack(spacing: 12) {
            QRCodeImage(text: code)
                .frame(width: 240, height: 240)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
            TextField("Account label", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Text("Code refreshes automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("OnboardingQRSection")
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                viewModel.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
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
