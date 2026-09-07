import AppKit
import SwiftUI

struct OrphanedAppDataView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var model: OrphanedAppDataModel

    private let onBack: (() -> Void)?

    init(onBack: (() -> Void)? = nil) {
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.separator.opacity(0.55))
                .frame(height: 1)
            content
            if model.analysis != nil, !model.isScanning, !model.groups.isEmpty {
                selectionBar
            }
        }
        .background(Color.appBackground)
        .sheet(isPresented: $model.showingReview) {
            OrphanDataReviewSheet()
                .environmentObject(model)
                .frame(width: 790, height: 650)
        }
        .sheet(isPresented: $model.showingOutcomeReport) {
            if let outcome = model.lastOutcome {
                OrphanDataOutcomeView(outcome: outcome)
                    .environmentObject(model)
                    .frame(width: 790, height: 650)
            }
        }
        .alert(item: $model.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onDisappear {
            if model.isScanning { model.cancelAnalysis() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                if let onBack {
                    onBack()
                } else {
                    appModel.selectWorkspaceSection(.appUninstaller)
                }
            } label: {
                Label("К приложениям", systemImage: "chevron.left")
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
            .disabled(model.isNavigationLocked || model.isScanning)

            VStack(alignment: .leading, spacing: 3) {
                Text("Возможные остатки приложений")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primaryText)
                Text("Точные папки bundle ID в пользовательской Library")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondaryText)
            }

            Spacer()

            if model.lastOutcome != nil, !model.showingOutcomeReport {
                Button {
                    model.showingOutcomeReport = true
                } label: {
                    Label("Отчёт", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isScanning || model.isMovingToTrash)
            }

            if model.isScanning {
                Button(action: model.cancelAnalysis) {
                    Label("Остановить", systemImage: "stop.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
            } else {
                Button(action: model.startAnalysis) {
                    Label(model.analysis == nil ? "Начать анализ" : "Повторить анализ", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isNavigationLocked || model.hasUncertainOutcome)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 68)
        .background(Color.panel.opacity(0.78))
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            OrphanAnalysisProgressView()
        } else if let analysis = model.analysis {
            if analysis.groups.isEmpty {
                OrphanEmptyView(analysis: analysis)
            } else {
                results(analysis)
            }
        } else {
            OrphanWelcomeView(startAnalysis: model.startAnalysis)
        }
    }

    private func results(_ analysis: OrphanDataAnalysis) -> some View {
        VStack(spacing: 0) {
            OrphanWarningStrip(
                icon: "exclamationmark.shield.fill",
                title: "Это кандидаты, а не доказанные остатки",
                message: "DiskBloom не нашёл текущего владельца среди установленных, встроенных, запущенных и зарегистрированных компонентов. Перед очисткой проверьте каждый точный путь. Произвольные документы вне Library здесь не показываются.",
                tone: .warning
            )
            .padding(.horizontal, 18)
            .padding(.top, 14)

            HStack(spacing: 14) {
                Label("\(analysis.groups.count.formatted()) bundle ID", systemImage: "shippingbox")
                Label("\(analysis.examinedPathCount.formatted()) путей проверено", systemImage: "magnifyingglass")
                if analysis.protectedGroupCount > 0 {
                    Label("\(analysis.protectedGroupCount.formatted()) защищено", systemImage: "lock.shield")
                }
                if analysis.skippedUnsafePathCount > 0 {
                    Label("\(analysis.skippedUnsafePathCount.formatted()) небезопасных пропущено", systemImage: "exclamationmark.triangle")
                }
                Spacer()
                Text(analysis.scannedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(Color.secondaryText)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ScrollView {
                LazyVStack(spacing: 11) {
                    ForEach(analysis.groups) { group in
                        OrphanGroupCard(group: group)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedItems.isEmpty ? "Ничего не выбрано" : "Выбрано: \(model.selectedItems.count.formatted())")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.primaryText)
                Text(model.selectedItems.isEmpty ? "Каждая папка изначально выключена" : ByteFormat.string(model.selectedSize))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondaryText)
            }

            if model.needsExtraAcknowledgement, !model.selectedItems.isEmpty {
                Label("есть возможные пользовательские данные", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.orange)
            }

            Spacer()

            if model.isReviewing {
                ProgressView()
                    .controlSize(.small)
                Text("Повторная проверка…")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.secondaryText)
            }

            Button(action: model.requestReview) {
                Label("Проверить перед удалением", systemImage: "checkmark.shield")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.selectedItems.isEmpty || model.isReviewing || model.isMovingToTrash || model.hasUncertainOutcome)
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
        .background(Color.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.separator.opacity(0.65)).frame(height: 1)
        }
    }
}

private struct OrphanWelcomeView: View {
    let startAnalysis: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.accentMint.opacity(0.08))
                    .frame(width: 132, height: 132)
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Color.accentMint)
            }
            Text("Найдём папки без текущего владельца")
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primaryText)
            Text("Анализ ограничен точными app-managed папками в вашей Library. DiskBloom сравнит их bundle ID с установленными, встроенными, работающими и зарегистрированными приложениями. Ничего не будет выбрано или удалено автоматически.")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 610)
            HStack(spacing: 10) {
                Label("точные пути", systemImage: "point.3.connected.trianglepath.dotted")
                Label("выбор вручную", systemImage: "checklist")
                Label("только в Корзину", systemImage: "trash")
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.accentMint)
            Button(action: startAnalysis) {
                Label("Начать анализ", systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(PrimaryButtonStyle())
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

private struct OrphanAnalysisProgressView: View {
    @EnvironmentObject private var model: OrphanedAppDataModel

    var body: some View {
        VStack(spacing: 17) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Анализируем пользовательскую Library")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primaryText)
            Text("Проверено объектов: \(model.progress.itemCount.formatted())")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.accentMint)
            Text(model.progress.currentPath)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Color.secondaryText)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 650)
            Text("Удаление во время анализа невозможно")
                .font(.system(size: 10))
                .foregroundStyle(Color.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

private struct OrphanEmptyView: View {
    let analysis: OrphanDataAnalysis

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Color.accentMint)
            Text("Кандидаты не найдены")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primaryText)
            Text("Проверено \(analysis.examinedPathCount.formatted()) точных путей. Папки с найденным владельцем, небезопасные пути и объекты вне пользовательской Library не включены в результат. Это не доказывает отсутствие других остатков.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 560)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

private struct OrphanGroupCard: View {
    @EnvironmentObject private var model: OrphanedAppDataModel

    let group: OrphanDataGroup

    private var confidenceColor: Color {
        group.confidence == .probable ? Color.accentMint : Color.orange
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: group.confidence == .probable ? "shippingbox.fill" : "questionmark.folder.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(confidenceColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.identifier)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primaryText)
                        .textSelection(.enabled)
                    Text(group.confidence.explanation)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(group.confidence.title)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(confidenceColor)
                    Text("\(group.items.count.formatted()) папок · \(ByteFormat.string(group.totalSize))")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.secondaryText)
                }
            }
            .padding(13)

            Rectangle().fill(Color.separator.opacity(0.5)).frame(height: 1)

            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    OrphanPathRow(item: item)
                    if index < group.items.count - 1 {
                        Rectangle()
                            .fill(Color.separator.opacity(0.35))
                            .frame(height: 1)
                            .padding(.leading, 48)
                    }
                }
            }
        }
        .background(Color.panel.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.065), lineWidth: 1))
    }
}

