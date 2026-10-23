import SwiftUI
import GlutCore
import ServiceManagement

func heatColor(_ value: Double?) -> Color {
    guard let value else { return .secondary }
    if value >= 90 { return .red }
    if value >= 75 { return .orange }
    return .green
}

struct MainView: View {
    @EnvironmentObject private var monitor: Monitor
    @State private var group: SensorGroup?
    @State private var search = ""
    @State private var selection: String?
    @State private var showRules = false
    @AppStorage("showMaximums") private var showMaximums = true

    private var sensors: [Sensor] {
        monitor.visibleSensors.filter {
            (group == nil || $0.group == group) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if let error = monitor.sensorError {
                errorBanner(error, dismiss: nil)
            }
            if let error = monitor.controlError {
                errorBanner(error) { monitor.controlError = nil }
            }
            HStack(spacing: 0) {
                sensorPanel
                Divider()
                diagnostics.frame(width: 255)
            }
            Divider()
            fanPanel
            Divider()
            footer
        }
        .frame(minWidth: 880, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 7) {
                    Image(systemName: "thermometer.medium").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Glut").fontWeight(.semibold)
                        Text(monitor.chip).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItemGroup {
                Toggle(isOn: $showMaximums) { Label("Maximums", systemImage: "arrow.up.to.line") }
                    .help("Show highest temperature since launch")
                Button { monitor.resetMaximums() } label: { Label("Reset Maximums", systemImage: "arrow.counterclockwise") }
                Button { if monitor.logging { monitor.stopLogging() } else { monitor.startLogging() } } label: {
                    Label(monitor.logging ? "Stop Logging" : "Log to CSV", systemImage: monitor.logging ? "stop.circle.fill" : "record.circle")
                }.tint(monitor.logging ? .red : nil)
                SettingsLink { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showRules) { RulesView().environmentObject(monitor) }
    }
    private var sensorPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SummaryTile(title: "CPU", value: monitor.temperature(monitor.hottest(.cpu)), color: heatColor(monitor.hottest(.cpu)))
                SummaryTile(title: "GPU", value: monitor.temperature(monitor.hottest(.gpu)), color: heatColor(monitor.hottest(.gpu)))
                SummaryTile(title: "Highest", value: monitor.temperature(monitor.hottest()), color: heatColor(monitor.hottest()))
            }.padding(16)
            HStack {
                Picker("Sensors", selection: $group) {
                    Text("All Sensors").tag(Optional<SensorGroup>.none)
                    ForEach(SensorGroup.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }.labelsHidden().frame(width: 150)
                Spacer()
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter sensors", text: $search).textFieldStyle(.plain).frame(width: 170)
            }.padding(.horizontal, 16).padding(.bottom, 10)
            Table(sensors, selection: $selection) {
                TableColumn("Sensor") { sensor in
                    HStack(spacing: 8) {
                        Circle().fill(heatColor(sensor.celsius)).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sensor.name).lineLimit(1)
                            Text(sensor.id).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }.padding(.vertical, 3)
                }.width(min: 185, ideal: 230)
                TableColumn("Temperature") { sensor in
                    HStack(spacing: 8) {
                        GeometryReader { geometry in
                            Capsule().fill(.quaternary)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(heatColor(sensor.celsius).opacity(0.8))
                                        .frame(width: geometry.size.width * min(1, max(0, (sensor.celsius ?? 0) / 110)))
                                }
                        }.frame(width: 58, height: 5).accessibilityHidden(true)
                        Text(monitor.temperature(sensor.celsius)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }.width(min: 126, ideal: 140)
                TableColumn(showMaximums ? "Maximum" : "Group") { sensor in
                    if showMaximums {
                        Text(monitor.temperature(sensor.maximum)).monospacedDigit().foregroundStyle(.secondary)
                    } else { Text(sensor.group.rawValue).foregroundStyle(.secondary) }
                }.width(80)
            }
            .overlay {
                if monitor.snapshot == nil && monitor.sensorError == nil { ProgressView("Discovering sensors…") }
                else if sensors.isEmpty { ContentUnavailableView.search(text: search) }
            }
            if let selected = (monitor.snapshot?.sensors ?? []).first(where: { $0.id == selection }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(selected.name).font(.caption).fontWeight(.medium)
                        Spacer()
                        Text("Last 5 minutes").font(.caption2).foregroundStyle(.secondary)
                    }
                    Sparkline(values: monitor.history.map { $0.sensors.first { $0.id == selected.id }?.celsius }, color: heatColor(selected.celsius))
                        .frame(height: 42)
                }.padding(12).background(.quaternary.opacity(0.3))
            }
        }
    }
    private var diagnostics: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Hardware Status", systemImage: "stethoscope").font(.headline)
                VStack(spacing: 12) {
                    diagnosticRow("Thermal pressure", value: monitor.snapshot?.thermalState ?? "—", good: monitor.snapshot?.thermalState == "Nominal")
                    diagnosticRow("Readable sensors", value: "\(monitor.snapshot?.sensors.filter { $0.celsius != nil }.count ?? 0) / \(monitor.snapshot?.sensors.count ?? 0)", good: monitor.snapshot.map { $0.sensors.allSatisfy { $0.celsius != nil } } ?? false)
                    diagnosticRow("Fans detected", value: String(monitor.snapshot?.fans.count ?? 0), good: true)
                    diagnosticRow("Control", value: monitor.mode.rawValue, good: true)
                }
                Divider()
                Text("This Mac").font(.headline)
                Text(monitor.chip).font(.callout)
                Text(monitor.machine).font(.caption).foregroundStyle(.secondary)
                Text(ProcessInfo.processInfo.operatingSystemVersionString).font(.caption).foregroundStyle(.secondary)
                if let battery = monitor.snapshot?.battery, !battery.isEmpty {
                    Divider()
                    Label("Battery", systemImage: "battery.100percent").font(.headline)
                    ForEach(battery.keys.sorted(), id: \.self) { key in
                        HStack { Text(key).foregroundStyle(.secondary); Spacer(); Text(battery[key] ?? "—").monospacedDigit() }.font(.caption)
                    }
                }
                Divider()
                Text("Status reflects available sensor readings and macOS thermal pressure. It is not an Apple hardware diagnostic test.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(18)
        }
    }
    private var fanPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Fans", systemImage: "fanblades").font(.headline)
                Spacer()
                if monitor.authorizing { ProgressView().controlSize(.small); Text("Waiting for authorization…").font(.caption).foregroundStyle(.secondary) }
                Picker("Control mode", selection: Binding(get: { monitor.mode }, set: { monitor.setMode($0) })) {
                    ForEach(ControlMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 360)
                    .disabled(monitor.authorizing || monitor.snapshot?.fans.isEmpty != false)
            }
            if let fans = monitor.snapshot?.fans, !fans.isEmpty {
                HStack(spacing: 24) {
                    ForEach(fans) { fan in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(fan.name).font(.callout)
                                Spacer()
                                Text(fan.actual.map { "\(Int($0)) RPM" } ?? "Unavailable").monospacedDigit().fontWeight(.medium)
                            }
                            ProgressView(value: fan.actual ?? 0, total: max(fan.maximum ?? 1, 1)).tint(.accentColor)
                            HStack {
                                Text("Min \(fan.minimum.map { String(Int($0)) } ?? "—")")
                                Spacer()
                                Text("Max \(fan.maximum.map { String(Int($0)) } ?? "—") RPM")
                            }.font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }
            } else {
                Text("No fans detected. Temperature monitoring remains available on fanless Macs.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if monitor.mode == .manual {
                    Text("Speed range").font(.caption)
                    Slider(value: $monitor.manualPercent, in: 0...100, step: 1).frame(maxWidth: 260)
                    Text("\(Int(monitor.manualPercent))%").monospacedDigit().font(.caption).frame(width: 36)
                    Text("0% = hardware minimum").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(monitor.mode == .system ? "macOS controls cooling automatically." : monitor.mode == .max ? "All fans target their maximum speed." : "Highest matching rule wins; otherwise macOS controls cooling.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Configure Auto Boost…") { showRules = true }
            }
        }.padding(16)
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(monitor.sensorError == nil ? .green : .red).frame(width: 5, height: 5)
            Text(monitor.snapshot.map { "Updated \($0.date.formatted(date: .omitted, time: .standard)) · every 2 seconds" } ?? "Connecting to AppleSMC…")
            Spacer()
            if monitor.logging { Label("Recording CSV", systemImage: "record.circle.fill").foregroundStyle(.red).help(monitor.logPath ?? "") }
            Text("Glut 0.1.0 · Open Source").foregroundStyle(.tertiary)
        }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
    }
    private func diagnosticRow(_ title: String, value: String, good: Bool) -> some View {
        HStack(alignment: .top) {
            Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(good ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.callout) }
            Spacer()
        }
    }
    private func errorBanner(_ message: String, dismiss: (() -> Void)?) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain) }
        }.padding(12).background(.orange.opacity(0.12))
    }
}

