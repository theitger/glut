import Foundation
import Darwin
import GlutCore
import os

private var stopping = false

func launch(uid: uid_t) throws {
    guard geteuid() == 0, uid >= 501 else { throw GlutError.message("Run the helper through Glut's administrator prompt.") }
    var template = Array("/private/tmp/glut.XXXXXX".utf8CString)
    guard let created = mkdtemp(&template) else { throw GlutError.message("Cannot create private helper directory.") }
    let directory = String(cString: created)
    let path = directory + "/control.sock"
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { rmdir(directory); throw GlutError.message("Cannot create helper socket.") }
    var address = try LocalSocket.address(path)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0, chmod(path, 0o600) == 0, chown(path, uid, gid_t.max) == 0,
          chmod(directory, 0o711) == 0, listen(listener, 1) == 0 else {
        close(listener); unlink(path); rmdir(directory)
        throw GlutError.message("Cannot prepare protected helper endpoint.")
    }
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
        close(listener); unlink(path); rmdir(directory)
        throw GlutError.message("Cannot initialize helper launch actions.")
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawn_file_actions_adddup2(&actions, listener, 198) == 0 else {
        close(listener); unlink(path); rmdir(directory)
        throw GlutError.message("Cannot pass the helper socket to its session.")
    }
    for fd: Int32 in [0, 1, 2] {
        guard posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0) == 0 else {
            close(listener); unlink(path); rmdir(directory)
            throw GlutError.message("Cannot detach helper input and output.")
        }
    }
    let executable = CommandLine.arguments[0]
    let arguments = [executable, "--listen", String(uid), path]
    let strings = arguments.map { strdup($0) }
    defer { strings.forEach { free($0) } }
    var pointers = strings + [nil]
    var child: pid_t = 0
    let spawned = posix_spawn(&child, executable, &actions, nil, &pointers, environ)
    close(listener)
    guard spawned == 0 else { unlink(path); rmdir(directory); throw GlutError.message("Cannot launch fan helper: \(spawned).") }
    print(path)
}

func serve(uid: uid_t, path: String) throws {
    guard geteuid() == 0, uid >= 501, path.hasPrefix("/private/tmp/glut."), path.hasSuffix("/control.sock") else {
        throw GlutError.message("Invalid helper session.")
    }
    let directory = (path as NSString).deletingLastPathComponent
    let listener: Int32 = 198
    signal(SIGPIPE, SIG_IGN)
    signal(SIGTERM) { _ in stopping = true }
    signal(SIGINT) { _ in stopping = true }
    defer { close(listener); unlink(path); rmdir(directory) }
    var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    guard poll(&poller, 1, 20_000) > 0 else { return }
    let client = accept(listener, nil, nil)
    guard client >= 0 else { return }
    defer { close(client) }
    var peer: uid_t = 0; var group: gid_t = 0
    guard getpeereid(client, &peer, &group) == 0, peer == uid else { return }
    try LocalSocket.configure(client, seconds: 8)
    let smc = try SMC()
    let fans = smc.fans()
    guard !fans.isEmpty else { try LocalSocket.send(FanResponse(error: "No controllable fans were found."), to: client); return }
    let session = try FanSession(hardware: smc, fans: fans)
    defer {
        // Retry the whole reset; firmware may temporarily reject mode changes.
        for _ in 0..<3 {
            do { try session.close(); break }
            catch {
                Logger(subsystem: "dev.theitger.glut", category: "fan-helper").error("Fan reset failed: \(error.localizedDescription, privacy: .public)")
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }
    while !stopping {
        do {
            let request = try LocalSocket.receive(FanRequest.self, from: client)
            try session.apply(request)
            try LocalSocket.send(FanResponse(), to: client)
        } catch {
            var message = error.localizedDescription
            // Restore before reporting: a blocked socket must never delay the first reset.
            do { try session.close() }
            catch { message += " Reset also failed: " + error.localizedDescription }
            Logger(subsystem: "dev.theitger.glut", category: "fan-helper").error("Session ended: \(message, privacy: .public)")
            try? LocalSocket.send(FanResponse(error: message), to: client)
            return
        }
    }
}

do {
    let args = CommandLine.arguments
    if args.count == 3, args[1] == "--serve", let uid = UInt32(args[2]) {
        try launch(uid: uid)
    } else if args.count == 4, args[1] == "--listen", let uid = UInt32(args[2]) {
        try serve(uid: uid, path: args[3])
    } else {
        throw GlutError.message("Usage: GlutHelper --serve <user-id> (launched by Glut)")
    }
} catch {
    fputs("GlutHelper: \(error.localizedDescription)\n", stderr)
    exit(1)
}
