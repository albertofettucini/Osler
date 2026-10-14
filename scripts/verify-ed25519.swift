// Checks a Sparkle EdDSA signature the way an installed Osler will: an
// Ed25519 signature over the whole archive, against the app's SUPublicEDKey.
// Public key only, so there's no Keychain prompt.
//
//   swift scripts/verify-ed25519.swift <file> <edSignature> <SUPublicEDKey>
//
// Exit 0 = valid, 1 = invalid, 2 = bad arguments.
import CryptoKit
import Foundation

func stop(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = CommandLine.arguments
guard args.count == 4 else {
    stop("usage: swift verify-ed25519.swift <file> <edSignature> <SUPublicEDKey>", 2)
}
guard let file = try? Data(contentsOf: URL(fileURLWithPath: args[1]), options: .alwaysMapped) else {
    stop("✗ can't read \(args[1])", 2)
}
guard let signature = Data(base64Encoded: args[2]), signature.count == 64 else {
    stop("✗ the signature isn't 64 bytes of base64", 2)
}
guard let rawKey = Data(base64Encoded: args[3]), rawKey.count == 32,
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else {
    stop("✗ the public key isn't 32 bytes of base64", 2)
}
if key.isValidSignature(signature, for: file) {
    print("✓ Ed25519 signature matches the key (\(file.count) bytes)")
} else {
    stop("✗ Ed25519 signature does NOT match the key (\(file.count) bytes)", 1)
}
