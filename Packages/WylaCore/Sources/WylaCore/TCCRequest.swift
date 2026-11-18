import Foundation

/// A process named in a TCC attribution chain.
public struct TCCProcess: Hashable, Sendable, Codable {
    public let identifier: String
    public let pid: Int
    public let binaryPath: String?

    public init(identifier: String, pid: Int, binaryPath: String?) {
        self.identifier = identifier
        self.pid = pid
        self.binaryPath = binaryPath
    }
}

/// One TCC access check, joined from its `AUTHREQ_CTX`, `AUTHREQ_ATTRIBUTION`, and `AUTHREQ_RESULT` lines.
public struct TCCRequest: Sendable, Equatable {
    public let messageID: String
    /// The time of the `AUTHREQ_CTX` line.
    public let time: Date
    /// The TCC service, for example `kTCCServiceCamera`.
    public let service: String
    public let responsible: TCCProcess?
    public let accessing: TCCProcess?
    public let requesting: TCCProcess?
    /// TCC's result: 0 denied, 1 unknown, 2 allowed, 3 limited.
    public let authValue: Int

    public init(
        messageID: String, time: Date, service: String, responsible: TCCProcess?, accessing: TCCProcess?, requesting: TCCProcess?,
        authValue: Int
    ) {
        self.messageID = messageID
        self.time = time
        self.service = service
        self.responsible = responsible
        self.accessing = accessing
        self.requesting = requesting
        self.authValue = authValue
    }

    public var sensor: Sensor? {
        switch service {
        case "kTCCServiceCamera": .camera
        case "kTCCServiceMicrophone": .microphone
        case "kTCCServiceScreenCapture": .screen
        default: nil
        }
    }

    /// The app TCC holds responsible. TCC omits `responsible` when a process is its own
    /// responsible process, and omits `accessing` when the app checks its own access.
    public var responsibleApp: TCCProcess? { responsible ?? accessing ?? requesting }
}

/// Joins the TCC `access` log lines of each request, keyed by `msgID`.
public struct TCCRequestAssembler: Sendable {
    /// Requests whose result hasn't arrived after this long are dropped.
    public static let pendingLifetime: TimeInterval = 10

    private struct Pending: Sendable {
        let time: Date
        let service: String
        var chain: [String: TCCProcess] = [:]
    }

    private var pending: [String: Pending] = [:]

    public init() {}

    public mutating func consume(_ event: LogEvent) -> ParseResult<TCCRequest> {
        pending = pending.filter { event.timestamp.timeIntervalSince($0.value.time) < Self.pendingLifetime }
        let message = event.message
        if message.hasPrefix("AUTHREQ_CTX: ") {
            guard let match = message.firstMatch(of: /^AUTHREQ_CTX: msgID=([^,]+), .*?service=(\w+)/) else {
                return .unparsed(reason: "AUTHREQ_CTX line has an unknown format")
            }
            pending[String(match.1)] = Pending(time: event.timestamp, service: String(match.2))
            return .ignored
        }
        if message.hasPrefix("AUTHREQ_ATTRIBUTION: ") {
            guard let match = message.firstMatch(of: /^AUTHREQ_ATTRIBUTION: msgID=([^,]+), attribution=/) else {
                return .unparsed(reason: "AUTHREQ_ATTRIBUTION line has an unknown format")
            }
            pending[String(match.1)]?.chain = Self.parseChain(message)
            return .ignored
        }
        if message.hasPrefix("AUTHREQ_RESULT: ") {
            return complete(message)
        }
        return .ignored
    }

    private mutating func complete(_ message: String) -> ParseResult<TCCRequest> {
        guard let match = message.firstMatch(of: /^AUTHREQ_RESULT: msgID=([^,]+), authValue=(\d+)/),
            let authValue = Int(match.2)
        else {
            return .unparsed(reason: "AUTHREQ_RESULT line has an unknown format")
        }
        let messageID = String(match.1)
        guard let request = pending.removeValue(forKey: messageID) else { return .ignored }
        return .event(
            TCCRequest(
                messageID: messageID, time: request.time, service: request.service,
                responsible: request.chain["responsible"], accessing: request.chain["accessing"],
                requesting: request.chain["requesting"], authValue: authValue))
    }

    /// `responsible={TCCDProcess: identifier=…, pid=…, …, binary_path=…}, accessing={…}`
    private static func parseChain(_ message: String) -> [String: TCCProcess] {
        let process = /(responsible|accessing|requesting)=\{TCCDProcess: identifier=([^,}]+), pid=(\d+)([^}]*)\}/
        var chain: [String: TCCProcess] = [:]
        for match in message.matches(of: process) {
            guard let pid = Int(match.3) else { continue }
            let path = match.4.firstMatch(of: /binary_path=([^,}]+)/).map { String($0.1) }
            chain[String(match.1)] = TCCProcess(identifier: String(match.2), pid: pid, binaryPath: path)
        }
        return chain
    }
}
