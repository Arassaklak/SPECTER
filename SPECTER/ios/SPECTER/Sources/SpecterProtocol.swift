import Foundation

// Frame types — must match server/protocol.py exactly.
enum F {
    // server -> client
    static let SCREEN_INFO: UInt8 = 0x01
    static let SCREEN_TILE: UInt8 = 0x02
    static let SCREEN_FLUSH: UInt8 = 0x03
    static let PONG: UInt8 = 0x41
    static let CLIPBOARD: UInt8 = 0x20
    static let FILE_OFFER: UInt8 = 0x30
    static let FILE_CHUNK: UInt8 = 0x31
    static let FILE_DONE: UInt8 = 0x32
    static let MSG: UInt8 = 0x60
    // client -> server
    static let MOUSE_MOVE: UInt8 = 0x10
    static let MOUSE_BUTTON: UInt8 = 0x11
    static let MOUSE_SCROLL: UInt8 = 0x12
    static let KEY: UInt8 = 0x13
    static let PING: UInt8 = 0x40
    static let SET_QUALITY: UInt8 = 0x50
    static let FILE_ACCEPT: UInt8 = 0x33
}

enum MouseButton: UInt8 { case left = 0, right = 1, middle = 2 }
enum FileDir: UInt8 { case toClient = 0, toServer = 1 }

// Big-endian byte packing helpers.
struct ByteWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { var b = v.bigEndian; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { var b = v.bigEndian; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { var b = v.bigEndian; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) } }
    mutating func i16(_ v: Int16) { var b = v.bigEndian; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func raw(_ d: Data) { data.append(d) }
}

struct ByteReader {
    let data: Data
    var off: Int = 0
    init(_ d: Data) { data = d }
    private func byte(_ i: Int) -> UInt8 { data[data.startIndex + i] }
    mutating func u8() -> UInt8 { defer { off += 1 }; return byte(off) }
    mutating func u16() -> UInt16 {
        let v = UInt16(byte(off)) << 8 | UInt16(byte(off + 1)); off += 2; return v
    }
    mutating func u32() -> UInt32 {
        var v: UInt32 = 0; for k in 0..<4 { v = v << 8 | UInt32(byte(off + k)) }; off += 4; return v
    }
    mutating func u64() -> UInt64 {
        var v: UInt64 = 0; for k in 0..<8 { v = v << 8 | UInt64(byte(off + k)) }; off += 8; return v
    }
    mutating func bytes(_ n: Int) -> Data {
        let v = data.subdata(in: idx(n)); off += n; return v
    }
    mutating func rest() -> Data {
        let v = data.subdata(in: (data.startIndex + off)..<data.endIndex); off = data.count; return v
    }
    private func idx(_ n: Int) -> Range<Int> { (data.startIndex + off)..<(data.startIndex + off + n) }
}

// Big-endian integer decode helpers for fixed-size Data slices (alignment-safe).
extension Data {
    var beUInt32: UInt32 { var v: UInt32 = 0; for b in self { v = v << 8 | UInt32(b) }; return v }
    var beUInt64: UInt64 { var v: UInt64 = 0; for b in self { v = v << 8 | UInt64(b) }; return v }
}
