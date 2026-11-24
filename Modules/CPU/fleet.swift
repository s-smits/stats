//
//  fleet.swift
//  CPU
//
//  Other machines' CPU: a command (CPU_fleetLoadCommand) prints one JSON line a
//  reading for every machine it watches, which the popup summarises and the
//  preview draws like this Mac's, keeping fifteen minutes of readings each.
//

import Cocoa
import Kit

/// One line of the command's output: every machine, at one moment.
public struct CPU_FleetLine: Codable {
    let hosts: [CPU_FleetEntry]
}

/// One machine in a line: its reading when `state` is `read`, else only its state.
public struct CPU_FleetEntry: Codable {
    struct Split: Codable { let user: Double; let system: Double; let idle: Double }
    struct Clusters: Codable { let efficiency: Int; let performance: Int }
    struct Busiest: Codable, Process_p {
        let pid: Int
        let cpu: Double
        let name: String
        var icon: NSImage { Constants.defaultProcessIcon }
    }

    let label: String
    let local: Bool
    /// `read`, `connecting` or `unreachable`.
    let state: String
    var cores: Int? = nil
    var model: String? = nil
    var clusters: Clusters? = nil
    /// The one-, five- and fifteen-minute load averages.
    var loads: [Double]? = nil
    /// The whole CPU over the last interval, in percent.
    var cpu: Split? = nil
    /// Each core's busy share over the last interval, in percent; efficiency cores first.
    var perCore: [Double]? = nil
    var top: [Busiest]? = nil
}

internal enum FleetLoad {
    static let enabledKey = "CPU_fleetLoad"
    static let commandKey = "CPU_fleetLoadCommand"
    static let selectedKey = "CPU_fleetSelected"
    /// Fifteen minutes of one-second readings.
    static let capacity = 900

    static var enabled: Bool {
        Store.shared.bool(key: enabledKey, defaultValue: true)
    }
    /// The shell command printing the lines, set with `defaults write eu.exelban.Stats CPU_fleetLoadCommand '<command>'`.
    static var command: String {
        Store.shared.string(key: commandKey, defaultValue: "")
    }
    static var available: Bool {
        !command.isEmpty
    }
}

/// Runs the command in a login shell while the module and the switch are on, restarting it when it
/// ends; nil when it stops, so the views clear.
public class FleetStreamReader: Reader<CPU_FleetLine> {
    private let queue = DispatchQueue(label: "eu.exelban.Stats.CPU.fleet")
    private var task: Process? = nil
    private var output: FileHandle? = nil
    private var buffer = Data()
    private var wanted = false
    private var delay: TimeInterval = 2

    public override func start() {
        self.queue.async {
            self.wanted = FleetLoad.enabled && FleetLoad.available
            self.wanted ? self.launch() : self.end(clear: true)
        }
    }

    // Always-on: the module pauses only readers that serve a visible view.
    public override func pause() {}

    public override func stop() {
        self.queue.sync {
            self.wanted = false
            self.end(clear: true)
        }
    }

    public override func terminate() {
        self.stop()
    }

    private func launch() {
        guard self.wanted, self.task == nil else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", FleetLoad.command]
        task.standardInput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        let output = pipe.fileHandleForReading
        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.queue.async { self?.received(data) }
        }
        task.terminationHandler = { [weak self] ended in
            self?.queue.async {
                guard let self, self.task === ended else { return }
                self.end(clear: false)
                self.queue.asyncAfter(deadline: .now() + self.delay) { self.launch() }
                self.delay = min(self.delay * 2, 60)
            }
        }

        do {
            try task.run()
            self.task = task
            self.output = output
        } catch let err {
            output.readabilityHandler = nil
            error("error run fleet command: \(err.localizedDescription)", log: self.log)
        }
    }

    /// Ends the command, closing its output so a child it left behind fails its next write and ends
    /// too; `clear` empties the views, which a restart keeps.
    private func end(clear: Bool) {
        self.output?.readabilityHandler = nil
        try? self.output?.close()
        self.output = nil
        if let task = self.task, task.isRunning { task.terminate() }
        self.task = nil
        self.buffer = Data()
        if clear { self.callbackHandler(nil) }
    }

    private func received(_ data: Data) {
        guard self.task != nil else { return }
        self.buffer.append(data)
        while let end = self.buffer.firstIndex(of: 0x0A) {
            let line = self.buffer[self.buffer.startIndex..<end]
            self.buffer = Data(self.buffer[self.buffer.index(after: end)...])
            guard let value = try? JSONDecoder().decode(CPU_FleetLine.self, from: line) else { continue }
            self.delay = 2
            self.callbackHandler(value)
        }
    }
}

/// One machine's readings over the last fifteen minutes.
internal final class FleetHost {
    let label: String
    private(set) var local: Bool = false
    private(set) var state: String = "connecting"
    /// The last entry that held a reading.
    private(set) var latest: CPU_FleetEntry? = nil
    let usage = LineChartData(capacity: FleetLoad.capacity)
    private var perCore: [[Double]] = []

    init(label: String) {
        self.label = label
    }

