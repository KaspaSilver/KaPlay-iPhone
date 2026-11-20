import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import UIKit


// MARK: - Shared category row (SettingsView + AppSettingsView)

/// The standard Settings category row: icon + title behind a NavigationLink. File-scope so the
/// in-account SettingsView and the accounts-screen AppSettingsView render identical rows.
fileprivate func settingsCategoryRow<Destination: View>(
    _ title: LocalizedStringKey,
    icon: String,
    tint: Color,
    @ViewBuilder destination: @escaping () -> Destination
) -> some View {
    NavigationLink {
        destination()
    } label: {
        Label {
            Text(title)
                .foregroundColor(tint == .red ? .red : .primary)
        } icon: {
            Image(systemName: icon)
                .foregroundColor(tint)
        }
    }
}

// MARK: - App-wide settings pages (shared by SettingsView and AppSettingsView)
//
// These pages carry the app-wide settings tier - everything here applies to the whole install
// regardless of which account is active, which is why the accounts-list screen's App Settings
// (see AppSettingsView) can host the SAME views without a wallet loaded. The in-account
// SettingsView embeds them unchanged, so there's exactly one source of truth per page.

/// Security page: biometric toggles + Simple Mode. All fields live in the global AppSettings
/// blob / device Keychain - nothing here needs an active account, which is exactly why Child
/// Mode is reachable from the accounts list (a parent can manage it without unlocking anything).
struct SecuritySettingsPage: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject private var walletManager = WalletManager.shared

    /// A biometric lock that could be switched off without passing the lock is not a lock -
    /// anyone holding an unlocked phone could have turned them off and then read the seed
    /// phrase. So the switch itself is gated, in BOTH directions: turning one on is a claim
    /// about who is holding the device too.
    ///
    /// The Toggle is driven off a proxy binding rather than the setting: the write only happens
    /// after authentication succeeds, so a failed or cancelled prompt leaves the switch exactly
    /// where it was instead of flipping and flipping back.
    /// `title` and `reason` are keys: the title is a `LocalizedStringKey` so it follows the in-app
    /// language, and the reason is looked up before it goes to the system prompt.
    private func biometricToggle(_ title: LocalizedStringKey, reason: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { isOn.wrappedValue },
            set: { requested in
                guard requested != isOn.wrappedValue else { return }
                DeviceAuth.authenticate(reason: AppLocalization.string(reason)) {
                    isOn.wrappedValue = requested
                    settingsViewModel.saveSettings()
                } onFailure: {
                    // Nothing to undo - the setting was never written.
                    Haptics.impact(.medium)
                }
            }
        ))
    }

    var body: some View {
        Form {
            Section("Security") {
                biometricToggle(
                    "Biometrics for 12 or 24 Words",
                    reason: "Unlock to change the 12 or 24 words biometric lock",
                    isOn: $settingsViewModel.settings.biometricSeedPhraseEnabled
                )
                biometricToggle(
                    "Biometrics for Account Login",
                    reason: "Unlock to change the account login biometric lock",
                    isOn: $settingsViewModel.settings.biometricAccountLoginEnabled
                )
                // No "Biometrics for Address Private Keys": no private key is shown anywhere
                // reachable since the Wallet tab became the chatting address only. The setting
                // (`biometricSpendingKeyEnabled`) stays for the unshown full wallet.
            }
        }
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The three app-wide customization pickers (Appearance / Language / Currency) as loose rows,
/// so each host wraps them in its own Section: SettingsView's Customization page adds the
/// per-account extras (Customize Dock, Show Setup Guides) after them; AppSettingsView shows
/// them alone.
struct AppWideCustomizationPickers: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        Group {
            Picker("Appearance", selection: $settingsViewModel.settings.appearance) {
                ForEach(AppAppearance.allCases, id: \.self) { option in
                    // displayName is already translated (AppLocalization).
                    Text(verbatim: option.displayName).tag(option)
                }
            }
            .onChange(of: settingsViewModel.settings.appearance) { _ in
                settingsViewModel.saveSettings()
            }

            Picker("Language", selection: $settingsViewModel.settings.language) {
                ForEach(AppLanguage.allCases, id: \.self) { option in
                    // Each language's own name; only "System" is a key.
                    Text(verbatim: option == .system ? AppLocalization.string(option.displayName) : option.displayName).tag(option)
                }
            }
            .onChange(of: settingsViewModel.settings.language) { newValue in
                settingsViewModel.saveSettings()
                settingsViewModel.applyLanguagePreference(newValue)
            }

            Picker("Currency", selection: $settingsViewModel.settings.currency) {
                ForEach(AppCurrency.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .onChange(of: settingsViewModel.settings.currency) { _ in
                settingsViewModel.saveSettings()
            }
        }
    }
}

/// Connection hub: endpoints (indexers/KNS/REST/node) and explorer choice - all global
/// AppSettings fields, safe with no active account.
struct ConnectionHubPage: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                // Mainnet <-> testnet, first in the section (no footer). The choice applies at the
                // next launch, all at once (`PendingNetworkSwitch`); each network keeps its own
                // connection settings (`AppSettings.switchNetwork(to:)`), so after the restart
                // Connection Settings below shows that network's values.
                Toggle(isOn: Binding(
                    get: { settingsViewModel.selectedNetworkType == .testnet },
                    set: { on in
                        settingsViewModel.switchNetwork(to: on ? .testnet : .mainnet)
                        Haptics.success()
                    }
                )) {
                    Label("Testnet", systemImage: "testtube.2")
                }
                .tint(.orange)

                if settingsViewModel.selectedNetworkType != settingsViewModel.launchNetworkType {
                    Label {
                        Text(settingsViewModel.selectedNetworkType == .testnet
                             ? LocalizedStringKey("Close KaPlay completely and open it again to finish switching to Testnet.")
                             : LocalizedStringKey("Close KaPlay completely and open it again to finish switching back to Mainnet."))
                    } icon: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundColor(.orange)
                    }
                    .font(.subheadline)
                }

                NavigationLink {
                    ConnectionSettingsView()
                } label: {
                    Label("Connection Settings", systemImage: "network")
                }
            } header: {
                Text("Connection")
            }

            Section {
                NavigationLink {
                    KaspaExplorerSettingsView()
                } label: {
                    HStack {
                        Label("Kaspa Explorer", systemImage: "safari")
                        Spacer()
                        Text(settingsViewModel.settings.kaspaExplorer.displayName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
    }
}


// MARK: - App Settings (accounts-list cog)

/// The app-wide settings tier, reachable from the accounts list's gear button when no account
/// is active. Contains ONLY settings that apply to the entire install: Customization
/// (Appearance/Language/Currency), Security and Connection endpoints -
/// nothing account-specific (that is the in-account SettingsView).
struct AppSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                settingsCategoryRow("Customization", icon: "paintbrush.pointed", tint: .accentColor) {
                    appCustomizationPage
                }
                settingsCategoryRow("Security", icon: "lock.shield", tint: .accentColor) {
                    SecuritySettingsPage()
                }
                settingsCategoryRow("Connection", icon: "antenna.radiowaves.left.and.right", tint: .accentColor) {
                    ConnectionHubPage()
                }
            }
            .navigationTitle("App Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var appCustomizationPage: some View {
        Form {
            Section("Customization") {
                AppWideCustomizationPickers()
            }
        }
        .navigationTitle("Customization")
        .navigationBarTitleDisplayMode(.inline)
    }
}


