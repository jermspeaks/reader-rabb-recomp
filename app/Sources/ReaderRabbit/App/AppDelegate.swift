import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var view: GameView?
    private var game: Game?
    private var timer: Timer?
    private var nextTick = Date()

    private static let folderKey = "GameFolderPath"

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 960),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Reader Rabbit's Preschool"
        w.contentAspectRatio = NSSize(width: 4, height: 3)
        w.contentMinSize = NSSize(width: 640, height: 480)
        w.center()
        w.delegate = self
        let v = GameView(frame: w.contentLayoutRect)
        w.contentView = v
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        window = w
        view = v
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.startGame() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { game?.player.save() }

    // MARK: Game folder

    /// The folder holding RRPDATA: command-line argument, environment, saved choice, or ask.
    private func gameFolder() -> URL? {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--game"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1])
        }
        if let env = ProcessInfo.processInfo.environment["RRP_GAME_DIR"] {
            return URL(fileURLWithPath: env)
        }
        if let saved = UserDefaults.standard.string(forKey: Self.folderKey) {
            let u = URL(fileURLWithPath: saved)
            if ResourceStore.looksLikeGame(u) { return u }
        }
        if let resources = Bundle.main.resourceURL {
            let embedded = resources.appendingPathComponent("GameData", isDirectory: true)
            if ResourceStore.looksLikeGame(embedded) { return embedded }
        }
        return askForFolder()
    }

    private func askForFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose your Reader Rabbit's Preschool CD or game folder"
        panel.message = "Select the folder that contains RRPDATA (your own copy of the game)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        while panel.runModal() == .OK, let url = panel.url {
            if ResourceStore.looksLikeGame(url) {
                UserDefaults.standard.set(url.path, forKey: Self.folderKey)
                return url
            }
            let alert = NSAlert()
            alert.messageText = "That folder doesn't contain RRPDATA/GRAPHIC.DAT."
            alert.informativeText = "Choose the top level of the game CD (or a copy of it)."
            alert.runModal()
        }
        return nil
    }

    @objc private func chooseFolder(_ sender: Any?) {
        guard let folder = askForFolder() else { return }
        UserDefaults.standard.set(folder.path, forKey: Self.folderKey)
        timer?.invalidate()
        game?.audio.stopSpeech()
        game?.audio.stopMusic()
        game = nil
        startGame()
    }

    private func startGame() {
        guard let root = gameFolder() else { NSApp.terminate(nil); return }
        do {
            let g = try Game(root: root)
            g.onFrame = { [weak self, weak g] in self?.view?.present(g?.fb.makeImage()) }
            g.onQuitRequest = { [weak self] in self?.confirmQuit() }
            game = g
            view?.game = g
            g.start(IntroScene())
            nextTick = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { [weak self] _ in
                self?.pump()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't load the game files"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            UserDefaults.standard.removeObject(forKey: Self.folderKey)
            NSApp.terminate(nil)
        }
    }

    /// Fixed-rate ticks against a deadline, like the original busy-wait loop.
    private func pump() {
        guard let g = game else { return }
        let now = Date()
        guard now >= nextTick else { return }
        g.tick()
        nextTick = nextTick.addingTimeInterval(g.tickInterval)
        if now.timeIntervalSince(nextTick) > 0.5 { nextTick = now }
    }

    private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = "Do you want to stop playing?"
        alert.addButton(withTitle: "Stop Playing")
        alert.addButton(withTitle: "Keep Playing")
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }

    @objc private func toggleSound(_ sender: Any?) { game?.toggleSound() }

    @objc private func toggleCase(_ sender: Any?) {
        game?.player.lowercase.toggle()
        game?.player.save()
    }

    /// The original's Ctrl+P parent overlay (FUN_0041ce84).
    @objc private func parentOptions(_ sender: Any?) {
        game?.change(to: ParentMenuScene())
    }

    @objc private func resetProgress(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Reset all progress and keys?"
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let g = game else { return }
        g.player = PlayerProfile()
        g.player.save()
        g.change(to: MainMenuScene())
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Reader Rabbit's Preschool",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let gameItem = NSMenuItem()
        main.addItem(gameItem)
        let gameMenu = NSMenu(title: "Game")
        gameMenu.addItem(withTitle: "Sound On/Off", action: #selector(toggleSound(_:)), keyEquivalent: "")
        gameMenu.addItem(withTitle: "Upper/Lower Case Letters", action: #selector(toggleCase(_:)), keyEquivalent: "")
        gameMenu.addItem(.separator())
        gameMenu.addItem(withTitle: "Choose Game Folder…", action: #selector(chooseFolder(_:)), keyEquivalent: "o")
        gameMenu.addItem(withTitle: "Parent Options…", action: #selector(parentOptions(_:)), keyEquivalent: "p")
        gameMenu.addItem(withTitle: "Reset Progress…", action: #selector(resetProgress(_:)), keyEquivalent: "")
        for item in gameMenu.items { item.target = self }
        gameItem.submenu = gameMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        windowMenu.items.last?.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.mainMenu = main
    }
}
