// Deterministic test bytes, NOT a cryptographic implementation.
public let kSecRandomDefault = 0
public let errSecSuccess: Int32 = 0
public func SecRandomCopyBytes(_ source: Int, _ count: Int, _ bytes: UnsafeMutableRawPointer) -> Int32 {
    bytes.initializeMemory(as: UInt8.self, repeating: 0xA5, count: count)
    return errSecSuccess
}