struct SummaryTile: View {
    let title: String
    let value: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 29, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(color)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(13)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

struct Sparkline: View {
    let values: [Double?]
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                var drawing = false
                let valid = values.compactMap { $0 }
                let lower = max(0, (valid.min() ?? 0) - 5)
                let upper = max(lower + 10, (valid.max() ?? 100) + 5)
                for (index, value) in values.enumerated() {
                    guard let value else { drawing = false; continue }
                    let point = CGPoint(x: geometry.size.width * Double(index) / Double(max(1, values.count - 1)),
                                        y: geometry.size.height * (1 - (value - lower) / (upper - lower)))
                    if drawing { path.addLine(to: point) } else { path.move(to: point); drawing = true }
                }
            }.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }.accessibilityLabel("Temperature history")
    }
}

struct RulesView: View {
    @EnvironmentObject private var monitor: Monitor
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Auto Boost Rules").font(.title2).fontWeight(.semibold)
            Text("When a sensor reaches its threshold, boost every fan to the chosen point in its speed range. The highest matching rule wins. A rule clears 3°C below its threshold.")
                .font(.callout).foregroundStyle(.secondary)
            HStack { Text("Enabled").frame(width: 54); Text("Sensor").frame(maxWidth: .infinity, alignment: .leading); Text("Above °C").frame(width: 90); Text("Speed %").frame(width: 90); Spacer().frame(width: 24) }.font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach($monitor.rules) { $rule in
                        HStack {
                            Toggle("Enabled", isOn: $rule.enabled).labelsHidden().frame(width: 54)
                            Picker("Sensor", selection: $rule.sensor) {
                                if monitor.snapshot?.sensors.contains(where: { $0.id == rule.sensor }) != true { Text("Unavailable: \(rule.sensor)").tag(rule.sensor) }
                                ForEach(monitor.snapshot?.sensors ?? []) { Text("\($0.name) · \($0.id)").tag($0.id) }
                            }.labelsHidden().frame(maxWidth: .infinity)
                            TextField("°C", value: $rule.threshold, format: .number).frame(width: 80)
                            TextField("%", value: $rule.percent, format: .number).frame(width: 80)
                            Button { monitor.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).frame(width: 24)
                        }
                    }
                }.padding(.vertical, 4)
            }.frame(minHeight: 120)
            HStack {
                Button("Add Rule", systemImage: "plus") {
                    if let sensor = monitor.snapshot?.sensors.first(where: { $0.group == .cpu }) ?? monitor.snapshot?.sensors.first {
                        monitor.rules.append(BoostRule(sensor: sensor.id))
                    }
                }.disabled(monitor.snapshot?.sensors.isEmpty != false || monitor.rules.count >= 64)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Rules use Celsius in both display modes. Missing rule sensors stop custom control and return cooling to macOS. Changes apply immediately while Auto Boost is active.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 710, height: 370)
    }
}

