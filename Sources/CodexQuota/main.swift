import AppKit

struct QuotaWindow: Sendable, Decodable {
    let usedPercent: Int
    let resetsAt: TimeInterval?
    var windowDurationMins: Int? = nil

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
}

struct QuotaSnapshot: Sendable {
    let primary: QuotaWindow
    let secondary: QuotaWindow?
    let fetchedAt: Date
}

enum QuotaError: LocalizedError, Sendable {
    case malformedResponse
    case unavailable
    case timedOut
    case disconnected

    var errorDescription: String? {
        switch self {
        case .malformedResponse: "Codex вернул неожиданный ответ"
        case .unavailable: "Не удалось получить лимиты Codex"
        case .timedOut: "Codex не ответил вовремя"
        case .disconnected: "Соединение потеряно, переподключаюсь…"
        }
    }
}

private struct RateLimits: Decodable {
    let limitId: String?
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
}

private struct RPCMessage: Decodable {
    struct ResultPayload: Decodable {
        let rateLimits: RateLimits?
        let rateLimitsByLimitId: [String: RateLimits]?
    }
    struct Params: Decodable { let rateLimits: RateLimits? }
    struct ServerError: Decodable { let code: Int }
    let id: Int?
    let method: String?
    let result: ResultPayload?
    let params: Params?
    let error: ServerError?
}

private struct QuotaState {
    private var primary: QuotaWindow?
    private var secondary: QuotaWindow?

    mutating func apply(_ limits: RateLimits, sparse: Bool) throws -> QuotaSnapshot? {
        // Separate model buckets must never overwrite the main Codex quota.
        guard limits.limitId == nil || limits.limitId == "codex" else { return nil }
        if sparse && limits.primary == nil && limits.secondary == nil { return nil }
        if sparse {
            primary = merge(limits.primary, with: primary)
            secondary = merge(limits.secondary, with: secondary)
        } else {
            primary = limits.primary
            secondary = limits.secondary
        }
        // Classify by reported duration, not by the primary/secondary position.
        let windows = [primary, secondary].compactMap { $0 }
        guard let fiveHours = windows.first(where: { $0.windowDurationMins == 300 }) else {
            if sparse { return nil }
            throw QuotaError.malformedResponse
        }
        return QuotaSnapshot(primary: fiveHours,
                             secondary: windows.first(where: { $0.windowDurationMins == 10_080 }),
                             fetchedAt: Date())
    }

    private func merge(_ update: QuotaWindow?, with previous: QuotaWindow?) -> QuotaWindow? {
        guard let update else { return previous }
        let sameWindow = update.windowDurationMins == nil || update.windowDurationMins == previous?.windowDurationMins
        return QuotaWindow(usedPercent: update.usedPercent,
                           resetsAt: update.resetsAt ?? (sameWindow ? previous?.resetsAt : nil),
                           windowDurationMins: update.windowDurationMins ?? previous?.windowDurationMins)
    }
}

private struct JSONLines {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        guard buffer.count <= 1_048_576 else { throw QuotaError.malformedResponse }
        var lines: [Data] = []
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

@MainActor
final class CodexRateLimitClient {
    private let testCommand: [String]?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var generation = UUID()
    private var lines = JSONLines()
    private var state = QuotaState()
    private var initialized = false
    private var running = false
    private var nextID = 2
    private var pendingRead: Int?
    private var timeout: Timer?
    private var reconnect: Timer?
    private var reconcile: Timer?
    private var retryDelay: TimeInterval = 5
    private var onUpdate: ((Result<QuotaSnapshot, QuotaError>) -> Void)?

    init(testCommand: [String]? = nil) { self.testCommand = testCommand }
    var processID: Int32? { process?.processIdentifier }