private struct OrphanPathRow: View {
    @EnvironmentObject private var model: OrphanedAppDataModel

    let item: OrphanDataItem

    private var isSelected: Bool { model.selectedItemIDs.contains(item.id) }
    private var wasMoved: Bool { model.confirmedMovedItemIDs.contains(item.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { model.toggle(item) } label: {
                Image(systemName: wasMoved ? "checkmark.circle.fill" : isSelected ? "checkmark.square.fill" : item.isSelectable ? "square" : "lock.square.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(wasMoved ? Color.accentMint : isSelected ? Color.accentMint : Color.secondaryText)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!item.isSelectable || wasMoved || model.isReviewing || model.isMovingToTrash || model.hasUncertainOutcome)
            .accessibilityLabel("Выбрать \(item.rule.title): \(item.url.path)")
            .accessibilityValue(
                wasMoved ? "подтверждено в Корзине"
                    : !item.isSelectable ? "недоступно"
                    : isSelected ? "выбрано"
                    : "не выбрано"
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.rule.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                    Text(item.risk.title)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(item.risk.needsExtraAcknowledgement ? Color.orange : Color.accentMint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((item.risk.needsExtraAcknowledgement ? Color.orange : Color.accentMint).opacity(0.11), in: Capsule())
                    if wasMoved {
                        Text("В КОРЗИНЕ")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color.accentMint)
                    }
                    Spacer()
                    Text(ByteFormat.string(item.node.size))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primaryText)
                }
                Text(item.url.path)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let issue = item.eligibilityIssue {
                    Label(issue, systemImage: "lock.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button { model.reveal(item) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(IconButtonStyle())
            .help("Показать в Finder")
            .accessibilityLabel("Показать \(item.rule.title) в Finder: \(item.url.path)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentMint.opacity(0.055) : Color.clear)
    }
}

private struct OrphanDataReviewSheet: View {
    @EnvironmentObject private var model: OrphanedAppDataModel
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledgedRisk = false

    private var requiresAcknowledgement: Bool { model.needsExtraAcknowledgement }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentMint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Проверка точных путей")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primaryText)
                    Text("Выбрано \(model.selectedItems.count.formatted()) · \(ByteFormat.string(model.selectedSize))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
                Button("Отмена") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isMovingToTrash)
            }
            .padding(20)

            Rectangle().fill(Color.separator.opacity(0.55)).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    OrphanWarningStrip(
                        icon: "trash.fill",
                        title: "Папки будут перемещены в Корзину",
                        message: "DiskBloom ещё раз проверит владельцев, точный путь и снимок содержимого непосредственно перед каждым перемещением. Автоматическое окончательное удаление не выполняется.",
                        tone: .neutral
                    )

                    VStack(spacing: 0) {
                        ForEach(Array(model.selectedItems.enumerated()), id: \.element.id) { index, item in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(item.rule.title)
                                        .font(.system(size: 11.5, weight: .bold))
                                        .foregroundStyle(Color.primaryText)
                                    Text(item.risk.title)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(item.risk.needsExtraAcknowledgement ? Color.orange : Color.accentMint)
                                    Spacer()
                                    Text(ByteFormat.string(item.node.size))
                                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.primaryText)
                                }
                                Text(item.url.path)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(Color.secondaryText)
                                    .textSelection(.enabled)
                                Text(item.risk.warning)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Color.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(12)
                            if index < model.selectedItems.count - 1 {
                                Rectangle().fill(Color.separator.opacity(0.4)).frame(height: 1)
                            }
                        }
                    }
                    .background(Color.panel.opacity(0.76), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.06), lineWidth: 1))

