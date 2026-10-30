import SwiftUI

/// Lists the third-party components built into the app and shows the full
/// license text of the selected one, laid out like Settings: the list on the
/// left, the text on the right.
struct OpenSourceLicensesView: View {
    @Environment(AppRouter.self) private var router
    @State private var selected: OpenSourceLicense?

    private let licenses = OpenSourceLicense.bundled()

    private static let backHitOutset: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let listWidth = min(max(geometry.size.width * 0.3, 180), 260)
            HStack(spacing: 0) {
                componentList
                    .frame(width: listWidth)

                licenseText
                    .frame(maxWidth: .infinity)
            }
        }
        .background(AppColors.background1)
        .platformNavigationBarHidden(true)
        .onAppear {
            if selected == nil { selected = licenses.first }
        }
    }

    private var componentList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { router.pop() } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(AppColors.textPrimary)
                        .padding(Self.backHitOutset)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .padding(-Self.backHitOutset)
                .padding(.trailing, 4)

                Text(String(localized: "openSourceLicense"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: 0)
            }
            .avoidingWindowControls()
            .padding(.bottom, 24)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(licenses) { license in
                        componentRow(license)
                    }
                }
            }
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 12)
        .background(AppColors.background1)
    }

    private func componentRow(_ license: OpenSourceLicense) -> some View {
        let isSelected = license == selected
        return Button {
            selected = license
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(license.name)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AppColors.textPrimary : AppColors.textSecondary)
                Text("\(license.version) · \(license.license)")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.textSecondary)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AppColors.navItemSelected : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var licenseText: some View {
        if let selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(selected.name) \(selected.version)")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                        Text(selected.url)
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    Text(selected.text())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppColors.textSecondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("openSourceLicenseText")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .id(selected.id)
            .background(AppColors.darkSurface)
        }
    }
}
