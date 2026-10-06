import Foundation

/// The last few days of sleep, charge and stay-awake requests, from the log
/// macOS keeps for itself.
///
/// `pmset -g log` is power management's own record: every sleep and wake
/// with the charge at that moment, and every request a process made to keep
/// the Mac awake, with how long it was held. macOS keeps about a week of it
/// and anyone can read it. That is what lets Brim answer "why did my battery
/// go down overnight" without watching anything: the history was written by
/// macOS whether Brim was running or not, and Brim reads it when the page
/// opens.
public struct PowerHistory: Sendable, Equatable {
    /// Charge at one moment the log recorded it.
    public struct ChargePoint: Sendable, Equatable {
        public let time: Date
        public let percent: Int
        public let onBattery: Bool

        public init(time: Date, percent: Int, onBattery: Bool) {
            self.time = time
            self.percent = percent
            self.onBattery = onBattery
        }
    }

    /// A stretch the Mac spent asleep, from going to sleep to the next full
    /// wake. Brief wakes for maintenance inside it are counted, not split
    /// out: the screen stayed off and nobody was using it.
    public struct Sleep: Sendable, Equatable {
        public let span: DateInterval
        public let chargeAtStart: Int?
        public let chargeAtEnd: Int?
        /// Whether any of it was on the adapter, in which case the charge
        /// says nothing about what sleeping cost.
        public let onAdapter: Bool
        public let briefWakes: Int

        public var duration: TimeInterval {
            span.duration
        }

        /// Percentage points of charge used, when the whole stretch was on
        /// battery.
        public var chargeUsed: Int? {
            guard !onAdapter, let start = chargeAtStart, let end = chargeAtEnd else { return nil }
            return max(0, start - end)
        }
    }

    /// How long one process asked the Mac not to sleep, overlaps counted
    /// once.
    public struct Request: Sendable, Equatable {
        /// The process name as the log gives it, or the application's
        /// identifier when the request was made on an application's behalf.
        public let requester: String
        public let isIdentifier: Bool
        /// The stretches it was held, kept so requests that turn out to be
        /// the same application's can be added up without counting an
        /// overlap twice.
        public let spans: [DateInterval]

        public var seconds: TimeInterval {
            PowerHistory.union(spans)
        }

        public init(requester: String, isIdentifier: Bool, spans: [DateInterval]) {
            self.requester = requester
            self.isIdentifier = isIdentifier
            self.spans = spans
        }
    }

    public let charge: [ChargePoint]
    public let sleeps: [Sleep]
    public let requests: [Request]
    /// The earliest moment the log covers.
    public let since: Date?

    /// The most recent stretch asleep that lasted at least half an hour.
    public var lastSleep: Sleep? {
        sleeps.last { $0.duration >= 30 * 60 }
    }

    /// Requests added up per application, busiest first. A process no
    /// application answers to is macOS's own and is left out. Safari asks
    /// for itself and is asked for by `runningboardd`, and the two are one
    /// app's time, counted once.
    public func requestsByApplication(_ names: ApplicationNames) -> [ApplicationNames.Held] {
        var grouped: [String: (app: ApplicationNames.App, spans: [DateInterval])] = [:]
        for request in requests {
            guard let app = names.app(for: request) else { continue }
            grouped[app.bundlePath, default: (app, [])].spans += request.spans
        }
        return grouped.values
            .map { ApplicationNames.Held(app: $0.app, seconds: Self.union($0.spans)) }
            .filter { $0.seconds >= 60 }
            .sorted { $0.seconds > $1.seconds }
    }

    // MARK: - Reading

    /// About two and a half seconds on this Mac, so never on the main
    /// thread.
    public static func current(now: Date = Date()) -> PowerHistory? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "log"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(bytes: data, encoding: .utf8) else { return nil }
        return parse(text, now: now)
    }

    public static func parse(_ log: String, now: Date) -> PowerHistory {
        var reader = PowerLogReader()
        for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let entry = PowerLogEntry(line) else { continue }
            reader.read(entry)
        }
        return reader.history(now: now)
    }

    /// Total time covered by possibly overlapping spans.
    static func union(_ spans: [DateInterval]) -> TimeInterval {
        var total: TimeInterval = 0
        var current: DateInterval?
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let open = current, span.start <= open.end {
                current = DateInterval(start: open.start, end: max(open.end, span.end))
            } else {
                total += current?.duration ?? 0
                current = span
            }
        }
        return total + (current?.duration ?? 0)
    }
}

