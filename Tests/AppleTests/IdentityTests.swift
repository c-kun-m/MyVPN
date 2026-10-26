import CryptoKit
import XCTest
@testable import NPV

final class IdentityTests: XCTestCase {
    func testCurve25519MatchesRFC7748AlicePublicKey() throws {
        let privateHex = "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
        let expectedHex = "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"
        let bytes = stride(from: 0, to: privateHex.count, by: 2).map { offset -> UInt8 in
            let start = privateHex.index(privateHex.startIndex, offsetBy: offset)
            let end = privateHex.index(start, offsetBy: 2)
            return UInt8(privateHex[start..<end], radix: 16)!
        }
        let identity = DeviceIdentity(id: UUID(), privateKey: Data(bytes))
        let publicBytes = try XCTUnwrap(Data(base64Encoded: identity.publicKey))
        XCTAssertEqual(publicBytes.map { String(format: "%02x", $0) }.joined(), expectedHex)
    }
    func testMalformedPrivateKeyRejected() {
        XCTAssertThrowsError(try DeviceIdentity(id: UUID(), privateKey: Data(repeating: 0, count: 31)).publicKey)
    }
}
