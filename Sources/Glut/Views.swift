import SwiftUI
import GlutCore
import ServiceManagement

func heatColor(_ value: Double?) -> Color {
    guard let value else { return .secondary }
    if value >= 90 { return .red }
    if value >= 75 { return .orange }
    return .green
}

private enum PanelPage: String, CaseIterable {
    case overview = "Overview", sensors = "Sensors", rules = "Rules", settings = "Settings"
}

struct MenuPanel: View {
    @EnvironmentObject private var monitor: Monitor
    @State private var page: PanelPage = .overview

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
            navigation.padding(.horizontal, 18).padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let message = monitor.sensorError ?? monitor.controlError {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    switch page {
                    case .overview: OverviewPanel()
                    case .sensors: SensorsPanel()
                    case .rules: RulesPanel()
                    case .settings: SettingsPanel()
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer.padding(.horizontal, 18).padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.orange)
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 19, weight: .medium)).foregroundStyle(.orange)
                .frame(width: 36, height: 36).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("Glut").font(.system(size: 16, weight: .semibold))
                Text(monitor.chip).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 5) {
                Circle().fill(monitor.authorizing ? .orange : .green).frame(width: 5, height: 5)
                Text(monitor.authorizing ? "Authorizing" : monitor.mode.rawValue)
                    .font(.system(size: 11, weight: .medium)).fixedSize()
            }.padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: Capsule())
        }
    }
    private var navigation: some View {
        HStack(spacing: 3) {
            ForEach(PanelPage.allCases, id: \.self) { destination in
                Button { page = destination } label: {
                    Text(destination.rawValue).font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity).padding(.horizontal, 6).padding(.vertical, 8)
                        .foregroundStyle(page == destination ? .primary : .secondary)
                        .background {
                            if page == destination {
                                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityAddTraits(page == destination ? [.isSelected] : [])
            }
        }.padding(4).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
    }
    private var footer: some View {
        HStack(spacing: 8) {
            if monitor.logging {
                Label("Recording CSV", systemImage: "record.circle.fill").font(.caption2).foregroundStyle(.red)
            } else {
                Circle().fill(monitor.sensorError == nil ? .green : .orange).frame(width: 5, height: 5)
                Text(monitor.snapshot?.date.formatted(date: .omitted, time: .standard) ?? "Connecting…")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Text("v\(monitor.version)").font(.caption2).foregroundStyle(.tertiary)
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 12, weight: .medium))
                    .frame(width: 30, height: 30).contentShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).help("Quit Glut").accessibilityLabel("Quit Glut")
        }
    }
}

