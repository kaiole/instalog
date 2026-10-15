import InstalogCore
import SwiftUI

@main
struct InstalogApp: App {
    @State private var model: DiaryModel?
    @State private var startupError: String?

    init() {
        Typeface.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let model, let loadError = model.loadError, !model.isLoaded {
                    // Never show an empty app over data that failed to load.
                    StartupErrorView(message: loadError) { await model.load() }
                } else if let model {
                    RootView(model: model)
                } else if let startupError {
                    StartupErrorView(message: startupError) {
                        self.startupError = nil
                        await start()
                    }
                } else {
                    Palette.background.ignoresSafeArea()
                }
            }
            .preferredColorScheme(.dark)
            .task { await start() }
        }
    }

    private func start() async {
        guard model == nil else { return }
        do {
            let url = try SQLitePersonalStore.defaultURL()
            #if DEBUG
            if CommandLine.arguments.contains("--reset-data") {
                for suffix in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(atPath: url.path + suffix)
                }
            }
            #endif
            let store = try SQLitePersonalStore(url: url)
            // Search still works for saved meals and custom foods if the catalog can't open.
            let catalog = try? SQLiteFoodCatalog.bundled()
            let diary = DiaryModel(store: store, catalog: catalog)
            await diary.load()
            model = diary
        } catch {
            startupError = "Couldn’t open your data. \(error.localizedDescription)"
        }
    }
}

struct StartupErrorView: View {
    let message: String
    let retry: () async -> Void
    @State private var isRetrying = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(Palette.dangerText)
                .frame(width: 56, height: 56)
                .background(Palette.dangerSurface, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                .accessibilityHidden(true)
            Text("Couldn’t open your food log")
                .font(Typeface.title2)
                .accessibilityAddTraits(.isHeader)
            Text("Your entries are still on this iPhone. Something stopped Instalog from reading them just now. Trying again usually fixes it.")
                .font(Typeface.body)
                .foregroundStyle(Palette.secondary)
            Button {
                isRetrying = true
                Task {
                    await retry()
                    isRetrying = false
                }
            } label: {
                if isRetrying { ProgressView().tint(Palette.onAccent) } else { Text("Try again") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isRetrying)
            .padding(.top, Spacing.s)
            DisclosureGroup("Technical details") {
                Text(message)
                    .font(Typeface.numFootnote)
                    .foregroundStyle(Palette.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Spacing.s)
            }
            .font(Typeface.body)
            .tint(Palette.secondary)
            .padding(Spacing.l)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
            Text("Nothing was deleted. If this keeps happening, restart your iPhone, then try again.")
                .font(Typeface.footnote)
                .foregroundStyle(Palette.secondary)
        }
        .foregroundStyle(Palette.text)
        .padding(.horizontal, Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }
}

/// Every sheet the main screen can present.
enum ActiveSheet: Identifiable {
    case sections
    case addFood(destinationID: String, date: LogDate)
    case settings
    case setup
    case nutrients
    case day
    case newMeal
    case editMeal(UUID)
    case schedule(ScheduleEditorTarget)

    var id: String {
        switch self {
        case .sections: "sections"
        case .addFood(let destination, let date): "add-\(destination)-\(date)"
        case .settings: "settings"
        case .setup: "setup"
        case .nutrients: "nutrients"
        case .day: "day"
        case .newMeal: "newMeal"
        case .editMeal(let id): "meal-\(id)"
        case .schedule(let target): "schedule-\(target.id)"
        }
    }
}

struct RootView: View {
    let model: DiaryModel
    @State private var sheet: ActiveSheet?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TodayView(model: model, sheet: $sheet)
            .sheet(item: $sheet) { sheet in
                sheetContent(sheet)
                    .errorAlert(model)
                    .presentationBackground(Palette.sheet)
                    .presentationCornerRadius(28)
                    .presentationDragIndicator(.visible)
                    .preferredColorScheme(.dark)
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { model.errorMessage != nil && sheet == nil }, set: { if !$0 { model.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            // While the app is open, scheduled meals log at their time; on return they catch up.
            .task(id: scenePhase == .active) {
                guard scenePhase == .active else { return }
                await model.tick(isIdle: sheet == nil)
                await ScheduleNotifier.reconcile(model)
                while !Task.isCancelled {
                    let untilNext = model.nextOccurrenceInstant.map { $0.timeIntervalSinceNow + 1 } ?? 60
                    try? await Task.sleep(for: .seconds(min(60, max(1, untilNext))))
                    guard !Task.isCancelled else { break }
                    await model.tick(isIdle: sheet == nil)
                }
            }
            .onChange(of: model.scheduleRevision) {
                Task { await ScheduleNotifier.reconcile(model) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                Task { await model.refreshForCurrentDate(isIdle: sheet == nil) }
            }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ActiveSheet) -> some View {
        let close = { self.sheet = nil }
        switch sheet {
        case .sections:
            SectionsSheet(model: model, close: close, editRoutine: { self.sheet = .setup })
                .presentationDetents([.medium, .large])
        case .addFood(let destinationID, let date):
            AddFoodSheet(
                model: model,
                destination: model.destinations.first { $0.id == destinationID } ?? model.currentDestination,
                date: date, close: close)
        case .settings:
            SettingsSheet(model: model, close: close)
        case .setup:
            NavigationStack { SetupView(model: model, close: close) }
        case .nutrients:
            NutrientsSheet(model: model, close: close, openSettings: { self.sheet = .settings })
        case .day:
            DayPickerSheet(model: model, close: close)
                .presentationDetents([.height(520), .large])
        case .newMeal:
            NavigationStack { MealEditorView(model: model, meal: nil, onDone: close) }
        case .editMeal(let id):
            NavigationStack { MealEditorView(model: model, meal: model.meal(id: id), onDone: close) }
        case .schedule(let target):
            ScheduleEditorView(model: model, target: target, close: close)
        }
    }
}
