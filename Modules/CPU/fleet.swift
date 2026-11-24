//
//  fleet.swift
//  CPU
//
//  The fleet load section: the CPU and load averages of every machine the
//  Anabasis checkout watches, read from its `bun run runs loadwatch --once`
//  verb while the popup is open.
//

import Cocoa
import Kit

public struct CPU_FleetHost: Codable, Equatable {
    var label: String
    var cores: Int? = nil
    var busy: Double? = nil
    var loads: [Double] = []
    var reachable: Bool = true
}

public struct CPU_FleetLoad: Codable, Equatable {
    var hosts: [CPU_FleetHost] = []
}

internal enum FleetLoad {
    static let enabledKey = "CPU_fleetLoad"
    static let directoryKey = "CPU_fleetLoadDirectory"

    static var enabled: Bool {
        Store.shared.bool(key: enabledKey, defaultValue: true)
    }
    /// The checkout to run loadwatch in, set with `defaults write eu.exelban.Stats CPU_fleetLoadDirectory <path>`.
    static var directory: String {
        (Store.shared.string(key: directoryKey, defaultValue: "") as NSString).expandingTildeInPath
    }
    static var available: Bool {
        !directory.isEmpty && FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent("package.json"))
    }

    /// Parses the `--once` frame: a head line per machine (`<label> <n> cores`, or the
    /// label and `UNREACHABLE` / `connecting…`), then `cpu now … N%` and `load 1m|5m|15m … N%  (x.xx)`.
    static func parse(_ raw: String) -> CPU_FleetLoad {
        let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]")
        var hosts: [CPU_FleetHost] = []

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let full = String(rawLine)
            let line = ansi.stringByReplacingMatches(in: full, range: NSRange(full.startIndex..., in: full), withTemplate: "")
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let first = words.first else { continue }

            if !line.hasPrefix(" ") {
                if words.count == 3, words[2] == "cores", let cores = Int(words[1]) {
                    hosts.append(CPU_FleetHost(label: first, cores: cores))
                } else if words.count == 2, words[1] == "UNREACHABLE" || words[1].hasPrefix("connecting") {
                    hosts.append(CPU_FleetHost(label: first, reachable: false))
                }
                continue
            }
            guard !hosts.isEmpty, hosts[hosts.count - 1].reachable else { continue }

            if first == "cpu", let percent = words.first(where: { $0.hasSuffix("%") }) {
                hosts[hosts.count - 1].busy = Double(percent.dropLast()).map { $0 / 100 }
            } else if first == "load", let raw = words.first(where: { $0.hasPrefix("(") && $0.hasSuffix(")") }) {
                if let load = Double(raw.dropFirst().dropLast()) {
                    hosts[hosts.count - 1].loads.append(load)
                }
            }
        }

        return CPU_FleetLoad(hosts: hosts)
    }
}

public class FleetLoadReader: Reader<CPU_FleetLoad> {
    private let timeout: TimeInterval = 30

    public override func setup() {
        self.setInterval(10)
    }

    public override func read() {
        guard FleetLoad.enabled, FleetLoad.available else {
            self.callback(nil)
            return
        }

        let task = Process()
        // A login shell, so bun and the checkout's PATH resolve as they do in a terminal.
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", "exec bun run --silent runs loadwatch --once"]
        task.currentDirectoryURL = URL(fileURLWithPath: FleetLoad.directory)
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        task.environment = environment

        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice

        do {
            try task.run()
        } catch let err {
            error("error read loadwatch: \(err.localizedDescription)", log: self.log)
            return
        }
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + self.timeout) {
            if task.isRunning { task.terminate() }
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        outputPipe.fileHandleForReading.closeFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0, let raw = String(data: data, encoding: .utf8) else { return }
        let value = FleetLoad.parse(raw)
        guard !value.hosts.isEmpty else { return }
        self.callback(value)
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
        separator.toolTip = "bun run runs loadwatch --once · cpu now, then the 1, 5 and 15 minute load against the cores"
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

    public func render(_ value: CPU_FleetLoad?) {
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

extension CPU_FleetHost {
    /// CPU busy now, then the 1, 5 and 15 minute load against the cores out of 100, and the queue beyond them.
    var summary: String {
        guard self.reachable else { return localizedString("Unreachable") }
        let cpu = self.busy.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
        let loads = self.loads.map { "\(min(100, self.perCore($0)))" }.joined(separator: " · ")
        let queued = self.loads.first.flatMap { load in self.cores.map { Int((load - Double($0)).rounded()) } } ?? 0
        return "\(cpu)  \(loads)\(queued > 0 ? "  +\(queued)" : "")"
    }

    var tint: NSColor {
        guard self.reachable else { return .systemRed }
        guard let load = self.loads.first else { return .textColor }
        let share = self.perCore(load)
        return share >= 100 ? .systemRed : share >= 75 ? .systemOrange : .textColor
    }

    func show(in field: NSTextField) {
        field.stringValue = self.summary
        field.textColor = self.tint
        field.toolTip = self.cores.map { "\($0) cores, load \(self.loads.map { String(format: "%.2f", $0) }.joined(separator: " / "))" }
    }

    private func perCore(_ load: Double) -> Int {
        guard let cores = self.cores, cores > 0 else { return 0 }
        return Int((100 * load / Double(cores)).rounded())
    }
}
