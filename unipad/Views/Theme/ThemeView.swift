import SwiftUI
import UniformTypeIdentifiers

struct ThemeView: View {
    @Environment(AppRouter.self) private var router
    @State private var vm = ThemeViewModel()
    @State private var showDeleteConfirmation = false
    @State private var deleteTarget: ThemeViewModel.ThemeItem?
    @State private var isFullscreen = false
    @State private var showThemeZipPicker = false
    @State private var showImportResultAlert = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if !isFullscreen {
                    themeListPanel
                        .frame(width: geometry.size.width * 0.4)
                        .transition(.move(edge: .leading))
                }

                previewPanel
                    .frame(maxWidth: .infinity)
            }
        }
        .background(AppColors.background1)
        .platformNavigationBarHidden(true)
        .animation(.easeInOut(duration: 0.3), value: isFullscreen)
        .alert(String(localized: "theme_delete_title"), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "delete"), role: .destructive) {
                if let target = deleteTarget {
                    vm.deleteTheme(target)
                    vm.selectedIndex = 0
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            if let target = deleteTarget {
                Text(String(localized: "theme_delete_confirm \(target.name)"))
            }
        }
        .fileImporter(
            isPresented: $showThemeZipPicker,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                vm.importTheme(from: url)
                if vm.importResultMessage != nil {
                    showImportResultAlert = true
                }
            }
        }
        .alert(String(localized: "theme"), isPresented: $showImportResultAlert) {
            Button(String(localized: "accept"), role: .cancel) {
                vm.importResultMessage = nil
            }
        } message: {
            Text(vm.importResultMessage ?? "")
        }
    }

    // MARK: - Theme List Panel

    private var themeListPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Button { router.pop() } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(AppColors.textPrimary)
                }
                .padding(.trailing, 4)

                Text(String(localized: "theme"))
                    .font(.system(size: 24))
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    vm.selectedIndex = vm.themes.count
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(AppColors.textPrimary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(vm.themes.enumerated()), id: \.element.id) { index, theme in
                        ThemeListItemView(
                            theme: theme,
                            isSelected: index == vm.selectedIndex,
                            isApplied: index == vm.appliedIndex,
                            onTap: { vm.selectedIndex = index },
                            onApply: { vm.applyTheme(at: index) },
                            onLongPress: theme.isDeletable ? {
                                deleteTarget = theme
                                showDeleteConfirmation = true
                            } : nil
                        )
                    }

                    addThemeGuideItem
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
        .background(Color(hex: 0x111825))
    }

    private var addThemeGuideItem: some View {
        let isSelected = vm.selectedIndex == vm.themes.count
        return Button {
            vm.selectedIndex = vm.themes.count
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 24))
                    .foregroundStyle(AppColors.orange)

                Text(String(localized: "theme_add_title"))
                    .font(.system(size: 15))
                    .foregroundStyle(AppColors.textPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.white.opacity(0.12) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? AppColors.orange : .clear, lineWidth: 1.5)
            )
        }
    }

    // MARK: - Preview Panel

    @ViewBuilder
    private var previewPanel: some View {
        if vm.selectedIndex == vm.themes.count {
            addThemePanel
        } else {
            themePreview
                .id(vm.selectedIndex)
                .transition(.opacity)
                .animation(.linear(duration: 0.4), value: vm.selectedIndex)
                .contentShape(Rectangle())
                .onTapGesture {
                    isFullscreen.toggle()
                }
        }
    }

    // MARK: - Theme Preview

    private var themePreview: some View {
        let resources = vm.selectedThemeResources
        return GeometryReader { geometry in
            let cols = 8
            let rows = 8
            let cellSize = min(
                geometry.size.width / CGFloat(cols),
                geometry.size.height / CGFloat(rows)
            )
            let gridWidth = cellSize * CGFloat(cols)
            let gridHeight = cellSize * CGFloat(rows)
            let offsetX = (geometry.size.width - gridWidth) / 2
            let offsetY = (geometry.size.height - gridHeight) / 2

            ZStack {
                // Background
                if let playbg = resources?.playbg {
                    Image(platformImage: playbg)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.black
                }

                // Custom logo
                if let customLogo = resources?.customLogo {
                    VStack {
                        HStack {
                            Spacer()
                            Image(platformImage: customLogo)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 90)
                                .padding(.top, 16)
                                .padding(.trailing, 16)
                        }
                        Spacer()
                    }
                }

                Canvas { context, _ in
                    let resolvedBtn = resources?.btn.flatMap { context.resolve(Image(platformImage: $0)) }
                    let resolvedBtnPressed = resources?.btnPressed.flatMap { context.resolve(Image(platformImage: $0)) }
                    let resolvedPhantom = resources?.phantom.flatMap { context.resolve(Image(platformImage: $0)) }
                    let resolvedPhantomVariant = resources?.phantomVariant.flatMap { context.resolve(Image(platformImage: $0)) }
                    let resolvedChainled = resources?.chainled.flatMap { context.resolve(Image(platformImage: $0)) }

                    let litCells: Set<String> = [
                        "1,2", "2,2", "3,2",
                        "1,3", "3,3",
                        "1,4", "2,4", "3,4",
                        "5,2", "6,2",
                        "5,3", "6,3", "7,3",
                        "5,4", "6,4",
                    ]
                    let litColors: [Color] = [
                        Color(hex: 0x00FF00).opacity(0.53),
                        Color(hex: 0xFF0000).opacity(0.53),
                        Color(hex: 0x0088FF).opacity(0.53),
                        Color(hex: 0xFFAA00).opacity(0.53),
                    ]

                    for y in 0..<rows {
                        for x in 0..<cols {
                            let rect = CGRect(
                                x: offsetX + CGFloat(x) * cellSize,
                                y: offsetY + CGFloat(y) * cellSize,
                                width: cellSize,
                                height: cellSize
                            )
                            let insetRect = rect.insetBy(dx: 1, dy: 1)
                            let key = "\(x),\(y)"
                            let isLit = litCells.contains(key)

                            if let btnImg = isLit ? resolvedBtnPressed : resolvedBtn {
                                context.draw(btnImg, in: insetRect)
                            } else {
                                context.fill(
                                    Path(roundedRect: insetRect, cornerRadius: 4),
                                    with: .color(Color(hex: 0x2A2A2A))
                                )
                            }

                            if isLit {
                                let color = litColors[(x + y) % litColors.count]
                                context.fill(
                                    Path(roundedRect: insetRect, cornerRadius: 4),
                                    with: .color(color)
                                )
                            }

                            // Phantom overlay (variant on center 4 cells for even grids)
                            let centerX = rows / 2 - 1
                            let centerY = cols / 2 - 1
                            let useVariant = rows % 2 == 0 && cols % 2 == 0 && resolvedPhantomVariant != nil
                            if useVariant {
                                let rotation: Angle?
                                if y == centerX && x == centerY { rotation = .degrees(0) }
                                else if y == centerX + 1 && x == centerY { rotation = .degrees(270) }
                                else if y == centerX && x == centerY + 1 { rotation = .degrees(90) }
                                else if y == centerX + 1 && x == centerY + 1 { rotation = .degrees(180) }
                                else { rotation = nil }

                                if let rot = rotation, let variant = resolvedPhantomVariant {
                                    let center = CGPoint(x: insetRect.midX, y: insetRect.midY)
                                    var rc = context
                                    rc.translateBy(x: center.x, y: center.y)
                                    rc.rotate(by: rot)
                                    rc.translateBy(x: -center.x, y: -center.y)
                                    rc.draw(variant, in: insetRect)
                                } else if let phantom = resolvedPhantom {
                                    context.draw(phantom, in: insetRect)
                                }
                            } else if let phantom = resolvedPhantom {
                                context.draw(phantom, in: insetRect)
                            }
                        }
                    }

                    // Chain column
                    let isChainLed = resources?.isChainLed ?? true
                    let resolvedChain = resources?.chain.flatMap { context.resolve(Image(platformImage: $0)) }

                    for i in 0..<rows {
                        let rect = CGRect(
                            x: offsetX + CGFloat(cols) * cellSize,
                            y: offsetY + CGFloat(i) * cellSize,
                            width: cellSize,
                            height: cellSize
                        )
                        let insetRect = rect.insetBy(dx: 1, dy: 1)

                        if isChainLed {
                            if let btnImg = resolvedBtn {
                                context.draw(btnImg, in: insetRect)
                            }
                            if i == 0 {
                                context.fill(
                                    Path(roundedRect: insetRect, cornerRadius: 4),
                                    with: .color(Color(hex: 0x00FF00).opacity(0.53))
                                )
                            }
                            if let chainledImg = resolvedChainled {
                                context.draw(chainledImg, in: insetRect)
                            }
                        } else {
                            if let chainImg = resolvedChain {
                                var ctx = context
                                ctx.opacity = i == 0 ? 1.0 : 0.5
                                ctx.draw(chainImg, in: insetRect)
                            }
                        }
                    }
                }
            }
            .clipped()
        }
    }

    // MARK: - Add Theme Panel

    private var addThemePanel: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "theme_add_title"))
                    .font(.system(size: 20))
                    .foregroundStyle(AppColors.textPrimary)

                addThemeOption(
                    icon: "folder",
                    title: String(localized: "theme_add_zip"),
                    subtitle: String(localized: "theme_add_zip_desc")
                ) {
                    showThemeZipPicker = true
                }

                addThemeOption(
                    icon: "pencil",
                    title: String(localized: "theme_add_create"),
                    subtitle: String(localized: "theme_add_create_desc")
                ) {
                    if let url = URL(string: "https://github.com/kimjisub/unipad-android/blob/main/docs/THEME_CREATION_GUIDE.md") {
                        PlatformHelpers.openURL(url)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(AppColors.textPrimary.opacity(0.4))

                    Text(String(localized: "theme_apk_deprecated"))
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.textPrimary.opacity(0.4))
                        .lineSpacing(4)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .frame(maxWidth: 320)
            .padding(24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(AppColors.background1)
    }

    private func addThemeOption(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(AppColors.orange)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15))
                        .foregroundStyle(AppColors.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textPrimary.opacity(0.5))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Theme List Item