                    if requiresAcknowledgement {
                        Button { acknowledgedRisk.toggle() } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: acknowledgedRisk ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(acknowledgedRisk ? Color.orange : Color.secondaryText)
                                Text("Я проверил точные пути и понимаю, что выбранные папки могут содержать документы, проекты, настройки, сеансы, cookies или другие пользовательские данные.")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Color.primaryText)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.25), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
            }

            Rectangle().fill(Color.separator.opacity(0.55)).frame(height: 1)

            HStack {
                Label("Операцию можно отменить из Корзины до её очистки", systemImage: "arrow.uturn.backward.circle")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                Button(action: model.moveReviewedItemsToTrash) {
                    Label("Переместить выбранное в Корзину", systemImage: "trash.fill")
                }
                .buttonStyle(DangerButtonStyle())
                .disabled(model.selectedItems.isEmpty || model.isMovingToTrash || (requiresAcknowledgement && !acknowledgedRisk))
            }
            .padding(.horizontal, 20)
            .frame(height: 64)
            .background(Color.panel)
        }
        .background(Color.appBackground)
        .interactiveDismissDisabled(model.isMovingToTrash)
        .onAppear { acknowledgedRisk = false }
    }
}

private struct OrphanDataOutcomeView: View {
    @EnvironmentObject private var model: OrphanedAppDataModel
    @State private var acknowledgedManualResolution = false

    let outcome: OrphanCleanupOutcome