// MARK: - Reading the log line by line

/// Walks the log in order, keeping the stretch asleep and the requests that
/// are still open.
struct PowerLogReader {
    /// The kinds of request that hold off sleep for the whole Mac. Display
    /// requests are left out: a lit screen is a different question.
    static let systemKinds: Set<String> = [
        "PreventUserIdleSystemSleep", "NoIdleSleepAssertion", "PreventSystemSleep"
    ]

    /// The verbs that end a request, each followed by how long it was held.
    static let endings: Set<String> = ["Released", "TimedOut", "ClientDied", "TurnedOff"]

    private struct Asleep {
        let start: Date
        let charge: Int?
        var onAdapter: Bool
        var briefWakes = 0
    }

    private struct Open {
        let requester: String
        let isIdentifier: Bool
        let start: Date
    }

    private struct Held {
        let isIdentifier: Bool
        var spans: [DateInterval]
    }

    private var charge: [PowerHistory.ChargePoint] = []
    private var sleeps: [PowerHistory.Sleep] = []
    private var asleep: Asleep?
    private var open: [String: Open] = [:]
    private var held: [String: Held] = [:]
    private var since: Date?

    mutating func read(_ entry: PowerLogEntry) {
        since = since ?? entry.time
        switch entry.domain {
        case "Sleep": readSleep(entry)
        case "DarkWake": readBriefWake(entry)
        case "Wake": readWake(entry)
        case "Assertions": readRequest(entry)
        default: break
        }
    }

    private mutating func record(_ entry: PowerLogEntry) -> PowerLogEntry.Charge? {
        guard let reading = entry.charge else { return nil }
        charge.append(.init(time: entry.time, percent: reading.percent, onBattery: reading.onBattery))
        return reading
    }

    private mutating func readSleep(_ entry: PowerLogEntry) {
        let reading = record(entry)
        let onAdapter = reading.map { !$0.onBattery } ?? false
        // Sleep lines after a brief wake belong to the stretch already open.
        if asleep == nil {
            asleep = Asleep(start: entry.time, charge: reading?.percent, onAdapter: onAdapter)
        } else if onAdapter {
            asleep?.onAdapter = true
        }
    }

    private mutating func readBriefWake(_ entry: PowerLogEntry) {
        let reading = record(entry)
        asleep?.briefWakes += 1
        if reading?.onBattery == false {
            asleep?.onAdapter = true
        }
    }

    private mutating func readWake(_ entry: PowerLogEntry) {
        let reading = record(entry)
        defer { asleep = nil }
        guard let stretch = asleep, entry.time > stretch.start else { return }
        sleeps.append(PowerHistory.Sleep(
            span: DateInterval(start: stretch.start, end: entry.time),
            chargeAtStart: stretch.charge, chargeAtEnd: reading?.percent,
            onAdapter: stretch.onAdapter || reading?.onBattery == false,
            briefWakes: stretch.briefWakes
        ))
    }

    private mutating func readRequest(_ entry: PowerLogEntry) {
        guard let request = PowerLogRequest(entry.message), Self.systemKinds.contains(request.kind) else { return }
        if request.verb == "Created" || request.verb == "TurnedOn" {
            open[request.id] = Open(requester: request.requester, isIdentifier: request.isIdentifier, start: entry.time)
        } else if Self.endings.contains(request.verb) {
            let start = open.removeValue(forKey: request.id)?.start ?? entry.time.addingTimeInterval(-request.held)
            add(request.requester, isIdentifier: request.isIdentifier, from: start, to: entry.time)
        }
    }

    private mutating func add(_ requester: String, isIdentifier: Bool, from start: Date, to end: Date) {
        guard end > start else { return }
        held[requester, default: Held(isIdentifier: isIdentifier, spans: [])]
            .spans.append(DateInterval(start: start, end: end))
    }

