import Foundation
import SECNetworkBroker

/// Apple's bundled-service namespace makes this listener private to its containing app:
/// https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html
/// No global Mach listener or transferable endpoint is published. The client additionally
/// verifies and pins the embedded helper's signature. Reading the parent's executable here
/// would require extra filesystem access outside standard installation locations; that is
/// unnecessary for this app-private listener and is deliberately not granted.
private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let broker = SECNetworkBrokerSession()
        connection.exportedInterface = NSXPCInterface(with: SECNetworkServiceProtocol.self)
        connection.exportedObject = broker
        connection.invalidationHandler = { broker.close() }
        connection.interruptionHandler = { broker.close() }
        connection.resume()
        return true
    }
}

private let delegate = ListenerDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