    func start(onUpdate: @escaping (Result<QuotaSnapshot, QuotaError>) -> Void) {
        guard !running else { return }
        running = true
        self.onUpdate = onUpdate
        connect()
        // A standalone app-server may not receive events from other Codex processes.
        // Reconcile the account using this same connection, without spawning new processes.
        reconcile = Timer(timeInterval: 120, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        reconcile?.tolerance = 10
        RunLoop.main.add(reconcile!, forMode: .common)
    }

    @objc func refresh() {
        guard running else { return }
        guard process != nil else {
            reconnect?.invalidate()
            reconnect = nil
            connect()
            return
        }
        guard initialized, pendingRead == nil else { return }
        let id = nextID
        nextID += 1
        pendingRead = id
        send(["id": id, "method": "account/rateLimits/read", "params": ["excludeResetCreditDetails": true]])
        if process != nil { armTimeout() }
    }

    func stop() {
        running = false
        reconcile?.invalidate()
        reconcile = nil
        reconnect?.invalidate()
        reconnect = nil
        closeConnection()
        onUpdate = nil
    }

    private func connect() {
        guard running, process == nil else { return }
        generation = UUID()
        let token = generation
        lines = JSONLines()
        state = QuotaState()
        initialized = false
        let child = Process()
        // Finder does not inherit the shell PATH. Prefer the bundled CLI on this Mac.
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        if let testCommand, let path = testCommand.first {
            child.executableURL = URL(fileURLWithPath: path)
            child.arguments = Array(testCommand.dropFirst())
        } else if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            child.executableURL = URL(fileURLWithPath: path)
            child.arguments = ["app-server"]
        } else {
            child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            child.arguments = ["codex", "app-server"]
        }
        let stdin = Pipe()
        let stdout = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        let readDescriptor = stdout.fileHandleForReading.fileDescriptor
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // Foundation's read(upToCount:) can wait to fill a pipe buffer on macOS.
            // POSIX read returns the currently available chunk and reports a closed FD safely.
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(readDescriptor, &bytes, bytes.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
            let data = count > 0 ? Data(bytes.prefix(count)) : Data()
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if data.isEmpty { self.fail(.disconnected) }
                else { self.receive(data) }
            }
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.fail(.disconnected)
            }
        }
        do {
            try child.run()
            send(["id": 1, "method": "initialize", "params": [
                "clientInfo": ["name": "codex_quota", "title": "Codex Quota", "version": "0.2.0"]
            ]])
            if process != nil { armTimeout() }
        } catch { fail(.unavailable) }
    }

    private func send(_ message: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: message) + Data([0x0A])
            guard let input else { throw QuotaError.disconnected }
            try input.write(contentsOf: data)
        } catch { fail(.disconnected) }
    }

    private func receive(_ data: Data) {
        do {
            for line in try lines.append(data) {
                let message = try JSONDecoder().decode(RPCMessage.self, from: line)
                if message.id == 1 {
                    guard message.error == nil, message.result != nil else { throw QuotaError.unavailable }
                    timeout?.invalidate()
                    initialized = true
                    send(["method": "initialized"])
                    refresh()
                } else if let id = message.id, id == pendingRead {
                    timeout?.invalidate()
                    pendingRead = nil
                    guard message.error == nil, let result = message.result else {
                        onUpdate?(.failure(.unavailable))
                        continue
                    }
                    // Do not fall back to a different bucket if the multi-bucket map is present.
                    let limits: RateLimits?
                    if let buckets = result.rateLimitsByLimitId { limits = buckets["codex"] }
                    else { limits = result.rateLimits }
                    guard let limits else { throw QuotaError.malformedResponse }
                    if let snapshot = try state.apply(limits, sparse: false) { publish(snapshot) }
                } else if message.method == "account/rateLimits/updated", let limits = message.params?.rateLimits {
                    if let snapshot = try state.apply(limits, sparse: true) { publish(snapshot) }
                } else if message.method == "account/updated" {
                    state = QuotaState()
                    refresh()
                }
            }
        } catch { fail(error as? QuotaError ?? .malformedResponse) }
    }

    private func publish(_ snapshot: QuotaSnapshot) {
        retryDelay = 5
        onUpdate?(.success(snapshot))
    }

    private func armTimeout() {
        timeout?.invalidate()
        timeout = Timer(timeInterval: 20, target: self, selector: #selector(timedOut), userInfo: nil, repeats: false)
        RunLoop.main.add(timeout!, forMode: .common)
    }

    @objc private func timedOut() { fail(.timedOut) }

    private func fail(_ error: QuotaError) {
        closeConnection()
        guard running else { return }
        onUpdate?(.failure(error))
        reconnect?.invalidate()
        reconnect = Timer(timeInterval: retryDelay, target: self, selector: #selector(retry), userInfo: nil, repeats: false)
        RunLoop.main.add(reconnect!, forMode: .common)
        retryDelay = min(60, retryDelay * 2)
    }

    @objc private func retry() {
        reconnect = nil
        connect()
    }

    private func closeConnection() {
        generation = UUID() // Ignore late callbacks from the old process.
        timeout?.invalidate()
        timeout = nil
        output?.readabilityHandler = nil
        try? input?.close()
        input = nil
        let child = process
        child?.terminationHandler = nil
        if let child, child.isRunning {
            child.terminate()
            // Bound shutdown even if app-server ignores SIGTERM.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        }
        try? output?.close()
        output = nil
        process = nil
        pendingRead = nil
        initialized = false
    }
}

final class QuotaView: NSView {
    var snapshot: QuotaSnapshot? { didSet { needsDisplay = true } }
    var errorText: String? { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 6), xRadius: 12, yRadius: 12)
        NSColor.windowBackgroundColor.setFill()
        background.fill()

        guard let snapshot else {
            let text = errorText ?? "Загружаю лимиты Codex…"
            draw(text, in: bounds.insetBy(dx: 20, dy: 24), size: 14, color: .secondaryLabelColor, centered: true)
            return
        }

        draw("Оставшаяся квота", in: NSRect(x: 16, y: 100, width: 280, height: 18), size: 13, color: .secondaryLabelColor)
        drawRing(window: snapshot.primary, label: "5 ЧАСОВ", frame: NSRect(x: 38, y: 20, width: 78, height: 78))
        if let secondary = snapshot.secondary {
            drawRing(window: secondary, label: "7 ДНЕЙ", frame: NSRect(x: 186, y: 20, width: 78, height: 78))
        }
    }

    private func drawRing(window: QuotaWindow, label: String, frame: NSRect) {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let radius = min(frame.width, frame.height) / 2 - 7
        let background = NSBezierPath()
        background.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360, clockwise: false)
        background.lineWidth = 7
        NSColor.quaternaryLabelColor.setStroke()
        background.stroke()

        let arc = NSBezierPath()
        let endAngle = -90 + CGFloat(window.remainingPercent) * 3.6
        arc.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: endAngle, clockwise: false)
        arc.lineCapStyle = .round
        arc.lineWidth = 7
        quotaColor(for: window.remainingPercent).setStroke()
        arc.stroke()

        draw("\(window.remainingPercent)%", in: NSRect(x: frame.minX, y: frame.midY - 8, width: frame.width, height: 18), size: 17, color: .labelColor, centered: true)
        draw(label, in: NSRect(x: frame.minX - 10, y: frame.minY - 17, width: frame.width + 20, height: 14), size: 10, color: .secondaryLabelColor, centered: true)
        draw(timeUntil(window.resetsAt), in: NSRect(x: frame.minX - 25, y: frame.minY - 31, width: frame.width + 50, height: 13), size: 10, color: .tertiaryLabelColor, centered: true)
    }

    private func draw(_ text: String, in rect: NSRect, size: CGFloat, color: NSColor, centered: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.alignment = centered ? .center : .left
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: size >= 17 ? .semibold : .regular),
            .foregroundColor: color,
            .paragraphStyle: style
        ])
    }
}

