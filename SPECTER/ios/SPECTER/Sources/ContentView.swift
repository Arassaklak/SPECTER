import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var client = SpecterClient()
    @AppStorage("host") private var host = ""
    @AppStorage("portStr") private var portStr = "45813"
    @AppStorage("remember") private var remember = false
    @State private var password = ""
    @State private var keyboardActive = false
    @State private var showControls = true
    @State private var showFileImporter = false
    @State private var showShare = false
    @State private var ctrlHeld = false
    @State private var shiftHeld = false
    @State private var altHeld = false
    @State private var winHeld = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if client.state == .connected {
                sessionView
            } else {
                connectForm
            }
        }
        .onAppear { if remember, let pw = Keychain.load() { password = pw } }
        .onChange(of: client.receivedFileURL) { _, url in if url != nil { showShare = true } }
        .sheet(isPresented: $showShare) {
            if let u = client.receivedFileURL { ShareSheet(items: [u]) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                client.sendFile(url: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    // MARK: Connect screen

    private var connectForm: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "display").font(.system(size: 54)).foregroundStyle(.tint)
            Text("SPECTER").font(.largeTitle.bold()).tracking(6)
            Text("Encrypted LAN remote desktop").font(.footnote).foregroundStyle(.secondary)

            VStack(spacing: 12) {
                field("PC IP address", text: $host, keyboard: .numbersAndPunctuation)
                field("Port", text: $portStr, keyboard: .numberPad)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never)
                Toggle("Remember password (Keychain)", isOn: $remember).font(.footnote)
            }
            .padding(.horizontal, 28)

            Button {
                connect()
            } label: {
                Text(client.state == .connecting || client.state == .handshaking ? "Connecting…" : "Connect")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(host.isEmpty || password.count < 8 || client.state == .connecting || client.state == .handshaking)
            .padding(.horizontal, 28)

            statusLine
            Spacer()
        }
        .foregroundStyle(.white)
    }

    private func field(_ title: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private var statusLine: some View {
        Group {
            switch client.state {
            case .failed(let m): Label(m, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            case .connecting, .handshaking: ProgressView().tint(.white)
            default: Text(client.status).foregroundStyle(.secondary)
            }
        }.font(.footnote).padding(.horizontal, 28)
    }

    private func connect() {
        if remember { Keychain.save(password) } else { Keychain.clear() }
        let port = UInt16(portStr) ?? 45813
        client.connect(host: host.trimmingCharacters(in: .whitespaces), port: port, password: password)
    }

    // MARK: Session screen

    private var sessionView: some View {
        ZStack(alignment: .bottom) {
            RemoteScreenView(client: client, keyboardActive: $keyboardActive)
                .ignoresSafeArea()
                .onTapGesture(count: 3) { withAnimation { showControls.toggle() } }  // 3-finger... (fallback toggle)

            VStack {
                topBar
                Spacer()
                if showControls { controlBar.transition(.move(edge: .bottom)) }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button(role: .destructive) { releaseMods(); client.disconnect() } label: {
                Image(systemName: "power").font(.headline)
            }
            Text("SPECTER").font(.caption.bold()).tracking(3)
            Spacer()
            Label("\(client.latencyMs) ms", systemImage: "bolt.fill")
                .font(.caption).foregroundStyle(client.latencyMs < 60 ? .green : .yellow)
            Button { withAnimation { showControls.toggle() } } label: {
                Image(systemName: showControls ? "chevron.down" : "chevron.up")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .foregroundStyle(.white)
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
            // modifier + special keys
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    modKey("Ctrl", $ctrlHeld, SK.ctrl)
                    modKey("Shift", $shiftHeld, SK.shift)
                    modKey("Alt", $altHeld, SK.alt)
                    modKey("Win", $winHeld, SK.cmd)
                    tapKeyBtn("Esc", SK.esc)
                    tapKeyBtn("Tab", SK.tab)
                    tapKeyBtn("⌫", SK.backspace)
                    tapKeyBtn("↵", SK.enter)
                    tapKeyBtn("↑", SK.up); tapKeyBtn("↓", SK.down)
                    tapKeyBtn("←", SK.left); tapKeyBtn("→", SK.right)
                    Menu("Fn") { ForEach(1...12, id: \.self) { n in Button("F\(n)") { client.tapKey(SK.f(n)) } } }
                        .buttonStyle(.bordered).tint(.gray)
                }.padding(.horizontal, 10)
            }
            // actions row
            HStack(spacing: 10) {
                Button { keyboardActive.toggle() } label: {
                    Image(systemName: keyboardActive ? "keyboard.chevron.compact.down" : "keyboard")
                }.buttonStyle(.bordered)

                Menu {
                    Button("High · crisp")      { client.setQuality(quality: 88, fps: 30, scale: 100) }
                    Button("Balanced")          { client.setQuality(quality: 70, fps: 30, scale: 85) }
                    Button("Fast · smooth")     { client.setQuality(quality: 55, fps: 45, scale: 65) }
                    Button("Data-saver")        { client.setQuality(quality: 45, fps: 20, scale: 40) }
                } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.bordered)

                Button { showFileImporter = true } label: { Image(systemName: "paperplane") }
                    .buttonStyle(.bordered)

                Button { if let s = UIPasteboard.general.string { client.sendClipboard(s) } } label: {
                    Image(systemName: "doc.on.clipboard")
                }.buttonStyle(.bordered)

                Spacer()
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
        }
        .background(.ultraThinMaterial)
        .tint(.white)
    }

    private func modKey(_ label: String, _ held: Binding<Bool>, _ code: UInt16) -> some View {
        Button(label) {
            held.wrappedValue.toggle()
            client.sendKey(down: held.wrappedValue, keycode: code)
        }
        .buttonStyle(.bordered)
        .tint(held.wrappedValue ? .blue : .gray)
    }

    private func tapKeyBtn(_ label: String, _ code: UInt16) -> some View {
        Button(label) { client.tapKey(code); autoReleaseMods() }
            .buttonStyle(.bordered).tint(.gray)
    }

    // After sending a key with sticky modifiers, drop the modifiers (one-shot combos).
    private func autoReleaseMods() {
        if ctrlHeld || shiftHeld || altHeld || winHeld { releaseMods() }
    }
    private func releaseMods() {
        if ctrlHeld { client.sendKey(down: false, keycode: SK.ctrl); ctrlHeld = false }
        if shiftHeld { client.sendKey(down: false, keycode: SK.shift); shiftHeld = false }
        if altHeld { client.sendKey(down: false, keycode: SK.alt); altHeld = false }
        if winHeld { client.sendKey(down: false, keycode: SK.cmd); winHeld = false }
    }
}
