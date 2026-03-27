import CryptoKit
import Foundation

enum WireGuardKeyUtils {
    static func generateKeypairBase64() -> (privateKey: String, publicKey: String) {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let pub = priv.publicKey.rawRepresentation
        return (
            Data(priv.rawRepresentation).base64EncodedString(),
            Data(pub).base64EncodedString()
        )
    }
}

