//
//  preview.swift
//  Stats
//
//  Created by Serhiy Mytrovtsiy on 09/03/2026
//  Using Swift 6.0
//  Running on macOS 26.3
//
//  Copyright © 2026 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class Preview: PreviewWrapper {
    private let chartHistory = LineChartData(capacity: FleetLoad.capacity)
    private var latestLoad: CPU_Load?
    private var latestAverage: CPU_AverageLoad?
    private var latestFrequency: CPU_Frequency?
    private var latestProcesses: [TopProcess]?
    
    private var initialized: Bool = false
    private var initializedAverage: Bool = false
    private var initializedFrequency: Bool = false
    private var initializedProcesses: Bool = false
    
    private var systemColorState: SColor = .secondRed
    private var systemColor: NSColor { self.systemColorState.additional as? NSColor ?? NSColor.systemRed }
    private var userColorState: SColor = .secondBlue
    private var userColor: NSColor { self.userColorState.additional as? NSColor ?? NSColor.systemBlue }
    private var idleColorState: SColor = .lightGray
    private var idleColor: NSColor { self.idleColorState.additional as? NSColor ?? NSColor.lightGray }
    private var chartColorState: SColor = .systemAccent
    private var chartColor: NSColor { self.chartColorState.additional as? NSColor ?? NSColor.systemBlue }
    
    private var eCoresColor: NSColor {
        let color = SColor.teal
        let key = Store.shared.string(key: "\(self.module.stringValue)_eCoresColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    private var pCoresColor: NSColor {
        let color = SColor.indigo
        let key = Store.shared.string(key: "\(self.module.stringValue)_pCoresColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    private var sCoresColor: NSColor {
        let color = SColor.orange
        let key = Store.shared.string(key: "\(self.module.stringValue)_sCoresColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    
    private var circle: PieChartView? = nil
    private var bar: BarChartView? = nil
    private var loadLineChart: LineChartView? = nil
    
    private var systemField: NSTextField? = nil
    private var userField: NSTextField? = nil
    private var idleField: NSTextField? = nil
    private var average1Field: NSTextField? = nil
    private var average5Field: NSTextField? = nil
    private var average15Field: NSTextField? = nil
    private var coresFreqField: NSTextField? = nil
    private var eCoresFreqField: NSTextField? = nil
    private var sCoresFreqField: NSTextField? = nil
    private var pCoresFreqField: NSTextField? = nil
    
    private var cores: [CoreView] = []
    private var processes: ProcessesView? = nil
    private var processesSection: PreferencesSection? = nil
    private var titleField: LabelField? = nil
    private var clustersField: LabelField? = nil
    private var remoteProcesses: [(name: LabelField, value: ValueField)] = []
    
    /// Every machine the fleet command reports, in its order, each with fifteen minutes of readings.
    private var fleet: [FleetHost] = []
    private var picker: NSSegmentedControl? = nil
    /// The machine the page shows, by label; empty for this Mac.
    private var selected: String = Store.shared.string(key: FleetLoad.selectedKey, defaultValue: "")
    /// The page's machine and its number of cores when it was built, which a change rebuilds.
    private var shown: String = ""
    
    private var remotes: [FleetHost] { self.fleet.filter { !$0.local } }
    private var remote: FleetHost? { self.remotes.first { $0.label == self.selected } }
    private var shape: String { self.remote.map { "\($0.label)#\($0.coreKinds.count)" } ?? "" }
    
    private var numberOfProcesses: Int {
        Store.shared.int(key: "\(self.module.stringValue)_processes", defaultValue: 8)
    }
    
    public init(_ module: ModuleType) {
        super.init(type: module)
    }
    
    public override func loadContent() {
        let host = self.remote
        self.shown = self.shape
        
        let picker = self.pickerView()
        self.addArrangedSubview(picker)
        picker.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true
        
        self.addArrangedSubview(PreferencesSection([self.totalView(host)]))
        self.addArrangedSubview(PreferencesSection(title: localizedString("Usage history"), [self.historyView(host?.usage ?? self.chartHistory)]))
        self.addArrangedSubview(PreferencesSection(title: localizedString("Load per core"), [
            self.coresView(host?.coreKinds ?? SystemKit.shared.device.info.cpu?.cores ?? [])
        ]))
        
        let splitView = NSStackView()
        splitView.orientation = .horizontal
        splitView.distribution = .fillEqually
        splitView.addArrangedSubview(PreferencesSection(title: localizedString("Average load"), [self.averageView()]))
        if host == nil {
            splitView.addArrangedSubview(PreferencesSection(title: localizedString("Frequency"), [self.frequencyView()]))
        }
        
        self.addArrangedSubview(splitView)
        
        self.addArrangedSubview(host == nil ? self.topProcesses() : self.remoteProcessesView())
        
        self.addArrangedSubview(NSView())
        
        if let host {
            self.renderRemote(host)
            return
        }
        if let value = self.latestLoad { self.renderLoad(value) }
        if let value = self.latestAverage { self.renderAverage(value) }
        if let value = self.latestFrequency { self.renderFrequency(value) }
        if let list = self.latestProcesses { self.renderProcesses(list) }
    }
    
    public override func unloadContent() {
        self.processes?.setLock(false)
        self.arrangedSubviews.forEach { self.removeArrangedSubview($0) }
        self.subviews.forEach { $0.removeFromSuperview() }
        self.cores.removeAll()
        self.circle = nil
        self.bar = nil
        self.loadLineChart = nil
        self.systemField = nil
        self.userField = nil
        self.idleField = nil
        self.average1Field = nil
        self.average5Field = nil
        self.average15Field = nil
        self.coresFreqField = nil
        self.eCoresFreqField = nil
        self.sCoresFreqField = nil
        self.pCoresFreqField = nil
        self.processes = nil
        self.processesSection = nil
        self.titleField = nil
        self.clustersField = nil
        self.remoteProcesses = []
        self.picker = nil
        self.initialized = false
        self.initializedAverage = false
        self.initializedFrequency = false
        self.initializedProcesses = false
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func totalView(_ host: FleetHost?) -> NSView {
        let view = NSStackView()
        view.distribution = .fill
        view.orientation = .horizontal
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 100).isActive = true
        view.edgeInsets = NSEdgeInsets(
            top: Constants.Settings.margin,
            left: Constants.Settings.margin,
            bottom: Constants.Settings.margin,
            right: Constants.Settings.margin
        )
        view.spacing = Constants.Settings.margin
        
        let circle = PieChartView(drawValue: true)
        circle.widthAnchor.constraint(equalToConstant: 90).isActive = true
        circle.toolTip = localizedString("CPU usage")
        self.circle = circle
        
        let details: NSView = {
            let view = NSStackView()
            view.orientation = .vertical
            view.distribution = .fillEqually
            view.spacing = 2
            
            var titleValue = localizedString("Unknown")
            var clastersValue = localizedString("Unknown")
            
            if let host {
                (titleValue, clastersValue) = host.title
            } else if let cpu = SystemKit.shared.device.info.cpu {
                if let name = cpu.name {
                    titleValue = name
                }
                var clusters: [String] = []
                if let eCores = cpu.eCores {
                    clusters.append("\(eCores) efficiency")
                }
                if let pCores = cpu.pCores {
                    clusters.append("\(pCores) performance")
                }
                if let sCores = cpu.sCores {
                    clusters.append("\(sCores) super")
                }
                if !clusters.isEmpty {
                    clastersValue = clusters.joined(separator: " • ")
                }
            }
            
            let titleField = LabelField(titleValue, size: 13)
            let clustersField = LabelField(clastersValue, size: 11)
            self.titleField = titleField
            self.clustersField = clustersField
            let title = NSStackView()
            title.addArrangedSubview(titleField)
            title.addArrangedSubview(NSView())
            title.addArrangedSubview(clustersField)
            
            let bar = BarChartView(size: 9, horizontal: true)
            self.bar = bar
            
            let levels = NSStackView()
            levels.orientation = .horizontal
            levels.distribution = .fill
            
            let leftSpacer = NSView()
            let rightSpacer = NSView()
            
            self.systemField = previewRow(levels, space: false, color: self.systemColor, title: "\(localizedString("System")):", value: "")
            levels.addArrangedSubview(leftSpacer)
            self.userField = previewRow(levels, space: false, color: self.userColor, title: "\(localizedString("User")):", value: "")
            levels.addArrangedSubview(rightSpacer)
            self.idleField = previewRow(levels, space: false, color: self.idleColor, title: "\(localizedString("Idle")):", value: "")
            
            leftSpacer.widthAnchor.constraint(equalTo: rightSpacer.widthAnchor).isActive = true
            
            view.addArrangedSubview(title)
            view.addArrangedSubview(bar)
            view.addArrangedSubview(levels)
            
            return view
        }()
        
        view.addArrangedSubview(circle)
        view.addArrangedSubview(details)
        
        return view
    }
    
    private func historyView(_ history: LineChartData) -> NSView {
        let view: NSStackView = NSStackView()
        view.orientation = .vertical
        view.distribution = .fillEqually
        view.spacing = Constants.Settings.margin*2
        view.heightAnchor.constraint(equalToConstant: 140).isActive = true
        
        let chart = LineChartView(history: history)
        chart.setColor(self.chartColor)
        chart.setLegend(x: true, y: true)
        self.loadLineChart = chart
        view.addArrangedSubview(chart)
        
        return view
    }
    
    private func coresView(_ cores: [core_s]) -> NSView {
        let view: NSStackView = NSStackView()
        view.orientation = .horizontal
        view.distribution = .fillEqually
        view.spacing = Constants.Settings.margin
        
        let leftColumn: NSStackView = NSStackView()
        leftColumn.orientation = .vertical
        leftColumn.distribution = .fillEqually
        leftColumn.spacing = Constants.Settings.margin/2
        
        let rightColumn: NSStackView = NSStackView()
        rightColumn.orientation = .vertical
        rightColumn.distribution = .fillEqually
        rightColumn.spacing = Constants.Settings.margin/2
        
        do {
            var e = 0
            var p = 0
            var s = 0
            
            for (i, core) in cores.enumerated() {
                var num = i
                
                if core.type == .efficiency {
                    e += 1
                    num = e
                } else if core.type == .performance {
                    p += 1
                    num = p
                } else if core.type == .super {
                    s += 1
                    num = s
                }
                
                let c = CoreView(core, num: num)
                if i % 2 == 0 {
                    leftColumn.addArrangedSubview(c)
                } else {
                    rightColumn.addArrangedSubview(c)
                }
                self.cores.append(c)
            }
        }
        
        view.addArrangedSubview(leftColumn)
        view.addArrangedSubview(rightColumn)
        
        return view
    }
    
    private func averageView() -> NSView {
        let view = NSStackView()
        view.orientation = .vertical
        view.distribution = .fillEqually
        view.spacing = 2
        
        self.average1Field = previewRow(view, title: "\(localizedString("1 minute")):", value: "")
        self.average5Field = previewRow(view, title: "\(localizedString("5 minutes")):", value: "")
        self.average15Field = previewRow(view, title: "\(localizedString("15 minutes")):", value: "")
        
        return view
    }
    
    private func frequencyView() -> NSView {
        let view = NSStackView()
        view.orientation = .vertical
        view.distribution = .fillEqually
        view.spacing = 2
        
        self.coresFreqField = previewRow(view, title: "\(localizedString("All cores")):", value: "")
        
        if isARM {
            if SystemKit.shared.device.info.cpu?.eCores != nil {
                self.eCoresFreqField = previewRow(view, color: self.eCoresColor, title: "\(localizedString("Efficiency cores")):", value: "")
            }
            if SystemKit.shared.device.info.cpu?.pCores != nil {
                self.pCoresFreqField = previewRow(view, color: self.pCoresColor, title: "\(localizedString("Performance cores")):", value: "")
            }
            if SystemKit.shared.device.info.cpu?.sCores != nil {
                self.sCoresFreqField = previewRow(view, color: self.sCoresColor, title: "\(localizedString("Super cores")):", value: "")
            }
        }
        
        return view
    }
    
    private func pickerView() -> NSSegmentedControl {
        let picker = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: self, action: #selector(self.pick))
        picker.segmentDistribution = .fillEqually
        self.picker = picker
        self.updatePicker()
        return picker
    }
    
    /// This Mac, then every other machine the fleet command reports; hidden while it reports none.
    private func updatePicker() {
        guard let picker = self.picker else { return }
        let remotes = self.remotes
        let labels = [localizedString("This Mac")] + remotes.map { $0.label }
        if picker.segmentCount != labels.count || labels.indices.contains(where: { picker.label(forSegment: $0) != labels[$0] }) {
            picker.segmentCount = labels.count
            for (i, label) in labels.enumerated() {
                picker.setLabel(label, forSegment: i)
            }
        }
        for (i, host) in remotes.enumerated() {
            picker.setToolTip(host.state == "read" ? nil : localizedString(host.state == "unreachable" ? "Unreachable" : "Connecting…"), forSegment: i + 1)
        }
        picker.selectedSegment = remotes.firstIndex { $0.label == self.selected }.map { $0 + 1 } ?? 0
        picker.isHidden = remotes.isEmpty
    }
    
    @objc private func pick(_ sender: NSSegmentedControl) {
        let remotes = self.remotes
        let i = sender.selectedSegment
        self.selected = i > 0 && i <= remotes.count ? remotes[i - 1].label : ""
        Store.shared.set(key: FleetLoad.selectedKey, value: self.selected)
        // Rebuild after the control's own action returns, since the rebuild replaces it.
        DispatchQueue.main.async { self.reload() }
    }
    
    private func reload() {
        guard self.contentLoaded else { return }
        self.unloadContent()
        self.loadContent()
    }
    
    private func remoteProcessesView() -> NSView {
        let view = NSStackView()
        view.orientation = .vertical
        view.distribution = .fillEqually
        view.spacing = 2
        
        self.remoteProcesses = (0..<max(self.numberOfProcesses, 0)).map { _ in
            let row = NSStackView()
            row.heightAnchor.constraint(equalToConstant: 22).isActive = true
            row.orientation = .horizontal
            row.distribution = .fill
            let name = LabelField("")
            name.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            let value = ValueField("")
            value.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            row.addArrangedSubview(name)
            row.addArrangedSubview(NSView())
            row.addArrangedSubview(value)
            view.addArrangedSubview(row)
            return (name, value)
        }
        
        let section = PreferencesSection(title: localizedString("Top processes"), [view])
        section.isHidden = self.numberOfProcesses == 0
        return section
    }
    
    private func topProcesses() -> NSView {
        let view = ProcessesView(
            values: [(localizedString("Usage"), nil)],
            n: self.numberOfProcesses,
            showPID: true,
            showChart: true
        )
        self.processes = view
        
        let section = PreferencesSection(title: localizedString("Top processes"), [view])
        section.isHidden = self.numberOfProcesses == 0
        self.processesSection = section
        
        return section
    }
    
    public func numberOfProcessesUpdated() {
        self.processes?.setLock(false)
        self.processes?.setNumberOfProcesses(self.numberOfProcesses)
        self.processesSection?.isHidden = self.numberOfProcesses == 0
        self.initializedProcesses = false
        if self.remote != nil { self.reload() }
    }
    
    public func processCallback(_ list: [TopProcess]?) {
        guard let list else { return }
        
        DispatchQueue.main.async(execute: {
            self.latestProcesses = list
            guard self.contentLoaded else { return }
            self.renderProcesses(list)
        })
    }
    
    private func renderProcesses(_ list: [TopProcess]) {
        guard (self.window?.isVisible ?? false) || !self.initializedProcesses, let view = self.processes else { return }
        
        for i in 0..<view.count {
            if list.indices.contains(i) {
                let process = list[i]
                view.set(i, process, [String(format: "%.1f%%", process.usage)], usage: ColorValue(process.usage / 100, color: self.chartColor))
            } else {
                view.set(i, nil, [])
            }
        }
        self.initializedProcesses = true
    }
    
    internal func loadCallback(_ value: CPU_Load) {
        let sample = DoubleValue(value.totalUsage)
        DispatchQueue.main.async(execute: {
            self.latestLoad = value
            self.chartHistory.append(sample)
            guard self.remote == nil else { return }
            self.loadLineChart?.historyUpdated()
            guard self.contentLoaded else { return }
            self.renderLoad(value)
        })
    }
    
    private func renderLoad(_ value: CPU_Load) {
        guard self.remote == nil else { return }
        if (self.window?.isVisible ?? false) || !self.initialized {
            self.renderSplit(total: value.totalUsage, system: value.systemLoad, user: value.userLoad, idle: value.idleLoad, perCore: value.usagePerCore)
            self.initialized = true
        }
    }
    
    /// The circle, the bar, the split and each core, out of 1.
    private func renderSplit(total: Double, system: Double, user: Double, idle: Double, perCore: [Double]) {
        self.circle?.toolTip = "\(localizedString("CPU usage")): \(Int(total.rounded(toPlaces: 2) * 100))%"
        self.circle?.setValue(total)
        self.circle?.setSegments([
            ColorValue(system, color: self.systemColor),
            ColorValue(user, color: self.userColor)
        ])
        self.circle?.setNonActiveSegmentColor(self.idleColor)
        
        self.systemField?.stringValue = "\(Int(system.rounded(toPlaces: 2) * 100))%"
        self.userField?.stringValue = "\(Int(user.rounded(toPlaces: 2) * 100))%"
        self.idleField?.stringValue = "\(Int(idle.rounded(toPlaces: 2) * 100))%"
        
        self.bar?.setValues([
            ColorValue(system, color: self.systemColor),
            ColorValue(user, color: self.userColor)
        ])
        
        for (i, v) in perCore.enumerated() {
            if let core = self.cores.first(where: {$0.identifier?.rawValue == "\(i)" }) {
                core.setValue(v)
            }
        }
    }
    
    public func averageCallback(_ value: CPU_AverageLoad?) {
        guard let value else { return }
        
        DispatchQueue.main.async(execute: {
            self.latestAverage = value
            guard self.contentLoaded else { return }
            self.renderAverage(value)
        })
    }
    
    private func renderAverage(_ value: CPU_AverageLoad) {
        guard self.remote == nil else { return }
        if (self.window?.isVisible ?? false) || !self.initializedAverage {
            self.average1Field?.stringValue = "\(value.load1)"
            self.average5Field?.stringValue = "\(value.load5)"
            self.average15Field?.stringValue = "\(value.load15)"
            
            self.initializedAverage = true
        }
    }
    
    public func fleetCallback(_ value: CPU_FleetLine?) {
        DispatchQueue.main.async(execute: {
            self.fleet = value?.hosts.map { entry in
                let host = self.fleet.first { $0.label == entry.label } ?? FleetHost(label: entry.label)
                host.record(entry)
                return host
            } ?? []
            guard self.contentLoaded else { return }
            if self.shape != self.shown {
                self.reload()
                return
            }
            self.updatePicker()
            if let host = self.remote, self.window?.isVisible ?? false {
                self.renderRemote(host)
            }
        })
    }
    
    /// The page for another machine: its last reading, each core's mean over the kept readings in
    /// the core's tooltip, and its usage history.
    private func renderRemote(_ host: FleetHost) {
        let title = host.title
        self.titleField?.stringValue = title.name
        self.clustersField?.stringValue = title.cores
        self.loadLineChart?.historyUpdated()
        guard let entry = host.latest, let cpu = entry.cpu else { return }
        
        self.renderSplit(
            total: (100 - cpu.idle) / 100,
            system: cpu.system / 100,
            user: cpu.user / 100,
            idle: cpu.idle / 100,
            perCore: (entry.perCore ?? []).map { $0 / 100 }
        )
        for (i, mean) in host.coreMeans.enumerated() {
            self.cores.first(where: { $0.identifier?.rawValue == "\(i)" })?.toolTip =
                "\(localizedString("Average")), \(host.minutes) min: \(Int((mean * 100).rounded()))%"
        }
        
        let loads = entry.loads ?? []
        for (field, load) in zip([self.average1Field, self.average5Field, self.average15Field], loads) {
            field?.stringValue = String(format: "%.2f", load)
        }
        
        let top = entry.top ?? []
        for (i, row) in self.remoteProcesses.enumerated() {
            let process = top.indices.contains(i) ? top[i] : nil
            row.name.stringValue = process?.name ?? ""
            row.value.stringValue = process.map { String(format: "%d   %.1f%%", $0.pid, $0.cpu) } ?? ""
        }
    }
    
    public func frequencyCallback(_ value: CPU_Frequency?) {
        guard let value else { return }
        
        DispatchQueue.main.async(execute: {
            self.latestFrequency = value
            guard self.contentLoaded else { return }
            self.renderFrequency(value)
        })
    }
    
    private func renderFrequency(_ value: CPU_Frequency) {
        if (self.window?.isVisible ?? false) || !self.initializedFrequency {
            if let v = value.value {
                self.coresFreqField?.stringValue = "\(Int(v)) MHz"
            }
            if let v = value.eCore {
                self.eCoresFreqField?.stringValue = "\(Int(v)) MHz"
            }
            if let v = value.pCore {
                self.pCoresFreqField?.stringValue = "\(Int(v)) MHz"
            }
            if let v = value.sCore {
                self.sCoresFreqField?.stringValue = "\(Int(v)) MHz"
            }
            
            self.initializedFrequency = true
        }
    }
}

class CoreView: NSStackView {
    private let core: core_s
    
    private let valueField = ValueField()
    private var bar: BarChartView = BarChartView(size: 8, horizontal: true)
    
    private var eCoresColor: NSColor {
        let color = SColor.teal
        let key = Store.shared.string(key: "CPU_eCoresColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    private var pCoresColor: NSColor {
        let color = SColor.indigo
        let key = Store.shared.string(key: "CPU_pCoresColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    private var sCoresColor: NSColor {
        let color = SColor.orange
        let key = Store.shared.string(key: "CPU_sCoresColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    
    public init(_ core: core_s, num: Int) {
        self.core = core
        
        super.init(frame: .zero)
        
        self.heightAnchor.constraint(equalToConstant: 24).isActive = true
        self.orientation = .vertical
        self.distribution = .fillEqually
        self.identifier = NSUserInterfaceItemIdentifier("\(core.id)")
        
        self.bar.heightAnchor.constraint(equalToConstant: 8).isActive = true
        self.valueField.font = .systemFont(ofSize: 12)
        
        let header: NSStackView = NSStackView()
        header.orientation = .horizontal
        header.distribution = .fill
        
        var title: String
        switch core.type {
        case .efficiency: title = localizedString("Efficiency core")
        case .performance: title = localizedString("Performance core")
        case .super: title = localizedString("Super core")
        default: title = localizedString("Core")
        }
        title += " \(num)"
        
        header.addArrangedSubview(LabelField(title))
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(self.valueField)
        
        self.addArrangedSubview(header)
        self.addArrangedSubview(self.bar)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func setValue(_ newValue: Double) {
        self.valueField.stringValue = "\(Int(newValue.rounded(toPlaces: 2) * 100))%"
        let color = self.core.type == .efficiency ? self.eCoresColor : self.core.type == .super ? self.sCoresColor : self.pCoresColor
        self.bar.setValue(ColorValue(newValue, color: color))
    }
}
