import SwiftUI

struct DuplicateFinderView: View {
    @EnvironmentObject private var model: DuplicateFinderModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.separator.opacity(0.55))
                .frame(height: 1)
            content
        }
        .background(Color.appBackground)
        .alert(item: $model.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onDisappear {
            if model.isScanning { model.cancelScan() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Дубликаты файлов")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primaryText)
                Text("Полное сравнение содержимого в выбранной папке")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondaryText)
            }

            Spacer()

            if model.isScanning {
                Button(action: model.cancelScan) {
                    Label("Остановить", systemImage: "stop.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
            } else if model.result != nil {
                Button(action: model.repeatScan) {
                    Label("Повторить", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Button(action: model.chooseFolder) {
                Label("Выбрать папку…", systemImage: "folder")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.isScanning)
        }
        .padding(.horizontal, 20)
        .frame(height: 68)
        .background(Color.panel.opacity(0.78))
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            DuplicateScanProgressView(progress: model.progress, rootURL: model.rootURL)
        } else if let result = model.result {
            DuplicateResultsView(result: result)
        } else {
            DuplicateWelcomeView(chooseFolder: model.chooseFolder)
        }
    }
}

private struct DuplicateWelcomeView: View {
    let chooseFolder: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.accentMint.opacity(0.08))
                    .frame(width: 132, height: 132)
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(Color.accentMint)
            }
            Text("Найдём байт-в-байт одинаковые файлы")
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primaryText)
            Text("Выберите конкретную папку или локальный диск. DiskBloom сначала сравнит размеры, затем полностью прочитает совпавшие кандидаты, вычислит SHA‑256 и подтвердит каждую группу побайтово. Имена и даты не влияют на результат.")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 650)
            HStack(spacing: 12) {
                Label("только чтение", systemImage: "eye")
                Label("полное содержимое", systemImage: "checkmark.seal")
                Label("точные пути", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.accentMint)
            Button(action: chooseFolder) {
                Label("Выбрать папку для анализа", systemImage: "folder.badge.magnifyingglass")
            }
            .buttonStyle(PrimaryButtonStyle())
            Text("Символические ссылки, hard link, скрытые файлы, пакеты приложений, другие тома и незагруженные облачные файлы пропускаются.")
                .font(.system(size: 9.5))
                .foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

private struct DuplicateScanProgressView: View {
    let progress: DuplicateScanProgress
    let rootURL: URL?

    private var progressFraction: Double? {
        guard progress.stage != .enumerating, progress.candidateFileCount > 0 else { return nil }
        return min(1, Double(progress.processedCandidateCount) / Double(progress.candidateFileCount))
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.055), lineWidth: 11)
                    .frame(width: 124, height: 124)
                Circle()
                    .trim(from: 0, to: progressFraction ?? 0.74)
                    .stroke(
                        Color.accentMint,
                        style: StrokeStyle(lineWidth: 11, lineCap: .round)
                    )
                    .frame(width: 124, height: 124)
                    .rotationEffect(.degrees(-90))
                Image(systemName: progress.stage == .verifying ? "checkmark.seal" : "doc.text.magnifyingglass")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Color.accentMint)
            }
            Text(progress.stage.title)
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primaryText)
            if let rootURL {
                Text(rootURL.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 680)
            }
            HStack(spacing: 18) {
                Label("\(progress.examinedFileCount.formatted()) проверено", systemImage: "doc")
                if progress.candidateFileCount > 0 {
                    Label("\(progress.processedCandidateCount.formatted()) из \(progress.candidateFileCount.formatted()) кандидатов", systemImage: "number")
                }
                if progress.bytesRead > 0 {
                    Label("прочитано \(ByteFormat.compact(progress.bytesRead))", systemImage: "externaldrive")
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Color.secondaryText)
            if !progress.currentPath.isEmpty {
                Text(progress.currentPath)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Color.secondaryText.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 620)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

private struct DuplicateResultsView: View {
    @EnvironmentObject private var model: DuplicateFinderModel
    let result: DuplicateScanResult

    var body: some View {
        VStack(spacing: 0) {
            resultSummary
            if result.groups.isEmpty {
                DuplicateEmptyResultView(result: result)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(result.groups) { group in
                            DuplicateGroupCard(group: group)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private var resultSummary: some View {
        VStack(spacing: 11) {
            HStack(spacing: 10) {
                DuplicateSummaryChip(
                    icon: "square.stack.3d.up.fill",
                    value: result.groups.count.formatted(),
                    label: "групп"
                )
                DuplicateSummaryChip(
                    icon: "doc.on.doc.fill",
                    value: result.duplicateFileCount.formatted(),
                    label: "лишних копий"
                )
                DuplicateSummaryChip(
                    icon: "internaldrive",
                    value: ByteFormat.compact(result.logicalDuplicateBytes),
                    label: "логический размер"
                )
                Spacer()
                Text(result.finishedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.secondaryText)
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Color.accentMint)
                Text("Совпадение подтверждено для содержимого data fork. Имена, даты, теги, расширенные атрибуты и resource fork могут различаться. «Логический размер» — верхняя оценка объёма копий, а не обещание физически освобождённого места на APFS.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(11)
            .background(Color.accentMint.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 13) {
                Label("\(result.examinedFileCount.formatted()) файлов просмотрено", systemImage: "magnifyingglass")
                Label("\(result.hashedFileCount.formatted()) хешировано", systemImage: "number.square")
                if totalSkipped > 0 {
                    Label("\(totalSkipped.formatted()) безопасно пропущено", systemImage: "arrowshape.turn.up.right")
                }
                Spacer()
                Text(result.rootURL.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(result.rootURL.path)
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(Color.secondaryText)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var totalSkipped: Int {
        result.skippedSymbolicLinkCount
            + result.skippedPackageCount
            + result.skippedMountCount
            + result.skippedCloudPlaceholderCount
            + result.skippedHardLinkCount
            + result.unreadableOrChangedCount
    }
}

private struct DuplicateSummaryChip: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentMint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primaryText)
                Text(label)
                    .font(.system(size: 8.5))
                    .foregroundStyle(Color.secondaryText)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 45)
        .background(Color.panelElevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.055), lineWidth: 1))
    }
}

private struct DuplicateGroupCard: View {
    @EnvironmentObject private var model: DuplicateFinderModel
    let group: DuplicateFileGroup

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.accentMint.opacity(0.1))
                        .frame(width: 38, height: 38)
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentMint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(group.files.count.formatted()) \(RussianPlural.files(group.files.count)) совпадают байт-в-байт")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(Color.primaryText)
                    Text("SHA‑256  \(shortDigest)")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteFormat.compact(group.logicalSize))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.primaryText)
                    Text("копии: \(ByteFormat.compact(group.logicalDuplicateBytes)) логически")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Color.secondaryText)
                }
            }
            .padding(13)

            Rectangle().fill(Color.separator.opacity(0.55)).frame(height: 1)

            VStack(spacing: 0) {
                ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                    DuplicateFileRow(file: file)
                    if index < group.files.count - 1 {
                        Rectangle()
                            .fill(Color.separator.opacity(0.38))
                            .frame(height: 1)
                            .padding(.leading, 47)
                    }
                }
            }
        }
        .background(Color.panelElevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.055), lineWidth: 1))
    }

    private var shortDigest: String {
        let prefix = group.digest.prefix(12)
        let suffix = group.digest.suffix(8)
        return "\(prefix)…\(suffix)"
    }
}

private struct DuplicateFileRow: View {
    @EnvironmentObject private var model: DuplicateFinderModel
    let file: DuplicateFileSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.url.lastPathComponent)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(1)
                Text(file.url.path)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.url.path)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(file.modificationDate.formatted(date: .abbreviated, time: .shortened))
                Text("на диске \(ByteFormat.string(file.allocatedSize))")
            }
            .font(.system(size: 8.5))
            .foregroundStyle(Color.secondaryText)
            Button {
                model.revealInFinder(file)
            } label: {
                Image(systemName: "finder")
            }
            .buttonStyle(IconButtonStyle())
            .help("Показать точный файл в Finder")
            .accessibilityLabel("Показать \(file.url.path) в Finder")
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 53)
    }
}

private struct DuplicateEmptyResultView: View {
    let result: DuplicateScanResult

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.accentMint)
            Text("Подтверждённых дубликатов не найдено")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primaryText)
            Text("В выбранной области нет двух доступных ненулевых файлов с полностью одинаковым содержимым. Пропущенные объекты не входят в этот вывод.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            Text("Проверено \(result.examinedFileCount.formatted()) файлов за \(String(format: "%.1f", result.duration)) с")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}