    func record(_ entry: CPU_FleetEntry) {
        self.local = entry.local
        self.state = entry.state
        guard entry.state == "read", let cpu = entry.cpu else { return }
        self.latest = entry
        self.usage.append(DoubleValue((100 - cpu.idle) / 100))
        if let cores = entry.perCore {
            self.perCore.append(cores)
            if self.perCore.count > FleetLoad.capacity { self.perCore.removeFirst() }
        }
    }

    /// The minutes the kept readings span.
    var minutes: Int {
        max(1, Int((Double(self.perCore.count) / 60).rounded()))
    }

    /// Each core's mean busy share over the kept readings, out of 1.
    var coreMeans: [Double] {
        guard let width = self.perCore.last?.count else { return [] }
        let kept = self.perCore.filter { $0.count == width }
        return (0..<width).map { core in kept.reduce(0) { $0 + $1[core] } / Double(kept.count) / 100 }
    }

    /// The model, then the cores by kind, as the preview's title shows them.
    var title: (name: String, cores: String) {
        guard let entry = self.latest else { return (self.label, localizedString(self.state == "unreachable" ? "Unreachable" : "Connecting…")) }
        var cores = "\(entry.cores ?? 0) cores"
        if let clusters = entry.clusters {
            cores = "\(clusters.efficiency) efficiency • \(clusters.performance) performance"
        }
        if self.state != "read" {
            cores += " • \(localizedString(self.state == "unreachable" ? "Unreachable" : "Connecting…"))"
        }
        return (entry.model ?? self.label, cores)
    }

    /// Each core as the preview lays it out: efficiency cores first where the machine has both kinds.
    var coreKinds: [core_s] {
        let count = self.latest?.perCore?.count ?? 0
        let efficiency = self.latest?.clusters?.efficiency
        return (0..<count).map { i in
            let type: coreType = efficiency.map { i < $0 ? .efficiency : .performance } ?? .unknown
            return core_s(id: Int32(i), type: type)
        }
    }
}

internal class FleetLoadView: NSStackView {
    private let rows: NSStackView
    private var labels: [String] = []
    private var fields: [ValueField] = []

    /// Called when the section shows, hides or changes its number of rows.
    public var resized: () -> Void = {}

    public init(width: CGFloat) {
        // Kit's popupRow lays a row out against its container's frame width, so the rows need it up front.
        self.rows = NSStackView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        self.orientation = .vertical
        self.spacing = 0
        self.isHidden = true

        let separator = separatorView(localizedString("Fleet load"), width: width)
        separator.toolTip = "CPU now, then the 1, 5 and 15 minute load against the cores"
        self.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true

        self.rows.orientation = .vertical
        self.rows.spacing = 0
        self.addArrangedSubview(self.rows)
        self.rows.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func render(_ value: CPU_FleetLine?) {
        guard let value, !value.hosts.isEmpty else {
            if !self.isHidden {
                self.isHidden = true
                self.resized()
            }
            return
        }

        let labels = value.hosts.map { $0.label }
        let rebuilt = labels != self.labels
        if rebuilt {
            self.rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
            self.fields = labels.map { label in
                let (_, field, row) = popupRow(self.rows, title: "\(label):", value: "")
                row.widthAnchor.constraint(equalTo: self.rows.widthAnchor).isActive = true
                return field
            }
            self.labels = labels
        }

        for (host, field) in zip(value.hosts, self.fields) {
            host.show(in: field)
        }

        if rebuilt || self.isHidden {
            self.isHidden = false
            self.resized()
        }
    }
}

extension CPU_FleetEntry {
    /// CPU busy now, then the 1, 5 and 15 minute load against the cores out of 100, and the queue beyond them.
    var summary: String {
        guard self.state == "read", let loads = self.loads else {
            return localizedString(self.state == "unreachable" ? "Unreachable" : "Connecting…")
        }
        let cpu = self.cpu.map { "\(Int((100 - $0.idle).rounded()))%" } ?? "–"
        let shares = loads.map { "\(min(100, self.perCore($0)))" }.joined(separator: " · ")
        let queued = loads.first.flatMap { load in self.cores.map { Int((load - Double($0)).rounded()) } } ?? 0
        return "\(cpu)  \(shares)\(queued > 0 ? "  +\(queued)" : "")"
    }

    var tint: NSColor {
        guard self.state == "read" else { return self.state == "unreachable" ? .systemRed : .secondaryLabelColor }
        guard let load = self.loads?.first else { return .textColor }
        let share = self.perCore(load)
        return share >= 100 ? .systemRed : share >= 75 ? .systemOrange : .textColor
    }

    func show(in field: NSTextField) {
        field.stringValue = self.summary
        field.textColor = self.tint
        field.toolTip = self.cores.map { "\($0) cores, load \((self.loads ?? []).map { String(format: "%.2f", $0) }.joined(separator: " / "))" }
    }

    private func perCore(_ load: Double) -> Int {
        guard let cores = self.cores, cores > 0 else { return 0 }
        return Int((100 * load / Double(cores)).rounded())
    }
}
