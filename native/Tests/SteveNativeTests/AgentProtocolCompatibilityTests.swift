import XCTest
@testable import SteveNative

final class AgentProtocolCompatibilityTests: XCTestCase {
    func testDeliveryDefaultsOmittedArraysWithoutWeakeningValidation() throws {
        let messageOnly = try AgentEnvelopeParser.deliveryPlan(from: #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":["Done."]}"#)
        XCTAssertEqual(messageOnly.messages, ["Done."])
        XCTAssertEqual(messageOnly.attachments, [])

        let attachmentOnly = try AgentEnvelopeParser.deliveryPlan(from: #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","attachments":[{"artifactID":"report"}]}"#)
        XCTAssertEqual(attachmentOnly.messages, [])
        XCTAssertEqual(attachmentOnly.attachments, [.init(artifactID: "report", caption: nil)])

        XCTAssertThrowsError(try AgentEnvelopeParser.deliveryPlan(from: #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete"}"#))
    }

    func testWorkerDefaultsOmittedOptionalFieldsAndArtifacts() throws {
        let result = try AgentEnvelopeParser.workerResult(from: #"{"schemaVersion":1,"kind":"worker_result","status":"completed","summary":"Verified."}"#)
        XCTAssertEqual(result.summary, "Verified.")
        XCTAssertNil(result.userQuestion)
        XCTAssertEqual(result.artifacts, [])
        XCTAssertNil(result.blocker)
        XCTAssertNil(result.plan)
        XCTAssertNil(result.notifyUser)
    }

    func testCompatibilityDefaultsStillRejectMalformedTypesAndSchemas() {
        for value in [
            #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":"Done."}"#,
            #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","attachments":{}}"#
        ] {
            XCTAssertThrowsError(try AgentEnvelopeParser.deliveryPlan(from: value))
        }
        XCTAssertThrowsError(try AgentEnvelopeParser.workerResult(from: #"{"schemaVersion":1,"kind":"worker_result","status":"completed","summary":"Verified.","artifacts":{}}"#))
        XCTAssertThrowsError(try AgentEnvelopeParser.workerResult(from: #"{"schemaVersion":2,"kind":"worker_result","status":"completed","summary":"Verified."}"#))
        XCTAssertThrowsError(try AgentEnvelopeParser.deliveryPlan(from: #"{"schemaVersion":2,"kind":"delivery_plan","status":"complete","messages":["Done."]}"#))
    }

    func testClarifyAllowsOmittedOrEmptyWorkerPromptButRejectsWork() throws {
        let omitted = try AgentEnvelopeParser.relayRequest(from: #"{"schemaVersion":1,"kind":"relay_request","action":"clarify","userMessage":"Which date?"}"#)
        XCTAssertNil(omitted.workerPrompt)
        let empty = try AgentEnvelopeParser.relayRequest(from: #"{"schemaVersion":1,"kind":"relay_request","action":"clarify","userMessage":"Which date?","workerPrompt":"  "}"#)
        XCTAssertEqual(empty.workerPrompt, "  ")
        XCTAssertThrowsError(try AgentEnvelopeParser.relayRequest(from: #"{"schemaVersion":1,"kind":"relay_request","action":"clarify","userMessage":"Which date?","workerPrompt":"Start researching"}"#))
    }
}
