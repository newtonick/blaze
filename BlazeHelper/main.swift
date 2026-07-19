import Foundation
import os.log

let log = Logger(subsystem: "com.klockenga.blaze.helper", category: "daemon")

// Debug affordance: `com.klockenga.blaze.helper --validate diskN` runs the
// safety gates against a device and exits — lets the refusal paths be tested
// directly, without XPC or a UI.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--validate" {
    let bsd = CommandLine.arguments[2]
    do {
        _ = try Flasher().validateTarget(bsdName: bsd, imageSize: 1024)
        print("ALLOW \(bsd)")
        exit(0)
    } catch {
        print("REFUSE \(bsd): \(error.localizedDescription)")
        exit(1)
    }
}

log.info("blaze helper \(blazeHelperVersion, privacy: .public) starting")

let listener = NSXPCListener(machServiceName: blazeHelperMachServiceName)
let delegate = HelperService()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