struct MenuPanel: View {
    @EnvironmentObject private var monitor: Monitor
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 12) {
            HStack { Label("Glut", systemImage: "thermometer.medium").fontWeight(.semibold); Spacer(); Text(monitor.mode.rawValue).font(.caption).foregroundStyle(.secondary) }
            HStack {
                SummaryTile(title: "CPU", value: monitor.temperature(monitor.hottest(.cpu)), color: heatColor(monitor.hottest(.cpu)))
                SummaryTile(title: "GPU", value: monitor.temperature(monitor.hottest(.gpu)), color: heatColor(monitor.hottest(.gpu)))
            }
            if let error = monitor.sensorError ?? monitor.controlError { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(4) }
            ForEach(monitor.snapshot?.fans ?? []) { fan in
                HStack { Label(fan.name, systemImage: "fanblades"); Spacer(); Text(fan.actual.map { "\(Int($0)) RPM" } ?? "—").monospacedDigit() }.font(.callout)
            }
            Picker("Fan mode", selection: Binding(get: { monitor.mode }, set: { monitor.setMode($0) })) {
                ForEach(ControlMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().disabled(monitor.authorizing || monitor.snapshot?.fans.isEmpty != false)
            Divider()
            HStack {
                Button("Open Glut") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit Glut")
            }
        }.padding(16).frame(width: 330)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var monitor: Monitor
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch Glut at login", isOn: Binding(get: { launchAtLogin }, set: {
                    monitor.setLaunchAtLogin($0); launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
                Toggle("Display Fahrenheit", isOn: $monitor.fahrenheit)
                Toggle("Include unmapped sensor keys", isOn: $monitor.showAdditionalSensors)
                Picker("Menu bar temperature", selection: $monitor.menuSensor) {
                    Text("CPU maximum").tag("cpu")
                    Text("GPU maximum").tag("gpu")
                    Text("Highest sensor").tag("hottest")
                    ForEach(monitor.snapshot?.sensors ?? []) { Text("\($0.name) · \($0.id)").tag($0.id) }
                }
            }
            Section("Temperature Alerts") {
                Toggle("Notify when a sensor exceeds the limit", isOn: $monitor.alerts)
                Stepper("Limit: \(Int(monitor.alertThreshold))°C", value: $monitor.alertThreshold, in: 40...120, step: 1)
                Text("At most one notification every 5 minutes. Alert limits and CSV exports always use Celsius.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Fan Control") {
                Text("Custom control requires administrator approval for each app session. Closing Glut or sleeping your Mac ends the session. If Glut stops responding, the helper attempts to return control to macOS after 8 seconds without a heartbeat.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("End Custom Control Session") { monitor.releaseControl() }.disabled(!monitor.connected)
            }
            Section {
                HStack {
                    Text("Glut 0.1.0 · MIT License").foregroundStyle(.secondary)
                    Spacer()
                    Link("Source Code", destination: URL(string: "https://github.com/theitger/glut")!)
                }.font(.caption)
            }
        }.formStyle(.grouped).frame(width: 500, height: 520)
    }
}
