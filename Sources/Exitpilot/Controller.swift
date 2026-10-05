import Foundation
import Network
import ServiceManagement
import UserNotifications

@MainActor
final class Controller: ObservableObject {
    @Published private(set) var status: TailscaleStatus?
    @Published private(set) var netcheck: NetCheck?
    @Published private(set) var checking = false
    @Published private(set) var lastError: String?
    @Published private(set) var manualOverride = false
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    @Published var autoMode: Bool {
        didSet {
            defaults.set(autoMode, forKey: Keys.autoMode)
            if autoMode { manualOverride = false; Task { await evaluate() } }
        }
    }
    @Published var preferredExitNode: String {
        didSet { defaults.set(preferredExitNode, forKey: Keys.preferredExitNode) }
    }
    @Published var allowLANAccess: Bool {
        didSet { defaults.set(allowLANAccess, forKey: Keys.allowLANAccess) }
    }
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) }
    }

    private enum Keys {
        static let autoMode = "autoMode"
        static let preferredExitNode = "preferredExitNode"
        static let allowLANAccess = "allowLANAccess"
        static let notifications = "notifications"
    }

    private let defaults = UserDefaults.standard
    private let pathMonitor = NWPathMonitor()
    private var pathDebounce: Task<Void, Never>?
    private var timer: Timer?
    /// Public IP of the network the manual override was made on.
    private var overrideNetwork: String?

    init() {
        defaults.register(defaults: [
            Keys.autoMode: true,
            Keys.allowLANAccess: true,
            Keys.notifications: true,
        ])
        autoMode = defaults.bool(forKey: Keys.autoMode)
        preferredExitNode = defaults.string(forKey: Keys.preferredExitNode) ?? ""
        allowLANAccess = defaults.bool(forKey: Keys.allowLANAccess)
        notificationsEnabled = defaults.bool(forKey: Keys.notifications)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
        pathMonitor.start(queue: .global(qos: .utility))

        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.evaluate() }
        }
        Task { await evaluate() }
    }

    // MARK: - Derived state

    var activeExitNode: ExitNodeOption? {
        guard let ip = status?.activeExitNodeIP else { return nil }
        return status?.options.first { $0.ip == ip } ?? ExitNodeOption(ip: ip, name: ip, online: true)
    }

    var preferredOption: ExitNodeOption? {
        status?.options.first { $0.ip == preferredExitNode }
    }

    // MARK: - Actions

    func turnOn() async {
        guard let target = preferredOption ?? status?.options.first else {
            lastError = "No exit node available in your tailnet"
            return
        }
        holdManualChoice()
        await apply(target.ip)
    }

    func turnOff() async {
        holdManualChoice()
        await apply(nil)
    }

    /// A manual choice wins over automation until the physical network changes.
    private func holdManualChoice() {
        guard autoMode else { return }
        manualOverride = true
        overrideNetwork = netcheck?.publicIP
    }

    func selectExitNode(_ ip: String) async {
        preferredExitNode = ip
        if status?.activeExitNodeIP != nil { await apply(ip) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Automation

    private func networkChanged() {
        pathDebounce?.cancel()
        pathDebounce = Task {
            // Let DHCP/DNS settle before measuring the new network.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await evaluate()
        }
    }

    func evaluate() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }

        do {
            let current = try await Tailscale.status()
            status = current
            if preferredExitNode.isEmpty, current.options.count == 1 {
                preferredExitNode = current.options[0].ip
            }
            guard current.running else {
                lastError = "Tailscale is not connected"
                return
            }
            // netcheck measures the physical network even while an exit node is active.
            let check = try await Tailscale.netcheck()
            netcheck = check
            lastError = nil
            // Toggling the exit node itself fires path updates, so only a new
            // public IP counts as a different network.
            if manualOverride, check.publicIP != overrideNetwork {
                manualOverride = false
            }

            guard autoMode, !manualOverride, check.ipv4, let target = preferredOption else { return }
            if check.restrictive, current.activeExitNodeIP == nil {
                await apply(target.ip, notice: "Restrictive network – routing through \(target.name)")
            } else if !check.restrictive, current.activeExitNodeIP == target.ip {
                await apply(nil, notice: "Open network – exit node turned off")
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func apply(_ ip: String?, notice: String? = nil) async {
        do {
            try await Tailscale.setExitNode(ip, allowLANAccess: allowLANAccess)
            status = try await Tailscale.status()
            lastError = nil
            if let notice { notify(notice) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func notify(_ body: String) {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Exitpilot"
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