private enum QuotaStatusIcon {
    static let size = NSSize(width: 32, height: 18)
    static let itemWidth: CGFloat = 44

    static func image(snapshot: QuotaSnapshot?, stale: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            for (index, percent) in [snapshot?.primary.remainingPercent, snapshot?.secondary?.remainingPercent].enumerated() {
                let center = NSPoint(x: index == 0 ? 8 : 24, y: 9)
                let track = NSBezierPath(ovalIn: NSRect(x: center.x - 6, y: 3, width: 12, height: 12))
                track.lineWidth = 1.75
                NSColor.black.withAlphaComponent(percent == nil ? 0.4 : 0.22).setStroke()
                if percent == nil { track.setLineDash([1.5, 2], count: 2, phase: 0) }
                track.stroke()
                guard let percent, percent > 0 else { continue }
                let arc = NSBezierPath()
                arc.lineWidth = 1.75
                arc.lineCapStyle = .round
                arc.appendArc(withCenter: center, radius: 6, startAngle: 90,
                              endAngle: 90 - CGFloat(percent) * 3.6, clockwise: true)
                NSColor.black.withAlphaComponent(stale ? 0.5 : 1).setStroke()
                arc.stroke()
            }
            if stale {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 15, y: 15, width: 2, height: 2)).fill()
            }
            return true
        }
        // Let macOS tint the same alpha mask for light/dark menus and selection.
        image.isTemplate = true
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let client = CodexRateLimitClient()
    private let statusItem = NSStatusBar.system.statusItem(withLength: QuotaStatusIcon.itemWidth)
    private let quotaView = QuotaView(frame: NSRect(x: 0, y: 0, width: 310, height: 126))
    private let updatedItem = NSMenuItem(title: "Загрузка…", action: nil, keyEquivalent: "")
    private var redrawTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.autosaveName = "CodexQuota.main"
        updateStatusIcon()

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem())
        menu.items[0].view = quotaView
        menu.addItem(.separator())
        menu.addItem(updatedItem)
        menu.addItem(NSMenuItem(title: "Обновить", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти из Codex Quota", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        client.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                quotaView.snapshot = snapshot
                quotaView.errorText = nil
                updateStatusIcon()
                updatedItem.title = "Обновлено: \(Self.timeFormatter.string(from: snapshot.fetchedAt))"
            case .failure(let error):
                quotaView.errorText = error.localizedDescription
                updateStatusIcon()
                updatedItem.title = quotaView.snapshot == nil ? error.localizedDescription : "⚠ Данные устарели · \(error.localizedDescription)"
            }
        }
        redrawTimer = Timer(timeInterval: 60, target: self, selector: #selector(redraw), userInfo: nil, repeats: true)
        redrawTimer?.tolerance = 5
        RunLoop.main.add(redrawTimer!, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func refresh() {
        updatedItem.title = "Обновляю…"
        client.refresh()
    }

    @objc private func redraw() { quotaView.needsDisplay = true }
    @objc private func wokeUp() { refresh() }
    func menuWillOpen(_ menu: NSMenu) { redraw() }

    func applicationWillTerminate(_ notification: Notification) {
        client.stop()
        redrawTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let snapshot = quotaView.snapshot
        button.title = ""
        button.image = QuotaStatusIcon.image(snapshot: snapshot, stale: quotaView.errorText != nil)
        let details: String
        if let snapshot {
            let weekly = snapshot.secondary.map { "неделя: \($0.remainingPercent)%" } ?? "неделя: нет данных"
            details = "Осталось — 5 часов: \(snapshot.primary.remainingPercent)%, \(weekly)"
        } else {
            details = "Загрузка лимитов"
        }
        let warning = quotaView.errorText.map { "\nДанные не актуальны: \($0)" } ?? ""
        button.toolTip = "Codex · \(details)\(warning)\nЛевое кольцо — 5 часов, правое — неделя"
        button.setAccessibilityLabel("Codex: оставшаяся квота")
        button.setAccessibilityValue(details + warning)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private func quotaColor(for percent: Int) -> NSColor {
    switch percent {
    case 0..<20: .systemRed
    case 20..<45: .systemOrange
    default: .systemGreen
    }
}

private func timeUntil(_ timestamp: TimeInterval?) -> String {
    guard let timestamp else { return "сброс неизвестен" }
    let seconds = max(0, Int(timestamp - Date().timeIntervalSince1970))
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    return hours > 0 ? "сброс через \(hours)ч \(minutes)м" : "сброс через \(minutes)м"
}

private func runSelfCheck() throws {
    let window = QuotaWindow(usedPercent: 46, resetsAt: nil)
    precondition(window.remainingPercent == 54)
    precondition(QuotaWindow(usedPercent: 120, resetsAt: nil).remainingPercent == 0)
    precondition(QuotaWindow(usedPercent: -1, resetsAt: nil).remainingPercent == 100)
    var state = QuotaState()
    let full = RateLimits(limitId: "codex",
                          primary: QuotaWindow(usedPercent: 40, resetsAt: 1_900_000_000, windowDurationMins: 300),
                          secondary: QuotaWindow(usedPercent: 20, resetsAt: 1_900_500_000, windowDurationMins: 10_080))
    _ = try state.apply(full, sparse: false)
    let partial = RateLimits(limitId: "codex", primary: QuotaWindow(usedPercent: 50, resetsAt: nil), secondary: nil)
    let updated = try state.apply(partial, sparse: true)!
    precondition(updated.primary.remainingPercent == 50)
    precondition(updated.primary.resetsAt == full.primary?.resetsAt)
    precondition(updated.secondary?.remainingPercent == 80)
    let other = RateLimits(limitId: "codex_other", primary: QuotaWindow(usedPercent: 99, resetsAt: nil), secondary: nil)
    let ignored = try state.apply(other, sparse: true)
    precondition(ignored == nil)
    let swapped = RateLimits(limitId: "codex", primary: full.secondary, secondary: full.primary)
    let classified = try state.apply(swapped, sparse: false)!
    precondition(classified.primary.remainingPercent == 60 && classified.secondary?.remainingPercent == 80)
    let oneWindow = RateLimits(limitId: "codex", primary: full.primary, secondary: nil)
    let single = try state.apply(oneWindow, sparse: false)!
    precondition(single.secondary == nil)
    var lines = JSONLines()
    let first = try lines.append(Data("{\"id\":".utf8))
    precondition(first.isEmpty)
    let second = try lines.append(Data("1,\"result\":{}}\n{\"method\":\"account/rateLimits/updated\",\"params\":{\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":51}}}}\n".utf8))
    precondition(second.count == 2)
    let decoded = try JSONDecoder().decode(RPCMessage.self, from: second[1])
    precondition(decoded.params?.rateLimits?.primary?.usedPercent == 51)
    print("Self-check passed")
}

@MainActor
private func runIconCheck() throws {
    _ = NSApplication.shared
    func snapshot(_ remaining: Int, weekly: Bool = true) -> QuotaSnapshot {
        let window = QuotaWindow(usedPercent: 100 - remaining, resetsAt: nil)
        return QuotaSnapshot(primary: window, secondary: weekly ? window : nil, fetchedAt: Date())
    }
    let cases: [(String, QuotaSnapshot?, Bool)] = [
        ("Загрузка", nil, false), ("0%", snapshot(0), false),
        ("50%", snapshot(50), false), ("100%", snapshot(100), false),
        ("Устарело", snapshot(75), true), ("Нет недели", snapshot(75, weekly: false), false)
    ]
    var representations = Set<Data>()
    for (_, snapshot, stale) in cases {
        let icon = QuotaStatusIcon.image(snapshot: snapshot, stale: stale)
        precondition(icon.size == QuotaStatusIcon.size && icon.isTemplate)
        guard let bitmap = icon.tiffRepresentation else { preconditionFailure("Icon did not render") }
        representations.insert(bitmap)
    }
    precondition(representations.count == cases.count, "Loading, empty, full and stale must look different")
    if let flag = CommandLine.arguments.firstIndex(of: "--icon-test"), flag + 1 < CommandLine.arguments.count {
        let preview = NSImage(size: NSSize(width: 480, height: 86), flipped: false) { bounds in
            NSColor.white.setFill()
            bounds.fill()
            for (index, entry) in cases.enumerated() {
                let x = CGFloat(index) * 80
                let icon = QuotaStatusIcon.image(snapshot: entry.1, stale: entry.2)
                icon.isTemplate = false
                icon.draw(in: NSRect(x: x + 8, y: 34, width: 64, height: 36))
                (entry.0 as NSString).draw(in: NSRect(x: x + 4, y: 10, width: 76, height: 16),
                                          withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black])
            }
            return true
        }
        let bitmap = NSBitmapImageRep(data: preview.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    }
    print("Icon check passed: fixed width, template tinting, loading, 0%, 50%, 100%, stale, missing weekly")
}

@MainActor
private func runTransportCheck() {
    let server = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Tests/mock-app-server.sh").path
    precondition(FileManager.default.fileExists(atPath: server), "Run from the project directory")
    let client = CodexRateLimitClient(testCommand: ["/bin/zsh", server])
    var firstPID: Int32?
    var snapshots = 0
    var disconnected = false
    var finished = false
    client.start { result in
        switch result {
        case .success(let snapshot):
            snapshots += 1
            switch snapshots {
            case 1:
                firstPID = client.processID
                precondition(snapshot.primary.remainingPercent == 60)
                client.refresh()
                client.refresh() // Coalesce simultaneous refreshes.
            case 2:
                precondition(client.processID == firstPID)
                precondition(snapshot.primary.remainingPercent == 50)
                precondition(snapshot.primary.resetsAt == 1_900_000_000)
                precondition(snapshot.secondary?.remainingPercent == 80)
            case 3:
                precondition(client.processID == firstPID)
                precondition(snapshot.primary.remainingPercent == 40)
            case 4:
                precondition(disconnected && client.processID != firstPID)
                client.stop()
                precondition(client.processID == nil)
                finished = true
            default: preconditionFailure("Unexpected duplicate update")
            }
        case .failure(let error):
            precondition(snapshots == 3 && error.localizedDescription == QuotaError.disconnected.localizedDescription)
            disconnected = true
        }
    }
    let deadline = Date().addingTimeInterval(15)
    while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    client.stop()
    precondition(finished, "Transport check timed out")
    print("Transport check passed: streaming, same-process refresh, sparse update, reconnect, stop")
}

if CommandLine.arguments.contains("--self-test") {
    try runSelfCheck()
} else if CommandLine.arguments.contains("--icon-test") {
    try runIconCheck()
} else if CommandLine.arguments.contains("--transport-test") {
    runTransportCheck()
} else if CommandLine.arguments.contains("--print-status") || CommandLine.arguments.contains("--watch-status") {
    let watch = CommandLine.arguments.contains("--watch-status")
    var completed = false
    var exitCode: Int32 = 0
    let client = CodexRateLimitClient()
    client.start { result in
        switch result {
        case .success(let snapshot):
            let weekly = snapshot.secondary.map { " 7D=\($0.remainingPercent)%" } ?? ""
            print("5H=\(snapshot.primary.remainingPercent)%\(weekly)")
        case .failure(let error):
            print(error.localizedDescription)
            exitCode = 1
        }
        completed = !watch
    }
    let deadline = Date().addingTimeInterval(watch ? 130 : 25)
    while !completed && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    client.stop()
    if !watch && !completed { exitCode = 1; print("Превышено время ожидания") }
    exit(exitCode)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
