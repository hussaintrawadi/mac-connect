import SwiftUI

struct PairingView: View {
    @StateObject private var pairingManager = PairingManager()
    var onPaired: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.s5) {
            // App mark + title
            VStack(spacing: Theme.s3) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

                VStack(spacing: Theme.s1) {
                    Text("Pair with Android")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Connect a new device.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            switch pairingManager.state {
            case .idle, .waitingForPhone:
                VStack(spacing: Theme.s4) {
                    Text("Open Mac Connect on your phone and scan this code.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.s4)

                    QRCard(payload: pairingManager.qrPayload, size: 200)

                    HStack(spacing: Theme.s2) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for phone…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

            case .connecting:
                VStack(spacing: Theme.s3) {
                    ProgressView().scaleEffect(1.3)
                    Text("Connecting…")
                        .font(.title3)
                }
                .frame(maxHeight: .infinity)

            case .paired(let name):
                PairSuccessView(name: name)
                    .frame(maxHeight: .infinity)

            case .failed(let reason):
                PairFailureView(reason: reason) {
                    pairingManager.startPairing { success in
                        if success { onPaired?() }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.s6)
        .frame(width: 360, height: 480)
        .background(.background)
        .onAppear {
            pairingManager.startPairing { success in
                if success {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        onPaired?()
                    }
                }
            }
        }
        .onDisappear {
            pairingManager.stopPairing()
        }
    }
}
