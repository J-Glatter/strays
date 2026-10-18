import AppKit

// One binary, two faces: `strays` / `--list` / `--json` print a scan and exit;
// anything else starts the menu bar app.
let arguments = Array(CommandLine.arguments.dropFirst())
let invokedAs = CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent } ?? ""

if CLI.handles(arguments: arguments, invokedAs: invokedAs) {
    exit(CLI.run(arguments))
}
StraysApp.main()