    /// Requests still open when the log ends are held until now.
    mutating func history(now: Date) -> PowerHistory {
        for request in open.values {
            add(request.requester, isIdentifier: request.isIdentifier, from: request.start, to: now)
        }
        open = [:]
        let requests = held
            .map { PowerHistory.Request(requester: $0.key, isIdentifier: $0.value.isIdentifier, spans: $0.value.spans) }
            .filter { $0.seconds >= 60 }
            .sorted { $0.seconds > $1.seconds }
        return PowerHistory(charge: charge, sleeps: sleeps, requests: requests, since: since)
    }
}

/// One line: a timestamp, a domain padded to a column, a tab, then the
/// message.
struct PowerLogEntry {
    struct Charge {
        let percent: Int
        let onBattery: Bool
    }

    let time: Date
    let domain: Substring
    let message: Substring

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()

    private static let wanted: Set<Substring> = ["Sleep", "Wake", "DarkWake", "Assertions"]

    init?(_ line: Substring) {
        guard line.count > 26, line.first?.isNumber == true, let tab = line.firstIndex(of: "\t") else { return nil }
        let head = line[..<tab]
        let stampEnd = head.index(head.startIndex, offsetBy: 25, limitedBy: head.endIndex) ?? head.endIndex
        let domain = Substring(head[stampEnd...].trimmingCharacters(in: .whitespaces))
        let message = line[line.index(after: tab)...]
        // Only the lines used here pay for a date parse. Nearly all of the
        // log is requests of kinds that do not matter here, and parsing
        // every date took four seconds.
        guard Self.wanted.contains(domain),
              domain != "Assertions" || PowerLogReader.systemKinds.contains(where: { message.contains($0) }),
              let time = Self.stamp.date(from: head[..<stampEnd].trimmingCharacters(in: .whitespaces))
        else { return nil }
        self.time = time
        self.domain = domain
        self.message = message
    }

    static func date(_ text: String) -> Date? {
        stamp.date(from: text)
    }

    /// `Using Batt (Charge:80%)` or `Using AC (Charge:80%)`, in either case.
    var charge: Charge? {
        guard let range = message.range(of: "(Charge:") else { return nil }
        guard let percent = Int(message[range.upperBound...].prefix { $0.isNumber }) else { return nil }
        let before = message[..<range.lowerBound].lowercased()
        return Charge(percent: percent, onBattery: before.hasSuffix("using batt "))
    }
}

/// `PID 2158(ChatGPT) Released NoIdleSleepAssertion "Electron" 00:01:22  id:0x0x1000089e5 [...]`
struct PowerLogRequest {
    /// Processes that hold requests for others. A request from one of these
    /// counts only when it names the application it was made for.
    static let brokers: Set<String> = ["runningboardd"]

    let requester: String
    let isIdentifier: Bool
    let verb: String
    let kind: String
    let held: TimeInterval
    let id: String

    init?(_ message: Substring) {
        guard message.hasPrefix("PID "),
              let open = message.firstIndex(of: "("),
              let close = message[open...].firstIndex(of: ")") else { return nil }
        let process = String(message[message.index(after: open) ..< close])
        let words = message[message.index(after: close)...].split(separator: " ", maxSplits: 2)
        guard words.count == 3, let idRange = words[2].range(of: "id:") else { return nil }
        verb = String(words[0])
        kind = String(words[1])
        id = String(words[2][idRange.upperBound...].prefix { !$0.isWhitespace })
        let clock = words[2][..<idRange.lowerBound].split(separator: " ").last.map(String.init) ?? ""
        held = Self.seconds(clock)

        if Self.brokers.contains(process) {
            // `app<application.com.apple.Safari.512363.513029(501)>...`
            guard let named = Self.applicationIdentifier(in: words[2]) else { return nil }
            requester = named
            isIdentifier = true
        } else {
            requester = process
            isIdentifier = false
        }
    }

    static func seconds(_ clock: String) -> TimeInterval {
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    static func applicationIdentifier(in text: Substring) -> String? {
        guard let start = text.range(of: "application.") else { return nil }
        let labels = text[start.upperBound...].prefix { $0 != "(" && $0 != ">" }.split(separator: ".")
        let named = labels.prefix { !$0.allSatisfy(\.isNumber) }
        return named.isEmpty ? nil : named.joined(separator: ".")
    }
}