struct SeedPhraseView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var walletManager: WalletManager
    @State private var seedPhrase: SeedPhrase?
    @State private var isRevealed = false
    @State private var revealToken = UUID()
    @State private var error: String?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    @State private var showScreenshotWarning = false

    var body: some View {
        NavigationStack {
            // Scrolls: the warning, the 24-word grid, the passphrase box and both copy buttons
            // don't fit an iPhone SE or larger text sizes.
            ScrollView {
            VStack(spacing: 24) {
                // Warning
                VStack(alignment: .leading, spacing: 12) {
                    Label("Security Warning", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundColor(.orange)

                    Text("Anyone with your 12 or 24 words can access your account. Never share them with anyone.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("Best practice is to write your 12 or 24 words down to back them up, and never store it online.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if let seedPhrase = seedPhrase {
                    // A passphrase (the "25th word") changes every key: the words alone restore a
                    // different, empty wallet, so the backup screen must say so.
                    if let passphrase = seedPhrase.passphrase, !passphrase.isEmpty {
                        Label("This wallet also uses a passphrase. You need it together with these words to restore it.",
                              systemImage: "key.fill")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isRevealed {
                        // Seed phrase grid. SecureView only blurs it while the screen is recorded or
                        // mirrored; iOS can't stop a screenshot, so one gets the warning below.
                        SecureView {
                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                                GridItem(.flexible())
                            ], spacing: 8) {
                                ForEach(Array(seedPhrase.words.enumerated()), id: \.offset) { index, word in
                                    HStack(spacing: 4) {
                                        Text("\(index + 1).")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .frame(width: 18, alignment: .trailing)
                                        Text(word)
                                            .font(.system(.subheadline, design: .monospaced))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.6)
                                            .allowsTightening(true)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 6)
                                    .background(Color(.systemGray6))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        if let passphrase = seedPhrase.passphrase, !passphrase.isEmpty {
                            SecureView {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Passphrase")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(verbatim: passphrase)
                                        .font(.system(.subheadline, design: .monospaced))
                                        .textSelection(.disabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }

                        // Both copies go through the sensitive path: local-only clipboard (never
                        // Handoff / Universal Clipboard), wiped again 30 s later.
                        VStack(spacing: 12) {
                            Button {
                                copySensitiveToClipboard(seedPhrase.words.joined(separator: " "))
                                Haptics.success()
                                showToast("Words copied. Clipboard will clear in 30s.")
                            } label: {
                                Label("Copy 12 or 24 Words", systemImage: "doc.on.doc")
                            }
                            Button {
                                guard let privateKey = walletManager.getPrivateKey() else {
                                    showToast("Private key unavailable.", style: .error)
                                    return
                                }
                                copySensitiveToClipboard(privateKey.hexString)
                                Haptics.success()
                                showToast("Private key hex copied. Clipboard will clear in 30s.")
                            } label: {
                                Label("Copy Private Key Hex", systemImage: "number")
                            }
                        }
                        .padding(.top)
                    } else {
                        Button {
                            isRevealed = true
                            let token = UUID()
                            revealToken = token
                            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                                if revealToken == token {
                                    isRevealed = false
                                }
                            }
                        } label: {
                            VStack(spacing: 12) {
                                Image(systemName: "eye.slash.fill")
                                    .font(.largeTitle)
                                Text("Tap to reveal your 12 or 24 words")
                                    .font(.subheadline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(60)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .foregroundColor(.secondary)
                    }
                } else if let error = error {
                    Text(error)
                        .foregroundColor(.red)
                } else {
                    ProgressView()
                }
            }
            .padding()
            }
            .navigationTitle("12 or 24 Words")
            .navigationBarTitleDisplayMode(.inline)
            .toast(message: toastMessage, style: toastStyle)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadSeedPhrase()
            }
            // iOS can't stop a screenshot, only say so afterwards, as the backup steps do.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                if isRevealed { showScreenshotWarning = true }
            }
            .alert("Delete That Screenshot", isPresented: $showScreenshotWarning) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("A screenshot of your 12 or 24 words can end up online. Delete it from your photos and write the words on paper instead.")
            }
        }
    }

    private func loadSeedPhrase() {
        do {
            seedPhrase = try KeychainService.shared.loadSeedPhrase()
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }

    /// Copies sensitive material (the private key hex) to the clipboard with a hard 30s system
    /// expiration and `localOnly` (never syncs to other devices via Universal Clipboard/Handoff).
    /// The system honors `expirationDate` even if the app is suspended before it elapses; the
    /// asyncAfter wipe below is a belt-and-suspenders in-app clear that also fires at 30s when
    /// nothing else has overwritten the clipboard in the meantime.
    private func copySensitiveToClipboard(_ value: String) {
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": value]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(30)]
        )
        let copiedValue = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if UIPasteboard.general.string == copiedValue {
                UIPasteboard.general.string = ""
            }
        }
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }
}

struct KaspaExplorerSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                ForEach(KaspaExplorer.allCases, id: \.self) { explorer in
                    Button {
                        settingsViewModel.kaspaExplorer = explorer
                    } label: {
                        HStack {
                            Text(explorer.displayName)
                                .foregroundColor(.primary)
                            Spacer()
                            if settingsViewModel.settings.kaspaExplorer == explorer {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            } header: {
                Text("Explorer")
            } footer: {
                Text("Used to build \"view transaction\" links throughout the app.")
            }
        }
        .navigationTitle("Kaspa Explorer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Domains screen's "Reading names from" row: the .kachat source `KachatNamesRegistry` last
/// chose. Its own view so only this row observes the registry, not every Connection screen.
private struct KachatNamesSourceRow: View {
    @ObservedObject private var kachatRegistry = KachatNamesRegistry.shared

    var body: some View {
        HStack {
            Text("Reading names from")
            Spacer()
            sourceLabel
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .task { await kachatRegistry.refreshIfStale() }
    }

    @ViewBuilder
    private var sourceLabel: some View {
        if !KachatNamesService.isLaunched {
            Text("Not live on this network")
        } else {
            switch kachatRegistry.source {
            case .indexer(let base):
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Indexer")
                    Text(verbatim: URLComponents(string: base)?.host ?? base)
                        .font(.caption)
                }
            case .chain:
                VStack(alignment: .trailing, spacing: 2) {
                    Text("The chain")
                    Text("Indexer not usable right now")
                        .font(.caption)
                }
            case nil:
                if kachatRegistry.isRefreshing {
                    ProgressView()
                } else {
                    Text(kachatRegistry.lastError == nil ? "Checking..." : "Couldn't check")
                }
            }
        }
    }
}

struct ConnectionSettingsView: View {
    /// Nil: the cards. Set: that connection's own screen (as in KaPay).
    var page: Page? = nil
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    /// The .kachat names indexer (Domains screen). Blank = the network's default.
    @State private var indexerURL: String = ""
    @State private var publicChatIndexerURL: String = ""
    @State private var kaspaRestAPIURL: String = ""
    @State private var trustedNodeValidationError: String?

    @State private var newSavedNodeLabel: String = ""
    @State private var newSavedNodeAddress: String = ""
    @State private var savedNodeAddressError: String?

    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success

    /// Decision 3A: every endpoint field on this page is https-only. Shown inline under any
    /// field whose value starts with http://, and Save refuses to persist while one remains.
    private static let httpsRequiredError = "Use https. Unencrypted connections are not supported."

    /// True when the field value explicitly asks for cleartext http. Bare hostnames (no scheme)
    /// are fine - they are normalized to https:// on save, matching
    /// `NextcloudService.normalizedServerURL`.
    private func isCleartextHTTP(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://")
    }

    /// Inline red caption shown under a URL field while it holds an http:// value.
    @ViewBuilder
    private func httpsInlineError(for value: String) -> some View {
        if isCleartextHTTP(value) {
            Text(LocalizedStringKey(Self.httpsRequiredError))
                .font(.caption)
                .foregroundColor(.red)
        }
    }

    /// Normalizes a saved endpoint: trims whitespace and defaults a scheme-less value
    /// ("indexer.kachat.app") to https://, so bare hostnames keep working exactly like the
    /// Nextcloud server field already did. http:// never reaches here - Save rejects it first.
    private func normalizedHTTPSURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.lowercased().hasPrefix("https://") { return trimmed }
        return "https://" + trimmed
    }

    /// The Chess screen: the arena's indexer. (.kachat names have their own indexer field, on the
    /// Domains screen.)
    @ViewBuilder
    private var chessSections: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Chess Indexer URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(indexerPlaceholder(AppSettings.defaultPublicChatIndexerURL), text: $publicChatIndexerURL)
                    .font(.system(.body, design: .monospaced))
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                httpsInlineError(for: publicChatIndexerURL)
            }
        } header: {
            Text("Chess Indexer")
        } footer: {
            Text("Serves the chess arena's rooms, moves and leaderboards. A server that doesn't have them means online games can't find each other.")
        }

    }

    @ViewBuilder
    private var nodeSections: some View {
        Section {
            Picker(
                "Kaspa Node",
                selection: Binding(get: { nodeChoiceSelection }, set: { applyNodeChoice($0) })
            ) {
                // The shipped default node is a mainnet node.
                if settingsViewModel.settings.networkType == .mainnet || nodeChoiceSelection == .defaultNode {
                    Text("Default (Recommended)").tag(NodeChoice.defaultNode)
                }
                Text("Automatic Scan").tag(NodeChoice.automatic)
                ForEach(settingsViewModel.settings.savedNodeAddresses) { entry in
                    Text(entry.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entry.address : entry.label)
                        .tag(NodeChoice.saved(entry.address))
                }
                if case .custom(let address) = nodeChoiceSelection {
                    Text(address).tag(NodeChoice.custom(address))
                }
            }

            if let trustedNodeValidationError {
                Text(verbatim: AppLocalization.string(trustedNodeValidationError))
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if !settingsViewModel.settings.trustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Connected only to this node")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        } header: {
            Text("Kaspa Node")
        }

        Section {
            TextField("Label (optional)", text: $newSavedNodeLabel)
                .autocapitalization(.words)

            HStack {
                TextField("host:port or grpcs://host", text: $newSavedNodeAddress)
                    .font(.system(.body, design: .monospaced))
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: newSavedNodeAddress) { _ in
                        savedNodeAddressError = nil
                    }

                Button {
                    addSavedNodeAddress()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.accentColor)
                }
                .accessibilityLabel("Add")
                .disabled(newSavedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let savedNodeAddressError {
                Text(verbatim: AppLocalization.string(savedNodeAddressError))
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if settingsViewModel.settings.savedNodeAddresses.isEmpty {
                Text("No saved addresses")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ForEach(settingsViewModel.settings.savedNodeAddresses) { entry in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            if !entry.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(entry.label)
                                Text(entry.address)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            } else {
                                Text(entry.address)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIPasteboard.general.string = entry.address
                            Haptics.success()
                            showToast("Node address copied.")
                        }

                        Button {
                            deleteSavedNodeAddress(entry)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete saved address")
                    }
                }
                .onDelete { indexSet in
                    settingsViewModel.settings.savedNodeAddresses.remove(atOffsets: indexSet)
                    settingsViewModel.saveSettings()
                }
            }
        } header: {
            Text("IP Address Book")
        }
    }

    @ViewBuilder
    private var domainsSections: some View {
        // .kachat first: it is what every address field resolves before anything else. Names are
        // read through this indexer when it serves this network's registry and keeps up, else
        // straight from the chain (`KachatNamesRegistry.chooseSource`).
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(".kachat Indexer URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(indexerPlaceholder(AppSettings.defaultIndexerURL), text: $indexerURL)
                    .font(.system(.body, design: .monospaced))
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                httpsInlineError(for: indexerURL)
            }
            KachatNamesSourceRow()
        } header: {
            Text(".kachat Names")
        }
        // The other name services this app reads (see `NameServicesClient`). Shown, not
        // editable. The .kas URL had no empty-string fallback, so saving it blank wrote "" and
        // every lookup then failed with an unsupported-URL error until it was typed back in. It
        // now follows the selected network.
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: ".kas")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(settingsViewModel.knsBaseURL)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            ForEach([NameServiceTLD.k, .kaspa], id: \.self) { tld in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: tld.suffix)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(tld.apiBaseURL(for: settingsViewModel.settings.networkType) ?? AppLocalization.string("Not available on this network"))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Other Domains")
        }
    }

    @ViewBuilder
    private var explorerSections: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Kaspa REST API URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(AppSettings.defaultKaspaRestURL(for: settingsViewModel.settings.networkType), text: $kaspaRestAPIURL)
                    .font(.system(.body, design: .monospaced))
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                httpsInlineError(for: kaspaRestAPIURL)
            }
        } header: {
            Text("Kaspa Explorer API")
        } footer: {
            Text("REST API for transaction history and balance lookups")
        }

    }

    /// The field hint: the network's default (testnet has none).
    private func indexerPlaceholder(_ mainnetDefault: String) -> String {
        settingsViewModel.settings.networkType == .mainnet
            ? mainnetDefault
            : AppLocalization.string("No testnet indexer yet")
    }

    /// One card per kind of connection, as in KaPay: the chess indexer, the Kaspa node, name
    /// services and the block explorer.
    enum Page: String, CaseIterable, Identifiable {
        case chess, node, domains, explorer

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .chess: return "Chess"
            case .node: return "Node"
            case .domains: return "Domains"
            case .explorer: return "Explorer"
            }
        }

        var icon: String {
            switch self {
            case .chess: return "checkerboard.rectangle"
            case .node: return "server.rack"
            case .domains: return "at"
            case .explorer: return "safari"
            }
        }

        /// Only the node screen saves as you pick (the picker and the address book).
        var hasSave: Bool { self != .node }
    }

    var body: some View {
        Group {
            if let page {
                pageScreen(page)
            } else {
                cards
            }
        }
        .onAppear {
            loadCurrentSettings()
        }
        .toast(message: toastMessage, style: toastStyle)
    }

    /// The cards, each opening its connection's screen.
    private var cards: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(Page.allCases) { page in
                    NavigationLink {
                        ConnectionSettingsView(page: page)
                    } label: {
                        connectionCard(page)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle("Connection Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func connectionCard(_ page: Page) -> some View {
        HStack(spacing: 14) {
            Image(systemName: page.icon)
                .font(.body.weight(.semibold))
                .foregroundColor(.accentColor)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                Text(page.title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(verbatim: cardSummary(page))
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(uiColor: .separator), lineWidth: 0.8)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }

    /// What each card is set to right now: the server's host, or the node in use.
    private func cardSummary(_ page: Page) -> String {
        let settings = settingsViewModel.settings
        func host(_ url: String) -> String {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return AppLocalization.string("Not set") }
            return URLComponents(string: trimmed)?.host ?? trimmed
        }
        switch page {
        case .chess: return host(settings.publicChatIndexerURL)
        case .node:
            let trusted = settings.trustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            if trusted.isEmpty { return AppLocalization.string("Automatic Scan") }
            if trusted == normalizedDefaultAddress { return AppLocalization.string("Default (Recommended)") }
            if let saved = settings.savedNodeAddresses.first(where: { $0.address == trusted }),
               !saved.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return saved.label
            }
            return trusted
        case .domains: return host(settings.indexerURL)
        case .explorer: return host(settings.kaspaRestAPIURL)
        }
    }

    /// One connection's own screen; Save keeps it and goes back to the cards.
    private func pageScreen(_ page: Page) -> some View {
        Form {
            switch page {
            case .chess: chessSections
            case .node: nodeSections
            case .domains: domainsSections
            case .explorer: explorerSections
            }
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if page.hasSave {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if saveSettings() {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    /// Removes one IP Address Book entry (trash icon on its row). Deliberately does NOT touch
    /// the node selection: deleting the entry for the currently-pinned node keeps the pin (the
    /// picker then shows it as a custom address), matching the existing rule that the picker
    /// always reflects the real connection state - the toast tells the user which case they hit.
    private func deleteSavedNodeAddress(_ entry: SavedNodeAddress) {
        let entryAddress = entry.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinnedAddress = settingsViewModel.settings.trustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsViewModel.settings.savedNodeAddresses.removeAll { $0.id == entry.id }
        settingsViewModel.saveSettings()
        Haptics.success()
        if !pinnedAddress.isEmpty && pinnedAddress == entryAddress {
            showToast("Removed from address book. Still connected to this node.")
        } else {
            showToast("Address removed.")
        }
    }

    private func addSavedNodeAddress() {
        let trimmedAddress = newSavedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else { return }
        guard Endpoint(url: trimmedAddress) != nil else {
            savedNodeAddressError = "Enter as host:port or grpcs://host"
            return
        }
        savedNodeAddressError = nil
        let trimmedLabel = newSavedNodeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsViewModel.settings.savedNodeAddresses.append(
            SavedNodeAddress(label: trimmedLabel, address: trimmedAddress)
        )
        settingsViewModel.saveSettings()
        newSavedNodeLabel = ""
        newSavedNodeAddress = ""
    }

    private func loadCurrentSettings() {
        indexerURL = settingsViewModel.settings.indexerURL
        publicChatIndexerURL = settingsViewModel.settings.publicChatIndexerURL
        kaspaRestAPIURL = settingsViewModel.settings.kaspaRestAPIURL
    }

    /// Persists the endpoint fields, or returns false without saving anything when any field
    /// still holds an http:// value (its inline error is already visible; a toast repeats the
    /// reason so the refusal can't be missed). Non-empty scheme-less values are normalized to
    /// A blank field means "use the default", never an empty URL.
    private func normalizedOrDefault(_ value: String, _ fallback: String) -> String {
        let normalized = normalizedHTTPSURL(value)
        return normalized.isEmpty ? fallback : normalized
    }

    /// https:// (Decision 3A).
    @discardableResult
    private func saveSettings() -> Bool {
        let allFields = [indexerURL, publicChatIndexerURL, kaspaRestAPIURL]
        guard !allFields.contains(where: isCleartextHTTP) else {
            showToast(Self.httpsRequiredError, style: .error)
            return false
        }
        // Every field falls back to its default when left blank. Two of these already did; the
        // rest wrote "" straight through, and an empty base URL builds a scheme-less URL that
        // URLSession rejects with -1002 - which is exactly how the KNS endpoint got wiped, with
        // no error anywhere pointing at the setting that caused it.
        // Blank falls back to the network's default rather than being written through - an
        // empty base URL builds a request that fails as "unsupported URL" and reads as the
        // server being down, which is exactly how the KNS field broke.
        let defaults = ConnectionProfile.defaults(for: settingsViewModel.settings.networkType)
        let previousIndexerURL = settingsViewModel.settings.indexerURL
        settingsViewModel.settings.indexerURL = normalizedOrDefault(indexerURL, defaults.indexerURL)
        settingsViewModel.settings.publicChatIndexerURL = normalizedOrDefault(publicChatIndexerURL, defaults.publicChatIndexerURL)
        settingsViewModel.settings.kaspaRestAPIURL = normalizedOrDefault(kaspaRestAPIURL, defaults.kaspaRestAPIURL)
        settingsViewModel.saveSettings()
        // A new indexer is asked about .kachat names now, not at the next stale refresh.
        if settingsViewModel.settings.indexerURL != previousIndexerURL {
            Task { await KachatNamesRegistry.shared.refresh() }
        }
        return true
    }

    private enum NodeChoice: Hashable {
        case automatic
        case defaultNode
        case saved(String)
        /// A trusted node address that's currently active but matches neither the default nor any
        /// saved address book entry (e.g. a one-off address typed into the field below) - shown so
        /// the picker always reflects the real current state instead of misrepresenting it.
        case custom(String)
    }

    private var normalizedDefaultAddress: String {
        AppSettings.defaultTrustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nodeChoiceSelection: NodeChoice {
        let normalizedTrustedAddress = settingsViewModel.settings.trustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedTrustedAddress.isEmpty {
            return .automatic
        }
        if normalizedTrustedAddress == normalizedDefaultAddress {
            return .defaultNode
        }
        if let match = settingsViewModel.settings.savedNodeAddresses.first(where: {
            $0.address.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedTrustedAddress
        }) {
            return .saved(match.address)
        }
        return .custom(normalizedTrustedAddress)
    }

    private func applyNodeChoice(_ choice: NodeChoice) {
        let address: String
        switch choice {
        case .automatic: address = ""
        case .defaultNode: address = AppSettings.defaultTrustedNodeAddress
        case .saved(let addr): address = addr
        case .custom(let addr): address = addr
        }
        trustedNodeValidationError = settingsViewModel.applyTrustedNode(address)
    }
}

// MARK: - Kaspa Node (quick access from Connection Status)

/// A single dropdown for picking which node to connect to, right from the connection status
/// sheet (tap the status dot) without navigating to Settings > Connection Settings: the default
/// node (recommended), automatic discovery, or any address already saved in the IP Address Book
/// there. Managing the address book itself (adding/removing/labeling entries) still lives in
/// `ConnectionSettingsView` - this is a quick-select surface over that same underlying list, not
/// a duplicate of it.
struct KaspaNodeQuickAccessSections: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    var onToast: (String, ToastStyle) -> Void

    private enum NodeChoice: Hashable {
        case automatic
        case defaultNode
        case saved(String)
        /// A trusted node address that's currently active but matches neither the default nor any
        /// saved address book entry (e.g. entered as free text in Settings > Connection Settings) -
        /// shown so the picker always reflects the real current state instead of silently
        /// misrepresenting it as "Automatic Scan".
        case custom(String)
    }

    private var normalizedTrustedAddress: String {
        settingsViewModel.settings.trustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedDefaultAddress: String {
        AppSettings.defaultTrustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selection: NodeChoice {
        if normalizedTrustedAddress.isEmpty {
            return .automatic
        }
        if normalizedTrustedAddress == normalizedDefaultAddress {
            return .defaultNode
        }
        if let match = settingsViewModel.settings.savedNodeAddresses.first(where: {
            $0.address.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedTrustedAddress
        }) {
            return .saved(match.address)
        }
        return .custom(normalizedTrustedAddress)
    }

    var body: some View {
        Section {
            Picker(
                "Kaspa Node",
                selection: Binding(get: { selection }, set: { apply($0) })
            ) {
                // The shipped default node is a mainnet node.
                if settingsViewModel.settings.networkType == .mainnet || selection == .defaultNode {
                    Text("Default (Recommended)").tag(NodeChoice.defaultNode)
                }
                Text("Automatic Scan").tag(NodeChoice.automatic)
                ForEach(settingsViewModel.settings.savedNodeAddresses) { entry in
                    Text(entry.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entry.address : entry.label)
                        .tag(NodeChoice.saved(entry.address))
                }
                if case .custom(let address) = selection {
                    Text(address)
                        .tag(NodeChoice.custom(address))
                }
            }

            if case .automatic = selection {
                // No extra row - automatic discovery is the default connection mode.
            } else {
                HStack {
                    Text("Connected only to this node")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    Spacer()
                }
            }
        } header: {
            Text("Kaspa Node")
        } footer: {
            Text("Automatic Scan discovers and connects to the best available nodes. Choosing a specific node connects only to it, without falling back to others. Manage saved addresses in Settings > Connection Settings > IP Address Book.")
        }
    }

    private func apply(_ choice: NodeChoice) {
        let address: String
        switch choice {
        case .automatic: address = ""
        case .defaultNode: address = AppSettings.defaultTrustedNodeAddress
        case .saved(let addr): address = addr
        case .custom(let addr): address = addr
        }
        if let error = settingsViewModel.applyTrustedNode(address) {
            onToast(error, .error)
        } else {
            onToast(choice == .automatic ? "Automatic scan enabled." : "Node updated.", .success)
        }
    }
}

// MARK: - Connection Status Indicator

struct ConnectionStatusIndicator: View {
    @EnvironmentObject var chatService: ChatService
    @State private var showDetail = false
    /// Red is reserved for SUSTAINED disconnection. `.disconnected` is also what the status
    /// reads at cold start before the first subscribe and in the gaps between reconnect
    /// attempts, and flashing red there tells the user they're offline when they aren't -
    /// those windows show orange until the state has persisted for the grace period.
    @State private var disconnectedSince: Date?
    @State private var disconnectGraceElapsed = false
    private static let disconnectGrace: TimeInterval = 8

    var body: some View {
        Button {
            showDetail = true
        } label: {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                )
        }
        .sheet(isPresented: $showDetail) {
            // A full-height sheet, not a detented one: this is a page. It is still an OVERLAY
            // over whatever you were reading rather than a push, so Done puts you back exactly
            // where you were, from any of the fourteen places the dot appears.
            ConnectionStatusDetailView()
        }
        .onAppear { syncDisconnectedAnchor() }
        .onChange(of: chatService.connectionStatus) { _ in syncDisconnectedAnchor() }
        .task(id: disconnectedSince) {
            disconnectGraceElapsed = false
            guard let since = disconnectedSince else { return }
            let remaining = Self.disconnectGrace - Date().timeIntervalSince(since)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            if !Task.isCancelled, chatService.connectionStatus == .disconnected {
                disconnectGraceElapsed = true
            }
        }
    }

    private func syncDisconnectedAnchor() {
        if chatService.connectionStatus == .disconnected {
            if disconnectedSince == nil { disconnectedSince = Date() }
        } else {
            disconnectedSince = nil
        }
    }

    private var statusColor: Color {
        switch chatService.connectionStatus {
        case .connected:
            return KasiaAPIClient.shared.isDpiSuspected
                ? Color(red: 0.0, green: 0.50, blue: 0.0)
                : .green
        case .connecting:
            return .orange
        case .disconnected:
            return disconnectGraceElapsed ? .red : .orange
        }
    }
}

/// Kaspa-logo chatting-address balance for navigation bars - shared by the main pages
/// (KaPosts, Public Chats, Cold Storage, Portfolio, Swap) so the centered header reads
/// identically across tabs. Chats keeps its own tap-to-copy variant.
struct BalanceToolbarLabel: View {
    @EnvironmentObject var walletManager: WalletManager

    var body: some View {
        HStack(spacing: 6) {
            Image("KaspaLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
            Text(verbatim: "\(String(format: "%.8f", Double(walletManager.currentWallet?.balanceSompi ?? 0) / 100_000_000.0)) \(KaspaUnit.symbol)")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .task {
            _ = try? await walletManager.refreshBalance()
        }
    }
}

extension View {
    /// A menu's title, the same as KaPosts': big, fixed above the content that scrolls, with the
    /// balance alone in the center of the bar (a system large title would move with the scroll
    /// view). Keep `navigationTitle` as well: the next screen's Back reads it. A tab's first screen
    /// passes `showsBackupBanner`, so `AccountBackupBanner` sits above its title, as in KaChat.
    func fixedScreenTitle(_ title: Text, showsBackupBanner: Bool = false) -> some View {
        VStack(spacing: 0) {
            if showsBackupBanner {
                AccountBackupBanner()
            }
            title
                .font(.largeTitle.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            self
        }
    }
}

/// A game's title with the balance under it, for the center of a navigation bar: a board has no
/// room for `fixedScreenTitle`. A principal toolbar item takes the place of `navigationTitle`, so
/// a bar with only the balance there shows no title at all.
struct ScreenTitleToolbarLabel: View {
    let title: Text

    var body: some View {
        VStack(spacing: 0) {
            title
                .font(.headline)
                .lineLimit(1)
            BalanceToolbarLabel()
        }
    }
}

// MARK: - Connection Status Detail View

struct ConnectionStatusDetailView: View {
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @StateObject private var nodePool = NodePoolService.shared
    // Node + latency moved off ChatService to stop 2s ticks re-rendering the whole app;
    // this screen watches them directly so it still updates live.
    @ObservedObject private var nodeInfo = NodeConnectionInfo.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isReconnecting: Bool = false
    @State private var nodeRecords: [NodeRecord] = []
    @State private var showClearPoolConfirm: Bool = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success

    var body: some View {
        NavigationStack {
            // Each section is its own expression. As one Form the body was 330 lines the
            // type checker solved in a single go, and it stopped finishing ("unable to
            // type-check this expression in reasonable time").
            Form {
                statusSection
                poolStatisticsSection
                actionsSection
                KaspaNodeQuickAccessSections(onToast: showToast)
                nodeListSections
            }
            .alert("Clear connection pool?", isPresented: $showClearPoolConfirm) {
                Button("Clear", role: .destructive) {
                    Task {
                        await nodePool.clearConnectionPool()
                        await reconnect()
                        await reloadNodeRecords()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes discovered nodes, disconnects current sessions, and restarts discovery.")
            }
            .toast(message: toastMessage, style: toastStyle)
            .navigationTitle("Connection Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
                .task {
                    await refreshNodeRecordsContinuously()
                }
        }
    }

    /// Status, protocol, and the warnings that qualify them.
    @ViewBuilder
    private var statusSection: some View {
        // Status Section
        Section {
            HStack {
                Text("Status")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(verbatim: AppLocalization.string(chatService.connectionStatus.description))
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("Protocol")
                Spacer()
                Text("\(nodePool.activeProtocol) (\(nodePool.activeProtocolSecurity))")
                    .foregroundColor(.secondary)
            }

            if KasiaAPIClient.shared.isDpiSuspected {
                HStack {
                    Text("DPI")
                    Spacer()
                    Text("Suspected")
                        .foregroundColor(.orange)
                }
                Text("Connectivity might be limited. Using HTTP/1.1 and decreased pagination for indexer requests.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if nodePool.nodeNetworkBlockedSuspected {
                HStack {
                    Text("Node Network")
                    Spacer()
                    Text("Blocked")
                        .foregroundColor(.orange)
                }
                Text("Node connections appear blocked on this network. You can still see games through the indexer, but moves and payments need a node connection.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let node = nodeInfo.currentConnectedNode {
                HStack {
                    Text("Connected Node")
                    Spacer()
                    Text(extractHost(from: node))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            if let latency = nodeInfo.currentNodeLatencyMs {
                HStack {
                    Text("Latency")
                    Spacer()
                    Text("\(latency) ms")
                        .foregroundColor(latencyColor(latency))
                }
            }

            // Connected node geo info
            if let record = connectedNodeRecord {
                if let distKm = record.profile.geoDistanceKm {
                    HStack {
                        Text("Distance")
                        Spacer()
                        Text(formatDistance(distKm))
                            .foregroundColor(.secondary)
                    }
                }
                if let cc = record.profile.countryCode {
                    HStack {
                        Text("Country")
                        Spacer()
                        Text(cc)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Indexer endpoint
            HStack {
                Text("Indexer")
                Spacer()
                Text(extractHost(from: settingsViewModel.settings.indexerURL))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            HStack {
                Text("Last Sync")
                Spacer()
                Text(verbatim: AppLocalization.string(lastSyncText))
                    .foregroundColor(lastSyncColor)
            }
        } header: {
            Text("Connection Status")
        }
    }

    /// Only meaningful under automatic node selection - see the note inside.
    @ViewBuilder
    private var poolStatisticsSection: some View {

        // Pool Statistics Section - only meaningful under automatic node
        // selection, where the gRPC pool is actually picking nodes. When the
        // user is pinned to the default or a custom node, the registry holds
        // just that one node and pool health/counters are noise, so hide them.
        if isAutomaticNodeSelection {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("Active")
                            .font(.caption)
                    }
                    Text("\(nodePool.activeCount)")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                }
                Spacer()
                VStack(alignment: .center, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle().fill(.blue).frame(width: 8, height: 8)
                        Text("Verified")
                            .font(.caption)
                    }
                    Text("\(nodePool.verifiedCount)")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle().fill(.gray).frame(width: 8, height: 8)
                        Text("Total")
                            .font(.caption)
                    }
                    Text("\(nodePool.totalNodeCount)")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)

            HStack {
                Text("Pool Health")
                Spacer()
                Text(LocalizedStringKey(poolHealthDescription))
                    .foregroundColor(poolHealthColor)
            }
        } header: {
            Text("Pool Status")
        }
        }
    }

    /// Refresh Pool, Clear Pool, Reconnect.
    @ViewBuilder
    private var actionsSection: some View {
        // Actions Section (pool refresh/clear only apply in automatic mode;
        // Reconnect is useful in every mode)
        Section {
            if isAutomaticNodeSelection {
                Button {
                    Task {
                        await nodePool.refreshPool()
                    }
                } label: {
                    HStack {
                        Text("Refresh Pool")
                        Spacer()
                        if nodePool.isRefreshing {
                            ProgressView()
                        }
                    }
                }
                .disabled(nodePool.isRefreshing || isReconnecting)

                Button(role: .destructive) {
                    showClearPoolConfirm = true
                } label: {
                    Text("Clear Connection Pool")
                }
                .disabled(nodePool.isRefreshing || isReconnecting)
            }

            Button {
                Task {
                    await reconnect()
                }
            } label: {
                HStack {
                    Text("Reconnect")
                    Spacer()
                    if isReconnecting {
                        ProgressView()
                    }
                }
            }
            .disabled(nodePool.isRefreshing || isReconnecting)
        } header: {
            Text("Actions")
        } footer: {
            if let endpoint = nodePool.primaryEndpoint {
                Text("Primary: \(endpoint.host)")
            }
        }
    }

    /// Active Nodes and All Nodes, automatic mode only.
    @ViewBuilder
    private var nodeListSections: some View {
        // Node lists only make sense when the pool is discovering nodes;
        // in pinned mode there is nothing here but the pinned node itself.
        if isAutomaticNodeSelection {
        // Active Nodes Section
        Section {
            let activeNodes = nodeRecords.filter { $0.state == .active }
            if activeNodes.isEmpty {
                Text("No active nodes")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ForEach(activeNodes) { record in
                    ConnectionNodeRow(
                        record: record,
                        isConnected: record.endpoint.url == nodeInfo.currentConnectedNode
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIPasteboard.general.string = record.endpoint.key
                        Haptics.success()
                        showToast("Node endpoint copied.")
                    }
                }
            }
        } header: {
            HStack {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Active Nodes")
                Spacer()
                Text("\(nodePool.activeCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } footer: {
            Text("Tap a node to copy host:port.")
        }

        // All Nodes Section
        Section {
            let sortedNodes = nodeRecords.sorted { a, b in
                // Sort by state priority: active > verified > profiled > candidate > suspect > quarantined
                if a.state.rawValue != b.state.rawValue {
                    return a.state.rawValue > b.state.rawValue
                }
                // Then by latency (lower is better)
                let aLatency = a.health.latencyMs.value ?? a.health.globalLatencyMs.value ?? 9999
                let bLatency = b.health.latencyMs.value ?? b.health.globalLatencyMs.value ?? 9999
                return aLatency < bLatency
            }

            if sortedNodes.isEmpty {
                Text("No nodes discovered")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ForEach(sortedNodes) { record in
                    AllNodesRow(record: record)
                }
            }
        } header: {
            HStack {
                Image(systemName: "server.rack")
                    .font(.caption)
                Text("All Nodes")
                Spacer()
                Text("\(nodeRecords.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } footer: {
            Text("All discovered nodes sorted by state and latency. Nodes are deduplicated by host:port.")
        }
        }
    }

    /// True when node selection is Automatic Scan (empty trusted node address), i.e. the
    /// gRPC node pool is actually discovering and picking nodes. A non-empty address
    /// (default recommended node, a saved entry, or free-text custom) pins the app to
    /// that single node via NodeRegistry.setTrustedNode, so pool status is meaningless.
    private var isAutomaticNodeSelection: Bool {
        settingsViewModel.settings.trustedNodeAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var poolHealthDescription: String {
        switch nodePool.poolHealth {
        case .healthy: return "Healthy"
        case .degraded: return "Degraded"
        case .critical: return "Critical"
        case .failed: return "Failed"
        }
    }

    private var poolHealthColor: Color {
        switch nodePool.poolHealth {
        case .healthy: return .green
        case .degraded: return .orange
        case .critical: return .red
        case .failed: return .red
        }
    }

    private var statusColor: Color {
        switch chatService.connectionStatus {
        case .connected:
            return KasiaAPIClient.shared.isDpiSuspected
                ? Color(red: 0.0, green: 0.50, blue: 0.0)
                : .green
        case .connecting:
            return .orange
        case .disconnected:
            return .red
        }
    }

    private var connectedNodeRecord: NodeRecord? {
        guard let primary = nodePool.primaryEndpoint else { return nil }
        return nodeRecords.first { $0.endpoint.key == primary.key }
    }

    private var lastSyncText: String {
        if chatService.isSyncInProgress {
            return "in progress"
        }
        if let lastSync = chatService.lastSuccessfulSyncDate {
            return formatDate(lastSync)
        }
        return "Never"
    }

    private var lastSyncColor: Color {
        chatService.isSyncInProgress ? .orange : .secondary
    }

    private func extractHost(from url: String) -> String {
        guard let urlComponents = URLComponents(string: url),
              let host = urlComponents.host else {
            return url
        }
        return host
    }

    private func latencyColor(_ latency: Int) -> Color {
        if latency < 100 {
            return .green
        } else if latency < 200 {
            return .primary
        } else if latency < 500 {
            return .orange
        } else {
            return .red
        }
    }

    private func formatDistance(_ km: Double) -> String {
        if km < 100 {
            return "\(Int(km)) km"
        } else {
            let thousands = km / 1000
            return String(format: "%.1fk km", thousands)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func reconnect() async {
        isReconnecting = true
        defer { isReconnecting = false }

        let settings = AppSettings.load()

        AppLog.log("[ConnectionStatus] Starting reconnect via NodePoolService...")

        // Disconnect current subscription
        nodePool.disconnect()

        // Small delay to ensure clean disconnect
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Reconnect via node pool
        do {
            try await nodePool.connect(network: settings.networkType)
            AppLog.log("[ConnectionStatus] Connected via NodePool, activeNodes=%d",
                  nodePool.activeNodeCount)

            // Small delay to let connections stabilize
            try? await Task.sleep(nanoseconds: 200_000_000)

            // Re-setup subscriptions
            AppLog.log("[ConnectionStatus] Setting up subscriptions...")
            await chatService.setupUtxoSubscriptionAfterReconnect()
            AppLog.log("[ConnectionStatus] Subscription setup complete, isSubscribed=%@",
                  chatService.isRpcSubscribed ? "true" : "false")

            // Refresh node list
            await reloadNodeRecords()
        } catch {
            AppLog.log("[ConnectionStatus] Reconnect failed: %@", error.localizedDescription)
        }
    }

    private func reloadNodeRecords() async {
        nodeRecords = await nodePool.allNodeRecords()
    }

    private func refreshNodeRecordsContinuously() async {
        await reloadNodeRecords()

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { break }
            await reloadNodeRecords()
        }
    }
}

// MARK: - Connection Node Row (POOLS_v2)

private struct ConnectionNodeRow: View {
    let record: NodeRecord
    let isConnected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Connection indicator
                if isConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }

                // Origin indicator
                switch record.origin {
                case .userAdded:
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                        .font(.caption)
                case .seed:
                    Image(systemName: "shield.fill")
                        .foregroundColor(.blue)
                        .font(.caption)
                case .discovered:
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }

                Text(verbatim: record.endpoint.key)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)

                Spacer()

                Text(verbatim: AppLocalization.string(record.state.displayName))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(stateColor.opacity(0.2))
                    .foregroundColor(stateColor)
                    .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                // Origin label
                Text(verbatim: AppLocalization.string(record.origin.displayName))
                    .font(.caption2)
                    .foregroundColor(originColor)

                // Latency
                if let latency = record.health.latencyMs.value ?? record.health.globalLatencyMs.value {
                    Text("\(Int(latency))ms")
                        .font(.caption)
                        .foregroundColor(latencyColor(Int(latency)))
                }

                // Geo distance
                if let distKm = record.profile.geoDistanceKm {
                    Text(formatDistance(distKm))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Country code
                if let cc = record.profile.countryCode {
                    Text(cc)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // DPI check failed
                if record.profile.peerInfoOk == false {
                    HStack(spacing: 2) {
                        Image(systemName: "network.slash")
                            .font(.caption2)
                        Text("DPI")
                            .font(.caption2)
                    }
                    .foregroundColor(.red)
                }

                // Success/failure counts
                if record.health.consecutiveSuccesses > 0 {
                    Text("\(record.health.consecutiveSuccesses)✓")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                if record.health.consecutiveFailures > 0 {
                    Text("\(record.health.consecutiveFailures)✗")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Spacer()

                // DAA score (if available)
                if let daa = record.profile.virtualDaaScore {
                    Text("DAA: \(formatDaa(daa))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var stateColor: Color {
        switch record.state {
        case .active: return .green
        case .verified: return .blue
        case .profiled: return .orange
        case .candidate: return .gray
        case .suspect: return .red
        case .quarantined: return .red
        }
    }

    private var originColor: Color {
        switch record.origin {
        case .userAdded: return .yellow
        case .seed: return .blue
        case .discovered: return .secondary
        }
    }

    private func latencyColor(_ latency: Int) -> Color {
        if latency < 100 {
            return .green
        } else if latency < 200 {
            return .primary
        } else if latency < 500 {
            return .orange
        } else {
            return .red
        }
    }

    private func formatDaa(_ daa: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: daa)) ?? "\(daa)"
    }

    private func formatDistance(_ km: Double) -> String {
        if km < 100 {
            return "\(Int(km))km"
        } else {
            let thousands = km / 1000
            return String(format: "%.1fk km", thousands)
        }
    }
}

// MARK: - All Nodes Row (Compact)

private struct AllNodesRow: View {
    let record: NodeRecord

    var body: some View {
        HStack(spacing: 8) {
            // State indicator
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)

            // Origin indicator
            switch record.origin {
            case .userAdded:
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                    .font(.caption2)
            case .seed:
                Image(systemName: "shield.fill")
                    .foregroundColor(.blue)
                    .font(.caption2)
            case .discovered:
                EmptyView()
            }

            // Host:port
            Text(verbatim: "\(record.endpoint.host):\(record.endpoint.port)")
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)

            Spacer()

            // Country code
            if let cc = record.profile.countryCode {
                Text(cc)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Geo distance
            if let distKm = record.profile.geoDistanceKm {
                Text(formatDistance(distKm))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // DPI check failed
            if record.profile.peerInfoOk == false {
                Image(systemName: "network.slash")
                    .font(.caption2)
                    .foregroundColor(.red)
            }

            // Latency
            if let latency = record.health.latencyMs.value ?? record.health.globalLatencyMs.value {
                Text("\(Int(latency))ms")
                    .font(.caption2)
                    .foregroundColor(latencyColor(Int(latency)))
            }

            // State badge
            Text(verbatim: AppLocalization.string(record.state.displayName))
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(stateColor.opacity(0.2))
                .foregroundColor(stateColor)
                .clipShape(Capsule())
        }
        .padding(.vertical, 2)
    }

    private var stateColor: Color {
        switch record.state {
        case .active: return .green
        case .verified: return .blue
        case .profiled: return .orange
        case .candidate: return .gray
        case .suspect: return .red
        case .quarantined: return .red
        }
    }

    private func latencyColor(_ latency: Int) -> Color {
        if latency < 100 {
            return .green
        } else if latency < 200 {
            return .primary
        } else if latency < 500 {
            return .orange
        } else {
            return .red
        }
    }

    private func formatDistance(_ km: Double) -> String {
        if km < 100 {
            return "\(Int(km))km"
        } else {
            let thousands = km / 1000
            return String(format: "%.1fk km", thousands)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(WalletManager.shared)
        .environmentObject(SettingsViewModel())
        .environmentObject(ContactsManager.shared)
        .environmentObject(ChatService.shared)
}


// MARK: - Blocking restore progress modal


// MARK: - Wipe-and-resync coordinator (blocking progress modal)


// MARK: - Blocking wipe-and-resync progress modal


// MARK: - Resync chat picker


// MARK: - Cache



// MARK: - Settings tab

/// The Settings tab: KaChat Chess's own short list. The pages behind it are KaChat's
/// app-wide ones (Customization, Security, Connection); the account actions that live on
/// KaChat's Profile screen (seed phrase, Log Out) sit here, since there is no Profile.
struct SettingsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    @State private var showSeedPhrase = false
    @State private var showNFCCardBackup = false
    @State private var accountHasPassphrase = false
    /// The account `accountHasPassphrase` was worked out for, so the seed is read once per
    /// account rather than on every visit to the tab.
    @State private var passphraseCheckedAddress: String?
    @State private var showLogoutConfirmation = false
    @State private var showDeleteAccountConfirmation = false
    /// The seed phrase over the Delete Account warning, which it closes back to.
    @State private var showSeedPhraseOverDeleteWarning = false
    /// The backup steps over the Delete Account warning, for an account that hasn't finished them.
    @State private var showBackupOverDeleteWarning = false
    @ObservedObject private var backupStatus = AccountBackupStatus.shared
    @State private var showAccountBackup = false
    @AppStorage(KachatNameLabel.showEndingsKey) private var showKachatEndings = true
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    var body: some View {
        NavigationStack {
            Form {
                // Alphabetical, as in KaChat. Delete Account and Log Out stay apart below.
                settingsCategoryRow("About", icon: "info.circle", tint: .accentColor) {
                    AccountAboutPage()
                }
                settingsCategoryRow("Account Name", icon: "pencil", tint: .accentColor) {
                    AccountNamePage()
                }
                settingsCategoryRow("Back Up Account", icon: "key", tint: .accentColor) {
                    backUpAccountPage
                }
                settingsCategoryRow("Connection", icon: "antenna.radiowaves.left.and.right", tint: .accentColor) {
                    ConnectionHubPage()
                }
                settingsCategoryRow("Customization", icon: "paintbrush.pointed", tint: .accentColor) {
                    Form {
                        Section {
                            AppWideCustomizationPickers()

                            // Off shows .kachat names bare ("alice"). On by default: the ending is how
                            // a registered name tells itself apart from other services' names.
                            Toggle("Show .kachat Endings", isOn: $showKachatEndings)
                                .onChange(of: showKachatEndings) { _ in
                                    NotificationCenter.default.post(name: .settingsDidChange, object: nil)
                                }
                        } header: {
                            Text("Customization")
                        } footer: {
                            Text("Turn off to show names like alice instead of alice.kachat. A name you gave someone yourself never has the ending.")
                        }
                    }
                    .navigationTitle("Customization")
                    .navigationBarTitleDisplayMode(.inline)
                }
                settingsCategoryRow("Security", icon: "lock.shield", tint: .accentColor) {
                    SecuritySettingsPage()
                }

                // Its own section at the very bottom, so it is easy to find and hard to hit by
                // accident. Log Out sits here too: KaPlay has no Profile tab, where KaChat keeps it.
                Section {
                    Button(role: .destructive) {
                        showDeleteAccountConfirmation = true
                    } label: {
                        Label {
                            Text("Delete Account")
                                .foregroundColor(.red)
                        } icon: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                    }
                    Button(role: .destructive) {
                        showLogoutConfirmation = true
                    } label: {
                        Label {
                            Text("Log Out")
                                .foregroundColor(.red)
                        } icon: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .fixedScreenTitle(Text("Settings"), showsBackupBanner: true)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { ConnectionStatusIndicator() }
                ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
            }
            .toast(message: toastMessage, style: .error)
            .sheet(isPresented: $showSeedPhrase) {
                SeedPhraseView()
            }
            .task(id: walletManager.currentWallet?.publicAddress) {
                await refreshPassphraseFlag()
            }
            .sheet(isPresented: $showNFCCardBackup) {
                #if canImport(CoreNFC) && !targetEnvironment(macCatalyst)
                NFCCardBackupView()
                #endif
            }
            .sheet(isPresented: $showAccountBackup) {
                AccountBackupView()
            }
            .sheet(isPresented: $showLogoutConfirmation) {
                ConfirmActionSheet(
                    title: "Log Out",
                    confirmTitle: "Log Out",
                    confirmSubtitle: "Signs out of this account. Its data stays on this device.",
                    confirmSystemImage: "rectangle.portrait.and.arrow.right"
                ) {
                    Task { await walletManager.logout() }
                }
            }
            .sheet(isPresented: $showDeleteAccountConfirmation) {
                DeleteAccountSheet(
                    confirmSubtitle: "Removes this account and its data from this device.",
                    onViewSeedPhrase: { unlockSeedPhrase { showSeedPhraseOverDeleteWarning = true } },
                    notBackedUp: backupStatus.isPending(walletManager.currentWallet?.publicAddress),
                    onBackUp: { AccountBackupView.unlock { showBackupOverDeleteWarning = true } }
                ) {
                    DeviceAuth.authenticate(reason: AppLocalization.string("Confirm deleting this account")) {
                        Task {
                            do {
                                try await walletManager.deleteWallet()
                            } catch {
                                showErrorToast(String(format: AppLocalization.string("Couldn't delete the account: %@"),
                                                      locale: AppLocalization.locale,
                                                      AppLocalization.string(UserFacingError.message(for: error))))
                            }
                        }
                    }
                }
                .sheet(isPresented: $showSeedPhraseOverDeleteWarning) {
                    SeedPhraseView()
                }
                .sheet(isPresented: $showBackupOverDeleteWarning) {
                    AccountBackupView()
                }
            }
        }
    }

    /// Shows an error toast and clears it a few seconds later, unless a newer one replaced it.
    private func showErrorToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) { toastMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard toastToken == token else { return }
            withAnimation(.easeIn(duration: 0.2)) { toastMessage = nil }
        }
    }

    /// Whether the signed-in account has a passphrase (Back Up to NFC Card needs one). Asked
    /// once per account: WalletManager answers from a stored flag, reading the words (off the
    /// main thread) only for an older account that has none yet.
    private func refreshPassphraseFlag() async {
        guard let address = walletManager.currentWallet?.publicAddress else {
            accountHasPassphrase = false
            passphraseCheckedAddress = nil
            return
        }
        guard passphraseCheckedAddress != address else { return }
        let hasPassphrase = await walletManager.currentAccountHasPassphrase()
        // The account may have changed while the seed was read.
        guard walletManager.currentWallet?.publicAddress == address else { return }
        accountHasPassphrase = hasPassphrase
        passphraseCheckedAddress = address
    }

    /// The seed phrase, behind the biometric gate when enabled.
    private var backUpAccountPage: some View {
        Form {
            if backupStatus.isPending(walletManager.currentWallet?.publicAddress) {
                Section {
                    Button {
                        AccountBackupView.unlock { showAccountBackup = true }
                    } label: {
                        Label {
                            Text("Complete Your Backup")
                                .foregroundColor(.primary)
                        } icon: {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            Section {
                Button {
                    unlockSeedPhrase { showSeedPhrase = true }
                } label: {
                    Label {
                        Text("View 12 or 24 Words")
                            .foregroundColor(.primary)
                    } icon: {
                        Image(systemName: "key")
                            .foregroundColor(.accentColor)
                    }
                }
                #if canImport(CoreNFC) && !targetEnvironment(macCatalyst)
                // Without a passphrase, nothing would protect the seed if someone got past the PIN.
                if NFCCard.isAvailable && accountHasPassphrase {
                    Button {
                        unlockSeedPhrase { showNFCCardBackup = true }
                    } label: {
                        Label {
                            Text("Back Up to NFC Card")
                                .foregroundColor(.primary)
                        } icon: {
                            Image(systemName: "wave.3.right")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                #endif
            }
        }
        .navigationTitle("Back Up Account")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func unlockSeedPhrase(_ show: @escaping () -> Void) {
        if settingsViewModel.settings.biometricSeedPhraseEnabled {
            DeviceAuth.authenticate(reason: AppLocalization.string("Unlock to view your 12 or 24 words"), onSuccess: show)
        } else {
            show()
        }
    }
}

// MARK: - Account name

/// Your own label for this account, on this device. Saved when you leave the screen or tap Done,
/// into the saved-accounts list and the account's wallet record (`renameSavedAccount`).
private struct AccountNamePage: View {
    @EnvironmentObject private var walletManager: WalletManager
    @State private var name = ""

    var body: some View {
        Form {
            Section {
                TextField("Account name", text: $name)
                    .submitLabel(.done)
                    .onSubmit(save)
            }
        }
        .navigationTitle("Account Name")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = walletManager.currentWallet?.alias ?? "" }
        .onDisappear(perform: save)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let wallet = walletManager.currentWallet, !trimmed.isEmpty, trimmed != wallet.alias,
              let account = walletManager.savedAccounts.first(where: { WalletManager.isSameAccount($0.publicAddress, wallet.publicAddress) })
        else { return }
        walletManager.renameSavedAccount(account, to: trimmed)
    }
}

// MARK: - About

/// Settings > About: this account's created date, then the app's version, links and licenses.
/// The same page as KaChat's, with its website, support email and privacy policy.
private struct AccountAboutPage: View {
    @EnvironmentObject private var walletManager: WalletManager

    @State private var showOpenSourceLicenses = false

    private static let websiteURL = URL(string: "https://home.kachat.app")!
    private static let privacyPolicyURL = URL(string: "https://home.kachat.app/privacy/")!
    private static let supportEmailURL = URL(string: "mailto:kaspasilver@gmail.com")!

    var body: some View {
        Form {
            Section {
                if let wallet = walletManager.currentWallet {
                    HStack {
                        Text("Created")
                        Spacer()
                        Text(SharedFormatting.mediumDateShortTime.string(from: wallet.createdAt))
                            .foregroundColor(.secondary)
                    }
                }
                HStack {
                    Text("Version")
                    Spacer()
                    Text(verbatim: AppVersion.display)
                        .foregroundColor(.secondary)
                }
                Link(destination: Self.websiteURL) {
                    HStack {
                        Text("Website")
                            .foregroundColor(.primary)
                        Spacer()
                        Text(verbatim: "home.kachat.app")
                            .foregroundColor(.secondary)
                    }
                }
                Link(destination: Self.supportEmailURL) {
                    HStack {
                        Text("Support Email")
                            .foregroundColor(.primary)
                        Spacer()
                        Text(verbatim: "kaspasilver@gmail.com")
                            .foregroundColor(.secondary)
                    }
                }
                Link(destination: Self.privacyPolicyURL) {
                    HStack {
                        Text("Privacy Policy")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                }
                Button {
                    showOpenSourceLicenses = true
                } label: {
                    HStack {
                        Text("Open Source Licenses")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showOpenSourceLicenses) {
            OpenSourceLicensesView()
        }
    }
}
