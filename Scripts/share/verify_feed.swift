// Checks an update feed the way the app will, with only the public key that ships in it (SUPublicEDKey):
// the feed's own EdDSA signature, then every file it lists (dmg and deltas) in the update folder: length and
// EdDSA signature. Prints one line per file; exits 1 on the first mismatch.
//   swift Scripts/share/verify_feed.swift <public key base64> <appcast.xml> <update folder>
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4, let keyData = Data(base64Encoded: args[1]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    FileHandle.standardError.write("usage: verify_feed.swift <public key> <appcast.xml> <update folder>\n".data(using: .utf8)!)
    exit(2)
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

guard let text = try? String(contentsOfFile: args[2], encoding: .utf8) else { fail("Can't read \(args[2])") }
// generate_appcast signs everything before this comment and writes the signature inside it.
guard let block = text.range(of: "<!-- sparkle-signatures:") else { fail("The feed is not signed") }
let signatureLine = text[block.upperBound...].split(separator: "\n").first { $0.hasPrefix("edSignature:") }
guard let line = signatureLine,
      let feedSignature = Data(base64Encoded: String(line.dropFirst("edSignature:".count)).trimmingCharacters(in: .whitespaces)),
      key.isValidSignature(feedSignature, for: Data(text[..<block.lowerBound].utf8)) else {
    fail("The feed's signature does not match the public key")
}
print("appcast.xml: signature OK")

// Every <enclosure …> (full update and deltas): url, length, edSignature.
let enclosure = try! NSRegularExpression(pattern: "<enclosure\\b[^>]*>")
func attribute(_ name: String, _ tag: String) -> String? {
    guard let r = tag.range(of: "\(name)=\""), let end = tag[r.upperBound...].firstIndex(of: "\"") else { return nil }
    return String(tag[r.upperBound..<end])
}
let tags = enclosure.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]) }
if tags.isEmpty { fail("The feed lists no files") }
for tag in tags {
    guard let url = attribute("url", tag), let name = url.split(separator: "/").last.map(String.init)?.removingPercentEncoding,
          let length = attribute("length", tag).flatMap(Int.init),
          let signature = attribute("sparkle:edSignature", tag).flatMap({ Data(base64Encoded: $0) }) else {
        fail("An enclosure without url, length or signature: \(tag)")
    }
    let path = (args[3] as NSString).appendingPathComponent(name)
    guard let data = FileManager.default.contents(atPath: path) else { fail("Missing \(path)") }
    guard data.count == length else { fail("\(name): \(data.count) bytes, the feed says \(length)") }
    guard key.isValidSignature(signature, for: data) else { fail("\(name): signature does not match the public key") }
    print("\(name): \(length) bytes, signature OK")
}
