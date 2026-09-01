import Foundation
import Network
import CryptoKit
import UIKit

enum ConnState: Equatable { case idle, connecting, handshaking, connected, failed(String) }

final class SpecterClient: ObservableObject {
    @Published var state: ConnState = .idle
    @Published var status: String = "Not connected"
    @Published var frame: UIImage?
    @Published var latencyMs: Int = 0
    @Published var incomingClipboard: String = ""
    @Published var receivedFileURL: URL?
    @Published var screenSize: CGSize = .zero

    private var conn: NWConnection?
    private var channel: SecureChannel?
    private let netQueue = DispatchQueue(label: "specter.net")
    private let renderQueue = DispatchQueue(label: "specter.render")

    // screen assembly
    private var ctx: CGContext?
    private var pxW = 0, pxH = 0, tile = 128
    private var dirtySinceFlush = false

    // file receive assembly
    private var incoming: [UInt32: (name: String, data: Data)] = [:]

    private let magic = Data("SPECTR".utf8)
    private var running = false

    private func onMain(_ b: @escaping () -> Void) {
        if Thread.isMainThread { b() } else { DispatchQueue.main.async(execute: b) }
    }

    // MARK: - Connect

    func connect(host: String, port: UInt16, password: String) {
        disconnect()
        onMain { self.state = .connecting; self.status = "Connecting to \(host):\(port)…" }
        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        conn = c
        running = true
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                Task { await self.runSession(password: password) }
            case .failed(let e):
                self.onMain { self.fail("Network: \(e.localizedDescription)") }
            case .waiting(let e):
                self.onMain { self.status = "Waiting: \(e.localizedDescription)" }
            default: break
            }
        }
        c.start(queue: netQueue)
    }

    func disconnect() {
        running = false
        conn?.cancel()
        conn = nil
        channel = nil
        renderQueue.async { self.ctx = nil }
        onMain { self.state = .idle; self.status = "Not connected" }
    }

    private func fail(_ msg: String) {
        running = false
        conn?.cancel(); conn = nil
        onMain { self.state = .failed(msg); self.status = msg }
    }

    // MARK: - Session

    private func runSession(password: String) async {
        do {
            onMain { self.state = .handshaking; self.status = "Authenticating…" }
            let ch = try await handshake(password: password)
            self.channel = ch
            onMain { self.state = .connected; self.status = "Connected" }
            startPing()
            try await recvLoop(ch)
        } catch {
            if running { onMain { self.fail("Disconnected: \(error.localizedDescription)") } }
        }
    }

    private func handshake(password: String) async throws -> SecureChannel {
        let header = try await readExact(6 + 1 + 16 + 16 + 32)
        guard header.prefix(6) == magic else { throw err("Not a SPECTER server") }
        guard header[header.startIndex + 6] == 1 else { throw err("Unsupported version") }
        var o = header.startIndex + 7
        let salt = header.subdata(in: o ..< o + 16); o += 16
        let sNonce = header.subdata(in: o ..< o + 16); o += 16
        let sEph = header.subdata(in: o ..< o + 32)

        let eph = Curve25519.KeyAgreement.PrivateKey()
        let cEphPub = eph.publicKey.rawRepresentation
        var cNonce = Data(count: 16)
        _ = cNonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

        var transcript = Data()
        transcript.append(salt); transcript.append(sNonce); transcript.append(sEph)
        transcript.append(cNonce); transcript.append(cEphPub)

        let master = pbkdf2SHA256(password: password, salt: salt)
        let cProof = hmacSHA256(key: master, msg: transcript + Data("SPECTER-c2s".utf8))
        try await sendRaw(cNonce + cEphPub + cProof)

        let sProof = try await readExact(32)
        let expected = hmacSHA256(key: master, msg: transcript + Data("SPECTER-s2c".utf8))
        guard ctEqual(sProof, expected) else { throw err("Wrong password or tampering") }

        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: sEph)
        let secret = try eph.sharedSecretFromKeyAgreement(with: peer)
        let shared = secret.withUnsafeBytes { Data($0) }
        return deriveClientChannel(shared: shared, transcript: transcript)
    }

    private func recvLoop(_ ch: SecureChannel) async throws {
        while running {
            let lenData = try await readExact(4)
            let n = Int(lenData.beUInt32)
            guard n >= 8, n <= 32 * 1024 * 1024 else { throw err("bad frame length") }
            let wire = try await readExact(n)
            let pt = try ch.open(wire)
            dispatch(pt)
        }
    }

    private func dispatch(_ pt: Data) {
        guard !pt.isEmpty else { return }
        let type = pt[pt.startIndex]
        let body = pt.subdata(in: pt.startIndex + 1 ..< pt.endIndex)
        switch type {
        case F.SCREEN_INFO: onScreenInfo(body)
        case F.SCREEN_TILE: onScreenTile(body)
        case F.SCREEN_FLUSH: onFlush()
        case F.PONG: onPong(body)
        case F.CLIPBOARD:
            let s = String(data: body, encoding: .utf8) ?? ""
            onMain { self.incomingClipboard = s; UIPasteboard.general.string = s }
        case F.MSG:
            let s = String(data: body, encoding: .utf8) ?? ""
            onMain { self.status = s }
        case F.FILE_OFFER: onFileOffer(body)
        case F.FILE_CHUNK: onFileChunk(body)
        case F.FILE_DONE: onFileDone(body)
        default: break
        }
    }

    // MARK: - Screen assembly

    private func onScreenInfo(_ body: Data) {
        var r = ByteReader(body)
        let w = Int(r.u16()), h = Int(r.u16()), t = Int(r.u16())
        renderQueue.async { [weak self] in
            guard let self else { return }
            if self.pxW != w || self.pxH != h || self.ctx == nil {
                self.pxW = w; self.pxH = h
                let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                self.ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                self.onMain { self.screenSize = CGSize(width: w, height: h) }
            }
            self.tile = t
        }
    }

    private func onScreenTile(_ body: Data) {
        var r = ByteReader(body)
        let col = Int(r.u16()), row = Int(r.u16())
        let jlen = Int(r.u32())
        let jpeg = r.bytes(jlen)
        renderQueue.async { [weak self] in
            guard let self, let ctx = self.ctx, let img = UIImage(data: jpeg)?.cgImage else { return }
            let tw = img.width, th = img.height
            let x = col * self.tile
            let yCG = self.pxH - row * self.tile - th   // CoreGraphics origin = bottom-left
            ctx.draw(img, in: CGRect(x: x, y: yCG, width: tw, height: th))
            self.dirtySinceFlush = true
        }
    }

    private func onFlush() {
        renderQueue.async { [weak self] in
            guard let self, self.dirtySinceFlush, let ctx = self.ctx, let cg = ctx.makeImage() else { return }
            self.dirtySinceFlush = false
            let ui = UIImage(cgImage: cg)
            self.onMain { self.frame = ui }
        }
    }

    // MARK: - Ping

    private func startPing() {
        Task { [weak self] in
            while let self, self.running {
                var w = ByteWriter(); w.u64(UInt64(Date().timeIntervalSince1970 * 1000))
                self.sendFrame(F.PING, w.data)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func onPong(_ body: Data) {
        var r = ByteReader(body)
        let sent = r.u64()
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let ms = Int(now >= sent ? now - sent : 0)
        onMain { self.latencyMs = ms }
    }

    // MARK: - Input senders

    func sendMouseMove(_ x: Float, _ y: Float) { var w = ByteWriter(); w.f32(x); w.f32(y); sendFrame(F.MOUSE_MOVE, w.data) }
    func sendMouseButton(_ x: Float, _ y: Float, _ btn: MouseButton, down: Bool) {
        var w = ByteWriter(); w.f32(x); w.f32(y); w.u8(btn.rawValue); w.u8(down ? 1 : 0); sendFrame(F.MOUSE_BUTTON, w.data)
    }
    func sendScroll(_ x: Float, _ y: Float, _ dx: Int16, _ dy: Int16) {
        var w = ByteWriter(); w.f32(x); w.f32(y); w.i16(dx); w.i16(dy); sendFrame(F.MOUSE_SCROLL, w.data)
    }
    func sendKey(down: Bool, keycode: UInt16 = 0, text: String = "") {
        var w = ByteWriter(); w.u8(down ? 1 : 0); w.u16(keycode)
        let td = Data(text.utf8); w.u16(UInt16(td.count)); w.raw(td)
        sendFrame(F.KEY, w.data)
    }
    func tapKey(_ keycode: UInt16) { sendKey(down: true, keycode: keycode); sendKey(down: false, keycode: keycode) }
    func typeText(_ s: String) { for ch in s { let c = String(ch); sendKey(down: true, text: c); sendKey(down: false, text: c) } }
    func sendClipboard(_ text: String) { sendFrame(F.CLIPBOARD, Data(text.utf8)) }
    func setQuality(quality: UInt8, fps: UInt8, scale: UInt8) {
        var w = ByteWriter(); w.u8(quality); w.u8(fps); w.u8(scale); sendFrame(F.SET_QUALITY, w.data)
    }

    // MARK: - File transfer

    func sendFile(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let id = UInt32.random(in: 1...UInt32.max)
        let nd = Data(url.lastPathComponent.utf8)
        var off = ByteWriter()
        off.u8(FileDir.toServer.rawValue); off.u32(id); off.u64(UInt64(data.count)); off.u16(UInt16(nd.count)); off.raw(nd)
        sendFrame(F.FILE_OFFER, off.data)
        var seq: UInt32 = 0
        let chunk = 64 * 1024
        var i = 0
        while i < data.count {
            let end = min(i + chunk, data.count)
            var c = ByteWriter(); c.u32(id); c.u32(seq); c.raw(data.subdata(in: i ..< end))
            sendFrame(F.FILE_CHUNK, c.data)
            seq += 1; i = end
        }
        var d = ByteWriter(); d.u32(id); d.u8(1); sendFrame(F.FILE_DONE, d.data)
    }

    private func onFileOffer(_ body: Data) {
        var r = ByteReader(body)
        _ = r.u8()
        let id = r.u32(); _ = r.u64()
        let nlen = Int(r.u16())
        let name = String(data: r.bytes(nlen), encoding: .utf8) ?? "file_\(id)"
        incoming[id] = (name, Data())
        var a = ByteWriter(); a.u32(id); a.u8(1); sendFrame(F.FILE_ACCEPT, a.data)
    }
    private func onFileChunk(_ body: Data) {
        var r = ByteReader(body)
        let id = r.u32(); _ = r.u32()
        if incoming[id] != nil { incoming[id]!.data.append(r.rest()) }
    }
    private func onFileDone(_ body: Data) {
        var r = ByteReader(body)
        let id = r.u32()
        guard let f = incoming.removeValue(forKey: id) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(f.name)
        try? f.data.write(to: url)
        onMain { self.receivedFileURL = url }
    }

    // MARK: - Low-level I/O

    private func sendFrame(_ type: UInt8, _ body: Data) {
        guard let ch = channel, let c = conn else { return }
        do {
            var pt = Data([type]); pt.append(body)
            let sealed = try ch.seal(pt)
            var out = Data()
            var len = UInt32(sealed.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(sealed)
            c.send(content: out, completion: .contentProcessed { _ in })
        } catch { }
    }

    private func sendRaw(_ data: Data) async throws {
        guard let c = conn else { throw err("no connection") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: data, completion: .contentProcessed { e in
                if let e { cont.resume(throwing: e) } else { cont.resume() }
            })
        }
    }

    private func readExact(_ n: Int) async throws -> Data {
        guard let c = conn else { throw err("no connection") }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            c.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                if let data, data.count == n { cont.resume(returning: data); return }
                cont.resume(throwing: NSError(domain: "specter", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: isComplete ? "connection closed" : "short read"]))
            }
        }
    }

    private func err(_ m: String) -> NSError { NSError(domain: "specter", code: -1, userInfo: [NSLocalizedDescriptionKey: m]) }
}

func ctEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var r: UInt8 = 0
    for i in 0 ..< a.count { r |= a[a.startIndex + i] ^ b[b.startIndex + i] }
    return r == 0
}
