// No Keychain or navigation manager is instantiated by the adapter host tests.
// The native runner compiles the real shared credentials, demand, queue,
// authentication, packet and application-acknowledgement implementations.
import Foundation

final class WatchControllerCredentialStore {
    var credentials: [WatchControllerCredentialV1]
    init(credentials: [WatchControllerCredentialV1]) { self.credentials = credentials }
    func allActiveCredentials() throws -> [WatchControllerCredentialV1] { credentials }
}
protocol WatchNavigationDeviceLinking: AnyObject {}
