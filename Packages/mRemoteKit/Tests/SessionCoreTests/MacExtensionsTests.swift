import XCTest
@testable import SessionCore

final class MacExtensionsTests: XCTestCase {
    func testAutomaticQualityFollowsTheNetwork() {
        XCTAssertEqual(StreamQuality.automatic.streamRequest(onConstrainedNetwork: false).framesPerSecond, 60)
        XCTAssertEqual(StreamQuality.automatic.streamRequest(onConstrainedNetwork: true).bitrateKbps, 1_500)
        // An explicit choice ignores the network.
        XCTAssertEqual(StreamQuality.high.streamRequest(onConstrainedNetwork: true).framesPerSecond, 60)
        XCTAssertEqual(StreamQuality.low.streamRequest(onConstrainedNetwork: false).framesPerSecond, 15)
    }

    func testFeatureBitsMatchTheWireProtocol() {
        // MRX_CAP_* in macrdpx.h.
        XCTAssertEqual(MacExtensionFeatures.macKeys.rawValue, 1)
        XCTAssertEqual(MacExtensionFeatures.cursorAlpha.rawValue, 32)
        XCTAssertEqual(MacExtensionFeatures.gestures.rawValue, 64)
        XCTAssertEqual(MacExtensionFeatures.all.rawValue, 0x7F)
    }

    func testPlatformDefaultsAndRoundTrip() throws {
        var rdp = RDPConfiguration()
        XCTAssertEqual(rdp.remotePlatform, .automatic)
        XCTAssertEqual(rdp.preferredStreamQuality, .automatic)
        rdp.platform = .macOS
        rdp.streamQuality = .low
        let decoded = try JSONDecoder().decode(RDPConfiguration.self, from: JSONEncoder().encode(rdp))
        XCTAssertEqual(decoded.remotePlatform, .macOS)
        XCTAssertEqual(decoded.preferredStreamQuality, .low)
        // A document written before these existed finds out from the server.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RDPConfiguration())) as! [String: Any]
        old.removeValue(forKey: "platform")
        let legacy = try JSONDecoder().decode(RDPConfiguration.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(legacy.remotePlatform, .automatic)
        XCTAssertTrue(legacy.remotePlatform.offersMacExtensions)
        XCTAssertFalse(RemotePlatform.standard.offersMacExtensions)
    }
}
