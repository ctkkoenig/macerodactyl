import Foundation

// The System Management Controller is Apple hardware. The panel builds and runs
// headless on Linux (CI does exactly that), where there is nothing to read, so
// the whole client compiles out rather than being stubbed.
#if canImport(IOKit)

import IOKit

/// Minimal read-only client for Apple's System Management Controller.
///
/// Used for the host indicators the OS exposes nowhere else: die temperatures,
/// fan speed, and total system power. Everything else on the status page (load,
/// memory, uptime, disk) comes from `sysctl`/`statfs`, which are cheaper and
/// need no hardware access at all.
///
/// Why not shell out. CLAUDE.md's rule is to use the `docker` CLI rather than
/// its socket, and that reasoning does not carry over here: `docker` is
/// guaranteed present on a machine running this app, whereas `macmon`, `istats`
/// and `smctemp` are third-party installs that most users will not have. A
/// panel that silently shows no temperature unless you happen to have brewed a
/// tool is worse than one that reads the sensor itself.
///
/// **Read-only by construction.** Only the read and key-discovery selectors are
/// implemented; there is no write path. Fan control belongs to macOS (or to
/// whatever the user has chosen to run), not to a container panel.
///
/// Needs no elevated privileges — SMC reads work as the logged-in user.
public final class SMC: @unchecked Sendable {

    // MARK: - Wire format
    //
    // The SMC user client takes and returns one fixed C struct. The layout is
    // not public API; it is stable across every macOS release this app supports
    // and is what every SMC reader in the wild uses.

    private struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct KeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private struct ParamStruct {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        // 32 bytes of payload. A tuple because the C struct is a fixed array
        // and Swift has no better import for one.
        var bytes:
            (
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
            ) = (
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
            )
    }

    /// `data8` selectors on the shared struct.
    private enum Selector: UInt8 {
        case readBytes = 5
        case keyFromIndex = 8
        case keyInfo = 9
    }

    /// The user client's single method index.
    private static let kernelIndex: UInt32 = 2

    // MARK: - Connection

    private var connection: io_connect_t = 0
    private let lock = NSLock()
    /// Discovered once. Enumerating every key costs one syscall per key, and
    /// the set does not change while the machine is running.
    private var discovered: [String]?

    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: - Primitives

    private func call(_ input: inout ParamStruct) -> ParamStruct? {
        var output = ParamStruct()
        var outSize = MemoryLayout<ParamStruct>.stride
        let result = withUnsafePointer(to: &input) { inPtr in
            IOConnectCallStructMethod(
                connection, Self.kernelIndex,
                inPtr, MemoryLayout<ParamStruct>.stride,
                &output, &outSize)
        }
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    /// SMC keys are four ASCII characters packed big-endian into a UInt32.
    private static func encode(_ key: String) -> UInt32? {
        let scalars = Array(key.utf8)
        guard scalars.count == 4 else { return nil }
        return scalars.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func decode(_ value: UInt32) -> String {
        let bytes = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads one key as a Double, converting from whatever type the SMC says it
    /// is. Returns nil for keys that are absent or of a type this does not model.
    public func read(_ key: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return readLocked(key)
    }

    private func readLocked(_ key: String) -> Double? {
        guard let encoded = Self.encode(key) else { return nil }

        var info = ParamStruct()
        info.key = encoded
        info.data8 = Selector.keyInfo.rawValue
        guard let described = call(&info) else { return nil }

        var request = ParamStruct()
        request.key = encoded
        request.keyInfo.dataSize = described.keyInfo.dataSize
        request.data8 = Selector.readBytes.rawValue
        guard let response = call(&request) else { return nil }

        let size = Int(described.keyInfo.dataSize)
        let type = Self.decode(described.keyInfo.dataType)
        var raw = [UInt8](repeating: 0, count: 32)
        withUnsafeBytes(of: response.bytes) { buffer in
            for i in 0..<min(32, buffer.count) { raw[i] = buffer[i] }
        }
        return Self.value(bytes: Array(raw.prefix(max(0, min(size, 32)))), type: type)
    }

    /// SMC types are a fixed vocabulary. `flt` covers every sensor on Apple
    /// silicon; the integer forms appear on fan mode and a few counters, and
    /// `sp78` is the fixed-point form older Intel Macs used for temperature.
    static func value(bytes: [UInt8], type: String) -> Double? {
        switch type.trimmingCharacters(in: .whitespaces) {
        case "flt":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8", "hex_", "flag":
            guard let first = bytes.first else { return nil }
            return Double(first)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(
                UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "sp78":
            // Signed fixed point, 7 integer bits and 8 fractional.
            guard bytes.count >= 2 else { return nil }
            let whole = Int8(bitPattern: bytes[0])
            return Double(whole) + Double(bytes[1]) / 256.0
        default:
            return nil
        }
    }

    // MARK: - Discovery

    /// Every key the controller reports, in index order.
    ///
    /// Needed because the sensor names are not guessable and differ per model:
    /// this M4 exposes `Tp0U`, `Tp1o`, `Tp2G` and `Tpx9` among a hundred others.
    /// Enumerating and then filtering by prefix is the only approach that
    /// survives moving to different hardware.
    public func allKeys() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if let discovered { return discovered }

        guard let count = readLocked("#KEY").map({ Int($0) }), count > 0, count < 10_000 else {
            discovered = []
            return []
        }
        var keys: [String] = []
        keys.reserveCapacity(count)
        for index in 0..<count {
            var request = ParamStruct()
            request.data8 = Selector.keyFromIndex.rawValue
            request.data32 = UInt32(index)
            guard let response = call(&request) else { continue }
            keys.append(Self.decode(response.key))
        }
        discovered = keys
        return keys
    }

    /// Mean of every readable key with the given prefix.
    ///
    /// Apple silicon spreads die temperature across a sensor per core cluster —
    /// 102 `Tp` keys and 22 `Tg` keys on this machine — and no single key is
    /// "the" CPU temperature. Averaging the populated ones reproduces what
    /// Activity Monitor and the third-party tools report.
    ///
    /// Zero and obviously-invalid readings are skipped: unpopulated sensors read
    /// exactly 0, and including them would drag the mean toward room temperature.
    public func meanTemperature(prefix: String) -> Double? {
        let keys = allKeys().filter { $0.hasPrefix(prefix) }
        guard !keys.isEmpty else { return nil }
        var total = 0.0
        var n = 0
        for key in keys {
            guard let value = read(key), value > 1, value < 150 else { continue }
            total += value
            n += 1
        }
        return n > 0 ? total / Double(n) : nil
    }
}

#endif  // canImport(IOKit)