private struct OverviewPanel: View {
    @EnvironmentObject private var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                SummaryTile(title: "CPU", value: monitor.temperature(monitor.componentTemperature(.cpu)), color: heatColor(monitor.componentTemperature(.cpu)))
                SummaryTile(title: "GPU", value: monitor.temperature(monitor.componentTemperature(.gpu)), color: heatColor(monitor.componentTemperature(.gpu)))
            }
            HStack {
                Text("CPU live peak").foregroundStyle(.secondary)
                Spacer()
                Text(monitor.temperature(TemperatureSummary.componentPeak(.cpu, sensors: monitor.snapshot?.sensors ?? []))).monospacedDigit()
            }.font(.caption)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("CPU history").font(.caption).fontWeight(.medium)
                    Spacer()
                    Text("5 min · raw core average").font(.caption2).foregroundStyle(.secondary)
                }
                Sparkline(values: monitor.history.map { TemperatureSummary.componentMean(.cpu, sensors: $0.sensors) }, color: .orange)
                    .frame(height: 42)
            }.panelCard()
            FanPanel()
            HStack {
                Label(monitor.snapshot?.thermalState ?? "—", systemImage: "waveform.path")
                Spacer()
                Text("\(monitor.snapshot?.sensors.filter { $0.celsius != nil }.count ?? 0) readable sensors").monospacedDigit()
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct FanPanel: View {
    @EnvironmentObject private var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Fans", systemImage: "fanblades").font(.system(size: 12, weight: .semibold))
                Spacer()
                if monitor.authorizing { ProgressView().controlSize(.small) }
            }
            if let fans = monitor.snapshot?.fans, !fans.isEmpty {
                ForEach(fans) { fan in
                    VStack(spacing: 6) {
                        HStack {
                            Text(fan.name).foregroundStyle(.secondary)
                            Spacer()
                            Text(fan.actual.map { "\(Int($0)) RPM" } ?? "Unavailable").monospacedDigit()
                        }.font(.caption)
                        ProgressView(value: fan.actual ?? 0, total: max(fan.maximum ?? 1, 1)).controlSize(.small)
                    }
                }
                HStack(spacing: 4) {
                    ForEach(ControlMode.allCases, id: \.self) { mode in
                        Button { monitor.setMode(mode) } label: {
                            Text(mode == .automatic ? "Auto" : mode.rawValue)
                                .font(.system(size: 11, weight: .medium)).fixedSize()
                                .frame(maxWidth: .infinity).padding(.horizontal, 8).padding(.vertical, 8)
                                .foregroundStyle(monitor.mode == mode ? .white : .primary)
                                .background(monitor.mode == mode ? Color.orange : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).help(mode.rawValue)
                            .accessibilityAddTraits(monitor.mode == mode ? [.isSelected] : [])
                    }
                }.padding(4).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
                    .disabled(monitor.authorizing)
                if monitor.mode == .manual {
                    HStack(spacing: 10) {
                        Slider(value: $monitor.manualPercent, in: 0...100, step: 1).accessibilityLabel("Fan speed range")
                        Text("\(Int(monitor.manualPercent))%").font(.caption).monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                    Text("0% = hardware minimum · 100% = maximum").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(monitor.mode == .system ? "macOS manages cooling." : monitor.mode == .max ? "All fans target maximum speed." : "The highest matching rule wins.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("No readable fans. Temperature monitoring is available on fanless Macs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.panelCard()
    }
}

private struct SensorsPanel: View {
    @EnvironmentObject private var monitor: Monitor
    @State private var search = ""
    @State private var group: SensorGroup?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search sensors", text: $search).textFieldStyle(.plain)
            }.padding(.horizontal, 11).padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
            HStack {
                Picker("Group", selection: $group) {
                    Text("All sensors").tag(Optional<SensorGroup>.none)
                    ForEach(SensorGroup.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }.labelsHidden().frame(maxWidth: 170)
                Spacer()
                Button { monitor.resetMaximums() } label: {
                    Label("Reset peaks", systemImage: "arrow.counterclockwise").font(.caption)
                }.buttonStyle(PillButtonStyle())
            }
            HStack { Text("Sensor · live reading"); Spacer(); Text("Session max") }
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 2)
            LazyVStack(spacing: 8) {
                ForEach(monitor.visibleSensors.filter {
                    (group == nil || $0.group == group) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search))
                }) { sensor in
                    HStack(spacing: 10) {
                        Circle().fill(heatColor(sensor.celsius)).frame(width: 5, height: 5)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sensor.name).font(.caption).lineLimit(2)
                            HStack(spacing: 5) {
                                Text(sensor.id).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                                Text(monitor.temperature(sensor.celsius)).font(.caption).monospacedDigit()
                            }
                        }
                        Spacer(minLength: 8)
                        Text(monitor.temperature(sensor.maximum)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            Text("Live readings are unsmoothed. Unavailable CPU readings are shown as —.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct RulesPanel: View {
    @EnvironmentObject private var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Auto Boost").font(.headline)
            Text("Use live sensor temperatures to set fan speeds. The highest matching rule wins; rules clear 3°C below their threshold.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($monitor.rules) { $rule in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Toggle("Enabled", isOn: $rule.enabled).font(.caption).toggleStyle(.switch).controlSize(.small)
                        Spacer()
                        Button { monitor.rules.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "trash").frame(width: 28, height: 28)
                        }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Delete rule")
                    }
                    Picker("Sensor", selection: $rule.sensor) {
                        if monitor.snapshot?.sensors.contains(where: { $0.id == rule.sensor }) != true {
                            Text("Unavailable: \(rule.sensor)").tag(rule.sensor)
                        }
                        ForEach(monitor.snapshot?.sensors ?? []) { Text("\($0.name) · \($0.id)").tag($0.id) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                        Text("Above").font(.caption).foregroundStyle(.secondary)
                        TextField("°C", value: $rule.threshold, format: .number).textFieldStyle(.plain)
                            .padding(.horizontal, 8).padding(.vertical, 7).frame(width: 58)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                            .accessibilityLabel("Trigger temperature in Celsius")
                        Text("°C").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        TextField("%", value: $rule.percent, format: .number).textFieldStyle(.plain)
                            .padding(.horizontal, 8).padding(.vertical, 7).frame(width: 58)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                            .accessibilityLabel("Fan speed percentage")
                        Text("% fan").font(.caption).foregroundStyle(.secondary)
                    }
                }.panelCard()
            }
            Button {
                if let sensor = monitor.visibleSensors.first(where: { $0.group == .cpu }) ?? monitor.visibleSensors.first {
                    monitor.rules.append(BoostRule(sensor: sensor.id))
                }
            } label: { Label("Add rule", systemImage: "plus").font(.caption) }
                .buttonStyle(PillButtonStyle())
                .disabled(monitor.visibleSensors.isEmpty || monitor.rules.count >= 64)
            Text("Changes apply while Auto mode is active. A missing or invalid rule sensor returns cooling to macOS.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct SettingsPanel: View {
    @EnvironmentObject private var monitor: Monitor
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text("General").font(.system(size: 12, weight: .semibold))
                SettingsToggle(title: "Launch at login", isOn: Binding(get: { launchAtLogin }, set: {
                    monitor.setLaunchAtLogin($0); launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
                SettingsToggle(title: "Display Fahrenheit", isOn: $monitor.fahrenheit)
                SettingsToggle(title: "Include unmapped sensors", isOn: $monitor.showAdditionalSensors)
                Divider()
                Text("Menu bar temperature").foregroundStyle(.secondary)
                Picker("Menu bar temperature", selection: $monitor.menuSensor) {
                    Text("CPU · 10 s average").tag("cpu")
                    Text("GPU · 10 s average").tag("gpu")
                    Text("Highest live sensor").tag("hottest")
                    ForEach(monitor.snapshot?.sensors ?? []) { Text("\($0.name) · \($0.id)").tag($0.id) }
                }.labelsHidden().frame(maxWidth: .infinity)
            }.font(.caption).toggleStyle(.switch).controlSize(.small).panelCard()
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggle(title: "Temperature alerts", isOn: $monitor.alerts).fontWeight(.medium)
                Stepper("Above \(Int(monitor.alertThreshold))°C", value: $monitor.alertThreshold, in: 40...120, step: 1)
                Text("Alerts and fan rules use live readings. Summaries average mapped cores over 10 seconds. Rules, limits and CSV use Celsius.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.font(.caption).toggleStyle(.switch).controlSize(.small).panelCard()
            VStack(alignment: .leading, spacing: 12) {
                Text("CSV logging").font(.system(size: 12, weight: .semibold))
                Button {
                    if monitor.logging { monitor.stopLogging() } else { monitor.startLogging() }
                } label: {
                    Label(monitor.logging ? "Stop recording" : "Record to CSV…", systemImage: monitor.logging ? "stop.circle" : "record.circle")
                }.buttonStyle(PillButtonStyle())
                if let path = monitor.logPath { Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
            }.panelCard()
            VStack(alignment: .leading, spacing: 12) {
                Text("Fan control session").font(.system(size: 12, weight: .semibold))
                Text("Custom control requires administrator approval. Sleeping or quitting ends the session; the helper attempts a reset after 8 seconds without a heartbeat.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("End custom control") { monitor.releaseControl() }
                    .font(.caption).buttonStyle(PillButtonStyle()).disabled(!monitor.connected)
            }.panelCard()
            if let battery = monitor.snapshot?.battery, !battery.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Battery").font(.system(size: 12, weight: .semibold))
                    ForEach(battery.keys.sorted(), id: \.self) { key in
                        HStack { Text(key).foregroundStyle(.secondary); Spacer(); Text(battery[key] ?? "—").monospacedDigit() }.font(.caption)
                    }
                }.panelCard()
            }
            HStack {
                Text("Glut · MIT License").foregroundStyle(.secondary)
                Spacer()
                Link("Source code", destination: URL(string: "https://github.com/theitger/glut")!)
            }.font(.caption2)
        }.onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
}

struct SummaryTile: View {
    let title: String
    let value: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(value == "—" ? "unavailable" : "10s avg").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Text(value).font(.system(size: 29, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}

private struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.caption)
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
                .accessibilityLabel(title)
        }
    }
}

private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 12).padding(.vertical, 8)
            .background(.quaternary.opacity(configuration.isPressed ? 0.8 : 0.4), in: Capsule())
            .contentShape(Capsule())
    }
}

private extension View {
    func panelCard() -> some View {
        padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
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
