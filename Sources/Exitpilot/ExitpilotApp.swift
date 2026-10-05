import SwiftUI

@main
struct ExitpilotApp: App {
    @StateObject private var controller = Controller()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarSymbol: String {
        guard let status = controller.status, status.running else { return "exclamationmark.triangle" }
        return status.activeExitNodeIP != nil ? "network.badge.shield.half.filled" : "network"
    }
}

struct MenuContent: View {
    @ObservedObject var controller: Controller

    var body: some View {
        Text(exitNodeLine)
        Text(networkLine)
        if let error = controller.lastError {
            Text("⚠︎ \(error)")
        }

        Divider()

        if controller.activeExitNode != nil {
            Button("Turn Exit Node Off") { Task { await controller.turnOff() } }
        } else {
            Button(turnOnTitle) { Task { await controller.turnOn() } }
                .disabled(controller.status?.options.isEmpty ?? true)
        }

        Picker("Exit Node", selection: Binding(
            get: { controller.preferredExitNode },
            set: { ip in Task { await controller.selectExitNode(ip) } }
        )) {
            ForEach(controller.status?.options ?? []) { option in
                Text(option.online ? option.name : "\(option.name) (offline)").tag(option.ip)
            }
        }

        Divider()

        Toggle("Automatic Switching", isOn: $controller.autoMode)
        if controller.manualOverride {
            Text("Paused until the network changes")
        }
        Toggle("Allow LAN Access", isOn: $controller.allowLANAccess)
        Toggle("Notifications", isOn: $controller.notificationsEnabled)
        Toggle("Launch at Login", isOn: Binding(
            get: { controller.launchAtLogin },
            set: { controller.setLaunchAtLogin($0) }
        ))

        Divider()

        Button(controller.checking ? "Checking…" : "Check Network Now") {
            Task { await controller.evaluate() }
        }
        .disabled(controller.checking)
        .keyboardShortcut("r")

        Button("Quit Exitpilot") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var exitNodeLine: String {
        if let node = controller.activeExitNode { return "Exit node: \(node.name) ●" }
        return "Exit node: off"
    }

    private var networkLine: String {
        guard let check = controller.netcheck else {
            return controller.checking ? "Network: checking…" : "Network: unknown"
        }
        if !check.udp { return "Network: UDP blocked (restrictive)" }
        return check.mappingVariesByDestIP ? "Network: strict NAT (restrictive)" : "Network: open NAT"
    }

    private var turnOnTitle: String {
        guard let name = controller.preferredOption?.name ?? controller.status?.options.first?.name else {
            return "Turn Exit Node On"
        }
        return "Turn On via \(name)"
    }
}
