import AppKit
import Combine
import GlutCore
import ServiceManagement
import UserNotifications

final class Sampler {
    let queue = DispatchQueue(label: "dev.theitger.glut.sensors", qos: .utility)
    private var telemetry: Telemetry?
    private var timer: DispatchSourceTimer?
    private var connection: FanConnection?
    private var request = FanRequest(mode: .system)
    var receive: ((Result<Snapshot, Error>, String?) -> Void)?

    func start() {
        queue.async { [self] in
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: 2)
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source; source.resume()
        }
    }
    private func tick() {
        var controlError: String?
        if let connection {
            do { try connection.apply(request) }
            catch { controlError = error.localizedDescription; self.connection = nil; request = FanRequest(mode: .system) }
        }
        do {
            if telemetry == nil { telemetry = try Telemetry() }
            guard let telemetry else { return }
            receive?(.success(telemetry.sample()), controlError)
        } catch { receive?(.failure(error), controlError) }
    }
    func attach(path: String, request: FanRequest, completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            do {
                let connection = try FanConnection(path: path)
                try connection.apply(request)
                self.connection = connection; self.request = request
                completion(nil)
            } catch { completion(error) }
        }
    }
    // Coalesce slider edits until the next heartbeat instead of queuing a full sensor scan per pixel.
    func update(_ request: FanRequest) { queue.async { self.request = request } }
    func resetMaximums() { queue.async { self.telemetry?.resetMaximums(); self.tick() } }
    func disconnect() { queue.async { self.request = FanRequest(mode: .system); self.connection = nil } }
}

