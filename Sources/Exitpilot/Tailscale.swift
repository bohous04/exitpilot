import Foundation

struct ExitNodeOption: Identifiable, Hashable {
    let ip: String
    let name: String
    let online: Bool
    var id: String { ip }
}

struct TailscaleStatus {
    var running: Bool
    var activeExitNodeIP: String?
    var options: [ExitNodeOption]
}

struct NetCheck {
    var udp: Bool
    var ipv4: Bool
    var mappingVariesByDestIP: Bool
    /// Public IPv4 of the physical network, used to tell networks apart.
    var publicIP: String?

    /// A NAT that peer-to-peer apps (Parsec, games, WebRTC) can't punch through.
    var restrictive: Bool { !udp || mappingVariesByDestIP }
}

enum TailscaleError: LocalizedError {
    case notInstalled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Tailscale CLI not found"
        case .failed(let message): return message.isEmpty ? "tailscale command failed" : message
        }
    }
}

enum Tailscale {
    static let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    static var binary: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func status() async throws -> TailscaleStatus {
        let data = try await run(["status", "--json"])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TailscaleError.failed("Unexpected status output")
        }
        let running = (json["BackendState"] as? String) == "Running"
        let activeIP = ((json["ExitNodeStatus"] as? [String: Any])?["TailscaleIPs"] as? [String])?
            .first.map(stripPrefix)

        let peers = (json["Peer"] as? [String: [String: Any]])?.values.map { $0 } ?? []
        let options = peers.compactMap { peer -> ExitNodeOption? in
            guard peer["ExitNodeOption"] as? Bool == true,
                  let ip = (peer["TailscaleIPs"] as? [String])?.first.map(stripPrefix) else { return nil }
            let dnsName = (peer["DNSName"] as? String) ?? ""
            let name = dnsName.split(separator: ".").first.map(String.init)
                ?? (peer["HostName"] as? String) ?? ip
            return ExitNodeOption(ip: ip, name: name, online: peer["Online"] as? Bool ?? false)
        }.sorted { $0.name < $1.name }

        return TailscaleStatus(running: running, activeExitNodeIP: activeIP, options: options)
    }

    static func netcheck() async throws -> NetCheck {
        let data = try await run(["netcheck", "--format=json"])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TailscaleError.failed("Unexpected netcheck output")
        }
        return NetCheck(
            udp: json["UDP"] as? Bool ?? false,
            ipv4: json["IPv4"] as? Bool ?? false,
            mappingVariesByDestIP: json["MappingVariesByDestIP"] as? Bool ?? false,
            publicIP: (json["GlobalV4"] as? String)?.split(separator: ":").first.map(String.init)
        )
    }

    static func setExitNode(_ ip: String?, allowLANAccess: Bool) async throws {
        if let ip {
            _ = try await run(["set", "--exit-node=\(ip)", "--exit-node-allow-lan-access=\(allowLANAccess)"])
        } else {
            _ = try await run(["set", "--exit-node="])
        }
    }

    private static func stripPrefix(_ cidr: String) -> String {
        String(cidr.split(separator: "/").first ?? Substring(cidr))
    }

    private static func run(_ args: [String]) async throws -> Data {
        guard let binary else { throw TailscaleError.notInstalled }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = args
                let stdout = Pipe(), stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // Drain stderr concurrently so a chatty command can't block on a full pipe.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: outData)
                } else {
                    let message = String(decoding: errData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: TailscaleError.failed(message))
                }
            }
        }
    }
}
