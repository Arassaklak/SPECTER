import SwiftUI
import UIKit

// UIKit view that renders the remote frame and translates touch into mouse/keyboard.
//
// Interaction model (absolute touch — the cursor goes where you touch):
//   • quick one-finger swipe ....... move the cursor
//   • single tap ................... left click
//   • double tap ................... double click
//   • two-finger tap ............... right click
//   • press-and-hold then drag ..... left button held (drag / select / move windows)
//   • two-finger drag .............. scroll wheel
//   • keyboard button (toolbar) .... raises the iOS keyboard; typing is forwarded
final class RemoteScreenUIView: UIView, UIKeyInput {
    weak var client: SpecterClient?
    private let imageView = UIImageView()
    private var buttonDown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
        isUserInteractionEnabled = true
        setupGestures()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: UIImage?) { imageView.image = image }

    override func layoutSubviews() { super.layoutSubviews(); imageView.frame = bounds }

    // MARK: coordinate mapping (aspect-fit content rect -> normalised 0..1)

    private func contentRect() -> CGRect {
        guard let sz = imageView.image?.size, sz.width > 0, sz.height > 0 else { return bounds }
        let scale = min(bounds.width / sz.width, bounds.height / sz.height)
        let w = sz.width * scale, h = sz.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func norm(_ p: CGPoint) -> (Float, Float) {
        let r = contentRect()
        let x = Float(min(max((p.x - r.minX) / r.width, 0), 1))
        let y = Float(min(max((p.y - r.minY) / r.height, 0), 1))
        return (x, y)
    }

    // MARK: gestures

    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan))
        pan.maximumNumberOfTouches = 1
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap))
        let dbl = UITapGestureRecognizer(target: self, action: #selector(onDouble)); dbl.numberOfTapsRequired = 2
        let two = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerTap)); two.numberOfTouchesRequired = 2
        let long = UILongPressGestureRecognizer(target: self, action: #selector(onLong)); long.minimumPressDuration = 0.35
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll))
        scroll.minimumNumberOfTouches = 2; scroll.maximumNumberOfTouches = 2
        tap.require(toFail: dbl)
        for g in [pan, tap, dbl, two, long, scroll] { g.delegate = self; addGestureRecognizer(g) }
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let (x, y) = norm(g.location(in: self))
        client?.sendMouseMove(x, y)   // while a long-press holds the button, this becomes a drag
    }
    @objc private func onTap(_ g: UITapGestureRecognizer) {
        let (x, y) = norm(g.location(in: self))
        client?.sendMouseButton(x, y, .left, down: true)
        client?.sendMouseButton(x, y, .left, down: false)
    }
    @objc private func onDouble(_ g: UITapGestureRecognizer) {
        let (x, y) = norm(g.location(in: self))
        for _ in 0..<2 { client?.sendMouseButton(x, y, .left, down: true); client?.sendMouseButton(x, y, .left, down: false) }
    }
    @objc private func onTwoFingerTap(_ g: UITapGestureRecognizer) {
        let (x, y) = norm(g.location(in: self))
        client?.sendMouseButton(x, y, .right, down: true)
        client?.sendMouseButton(x, y, .right, down: false)
    }
    @objc private func onLong(_ g: UILongPressGestureRecognizer) {
        let (x, y) = norm(g.location(in: self))
        switch g.state {
        case .began: client?.sendMouseButton(x, y, .left, down: true); buttonDown = true
        case .changed: client?.sendMouseMove(x, y)
        case .ended, .cancelled, .failed:
            if buttonDown { client?.sendMouseButton(x, y, .left, down: false); buttonDown = false }
        default: break
        }
    }
    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        let (x, y) = norm(g.location(in: self))
        let dx = Int16(max(-30, min(30, -t.x / 8)))
        let dy = Int16(max(-30, min(30, t.y / 8)))
        if dx != 0 || dy != 0 { client?.sendScroll(x, y, dx, dy); g.setTranslation(.zero, in: self) }
    }

    // MARK: UIKeyInput (on-screen keyboard)

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    func insertText(_ text: String) {
        if text == "\n" { client?.tapKey(SK.enter) }
        else if text == "\t" { client?.tapKey(SK.tab) }
        else { client?.typeText(text) }
    }
    func deleteBackward() { client?.tapKey(SK.backspace) }

    // MARK: hardware keyboard (external Bluetooth keyboard) — modifiers + specials
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses { if let k = p.key, handleHardware(k, down: true) { handled = true } }
        if !handled { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses { if let k = p.key, handleHardware(k, down: false) { handled = true } }
        if !handled { super.pressesEnded(presses, with: event) }
    }
    private func handleHardware(_ key: UIKey, down: Bool) -> Bool {
        switch key.keyCode {
        case .keyboardLeftControl, .keyboardRightControl: client?.sendKey(down: down, keycode: SK.ctrl); return true
        case .keyboardLeftShift, .keyboardRightShift: client?.sendKey(down: down, keycode: SK.shift); return true
        case .keyboardLeftAlt, .keyboardRightAlt: client?.sendKey(down: down, keycode: SK.alt); return true
        case .keyboardLeftGUI, .keyboardRightGUI: client?.sendKey(down: down, keycode: SK.cmd); return true
        case .keyboardUpArrow: client?.sendKey(down: down, keycode: SK.up); return true
        case .keyboardDownArrow: client?.sendKey(down: down, keycode: SK.down); return true
        case .keyboardLeftArrow: client?.sendKey(down: down, keycode: SK.left); return true
        case .keyboardRightArrow: client?.sendKey(down: down, keycode: SK.right); return true
        case .keyboardEscape: client?.sendKey(down: down, keycode: SK.esc); return true
        case .keyboardTab: client?.sendKey(down: down, keycode: SK.tab); return true
        case .keyboardDeleteOrBackspace: client?.sendKey(down: down, keycode: SK.backspace); return true
        case .keyboardReturnOrEnter: client?.sendKey(down: down, keycode: SK.enter); return true
        default:
            if down, !key.characters.isEmpty { client?.typeText(key.characters) }
            return !key.characters.isEmpty
        }
    }
}

extension RemoteScreenUIView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
}

struct RemoteScreenView: UIViewRepresentable {
    @ObservedObject var client: SpecterClient
    @Binding var keyboardActive: Bool

    func makeUIView(context: Context) -> RemoteScreenUIView {
        let v = RemoteScreenUIView(); v.client = client; return v
    }
    func updateUIView(_ v: RemoteScreenUIView, context: Context) {
        v.setImage(client.frame)
        if keyboardActive, !v.isFirstResponder { v.becomeFirstResponder() }
        else if !keyboardActive, v.isFirstResponder { v.resignFirstResponder() }
    }
}
