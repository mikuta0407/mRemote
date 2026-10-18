import XCTest
import SessionCore
@testable import RDPProtocol

final class RDPErrorMapperTests: XCTestCase {
    private func connect(_ type: UInt32) -> Int32 {
        Int32(bitPattern: (RDPErrorMapper.connectErrorClass << 16) | type)
    }

    private func errinfo(_ type: UInt32) -> Int32 {
        Int32(bitPattern: (RDPErrorMapper.errorInfoClass << 16) | type)
    }

    func testAStopWeAskedForIsNotAFailure() {
        XCTAssertEqual(RDPErrorMapper.classify(status: .stopped), .stoppedLocally)
        XCTAssertEqual(RDPErrorMapper.classify(status: .ok), .stoppedLocally)
        XCTAssertEqual(
            RDPErrorMapper.classify(status: .backend, nativeCode: connect(0x0B)),
            .stoppedLocally
        )
    }

    func testThroughAProxyTheNetworkFailuresAreTheProxys() {
        XCTAssertEqual(RDPErrorMapper.throughProxy(.failed(.connectionRefused)), .failed(.proxyUnreachable))
        XCTAssertEqual(RDPErrorMapper.throughProxy(.failed(.nameResolutionFailed)), .failed(.proxyUnreachable))
        XCTAssertEqual(RDPErrorMapper.throughProxy(.failed(.authenticationFailed)), .failed(.authenticationFailed))
        XCTAssertEqual(RDPErrorMapper.throughProxy(.stoppedLocally), .stoppedLocally)
    }

    func testNameResolutionAndTransportAreDistinguished() {
        XCTAssertEqual(
            RDPErrorMapper.classify(status: .backend, nativeCode: connect(0x05)),
            .failed(.nameResolutionFailed)
        )
        XCTAssertEqual(
            RDPErrorMapper.classify(status: .backend, nativeCode: connect(0x06)),
            .failed(.connectionRefused)
        )
        XCTAssertEqual(
            RDPErrorMapper.classify(status: .backend, nativeCode: connect(0x08)),
            .failed(.tlsHandshakeFailed)
        )
    }

    func testAServerThatRefusesTLSIsASecurityNegotiationFailure() {
        // 0x2000C: what a real Windows listener set to the RDP Security Layer
        // only produced (SSL_NOT_ALLOWED_BY_SERVER in FreeRDP's log).
        let cause = RDPErrorMapper.classify(status: .backend, nativeCode: 0x0002_000C)
        XCTAssertEqual(cause, .failed(.securityNegotiationFailed))
        XCTAssertEqual(cause.error?.isRetriable, false)
    }

    func testAWrongPasswordIsNotReportedAsAnAccountRestriction() {
        // The categories differ because `isRetriable` differs: retrying a
        // locked-out account is how an account stays locked out.
        for type: UInt32 in [0x09, 0x14, 0x15, 0x16, 0x1B] {
            XCTAssertEqual(
                RDPErrorMapper.classify(status: .backend, nativeCode: connect(type)),
                .failed(.authenticationFailed),
                "connect type 0x\(String(type, radix: 16))"
            )
        }
        for type: UInt32 in [0x0A, 0x12, 0x17, 0x18, 0x19, 0x1A] {
            XCTAssertEqual(
                RDPErrorMapper.classify(status: .backend, nativeCode: connect(type)),
                .failed(.accountRestricted),
                "connect type 0x\(String(type, radix: 16))"
            )
        }
    }

    func testNoMappedConnectFailureIsAutomaticallyRetried() {
        // An automatic retry after a credential failure is what locks an
        // account out, so nothing on the authentication path may be retriable.
        for type: UInt32 in [0x09, 0x14, 0x15, 0x16, 0x1B, 0x0A, 0x12, 0x17, 0x18, 0x19] {
            let cause = RDPErrorMapper.classify(status: .backend, nativeCode: connect(type))
            XCTAssertEqual(cause.error?.isRetriable, false)
        }
    }

    func testASignOutOnTheServerIsNotAnError() {
        for type: UInt32 in [0x01, 0x02, 0x0B, 0x0C, 0x03, 0x04, 0x05] {
            let cause = RDPErrorMapper.classify(status: .backend, nativeCode: errinfo(type))
            guard case .remoteInitiated = cause else {
                return XCTFail("errinfo 0x\(String(type, radix: 16)) reported as \(cause)")
            }
        }
    }

