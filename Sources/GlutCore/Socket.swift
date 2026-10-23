import Foundation
import Darwin

public enum LocalSocket {
    public static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw GlutError.message("Helper socket path is too long.")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    public static func configure(_ fd: Int32, seconds: Int) throws {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw GlutError.message("Cannot configure the helper heartbeat timeout.")
        }
        var noPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw GlutError.message("Cannot configure helper socket signal handling.")
        }
    }
    public static func send<T: Encodable>(_ object: T, to fd: Int32) throws {
        var data = try JSONEncoder().encode(object)
        data.append(10)
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                guard count > 0 else { throw GlutError.message("Fan helper connection closed while writing.") }
                written += count
            }
        }
    }
    public static func receive<T: Decodable>(_ type: T.Type, from fd: Int32) throws -> T {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 16384 {
            guard Darwin.read(fd, &byte, 1) == 1 else {
                throw GlutError.message("Fan helper disconnected or heartbeat timed out.")
            }
            if byte == 10 { return try JSONDecoder().decode(type, from: data) }
            data.append(byte)
        }
        throw GlutError.message("Fan helper message exceeds its size limit.")
    }
}

public final class FanConnection {
    private var fd: Int32 = -1
    public init(path: String) throws {
        guard path.hasPrefix("/private/tmp/glut."), path.hasSuffix("/control.sock") else {
            throw GlutError.message("Unexpected helper endpoint.")
        }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GlutError.message("Cannot create helper connection.") }
        do {
            var address = try LocalSocket.address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { throw GlutError.message("Cannot connect to the fan helper.") }
            var uid: uid_t = 1; var gid: gid_t = 1
            guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { throw GlutError.message("Fan helper is not running as root.") }
            try LocalSocket.configure(fd, seconds: 15)
        } catch { close(fd); fd = -1; throw error }
    }
    deinit { if fd >= 0 { close(fd) } }
    public func apply(_ request: FanRequest) throws {
        try request.validate()
        try LocalSocket.send(request, to: fd)
        let response = try LocalSocket.receive(FanResponse.self, from: fd)
        if let error = response.error { throw GlutError.message(error) }
    }
}
