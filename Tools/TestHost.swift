import AppKit

final class TestHost: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var label: NSTextField!
    private var fileMenu: NSMenu!
    private var actions: [String] = []
    private var dynamicGeneration = 0
    private let args = CommandLine.arguments
    private var recordURL: URL {
        if let index = args.firstIndex(of: "--record-path"), index + 1 < args.count {
            return URL(fileURLWithPath: args[index + 1])
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("center-my-menu-fixture-actions.json")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let main = NSMenu()
        let host = NSMenu(title: "Test Host")
        add("About Test Host", to: host, id: "about")
        host.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Test Host", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        host.addItem(quit)
        attach(host, to: main)

        let file = NSMenu(title: "File")
        fileMenu = file
        add("Record Action", to: file, id: "record", key: "r", modifiers: [.command, .shift])
        add("Disabled Action", to: file, id: "disabled").isEnabled = false
        add("Checked Option", to: file, id: "checked").state = .on
        file.addItem(.separator())
        let nested = NSMenu(title: "Nested")
        add("Record Nested Action", to: nested, id: "nested")
        attach(nested, to: file)
        attach(file, to: main)

        let dynamic = NSMenu(title: "Dynamic")
        dynamic.delegate = self
        let placeholder = NSMenuItem(title: "Menu not populated yet", action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        dynamic.addItem(placeholder)
        attach(dynamic, to: main)
        let menuDelay: Double?
        if let i = args.firstIndex(of: "--menus-after"), i + 1 < args.count,
           let seconds = Double(args[i + 1]), seconds.isFinite, seconds >= 0 {
            menuDelay = seconds
            NSApp.mainMenu = nil
        } else {
            menuDelay = nil
            NSApp.mainMenu = main
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 160), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.delegate = self
        window.title = "Center My Menu Test Host"
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let title = NSTextField(labelWithString: "Center My Menu test fixture")
        title.font = .boldSystemFont(ofSize: 17)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "Use the File and Dynamic menus to verify mirrored commands. These actions only update this test log."))
        label = NSTextField(labelWithString: "No test action recorded yet.")
        stack.addArrangedSubview(label)
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        if args.contains("--reset-record") { writeLog() }
        if let i = args.firstIndex(of: "--exit-after"), i + 1 < args.count, let seconds = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
        if let i = args.firstIndex(of: "--mutate-after"), i + 1 < args.count,
           let seconds = Double(args[i + 1]), seconds.isFinite, seconds >= 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.replaceFileMenu()
            }
        }
        if let seconds = menuDelay {
            label.stringValue = "Menus are delayed for \(seconds) seconds."
            reportMenuReadiness(installed: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { return }
                NSApp.mainMenu = main
                self.reportMenuReadiness(installed: true)
                if self.actions.isEmpty { self.label.stringValue = "Menus are ready. No test action recorded yet." }
            }
        }
        if args.contains("--fullscreen-cycle") {
            window.collectionBehavior = [.fullScreenPrimary]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.recordFullScreen("request_enter"); self?.window.toggleFullScreen(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self, self.window.styleMask.contains(.fullScreen) else { return }
                self.window.toggleFullScreen(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowDidEnterFullScreen(_ notification: Notification) { recordFullScreen("entered") }
    func windowDidExitFullScreen(_ notification: Notification) { recordFullScreen("exited") }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { recordFullScreen("failed_enter") }
    private func recordFullScreen(_ event: String) {
        guard args.contains("--fullscreen-cycle") else { return }
        let url = recordURL.appendingPathExtension("fullscreen.jsonl")
        let frame = window.screen?.frame ?? .zero
        let value: [String: Any] = ["event": event, "fullScreen": window.styleMask.contains(.fullScreen),
                                   "uptime": ProcessInfo.processInfo.systemUptime,
                                   "displayFrame": [frame.minX, frame.minY, frame.width, frame.height],
                                   "options": NSApp.currentSystemPresentationOptions.rawValue]
        guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url) }
        else if let file = try? FileHandle(forWritingTo: url) {
            defer { try? file.close() }
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: data)
        }
    }

    private func reportMenuReadiness(installed: Bool) {
        // Opt-in fixture timing evidence only; action-log contents remain unchanged.
        let event: [String: Any] = ["event": "fixture_menus", "installed": installed,
                                    "uptime": ProcessInfo.processInfo.systemUptime,
                                    "topLevelItemCount": NSApp.mainMenu?.numberOfItems ?? 0]
        guard var data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }

    private func replaceFileMenu() {
        fileMenu.removeAllItems()
        add("Record Updated Action", to: fileMenu, id: "updated", key: "u", modifiers: [.command, .option])
        let info = NSMenuItem(title: "Source menu changed", action: nil, keyEquivalent: "")
        info.isEnabled = false
        fileMenu.addItem(info)
    }
    private func attach(_ submenu: NSMenu, to parent: NSMenu) {
        parent.autoenablesItems = false
        submenu.autoenablesItems = false
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        parent.addItem(item)
    }
    @discardableResult private func add(_ title: String, to menu: NSMenu, id: String, key: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        menu.autoenablesItems = false
        let item = NSMenuItem(title: title, action: #selector(record(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = id
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
        return item
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        dynamicGeneration += 1
        menu.removeAllItems()
        add("Record Dynamic Action", to: menu, id: "dynamic")
        let info = NSMenuItem(title: "Generation \(dynamicGeneration)", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
    }
    @objc private func record(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        actions.append(id)
        if id == "checked" { sender.state = sender.state == .on ? .off : .on }
        label.stringValue = "Recorded: \(id) (\(actions.count) total)"
        writeLog()
    }
    private func writeLog() {
        do {
            let data = try JSONSerialization.data(withJSONObject: actions, options: [.prettyPrinted])
            try data.write(to: recordURL, options: .atomic)
        } catch {
            label?.stringValue = "Could not write test log."
        }
    }
}

let app = NSApplication.shared
let delegate = TestHost()
app.delegate = delegate
app.run()