    private var isCleanSuccess: Bool {
        outcome.failure == nil && outcome.uncertainPaths.isEmpty && outcome.unattemptedPaths.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: isCleanSuccess ? "checkmark.circle.fill" : outcome.uncertainPaths.isEmpty ? "exclamationmark.triangle.fill" : "questionmark.diamond.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(isCleanSuccess ? Color.accentMint : Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isCleanSuccess ? "Перемещение подтверждено" : "Отчёт о перемещении")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primaryText)
                    Text("Ни один объект не удалялся безвозвратно")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
                if model.isReviewing {
                    ProgressView().controlSize(.small)
                    Text("Проверяем…")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondaryText)
                }
            }
            .padding(20)

            Rectangle().fill(Color.separator.opacity(0.55)).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !outcome.movedPaths.isEmpty {
                        OrphanReportSection(
                            title: "Подтверждено в Корзине",
                            icon: "checkmark.circle.fill",
                            color: .accentMint,
                            paths: outcome.movedPaths
                        )
                    }
                    if !outcome.uncertainPaths.isEmpty {
                        OrphanReportSection(
                            title: "Результат не подтверждён",
                            icon: "questionmark.diamond.fill",
                            color: .orange,
                            paths: outcome.uncertainPaths
                        )
                        OrphanWarningStrip(
                            icon: "hand.raised.fill",
                            title: "Автоматический повтор заблокирован",
                            message: "Исходный путь исчез, но объект в Корзине не удалось однозначно подтвердить. Проверьте Корзину вручную или запустите повторную проверку состояния.",
                            tone: .danger
                        )
                        Button { acknowledgedManualResolution.toggle() } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: acknowledgedManualResolution ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(acknowledgedManualResolution ? Color.orange : Color.secondaryText)
                                Text("Я проверю Корзину и исходный путь вручную. Я понимаю, что DiskBloom не подтвердил результат и не будет автоматически повторять перемещение.")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Color.primaryText)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.25), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    if !outcome.unattemptedPaths.isEmpty {
                        OrphanReportSection(
                            title: "Не предпринимались",
                            icon: "pause.circle.fill",
                            color: .secondaryText,
                            paths: outcome.unattemptedPaths
                        )
                    }
                    if let failure = outcome.failure {
                        OrphanWarningStrip(
                            icon: "exclamationmark.triangle.fill",
                            title: "Операция остановлена",
                            message: failure,
                            tone: .danger
                        )
                    }
                }
                .padding(18)
            }

            Rectangle().fill(Color.separator.opacity(0.55)).frame(height: 1)

            HStack(spacing: 10) {
                if model.hasUncertainOutcome {
                    Button(action: model.recheckUncertainOutcome) {
                        Label("Проверить спорный результат", systemImage: "arrow.clockwise.circle")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isReviewing || model.isMovingToTrash)
                    Spacer()
                    Button(action: model.acknowledgeUncertainOutcomeAfterManualCheck) {
                        Label("Закрыть без повтора", systemImage: "hand.raised.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(
                        !acknowledgedManualResolution
                            || model.isReviewing
                            || model.isMovingToTrash
                    )
                } else {
                    Button(action: model.clearLastOutcome) {
                        Text("Готово")
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Spacer()

                    Button {
                        model.clearLastOutcome()
                        model.startAnalysis()
                    } label: {
                        Label("Обновить анализ", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 64)
            .background(Color.panel)
        }
        .background(Color.appBackground)
        .interactiveDismissDisabled(model.isMovingToTrash || model.hasUncertainOutcome)
    }
}

private struct OrphanReportSection: View {
    let title: String
    let icon: String
    let color: Color
    let paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("\(title) (\(paths.count.formatted()))", systemImage: icon)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(paths, id: \.self) { path in
                    Text(path)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color.primaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(11)
            .background(Color.panel.opacity(0.75), in: RoundedRectangle(cornerRadius: 9))
        }
    }
}

private struct OrphanWarningStrip: View {
    enum Tone {
        case neutral
        case warning
        case danger

        var color: Color {
            switch self {
            case .neutral: Color.accentMint
            case .warning: Color.orange
            case .danger: Color.danger
            }
        }
    }

    let icon: String
    let title: String
    let message: String
    let tone: Tone

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tone.color)
                .frame(width: 19)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.primaryText)
                Text(message)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(tone.color.opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tone.color.opacity(0.2), lineWidth: 1))
    }
}