    func testATakeoverIsReportedAsSuch() {
        XCTAssertEqual(
            RDPErrorMapper.classify(status: .backend, nativeCode: errinfo(0x05)),
            .remoteInitiated(.anotherConnection)
        )
        // What Windows 11 actually sent when a second client signed in as the
        // same user (verified against a Windows 11 VM).
        XCTAssertEqual(
            RDPErrorMapper.classify(status: .backend, nativeCode: 0x0001_0001),
            .remoteInitiated(.disconnectedOnServer)
        )
        XCTAssertEqual(
            RDPErrorMapper.classify(status: .backend, nativeCode: errinfo(0x0C)),
            .remoteInitiated(.signedOut)
        )
    }

    func testLicensingFailuresAreNotBlamedOnTheCredentials() {
        XCTAssertEqual(
            RDPErrorMapper.classify(status: .backend, nativeCode: errinfo(0x0102)),
            .failed(.accountRestricted)
        )
    }

    func testAnUnknownFreeRDPCodeIsReportedRatherThanGuessed() {
        let cause = RDPErrorMapper.classify(status: .backend, nativeCode: errinfo(0x10C9))
        XCTAssertEqual(cause, .failed(.protocolFailure(detail: "freerdp errinfo 0x10C9")))

        let unknownClass = RDPErrorMapper.classify(
            status: .backend,
            nativeCode: Int32(bitPattern: 0x0009_0001)
        )
        XCTAssertEqual(unknownClass, .failed(.protocolFailure(detail: "freerdp 0x00090001")))
    }

    func testABackendFailureWithNoCodeSaysSo() {
        XCTAssertEqual(
            RDPErrorMapper.classify(status: .backend, nativeCode: 0),
            .failed(.protocolFailure(detail: "backend failure with no reported cause"))
        )
    }

    func testBridgeLevelStatusesMapWithoutConsultingFreeRDP() {
        XCTAssertEqual(
            RDPErrorMapper.classify(status: .certificateRejected),
            .failed(.certificateRejected)
        )
        XCTAssertEqual(
            RDPErrorMapper.classify(status: .timeout),
            .failed(.connectionTimedOut)
        )
        XCTAssertEqual(
            RDPErrorMapper.classify(status: .outOfMemory),
            .failed(.resourceUnavailable)
        )
        XCTAssertEqual(
            RDPErrorMapper.classify(status: .limitExceeded),
            .failed(.resourceUnavailable)
        )
    }

    func testEveryStatusHasAClassification() {
        for status in RDPBridgeStatus.allCases {
            _ = RDPErrorMapper.classify(status: status, nativeCode: 0)
        }
    }
}

final class RDPBridgePhaseTests: XCTestCase {
    func testPhasesMapOntoTheSessionStateMachine() {
        XCTAssertEqual(RDPBridgePhase.connecting.sessionState, .connecting)
        XCTAssertEqual(RDPBridgePhase.connected.sessionState, .connected)
        XCTAssertEqual(RDPBridgePhase.stopping.sessionState, .disconnecting)
        XCTAssertEqual(RDPBridgePhase.failed.sessionState, .failed)
    }

    func testTheBackendCannotDeclareTheSessionFinished() {
        // `disconnected` has to wait for the worker to join and the native
        // memory to be released, so the backend's own STOPPED is not allowed
        // to publish it.
        XCTAssertNil(RDPBridgePhase.stopped.sessionState)
        XCTAssertNil(RDPBridgePhase.created.sessionState)
    }

    func testCheckingACertificateIsNotWaitingForTheUser() {
        // A certificate accepted from a stored approval never asks, so the
        // backend's phase must not put the session where only an answer
        // would take it out: connecting -> connected has to stay open.
        XCTAssertNil(RDPBridgePhase.awaitingCertificate.sessionState)
    }

    func testEveryMappedPhaseIsAStateTheMachineCanReach() {
        for phase in RDPBridgePhase.allCases {
            guard let state = phase.sessionState else { continue }
            XCTAssertNotEqual(state, .disconnected)
            XCTAssertNotEqual(state, .idle)
        }
    }
}

/// The bridge ABI is mirrored in Swift rather than imported, so something has
/// to fail when the header changes. This reads the header in the repository
/// and compares the numbers.
final class RDPBridgeStatusABITests: XCTestCase {
    private func headerText() throws -> String {
        // Tests/RDPProtocolTests/<file> -> repository root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let header = root.appendingPathComponent("bridge/include/mremote/rdp_bridge.h")
        return try String(contentsOf: header, encoding: .utf8)
    }

