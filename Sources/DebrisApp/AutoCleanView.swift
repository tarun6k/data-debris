import SwiftUI
import DebrisCore

extension AutoCleanFrequency {
    var displayName: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}

extension AutoCleanNotify {
    var displayName: String {
        switch self {
        case .always: return "Always"
        case .overOneGB: return "Only if over 1 GB"
        case .never: return "Never"
        }
    }
}

/// Screen 8: opt-in scheduled cleaning, limited to the categories ticked
/// here. Always to the Trash (S3); nothing is ticked by default (S9).
struct AutoCleanView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmingEnable = false

    private var config: AutoCleanConfig { model.autoCleanConfig }

    var body: some View {
        Form {
            if !model.entitlementState.isEntitled {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "lock")
                            .foregroundStyle(.secondary)
                        Text("Auto Clean is part of the paid plan — scanning stays free.")
                            .font(.system(size: 12))
                        Spacer()
                        Button("Choose a plan") { model.startPurchase() }
                            .controlSize(.small)
                    }
                }
            }
            Section {
                Toggle("Auto Clean", isOn: enabledBinding)
                    .toggleStyle(.switch)
                Text(model.autoCleanStatusLine)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Group {
                scheduleSection
                categoriesSection
                notifySection
                runNowSection
            }
            .disabled(!config.enabled)
        }
        .formStyle(.grouped)
        .navigationTitle("Auto Clean")
        .onAppear { model.refreshEntitlement() }
        .sheet(isPresented: $confirmingEnable) {
            AutoCleanEnableSheet {
                Task {
                    _ = await AutoCleanNotifier.requestPermission()
                    model.setAutoCleanEnabled(true)
                }
            }
        }
    }

    /// Turning on goes through the confirmation sheet; the switch only flips
    /// once the sheet is confirmed.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { config.enabled },
            set: { on in
                if on { confirmingEnable = true } else { model.setAutoCleanEnabled(false) }
            })
    }

    private func bind<T>(_ keyPath: WritableKeyPath<AutoCleanConfig, T>) -> Binding<T> {
        Binding(
            get: { model.autoCleanConfig[keyPath: keyPath] },
            set: { value in model.updateAutoClean { $0[keyPath: keyPath] = value } })
    }

    // MARK: - Schedule

    private var scheduleSection: some View {
        Section("Schedule") {
            Picker("Frequency", selection: bind(\.schedule.frequency)) {
                ForEach(AutoCleanFrequency.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            if config.schedule.frequency == .weekly {
                Picker("Day", selection: bind(\.schedule.weekday)) {
                    ForEach(1...7, id: \.self) { weekday in
                        Text(Calendar.current.weekdaySymbols[weekday - 1]).tag(weekday)
                    }
                }
            }
            if config.schedule.frequency == .monthly {
                LabeledContent("Day", value: "1st of the month")
            }
            DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
            Toggle("Also run when free space drops below", isOn: lowSpaceBinding)
            if let gb = config.lowSpaceTriggerGB {
                Stepper("\(gb) GB", value: lowSpaceGBBinding, in: 5...500, step: 5)
                    .monospacedDigit()
            }
        }
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(
                    hour: config.schedule.hour, minute: config.schedule.minute)) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.updateAutoClean {
                    $0.schedule.hour = parts.hour ?? 3
                    $0.schedule.minute = parts.minute ?? 0
                }
            })
    }

    private var lowSpaceBinding: Binding<Bool> {
        Binding(
            get: { config.lowSpaceTriggerGB != nil },
            set: { on in model.updateAutoClean { $0.lowSpaceTriggerGB = on ? 10 : nil } })
    }

    private var lowSpaceGBBinding: Binding<Int> {
        Binding(
            get: { config.lowSpaceTriggerGB ?? 10 },
            set: { gb in model.updateAutoClean { $0.lowSpaceTriggerGB = gb } })
    }

    // MARK: - Categories

    private var categoriesSection: some View {
        Section {
            ForEach(model.autoCleanCategories, id: \.self) { category in
                categoryRow(category)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manual only: Duplicates, Large & old files, Xcode Archives")
                        .font(.system(size: 12))
                    Text("These always need your review before anything is removed.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Categories")
        } footer: {
            Text("Auto Clean removes only what is ticked here, and only to the Trash.")
        }
    }

    @ViewBuilder
    private func categoryRow(_ category: Category) -> some View {
        HStack(spacing: 10) {
            TriStateCheckbox(state: model.autoCleanState(for: category)) {
                model.toggleAutoCleanCategory(category)
            }
            Text(category.displayName)
        }
        if category == .appCaches {
            Toggle("Exclude browser caches", isOn: bind(\.browserCachesExcluded))
                .padding(.leading, 26)
                .disabled(model.autoCleanState(for: category) == CategoryState.none)
        }
        if category == .developer {
            developerAgeRow
                .padding(.leading, 26)
                .disabled(model.autoCleanState(for: category) == CategoryState.none)
        }
    }

    private var developerAgeRow: some View {
        HStack {
            Toggle("Only items older than", isOn: Binding(
                get: { config.developerMinAgeDays != nil },
                set: { on in model.updateAutoClean { $0.developerMinAgeDays = on ? 30 : nil } }))
            if let days = config.developerMinAgeDays {
                Stepper("\(days) days", value: Binding(
                    get: { config.developerMinAgeDays ?? 30 },
                    set: { value in model.updateAutoClean { $0.developerMinAgeDays = value } }),
                    in: 7...365, step: 7)
                .monospacedDigit()
            }
        }
    }

    // MARK: - Notify / run now

    private var notifySection: some View {
        Section("Notification") {
            Picker("Notify after a run", selection: bind(\.notify)) {
                ForEach(AutoCleanNotify.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
        }
    }

    private var runNowSection: some View {
        Section {
            HStack(spacing: 12) {
                Button("Run now") { model.runAutoCleanNow() }
                    .disabled(model.autoCleanRunning)
                if model.autoCleanRunning {
                    ProgressView().controlSize(.small)
                }
                if let outcome = model.autoCleanLastOutcome {
                    Text(outcome)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

/// The confirmation shown before Auto Clean turns on: what runs, where items
/// go, and why notification permission is requested next.
private struct AutoCleanEnableSheet: View {
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Turn on Auto Clean")
                .font(.system(size: 15, weight: .semibold))
            Text("""
                Auto Clean runs on your schedule and removes only the categories \
                ticked on this screen. Items always go to the Trash — nothing is \
                deleted permanently. After each run a notification lets you undo \
                it for 24 hours, which is why Data Debris asks for notification \
                permission next.
                """)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Turn On Auto Clean") {
                    confirm()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.teal)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
