import SwiftUI

struct UniPadLogoView: View {
    let size: CGFloat

    private var quadrantSize: CGFloat { size * 0.44 }
    private var gap: CGFloat { size * 0.06 }
    private var cornerRadius: CGFloat { quadrantSize * 0.15 }

    var body: some View {
        VStack(spacing: gap) {
            HStack(spacing: gap) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(AppColors.logoOrange)
                    .frame(width: quadrantSize, height: quadrantSize)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(AppColors.logoCyan)
                    .frame(width: quadrantSize, height: quadrantSize)
            }
            HStack(spacing: gap) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(AppColors.logoOrange)
                    .frame(width: quadrantSize, height: quadrantSize)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(AppColors.logoCyan)
                    .frame(width: quadrantSize, height: quadrantSize)
            }
        }
        .frame(width: size, height: size)
    }
}

struct SplashView: View {
    @Environment(AppRouter.self) private var router

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        ZStack {
            AppColors.background1
                .ignoresSafeArea()

            VStack {
                Spacer()

                VStack(spacing: 12) {
                    UniPadLogoView(size: 70)

                    Text("UniPad")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }

                Spacer()

                VStack(spacing: 5) {
                    Text("v\(versionString)")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)

                    Text(String(localized: "copyright"))
                        .font(.system(size: 10))
                        .foregroundStyle(AppColors.textSecondary)
                }
                .padding(.bottom, 30)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(2))
            router.dismissSplash()
        }
    }
}