    private func constants(in text: String, names: [String]) -> [String: Int64] {
        var values: [String: Int64] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            guard names.contains(name) else { continue }
            let rest = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            values[name] = Int64(rest)
        }
        return values
    }

    func testStatusCodesStillMatchTheHeader() throws {
        let text = try headerText()
        let expected: [String: RDPBridgeStatus] = [
            "MR_RDP_STATUS_OK": .ok,
            "MR_RDP_ERROR_INVALID_ARGUMENT": .invalidArgument,
            "MR_RDP_ERROR_OUT_OF_MEMORY": .outOfMemory,
            "MR_RDP_ERROR_INVALID_STATE": .invalidState,
            "MR_RDP_ERROR_STOPPED": .stopped,
            "MR_RDP_ERROR_TIMEOUT": .timeout,
            "MR_RDP_ERROR_STALE_CHALLENGE": .staleChallenge,
            "MR_RDP_ERROR_BACKEND_UNAVAILABLE": .backendUnavailable,
            "MR_RDP_ERROR_BACKEND": .backend,
            "MR_RDP_ERROR_INVALID_DATA": .invalidData,
            "MR_RDP_ERROR_LIMIT_EXCEEDED": .limitExceeded,
            "MR_RDP_ERROR_CERTIFICATE_REJECTED": .certificateRejected,
            "MR_RDP_ERROR_UNSUPPORTED": .unsupported,
        ]
        let parsed = constants(in: text, names: Array(expected.keys))
        XCTAssertEqual(parsed.count, expected.count, "the header no longer declares every status")
        for (name, status) in expected {
            XCTAssertEqual(parsed[name], Int64(status.rawValue), name)
        }
    }

    func testSessionPhasesStillMatchTheHeader() throws {
        let text = try headerText()
        let expected: [String: RDPBridgePhase] = [
            "MR_RDP_SESSION_CREATED": .created,
            "MR_RDP_SESSION_CONNECTING": .connecting,
            "MR_RDP_SESSION_AWAITING_CERTIFICATE": .awaitingCertificate,
            "MR_RDP_SESSION_CONNECTED": .connected,
            "MR_RDP_SESSION_STOPPING": .stopping,
            "MR_RDP_SESSION_STOPPED": .stopped,
            "MR_RDP_SESSION_FAILED": .failed,
        ]
        let parsed = constants(in: text, names: Array(expected.keys))
        XCTAssertEqual(parsed.count, expected.count, "the header no longer declares every phase")
        for (name, phase) in expected {
            XCTAssertEqual(parsed[name], Int64(phase.rawValue), name)
        }
    }

    func testChannelKindsStillMatchTheHeader() throws {
        let text = try headerText()
        let expected: [String: RDPBridgeChannel] = [
            "MR_RDP_CHANNEL_CLIPRDR": .cliprdr,
            "MR_RDP_CHANNEL_RDPSND": .rdpsnd,
            "MR_RDP_CHANNEL_DRDYNVC": .drdynvc,
            "MR_RDP_CHANNEL_DISP": .disp,
            "MR_RDP_CHANNEL_RDPGFX": .rdpgfx,
            "MR_RDP_CHANNEL_RDPEI": .rdpei,
            "MR_RDP_CHANNEL_RDPDR": .rdpdr,
        ]
        let parsed = constants(in: text, names: Array(expected.keys))
        XCTAssertEqual(parsed.count, expected.count, "the header no longer declares every channel")
        for (name, channel) in expected {
            XCTAssertEqual(parsed[name], Int64(channel.rawValue), name)
        }
    }

    func testFrameLimitsStillMatchTheHeader() throws {
        let text = try headerText()
        // The limits `DesktopFrameValidator` re-checks are the header's, so a
        // change there has to be noticed rather than silently diverge.
        XCTAssertTrue(text.contains("#define MR_RDP_MAX_DESKTOP_DIMENSION 8192u"))
        XCTAssertTrue(text.contains("#define MR_RDP_MAX_DESKTOP_FRAME_BYTES (512u * 1024u * 1024u)"))
        XCTAssertTrue(text.contains("#define MR_RDP_MAX_DESKTOP_DIRTY_RECTS 512u"))
        XCTAssertEqual(DesktopFrameValidator.maximumDimension, 8_192)
        XCTAssertEqual(DesktopFrameValidator.maximumFrameBytes, 512 * 1_024 * 1_024)
        XCTAssertEqual(DesktopFrameValidator.maximumDirtyRectangles, 512)
    }
}
