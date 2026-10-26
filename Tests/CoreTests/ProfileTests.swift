import Foundation
import XCTest
@testable import NPVCore

final class ProfileTests: XCTestCase {
    func sample() -> TunnelProfile {
        TunnelProfile(identityID: UUID(), name: "Lab", endpoint: TunnelEndpoint(host: "vpn.example.org", port: 51820),
                      serverPublicKey: Data(repeating: 7, count: 32).base64EncodedString(),
                      ipv4Address: "10.77.0.2/32", ipv6Address: "fd77::2/128", dnsServers: ["10.77.0.1", "fd77::1"])
    }
    func testProfileRoundTripPreservesIdentityAndPolicy() throws {
        let p = sample()
        XCTAssertEqual(try TunnelProfile.decode(p.encoded()), p)
    }
    func testProfileNeverContainsDevicePrivateKey() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sample().encoded()) as? [String: Any])
        XCTAssertNil(object["privateKey"])
        XCTAssertNil(object["presharedKey"])
        XCTAssertNotNil(object["identityID"])
        XCTAssertNotNil(object["serverPublicKey"])
    }
    func testEndpointsAcceptIPv4IPv6AndDNS() throws {
        for host in ["203.0.113.1", "2001:db8::1", "fd77::1", "lab", "vpn.example.org", "xn--fiqs8s.example"] {
            XCTAssertNoThrow(try TunnelEndpoint(host: host, port: 51820).validate(), host)
        }
    }
    func testEndpointsRejectAmbiguousOrInjectedValues() {
        for host in ["", "https://vpn.example.org", "vpn.example.org:443", "a/b", "a b", "a\nPostUp=evil", "a\0b",
                     "[2001:db8::1]", "-a.example", "a-.example", ".a", "a..b", "a.", "999.1.1.1",
                     "0.0.0.0", "127.0.0.1", "224.0.0.1", "169.254.169.254", "::", "::1", "ff02::1",
                     "fe80::1", "::ffff:127.0.0.1", "中文.example", String(repeating: "a", count: 64) + ".org"] {
            XCTAssertThrowsError(try TunnelEndpoint(host: host, port: 51820).validate(), host)
        }
    }
    func testEndpointPortBounds() {
        for port in [-1, 0, 65_536, Int.max] { XCTAssertThrowsError(try TunnelEndpoint(host: "vpn.example.org", port: port).validate()) }
        for port in [1, 65_535] { XCTAssertNoThrow(try TunnelEndpoint(host: "vpn.example.org", port: port).validate()) }
    }
    func testIPv6EndpointRendering() {
        XCTAssertEqual(TunnelEndpoint(host: "2001:db8::1", port: 51820).wireGuardValue, "[2001:db8::1]:51820")
        XCTAssertEqual(TunnelEndpoint(host: "vpn.example.org", port: 443).wireGuardValue, "vpn.example.org:443")
    }
    func testNamesRejectEmptyLongAndControlCharacters() {
        for name in ["", "  ", "test\nkey", "test\0key", String(repeating: "a", count: 65)] {
            var p = sample(); p.name = name; XCTAssertThrowsError(try p.validate())
        }
    }
    func testRejectsInvalidPublicKeys() {
        for key in ["", "not-a-key", Data(repeating: 0, count: 32).base64EncodedString(),
                    Data(repeating: 1, count: 31).base64EncodedString(), Data(repeating: 1, count: 33).base64EncodedString(),
                    Data(repeating: 1, count: 32).base64EncodedString() + "\n"] {
            var p = sample(); p.serverPublicKey = key; XCTAssertThrowsError(try p.validate())
        }
    }
    func testRejectsIPv4CIDROverflowAndWrongFamily() {
        for address in ["10.0.0.2", "10.0.0.2/33", "10.0.0.2/-1", "10.0.0.2/0", "10.0.0.2/032", "10.0.0.2/32/1", "fd77::2/32", "127.0.0.1/32"] {
            var p = sample(); p.ipv4Address = address; XCTAssertThrowsError(try p.validate(), address)
        }
    }
    func testRejectsIPv6CIDROverflowAndMissingAddress() {
        for address in ["", "fd77::2/129", "fd77::2/0", "fd77::2", "10.0.0.2/32", "::1/128", "fe80::1/64"] {
            var p = sample(); p.ipv6Address = address; XCTAssertThrowsError(try p.validate(), address)
        }
    }
    func testDNSMustBeBoundedListOfLiteralAddresses() {
        for addresses in [[], ["dns.example.org"], ["https://dns.example.org"], ["127.0.0.1"], ["1.1.1.1\n"], Array(repeating: "1.1.1.1", count: 4)] as [[String]] {
            var p = sample(); p.dnsServers = addresses; XCTAssertThrowsError(try p.validate())
        }
    }
    func testMTUBoundsProtectIPv6Minimum() {
        for mtu in [0, 1279, 1421, Int.max] { var p = sample(); p.mtu = mtu; XCTAssertThrowsError(try p.validate()) }
        for mtu in [1280, 1420] { var p = sample(); p.mtu = mtu; XCTAssertNoThrow(try p.validate()) }
    }
    func testKeepaliveIsOffOrBounded() {
        for interval in [-1, 1, 14, 121] { var p = sample(); p.keepaliveSeconds = interval; XCTAssertThrowsError(try p.validate()) }
        for interval in [0, 15, 25, 120] { var p = sample(); p.keepaliveSeconds = interval; XCTAssertNoThrow(try p.validate()) }
    }
    func testUnknownSchemaRejected() throws {
        var p = sample(); p.schemaVersion = 2
        XCTAssertThrowsError(try p.encoded())
        XCTAssertThrowsError(try TunnelProfile.decode(JSONEncoder().encode(p)))
    }
    func testOversizedAndMalformedInputRejected() {
        XCTAssertThrowsError(try TunnelProfile.decode(Data(repeating: 32, count: TunnelProfile.maximumBytes + 1)))
        for json in ["{}", "null", "[]", "{", "{\"schemaVersion\":1}"] {
            XCTAssertThrowsError(try TunnelProfile.decode(Data(json.utf8)))
        }
    }
    func testDecodeRevalidatesUntrustedValues() throws {
        var p = sample(); p.endpoint.port = 0
        XCTAssertThrowsError(try TunnelProfile.decode(JSONEncoder().encode(p)))
    }
}
