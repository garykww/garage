import AppKit
import SwiftUI
import DisplayControl
import DisplayProtocol

@MainActor
final class Model: ObservableObject {
    @Published var monitors: [Monitor] = []
    @Published var selected: UInt64 = 0
    @Published var level: Double = 50
    @Published var confirmed: Int?
    @Published var busy = false
    @Published var message: String?
    @Published var volume: Double = 0
    @Published var confirmedVolume: Int?
    @Published var volumeMessage: String?
    private let queue = DispatchQueue(label: "DellS3225QSControl.DDC", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []

    init() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refresh() }
        })
        refresh()
    }

    func refresh() {
        guard !busy else { return }
        busy = true; message = nil; confirmed = nil; confirmedVolume = nil; volumeMessage = nil
        let previous = selected
        queue.async {
            let displays = DisplayDiscovery.monitors()
            let chosen = displays.first(where: { $0.id == previous }) ?? displays.first
            let result: Result<Brightness, Error> = Result {
                guard let chosen else { throw ControlError.unavailable }
                return try chosen.brightness()
            }
            let audio: Result<Brightness, Error> = Result {
                guard let chosen else { throw ControlError.unavailable }
                return try chosen.volume()
            }
            DispatchQueue.main.async {
                self.monitors = displays; self.selected = chosen?.id ?? 0
                self.finish(result)
                self.finishVolume(audio)
            }
        }
    }

    func apply(_ value: Int) {
        guard !busy, let monitor = monitors.first(where: { $0.id == selected }) else { return }
        busy = true; message = nil; level = Double(value)
        queue.async {
            let result = Result { try monitor.setBrightness(percent: value) }
            // On failure, restore the slider from a fresh hardware read if possible.
            let fallback: Brightness?
            if case .failure = result { fallback = try? monitor.brightness() } else { fallback = nil }
            DispatchQueue.main.async {
                self.finish(result)
                if case .failure = result {
                    self.confirmed = fallback?.percent
                    if let fallback { self.level = Double(fallback.percent) }
                }
            }
        }
    }

    private func finish(_ result: Result<Brightness, Error>) {
        busy = false
        switch result {
        case .success(let value): level = Double(value.percent); confirmed = value.percent; message = nil
        case .failure(let error): message = error.localizedDescription
        }
    }

    func applyVolume(_ value: Int) {
        guard !busy, let monitor = monitors.first(where: { $0.id == selected }) else { return }
        busy = true; volumeMessage = nil; volume = Double(value)
        queue.async {
            let result = Result { try monitor.setVolume(percent: value) }
            let fallback: Brightness?
            if case .failure = result { fallback = try? monitor.volume() } else { fallback = nil }
            DispatchQueue.main.async {
                self.busy = false
                self.finishVolume(result)
                if case .failure = result {
                    self.confirmedVolume = fallback?.percent
                    if let fallback { self.volume = Double(fallback.percent) }
                }
            }
        }
    }

    private func finishVolume(_ result: Result<Brightness, Error>) {
        switch result {
        case .success(let value): volume = Double(value.percent); confirmedVolume = value.percent; volumeMessage = nil
        case .failure(let error): volumeMessage = error.localizedDescription
        }
    }
}