private struct ThemeListItemView: View {
    let theme: ThemeViewModel.ThemeItem
    let isSelected: Bool
    let isApplied: Bool
    var onTap: () -> Void
    var onApply: () -> Void
    var onLongPress: (() -> Void)?

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if let icon = theme.icon {
                    Image(platformImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: 0x2A2A2A))
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: "paintpalette")
                                .foregroundStyle(AppColors.orange)
                        }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.name)
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        ThemeTypeBadge(type: theme.type)

                        Text([theme.author, theme.version].compactMap { $0 }.joined(separator: "  "))
                            .font(.system(size: 11))
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isApplied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22))
                        .foregroundStyle(AppColors.orange)
                } else if isSelected {
                    Button(action: onApply) {
                        Text(String(localized: "apply"))
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(AppColors.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? Color.white.opacity(0.12) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? AppColors.orange : .clear, lineWidth: 1.5)
            )
        }
        .simultaneousGesture(
            LongPressGesture().onEnded { _ in
                onLongPress?()
            }
        )
    }
}

// MARK: - Theme Type Badge

private struct ThemeTypeBadge: View {
    let type: ThemeViewModel.ThemeType

    private var label: String {
        switch type {
        case .builtin: String(localized: "theme_type_builtin")
        case .zip: String(localized: "theme_type_zip")
        }
    }

    private var badgeColor: Color {
        switch type {
        case .builtin: Color(hex: 0x4CAF50)
        case .zip: Color(hex: 0x42A5F5)
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(badgeColor.opacity(0.6), lineWidth: 1)
            )
    }
}
