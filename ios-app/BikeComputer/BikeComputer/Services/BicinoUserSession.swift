import AuthenticationServices
import Combine
import CryptoKit
import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import UIKit

enum SocialFailure: LocalizedError {
    case unavailable, signedOut, cancelled, accountChanged, invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Social riding is not configured for this build."
        case .signedOut: "Sign in to use social riding."
        case .cancelled: "Sign-in was cancelled."
        case .accountChanged: "Your account changed. Try again."
        case .invalidResponse: "Bicino returned an invalid response."
        case .server(let code): code.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

@MainActor
final class BicinoUserSession: NSObject, ObservableObject {
    enum State: Equatable { case unavailable, restoring, signedOut, signedIn }
    @Published private(set) var state: State = .unavailable
    @Published private(set) var generation = UUID()
    private var auth: Auth?
    private var listener: AuthStateDidChangeListenerHandle?
    private var appleFlow: AppleSignInFlow?
    private var observedUID: String?
    private var refresh: Task<String, Error>?

    override init() {
        super.init()
        let info = Bundle.main.infoDictionary ?? [:]
        guard (info["BicinoSocialEnabled"] as? String) == "YES",
              let appID = info["BicinoFirebaseAppID"] as? String, !appID.isEmpty,
              let senderID = info["BicinoFirebaseSenderID"] as? String, !senderID.isEmpty,
              let apiKey = info["BicinoFirebaseAPIKey"] as? String, !apiKey.isEmpty,
              let project = info["BicinoFirebaseProjectID"] as? String, !project.isEmpty,
              let clientID = info["BicinoGoogleClientID"] as? String, !clientID.isEmpty,
              ![appID, senderID, apiKey, project, clientID].contains(where: { $0.contains("$(") }) else { return }
        let options = FirebaseOptions(googleAppID: appID, gcmSenderID: senderID)
        options.apiKey = apiKey
        options.projectID = project
        options.clientID = clientID
        options.bundleID = Bundle.main.bundleIdentifier ?? ""
        if FirebaseApp.app() == nil { FirebaseApp.configure(options: options) }
        auth = Auth.auth()
        state = .restoring
        listener = auth?.addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply(user: self.auth?.currentUser)
            }
        }
    }

    private func apply(user: User?) {
        if observedUID != user?.uid {
            generation = UUID()
            refresh?.cancel()
            refresh = nil
            observedUID = user?.uid
        }
        state = user == nil ? .signedOut : .signedIn
    }

    func token(forceRefresh: Bool = false) async throws -> String {
        guard state == .signedIn, let user = auth?.currentUser else { throw SocialFailure.signedOut }
        let expected = generation
        if forceRefresh, let refresh {
            let value = try await refresh.value
            guard expected == generation else { throw SocialFailure.accountChanged }
            return value
        }
        let task = Task { try await user.getIDToken(forcingRefresh: forceRefresh) }
        if forceRefresh { refresh = task }
        defer { if forceRefresh { refresh = nil } }
        let token = try await task.value
        guard expected == generation else { throw SocialFailure.accountChanged }
        return token
    }

    func signInWithGoogle(reauthenticate: Bool = false, link: Bool = false) async throws {
        guard let auth, let clientID = FirebaseApp.app()?.options.clientID,
              let presenter = Self.presenter else { throw SocialFailure.unavailable }
        let generation = generation
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard generation == self.generation, let idToken = result.user.idToken?.tokenString else {
            throw SocialFailure.accountChanged
        }
        let credential = GoogleAuthProvider.credential(withIDToken: idToken,
                                                        accessToken: result.user.accessToken.tokenString)
        if link {
            guard let user = auth.currentUser else { throw SocialFailure.signedOut }
            _ = try await user.link(with: credential)
        } else if reauthenticate {
            guard let user = auth.currentUser else { throw SocialFailure.signedOut }
            _ = try await user.reauthenticate(with: credential)
        } else {
            _ = try await auth.signIn(with: credential)
        }
        apply(user: auth.currentUser)
    }

    @discardableResult
    func signInWithApple(reauthenticate: Bool = false, link: Bool = false) async throws -> String? {
        guard let auth, appleFlow == nil else { throw SocialFailure.unavailable }
        let flow = AppleSignInFlow()
        appleFlow = flow
        defer { appleFlow = nil }
        let expected = generation
        let result = try await flow.start()
        guard expected == generation else { throw SocialFailure.accountChanged }
        let credential = OAuthProvider.appleCredential(withIDToken: result.token,
                                                        rawNonce: result.nonce, fullName: result.name)
        if link {
            guard let user = auth.currentUser else { throw SocialFailure.signedOut }
            _ = try await user.link(with: credential)
        } else if reauthenticate {
            guard let user = auth.currentUser else { throw SocialFailure.signedOut }
            _ = try await user.reauthenticate(with: credential)
        } else {
            _ = try await auth.signIn(with: credential)
        }
        apply(user: auth.currentUser)
        return result.code
    }

    var usesApple: Bool { auth?.currentUser?.providerData.contains { $0.providerID == "apple.com" } ?? false }

    func signOut() throws {
        generation = UUID()
        refresh?.cancel()
        refresh = nil
        defer {
            GIDSignIn.sharedInstance.signOut()
            observedUID = nil
            state = .signedOut
        }
        try auth?.signOut()
    }

    func handleURL(_ url: URL) -> Bool { GIDSignIn.sharedInstance.handle(url) }

    static var presenter: UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let next = controller?.presentedViewController { controller = next }
        return controller
    }
}

@MainActor
private final class AppleSignInFlow: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {
    struct Result { let token: String; let nonce: String; let code: String?; let name: PersonNameComponents? }
    private var continuation: CheckedContinuation<Result, Error>?
    private var controller: ASAuthorizationController?
    private var nonce = ""

    func start() async throws -> Result {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SocialFailure.unavailable
        }
        nonce = bytes.map { String(format: "%02x", $0) }.joined()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        BicinoUserSession.presenter?.view.window ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        defer { continuation = nil; self.controller = nil }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
            continuation?.resume(throwing: SocialFailure.invalidResponse)
            return
        }
        continuation?.resume(returning: Result(token: token, nonce: nonce,
            code: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }, name: credential.fullName))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
        self.controller = nil
    }
}
