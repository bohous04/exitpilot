import SwiftUI

@main
struct ExitpilotApp: App {
    @StateObject private var controller = Controller()

    var body: some Scene {
        MenuBarExtra {
            PanelView(controller: controller)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        guard let status = controller.status, status.running else { return "exclamationmark.triangle" }
        return status.activeExitNodeIP != nil ? "network.badge.shield.half.filled" : "network"
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var controller: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            StatusCard(controller: controller)
            if controller.manualOverride { pausedBanner }
            if let error = controller.lastError { errorBanner(error) }
            exitNodeSection
            Divider()
            settingsSection
            Divider()
            footer
        }
        .padding(.horizontal, 14)
        // The header switch is taller than its text, so less top padding looks even.
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("Exitpilot").font(.headline)
            Spacer()
            Text("Tailscale").foregroundStyle(.secondary)
            Toggle("Tailscale", isOn: Binding(
                get: { controller.isConnected },
                set: { connected in Task { await controller.setConnected(connected) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            // Small/mini switches measure 22 pt until they are in a window, and MenuBarExtra
            // sizes its window before that, which leaves an empty band above and below.
            .frame(height: 18)
            .disabled(controller.checking || controller.status == nil)
        }
    }

    private var pausedBanner: some View {
        Banner(symbol: "pause.circle.fill", tint: .orange,
               text: "Automatic switching is paused until the network changes.") {
            Button("Resume") { Task { await controller.resumeAutomation() } }
                .controlSize(.small)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Banner(symbol: "xmark.octagon.fill", tint: .red, text: message) { EmptyView() }
    }

    private var exitNodeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Exit node")
            HStack(spacing: 8) {
                Picker("Exit node", selection: Binding(
                    get: { controller.preferredExitNode },
                    set: { ip in Task { await controller.selectExitNode(ip) } }
                )) {
                    if controller.preferredOption == nil {
                        Text("Choose…").tag(controller.preferredExitNode)
                    }
                    ForEach(controller.status?.options ?? []) { option in
                        Text(option.online ? option.name : "\(option.name) (offline)").tag(option.ip)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                if controller.activeExitNode != nil {
                    Button("Turn Off") { Task { await controller.turnOff() } }
                        .disabled(!controller.isConnected)
                } else {
                    Button("Turn On") { Task { await controller.turnOn() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.status?.options.isEmpty ?? true)
                }
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingRow("Switch automatically", isOn: $controller.autoMode)
            SettingRow("Allow LAN access", isOn: $controller.allowLANAccess)
            SettingRow("Notifications", isOn: $controller.notificationsEnabled)
            SettingRow("Launch at login", isOn: Binding(
                get: { controller.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            ))
        }
    }

    private var footer: some View {
        HStack {
            Button {
                Task { await controller.evaluate() }
            } label: {
                if controller.checking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Checking…")
                    }
                } else {
                    Label("Check Network", systemImage: "arrow.clockwise")
                }
            }
            .disabled(controller.checking)
            .keyboardShortcut("r")

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
    }
}

// MARK: - Status card

struct StatusCard: View {
    @ObservedObject var controller: Controller

    private struct Look {
        var symbol: String
        var tint: Color
        var title: String
        var detail: String
    }

    var body: some View {
        let look = self.look
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(look.tint.gradient)
                Image(systemName: look.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(look.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(look.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(look.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(look.tint.opacity(0.35))
        )
    }

    private var look: Look {
        guard controller.status != nil else {
            return Look(symbol: "hourglass", tint: .gray, title: "Connecting…",
                        detail: "Reading Tailscale status")
        }
        guard controller.isConnected else {
            return Look(symbol: "power", tint: .gray, title: "Tailscale is off",
                        detail: "Turn it on to use an exit node")
        }
        let network = networkDescription
        if let node = controller.activeExitNode {
            return Look(symbol: "checkmark.shield.fill", tint: .green,
                        title: "Routing via \(node.name)", detail: network.text)
        }
        if network.restrictive == true {
            return Look(symbol: "exclamationmark.triangle.fill", tint: .orange,
                        title: "Restrictive network",
                        detail: "\(network.text). Peer-to-peer apps may fail without an exit node.")
        }
        return Look(symbol: "arrow.right.circle.fill", tint: .blue,
                    title: "Direct connection", detail: network.text)
    }

    /// `restrictive` is nil while the network hasn't been measured yet.
    private var networkDescription: (text: String, restrictive: Bool?) {
        guard let check = controller.netcheck else {
            return (controller.checking ? "Checking network…" : "Network not checked yet", nil)
        }
        if !check.udp { return ("UDP is blocked on this network", true) }
        if check.mappingVariesByDestIP { return ("Strict NAT on this network", true) }
        return ("Open network, no exit node needed", false)
    }
}

// MARK: - Building blocks

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct SettingRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .frame(height: 16)
    }
}

private struct Banner<Action: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            action()
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
