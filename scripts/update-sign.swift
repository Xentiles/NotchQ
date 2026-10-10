// Release-side Ed25519 tool for NotchQ update archives. Built and run by scripts/update-key.sh.
// Private keys are read from stdin, never passed as arguments, and never written by this tool.
import CryptoKit
import Foundation

func notchQFail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
func notchQPrivateKey() -> Curve25519.Signing.PrivateKey {
    let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: text), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { notchQFail("No valid private key on stdin.") }
    return key
}
func notchQRead(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { notchQFail("Cannot read \(path).") }
    return data
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate":
    print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
case "public":
    print(notchQPrivateKey().publicKey.rawRepresentation.base64EncodedString())
case "sign" where arguments.count == 2:
    let signature = try notchQPrivateKey().signature(for: notchQRead(arguments[1]))
    print(signature.base64EncodedString())
case "verify" where arguments.count == 4:
    guard let raw = Data(base64Encoded: arguments[3]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { notchQFail("Invalid public key.") }
    let text = String(decoding: notchQRead(arguments[2]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let signature = Data(base64Encoded: text), key.isValidSignature(signature, for: notchQRead(arguments[1])) else { notchQFail("Signature does NOT match.") }
    print("Signature verified.")
default:
    notchQFail("usage: notchq-update-sign generate | public | sign <file> | verify <file> <signature-file> <public-key>")
}
