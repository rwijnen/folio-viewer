import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

// Registers a Folio.app bundle as the default handler for the diff and Markdown
// extensions it handles.
//
// Usage: folio-register /Applications/Folio.app
//
// Kept as a separate tool so build.sh can do this without launching the UI, and so
// nothing changes your Launch Services database unless you run the install step.

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("usage: folio-register <path to Folio.app>\n".data(using: .utf8)!)
    exit(64)
}

let appURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
guard FileManager.default.fileExists(atPath: appURL.path) else {
    FileHandle.standardError.write("error: \(appURL.path) does not exist\n".data(using: .utf8)!)
    exit(66)
}

guard let bundle = Bundle(url: appURL), let bundleIdentifier = bundle.bundleIdentifier else {
    FileHandle.standardError.write("error: \(appURL.path) is not a readable app bundle\n".data(using: .utf8)!)
    exit(66)
}

let handledExtensions = ["diff", "patch", "rej",
                         "md", "markdown", "mdown", "mkd", "mdx", "mdc"]

// Every content type behind those extensions. On current macOS `.diff` and `.patch`
// are both `public.patch-file`; `.rej` resolves to the type the app declares itself.
var identifiers: [String] = []
for extensionName in handledExtensions {
    guard let type = UTType(filenameExtension: extensionName) else {
        print("  · .\(extensionName): no content type registered, skipping")
        continue
    }
    if !identifiers.contains(type.identifier) { identifiers.append(type.identifier) }
}

guard !identifiers.isEmpty else {
    FileHandle.standardError.write("error: no content types found — is the app registered with Launch Services?\n"
        .data(using: .utf8)!)
    exit(70)
}

// LSSetDefaultRoleHandlerForContentType is deprecated but synchronous and reliable.
// NSWorkspace's replacement only calls back inside a running app, which this is not.
var failures = 0
for identifier in identifiers {
    let status = LSSetDefaultRoleHandlerForContentType(
        identifier as CFString, .all, bundleIdentifier as CFString)
    if status == noErr {
        print("  ✓ \(identifier)")
    } else {
        failures += 1
        print("  ✗ \(identifier) (OSStatus \(status))")
    }
}

// Verify against a throwaway file of each extension rather than trusting the status.
let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("folio-register-\(ProcessInfo.processInfo.processIdentifier)",
                            isDirectory: true)
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

for extensionName in handledExtensions {
    let probe = scratch.appendingPathComponent("probe.\(extensionName)")
    try? Data().write(to: probe)
    // Retry: the binding lands asynchronously, and this process caches the old answer.
    var handler: URL?
    var isUs = false
    for attempt in 0..<6 {
        handler = NSWorkspace.shared.urlForApplication(toOpen: probe)
        isUs = handler?.standardizedFileURL.path == appURL.path
        if isUs { break }
        if attempt < 5 { Thread.sleep(forTimeInterval: 0.35) }
    }
    print("  \(isUs ? "✓" : "✗") .\(extensionName) opens with \(handler?.lastPathComponent ?? "nothing")")
    if !isUs { failures += 1 }
}

if failures > 0 {
    print("")
    print("Some associations did not stick. Set it by hand in Finder:")
    print("  select a .diff file → ⌘I → Open with → Folio → Change All…")
}
exit(failures == 0 ? 0 : 1)
