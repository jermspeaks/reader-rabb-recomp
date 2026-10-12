import AppKit

if CommandLine.arguments.contains("--snapshot") {
    // Headless verification: run scripted input and write PNG snapshots.
    exit(Snapshot.run(CommandLine.arguments) ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
