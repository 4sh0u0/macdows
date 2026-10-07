import AppKit
import SwiftUI

/// UI slice ③ (UI-1 spec §1 / §3 / §4.6): the four Settings pages, SwiftUI content hosted in the
/// AppKit Settings window (`SettingsWindowController`). Each page is a grouped form -- standard
/// material cards, content layer, no glass (§3 material rule) -- built from `SettingsModel`: a
/// choice is enabled only when it is the behaviour the App has today, every other one is disabled
/// and labelled Coming later (§7.1: not by dimming alone). No page keeps or writes a setting; the
/// bindings are constant -- except the General page's start-panel checkbox (ADR-0025 R-2), whose
/// value lives in `StartPanelPreferences` (`App/UI/StartPanel/`) and is only rendered and handed
/// back from here. Every text is `verbatim` (catalog strings are resolved in
/// `SettingsStrings`; `Text("…")` would look its argument up a second time and read `%` as a
/// format).

// MARK: - Shared rows

/// A secondary note under a row (11 pt, secondary colour, wraps).
struct SettingsNote: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The secondary "Coming later" label next to a disabled control.
struct ComingLaterLabel: View {
    var body: some View {
        Text(verbatim: UIStrings.comingLater)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            .fixedSize()
    }
}

/// One form row as the artboards lay it out: the label in a left column (150–210 pt), the content
/// left-aligned beside it, top-aligned, 6 pt between the content's lines.
struct SettingsRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(verbatim: label)
                .frame(minWidth: 150, idealWidth: 180, maxWidth: 210, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A system checkbox or radio button (`NSButton`; UI-1 spec §3: radio / checkbox are the system
/// `NSButton(.radio / .checkbox)`) for one model choice: its state is the model's, it is enabled
/// only when the choice is today's behaviour, and it has no action -- nothing is stored. A radio
/// button that is already on stays on when clicked, and every other option is disabled, so no
/// click changes anything.
struct SettingsChoiceButton: NSViewRepresentable {
    enum Kind {
        case checkbox
        case radio
    }

    let kind: Kind
    let choice: SettingsModel.Choice

    func makeNSView(context: Context) -> NSButton {
        let title = SettingsModel.title(of: choice)
        let button: NSButton
        switch kind {
        case .checkbox: button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        case .radio: button = NSButton(radioButtonWithTitle: title, target: nil, action: nil)
        }
        button.identifier = NSUserInterfaceItemIdentifier("settings.\(choice.id)")
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        update(button, environmentEnabled: context.environment.isEnabled)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        update(button, environmentEnabled: context.environment.isEnabled)
    }

    /// SwiftUI sets a hosted control's enabled state from its environment, so the row also applies
    /// `.disabled` to this view; both say the same.
    private func update(_ button: NSButton, environmentEnabled: Bool) {
        button.state = choice.isSelected ? .on : .off
        button.isEnabled = choice.isEnabled && environmentEnabled
    }
}

/// One model choice with its Coming later label when it is disabled.
struct SettingsChoiceRow: View {
    let kind: SettingsChoiceButton.Kind
    let choice: SettingsModel.Choice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SettingsChoiceButton(kind: kind, choice: choice)
                .fixedSize()
                .disabled(!choice.isEnabled)
            if choice.showsComingLater {
                ComingLaterLabel()
            }
        }
    }
}

/// A radio group from the model (today's behaviour selected, every later option disabled).
struct SettingsRadioGroup: View {
    let label: String
    let choices: [SettingsModel.Choice]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(choices) { SettingsChoiceRow(kind: .radio, choice: $0) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: label))
    }
}

/// A system pop-up button (`NSPopUpButton`, UI-1 spec §3) for a model choice group: today's
/// behaviour selected, every later option a disabled item (its title says Coming later), no action.
struct SettingsPopUp: NSViewRepresentable {
    let label: String
    let choices: [SettingsModel.Choice]

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.autoenablesItems = false
        button.setAccessibilityLabel(label)
        for choice in choices {
            button.addItem(withTitle: SettingsModel.title(of: choice))
            button.lastItem?.isEnabled = choice.isEnabled
            button.lastItem?.identifier = NSUserInterfaceItemIdentifier("settings.\(choice.id)")
        }
        if let selected = choices.firstIndex(where: \.isSelected) {
            button.selectItem(at: selected)
        }
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {}
}

// MARK: - General

struct SettingsGeneralPage: View {
    /// ADR-0025 R-2 / design note §7: the start panel's one stored preference and the Accessibility
    /// state beside it. This page renders it and calls its methods; it stores nothing itself.
    @ObservedObject var startPanel: StartPanelPreferences