struct Panel: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dell S3225QS Control").font(.headline)
                    Text(model.monitors.first(where: { $0.id == model.selected })?.name ?? "External monitor")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            if model.monitors.count > 1 {
                Picker("Display", selection: $model.selected) {
                    ForEach(model.monitors) { Text($0.name).tag($0.id) }
                }
                .disabled(model.busy)
                .onChange(of: model.selected) { _ in model.refresh() }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Brightness").foregroundStyle(.secondary)
                Spacer()
                Text(model.confirmed == nil ? "—" : "\(Int(model.level))%")
                    .font(.system(size: 32, weight: .medium, design: .rounded)).monospacedDigit()
            }
            HStack(spacing: 12) {
                Image(systemName: "sun.min")
                Slider(value: $model.level, in: 0...100, step: 1) { editing in
                    if !editing { model.apply(Int(model.level)) }
                }
                .accessibilityLabel("Monitor brightness")
                Image(systemName: "sun.max.fill")
            }
            .disabled(model.busy || model.confirmed == nil)
            HStack(spacing: 8) {
                ForEach([25, 50, 75, 100], id: \.self) { value in
                    Button("\(value)%") { model.apply(value) }.frame(maxWidth: .infinity)
                }
            }
            .disabled(model.busy || model.confirmed == nil)
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Label(model.busy ? "Communicating with monitor…" : "Monitor brightness synced", systemImage: model.busy ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("Speaker volume").foregroundStyle(.secondary)
                Spacer()
                Text(model.confirmedVolume == nil ? "—" : "\(Int(model.volume))%")
                    .font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
            }
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                Slider(value: $model.volume, in: 0...100, step: 1) { editing in
                    if !editing { model.applyVolume(Int(model.volume)) }
                }
                .accessibilityLabel("Monitor speaker volume")
                Image(systemName: "speaker.wave.3.fill")
            }
            .disabled(model.busy || model.confirmedVolume == nil)
            if let message = model.volumeMessage {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Controls the monitor’s built-in speakers.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.busy)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .buttonStyle(.borderless).font(.caption)
        }
        .padding(22).frame(width: 330)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private let popover = NSPopover()
    private var model: Model!
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = Model()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Dell S3225QS Control brightness")
        status.button?.toolTip = "Dell S3225QS Control — brightness & speaker volume"
        status.button?.target = self; status.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: Panel(model: model))
        if CommandLine.arguments.contains("--show") { toggle() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { toggle() }
        return true
    }
    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = status.button {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

func cli(_ args: [String]) -> Int32 {
    if args == ["help"] || args == ["--help"] {
        print("DellS3225QSControl: launch without arguments for menu bar app.\nCommands: list | get [display-id] | set <0-100> [display-id] | volume-get [display-id] | volume-set <0-100> [display-id] | self-test [display-id]")
        return 0
    }
    let command = args[0]
    guard ["list", "get", "set", "volume-get", "volume-set", "self-test"].contains(command) else {
        fputs("Unknown command. Use --help.\n", stderr); return 2
    }
    let isSet = command == "set" || command == "volume-set"
    let idIndex = isSet ? 2 : 1
    guard args.count <= idIndex + 1, command != "list" || args.count == 1,
          args.count <= idIndex || UInt64(args[idIndex]) != nil,
          !isSet || (args.count >= 2 && Int(args[1]).map { (0...100).contains($0) } == true) else {
        fputs("Invalid arguments. Use --help.\n", stderr); return 2
    }
    do {
        let monitors = DisplayDiscovery.monitors()
        if command == "list" {
            for monitor in monitors {
                let value = try? monitor.brightness()
                print("\(monitor.id)\t\(monitor.name)\t\(value.map { "\($0.percent)%" } ?? "brightness unavailable")")
            }
            if monitors.isEmpty { throw ControlError.unavailable }
            return 0
        }
        let id = args.count > idIndex ? UInt64(args[idIndex]) : nil
        guard let monitor = id == nil ? monitors.first : monitors.first(where: { $0.id == id }) else { throw ControlError.unavailable }
        if command == "get" { print(try monitor.brightness().percent) }
        else if command == "set" { print(try monitor.setBrightness(percent: Int(args[1])!).percent) }
        else if command == "volume-get" { print(try monitor.volume().percent) }
        else if command == "volume-set" { print(try monitor.setVolume(percent: Int(args[1])!).percent) }
        else {
            // A reversible one-point change exercises the complete hardware path.
            let original = try monitor.brightness().percent
            var restored = false
            defer { if !restored { _ = try? monitor.setBrightness(percent: original) } }
            let target = original >= 100 ? 99 : original + 1
            let changed = try monitor.setBrightness(percent: target)
            let final = try monitor.setBrightness(percent: original)
            restored = true
            print("PASS: \(monitor.name): \(original)% → \(changed.percent)% → \(final.percent)% (restored)")
            let originalVolume = try monitor.volume().percent
            var volumeRestored = false
            defer { if !volumeRestored { _ = try? monitor.setVolume(percent: originalVolume) } }
            // Prefer a quieter test level; never jump to a loud preset.
            let targetVolume = originalVolume > 0 ? originalVolume - 1 : 1
            let changedVolume = try monitor.setVolume(percent: targetVolume)
            let finalVolume = try monitor.setVolume(percent: originalVolume)
            volumeRestored = true
            print("PASS: speaker volume: \(originalVolume)% → \(changedVolume.percent)% → \(finalVolume.percent)% (restored)")
        }
        return 0
    } catch { fputs("\(error.localizedDescription)\n", stderr); return 1 }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.isEmpty && arguments != ["--show"] { exit(cli(arguments)) }
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
