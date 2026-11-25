import AppKit
import Foundation
import Darwin

struct LaunchOptions {
    var uiTestMode = false
    #if QA_CHECKS
    var uiSmokeDirectory: String?
    var settingsCheckOnly = false
    var fullScreenCheckOutput: String?
    #endif
    var fixtureCheckOutput: String?
    var fixtureRecordPath: String?
}

// These switches are only entry points for automated app checks.
// Leave Xcode and Foundation launch arguments alone.
let arguments = Array(CommandLine.arguments.dropFirst())
var options = LaunchOptions()
var index = 0
func argumentError(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)
}
func pathArgument() -> String {
    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
        argumentError("\(arguments[index]) requires a path.")
    }
    index += 1
    return arguments[index]
}
while index < arguments.count {
    switch arguments[index] {
    #if QA_CHECKS
    case "--fullscreen-check":
        options.fullScreenCheckOutput = pathArgument()
        options.uiTestMode = true
    case "--settings-check":
        options.uiSmokeDirectory = pathArgument()
        options.settingsCheckOnly = true
        options.uiTestMode = true
    case "--ui-smoke":
        options.uiSmokeDirectory = pathArgument()
        options.uiTestMode = true
    #endif
    case "--fixture-check":
        options.fixtureCheckOutput = pathArgument()
    case "--fixture-record":
        options.fixtureRecordPath = pathArgument()
    default:
        if arguments[index].hasPrefix("--") {
            argumentError("Unknown argument: \(arguments[index])")
        }
    }
    index += 1
}
if options.fixtureRecordPath != nil && options.fixtureCheckOutput == nil {
    argumentError("--fixture-record requires --fixture-check.")
}
#if QA_CHECKS
if [options.uiSmokeDirectory, options.fullScreenCheckOutput, options.fixtureCheckOutput].compactMap({ $0 }).count > 1 {
    argumentError("Choose only one check mode.")
}
#endif

// The process entry point is the main thread. Keep all AppKit ownership here.
MainActor.assumeIsolated {
    let application = MenuApplication.shared
    application.setActivationPolicy(.accessory)
    let controller = AppController(options: options)
    application.delegate = controller
    application.run()
    withExtendedLifetime(controller) {}
}