    var body: some View {
        Form {
            Section {
                SettingsRow(SettingsStrings.launch) {
                    SettingsChoiceRow(kind: .checkbox, choice: SettingsModel.launchOpensHosts)
                }
                SettingsRow(SettingsStrings.connectionDrops) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: SettingsStrings.reconnectPolicy)
                        SettingsNote(text: SettingsStrings.reconnectPolicyNote)
                    }
                }
            }
            Section {
                SettingsRow(UIStrings.startPanelTitle) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: Binding(get: { startPanel.preciseDockPositioning }, set: { startPanel.setPreciseDockPositioning($0) })) {
                            Text(verbatim: UIStrings.startPanelPrecise)
                        }
                        .toggleStyle(.checkbox)
                        SettingsNote(text: UIStrings.startPanelPreciseNote)
                        if startPanel.showsAuthorizationHint {
                            SettingsNote(text: UIStrings.startPanelNotAuthorized)
                            Button {
                                startPanel.openAccessibilityPrivacy()
                            } label: {
                                Text(verbatim: UIStrings.startPanelOpenPrivacy)
                            }
                            .settingsSecondaryButtonStyle()
                        }
                    }
                }
            }
            .onAppear { startPanel.refreshTrust() }
            Section {
                SettingsRow(SettingsStrings.notifications) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(SettingsModel.notifications) { SettingsChoiceRow(kind: .checkbox, choice: $0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Keyboard

struct SettingsKeyboardPage: View {
    var body: some View {
        Form {
            Section {
                SettingsRow(SettingsStrings.commandKey) {
                    SettingsRadioGroup(label: SettingsStrings.commandKeyGroup, choices: SettingsModel.commandKey)
                }
                SettingsRow(SettingsStrings.optionKey) {
                    Text(verbatim: SettingsStrings.optionValue)
                }
                SettingsRow(SettingsStrings.fnKey) {
                    Text(verbatim: SettingsStrings.fnValue)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: SettingsStrings.tableLabel)
                        .font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text(verbatim: SettingsStrings.tableMac).font(.system(size: 11, weight: .semibold))
                            Text(verbatim: SettingsStrings.tableWindows).font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                        Divider()
                        ForEach(SettingsModel.keyRows()) { row in
                            GridRow {
                                Text(verbatim: row.mac)
                                Text(verbatim: row.windows)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Text(verbatim: SettingsStrings.tableLabel))
                    SettingsNote(text: SettingsStrings.menuShortcutsNote)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Display

struct SettingsDisplayPage: View {
    var body: some View {
        Form {
            Section {
                SettingsRow(SettingsStrings.scale) {
                    VStack(alignment: .leading, spacing: 4) {
                        SettingsRadioGroup(label: SettingsStrings.scale, choices: SettingsModel.scale)
                        SettingsNote(text: SettingsStrings.scaleNote)
                    }
                }
                SettingsRow(SettingsStrings.displays) {
                    VStack(alignment: .leading, spacing: 4) {
                        SettingsChoiceRow(kind: .checkbox, choice: SettingsModel.followDisplays)
                        SettingsNote(text: SettingsStrings.followNote)
                    }
                }
                SettingsRow(SettingsStrings.afterReconnect) {
                    VStack(alignment: .leading, spacing: 4) {
                        SettingsChoiceRow(kind: .checkbox, choice: SettingsModel.restoreWindows)
                        SettingsNote(text: SettingsStrings.restoreNote)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

/// What the Advanced page shows that changes while the window is open, and the two actions it
/// asks the window controller to run.
@MainActor
final class SettingsAdvancedState: ObservableObject {
    /// `a_include`: off by default, for the next export only (cleared after each export).
    @Published var includeAccountAndKeyWitness = false
    /// The last export's one-line result, if any.
    @Published var exportResult: String?
    /// True while an export or a reset is running (both buttons are disabled meanwhile).
    @Published var isBusy = false
    /// How many of the seven launch knobs are present (never which, never their values).
    let overrideCount: Int

    var onExport: () -> Void = {}
    var onResetPins: () -> Void = {}

    init(overrideCount: Int) {
        self.overrideCount = overrideCount
    }
}

struct SettingsAdvancedPage: View {
    @ObservedObject var state: SettingsAdvancedState

    var body: some View {
        Form {
            Section {
                SettingsRow(SettingsStrings.logDetail) {
                    VStack(alignment: .leading, spacing: 4) {
                        SettingsPopUp(label: SettingsStrings.logDetail, choices: SettingsModel.logDetail)
                            .frame(minWidth: 220, alignment: .leading)
                            .fixedSize()
                        SettingsNote(text: SettingsStrings.logNote)
                    }
                }
            }
            Section {
                SettingsRow(SettingsStrings.diagnostics) {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            state.onExport()
                        } label: {
                            Text(verbatim: SettingsStrings.export)
                        }
                        .settingsSecondaryButtonStyle()
                        .disabled(state.isBusy)
                        SettingsNote(text: SettingsStrings.exportNote)
                        Toggle(isOn: $state.includeAccountAndKeyWitness) {
                            Text(verbatim: SettingsStrings.includeAccounts)
                        }
                        .toggleStyle(.checkbox)
                        if let result = state.exportResult {
                            SettingsNote(text: result)
                        }
                    }
                }
                SettingsRow(SettingsStrings.pins) {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            state.onResetPins()
                        } label: {
                            Text(verbatim: SettingsStrings.reset)
                        }
                        .settingsSecondaryButtonStyle()
                        .disabled(state.isBusy)
                        SettingsNote(text: SettingsStrings.resetNote)
                    }
                }
            }
            Section {
                SettingsRow(SettingsStrings.overrides) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: SettingsModel.overridesText(count: state.overrideCount))
                        SettingsNote(text: SettingsStrings.overridesNote)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