@MainActor final class Monitor: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var history: [Snapshot] = []
    @Published var sensorError: String?
    @Published var controlError: String?
    @Published var mode: ControlMode = .system
    @Published var connected = false
    @Published var authorizing = false
    @Published var logging = false
    @Published var showAdditionalSensors = UserDefaults.standard.bool(forKey: "showAdditionalSensors") {
        didSet { UserDefaults.standard.set(showAdditionalSensors, forKey: "showAdditionalSensors") }
    }
    @Published var logPath: String?
    @Published var rules: [BoostRule] = [] { didSet { saveRules(); updateControl() } }
    @Published var manualPercent = 70.0 { didSet { updateControl() } }
    @Published var fahrenheit = UserDefaults.standard.bool(forKey: "fahrenheit") {
        didSet { UserDefaults.standard.set(fahrenheit, forKey: "fahrenheit") }
    }
    @Published var alerts = UserDefaults.standard.bool(forKey: "alerts") {
        didSet { UserDefaults.standard.set(alerts, forKey: "alerts"); if alerts { requestNotifications() } }
    }
    @Published var alertThreshold = UserDefaults.standard.object(forKey: "alertThreshold") as? Double ?? 90 {
        didSet { UserDefaults.standard.set(alertThreshold, forKey: "alertThreshold") }
    }
    @Published var menuSensor = UserDefaults.standard.string(forKey: "menuSensor") ?? "cpu" {
        didSet { UserDefaults.standard.set(menuSensor, forKey: "menuSensor") }
    }
    private let sampler = Sampler()
    private var log: FileHandle?
    private var lastAlert = Date.distantPast
    private var sleepObserver: NSObjectProtocol?
    private var controlGeneration = 0
    let chip = Machine.chip
    let machine = Machine.model
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"

    init() {
        if let data = UserDefaults.standard.data(forKey: "rules") {
            do {
                let rules = try JSONDecoder().decode([BoostRule].self, from: data)
                try FanRequest(mode: .automatic, rules: rules).validate()
                self.rules = rules
            } catch { controlError = "Saved rules could not be loaded: " + error.localizedDescription }
        }
        sampler.receive = { [weak self] result, controlError in
            DispatchQueue.main.async { self?.accept(result, controlError: controlError) }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.releaseControl() }
        }
        sampler.start()
    }
    func temperature(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f°%@", fahrenheit ? value * 1.8 + 32 : value, fahrenheit ? "F" : "C")
    }
    func hottest(_ group: SensorGroup? = nil) -> Double? {
        visibleSensors.filter { group == nil || $0.group == group }.compactMap(\.celsius).max()
    }
    var visibleSensors: [Sensor] { (snapshot?.sensors ?? []).filter { showAdditionalSensors || $0.isKnown } }
    func componentTemperature(_ group: SensorGroup) -> Double? {
        guard snapshot != nil else { return nil }
        return TemperatureSummary.rollingMean(group, history: history)
    }
    var menuValue: Double? {
        if menuSensor == "cpu" { return componentTemperature(.cpu) }
        if menuSensor == "gpu" { return componentTemperature(.gpu) }
        if menuSensor == "hottest" { return hottest() }
        return snapshot?.sensors.first { $0.id == menuSensor }?.celsius
    }
    private var request: FanRequest { FanRequest(mode: mode, percent: manualPercent, rules: rules) }
    private func saveRules() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(rules), forKey: "rules") }
        catch { controlError = "Could not save fan rules: " + error.localizedDescription }
    }
    private func updateControl() { if connected { sampler.update(request) } }
    func setMode(_ newMode: ControlMode) {
        guard !authorizing else { return }
        if newMode == .system { mode = .system; updateControl(); return }
        guard snapshot?.fans.isEmpty == false else { controlError = "This Mac has no readable fans."; return }
        if connected { mode = newMode; updateControl(); return }
        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("GlutHelper"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            controlError = "GlutHelper is missing. Run the packaged Glut.app built by Scripts/build.sh."
            return
        }
        authorizing = true; controlError = nil
        controlGeneration += 1
        let generation = controlGeneration
        let next = FanRequest(mode: newMode, percent: manualPercent, rules: rules)
        let uid = getuid()
        Task {
            do {
                let path = try await Task.detached(priority: .userInitiated) {
                    let shellPath = "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
                    let command = shellPath + " --serve " + String(uid)
                    let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = ["-e", "do shell script \"\(literal)\" with administrator privileges"]
                    let output = Pipe(); let errors = Pipe()
                    process.standardOutput = output; process.standardError = errors
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Authorization failed."
                        throw GlutError.message(detail.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                }.value
                guard generation == controlGeneration else { authorizing = false; return }
                sampler.attach(path: path, request: next) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.authorizing = false
                        guard generation == self.controlGeneration else { self.sampler.disconnect(); return }
                        if let error { self.controlError = error.localizedDescription }
                        else { self.connected = true; self.mode = newMode; self.updateControl() }
                    }
                }
            } catch { authorizing = false; controlError = error.localizedDescription }
        }
    }
    func releaseControl() {
        controlGeneration += 1
        mode = .system; connected = false; sampler.disconnect()
    }
    func resetMaximums() { sampler.resetMaximums() }
    private func accept(_ result: Result<Snapshot, Error>, controlError: String?) {
        if let controlError { self.controlError = controlError; connected = false; mode = .system }
        switch result {
        case .failure(let error): sensorError = error.localizedDescription; snapshot = nil
        case .success(let sample):
            sensorError = nil; snapshot = sample
            history.append(sample)
            if history.count > 150 { history.removeFirst(history.count - 150) }
            if logging { appendLog(sample) }
            if alerts, let value = hottest(), value >= alertThreshold, Date().timeIntervalSince(lastAlert) > 300 {
                lastAlert = Date()
                let content = UNMutableNotificationContent()
                content.title = "Glut · Temperature alert"
                content.body = "Highest sensor temperature: \(temperature(value)). Open Glut to inspect your sensors."
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { [weak self] error in
                    if let error { Task { @MainActor in self?.controlError = "Notification failed: " + error.localizedDescription } }
                }
            }
        }
    }
    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if !granted { Task { @MainActor in self?.controlError = error?.localizedDescription ?? "Notifications are disabled. Enable Glut in System Settings → Notifications." } }
        }
    }
    func startLogging() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Glut-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data("timestamp,type,key,name,value,unit\n".utf8).write(to: url, options: .atomic)
            log = try FileHandle(forWritingTo: url); try log?.seekToEnd()
            logging = true; logPath = url.path
            if let snapshot { appendLog(snapshot) }
        } catch { controlError = "Could not start logging: " + error.localizedDescription }
    }
    private func appendLog(_ sample: Snapshot) {
        do {
            guard let log else { throw GlutError.message("The log file is not open.") }
            try log.write(contentsOf: Data(CSV.snapshot(date: sample.date, sensors: sample.sensors, fans: sample.fans).utf8))
        } catch { controlError = "CSV logging stopped: " + error.localizedDescription; stopLogging() }
    }
    func stopLogging() {
        logging = false
        do { try log?.close() } catch { controlError = "Could not close CSV log: " + error.localizedDescription }
        log = nil
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { controlError = "Login item: " + error.localizedDescription }
    }
}
