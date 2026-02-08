import SwiftUI

struct SplashScreenView: View {
    @State private var iconScale: CGFloat = 0.5
    @State private var iconOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var titleOffset: CGFloat = 20
    @State private var glowOpacity: Double = 0

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color.backgroundPrimary,
                    Color.backgroundSecondary,
                    Color.backgroundPrimary
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Glow behind icon
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.goldAccent.opacity(0.3),
                                    Color.goldAccent.opacity(0.05),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 20,
                                endRadius: 120
                            )
                        )
                        .frame(width: 240, height: 240)
                        .opacity(glowOpacity)

                    // App icon
                    if let uiImage = UIImage(named: "AppIcon") {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 140, height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 30))
                            .shadow(color: Color.goldAccent.opacity(0.4), radius: 20)
                            .scaleEffect(iconScale)
                            .opacity(iconOpacity)
                    }
                }

                // App name
                VStack(spacing: 6) {
                    Text("Stack Tracker")
                        .font(.system(size: 32, weight: .bold, design: .default))
                        .foregroundColor(.goldAccent)

                    Text("PRO")
                        .font(.system(size: 16, weight: .heavy, design: .default))
                        .tracking(6)
                        .foregroundColor(.textSecondary)
                }
                .opacity(titleOpacity)
                .offset(y: titleOffset)

                Spacer()
                Spacer()
            }
        }
        .onAppear {
            // Icon entrance
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                iconScale = 1.0
                iconOpacity = 1.0
            }

            // Glow pulse
            withAnimation(.easeIn(duration: 0.8).delay(0.2)) {
                glowOpacity = 1.0
            }

            // Title slide up
            withAnimation(.easeOut(duration: 0.5).delay(0.3)) {
                titleOpacity = 1.0
                titleOffset = 0
            }
        }
    }
}

#Preview {
    SplashScreenView()
}
