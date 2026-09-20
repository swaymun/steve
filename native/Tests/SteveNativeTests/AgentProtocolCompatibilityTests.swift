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

    func testDeliveryAcceptsTextOnlyRelayClarificationWithoutChangingText() throws {
        let result = try AgentEnvelopeParser.deliveryPlan(from: #"{"schemaVersion":1,"kind":"relay_request","action":"clarify","userMessage":"Please confirm the date.\nKeep the 2–4 PM window?","workerPrompt":null,"taskID":null,"taskTitle":null,"mode":null,"workerContextAction":"reuse"}"#)
        XCTAssertEqual(result.schemaVersion, 1)
        XCTAssertEqual(result.kind, "delivery_plan")
        XCTAssertEqual(result.status, .needsClarification)
        XCTAssertEqual(result.messages, ["Please confirm the date.\nKeep the 2–4 PM window?"])
        XCTAssertTrue(result.attachments.isEmpty)
        XCTAssertNil(result.recovery)
    }

    func testDeliveryAcceptsTextOnlyRelayReplyAndRefusal() throws {
        for (action, status) in [("reply", DeliveryStatus.complete), ("refuse", .failed)] {
            let result = try AgentEnvelopeParser.deliveryPlan(from: """
            {"schemaVersion":1,"kind":"relay_request","action":"\(action)","userMessage":"  Exact reply.  ","workerPrompt":"  ","control":null,"memoryUpdates":[]}
            """)
            XCTAssertEqual(result.status, status)
            XCTAssertEqual(result.messages, ["  Exact reply.  "])
            XCTAssertTrue(result.attachments.isEmpty)
            XCTAssertNil(result.recovery)
        }
    }

    func testDeliveryRejectsActionBearingRelayRequests() {
        for payload in [
            #"{"schemaVersion":1,"kind":"relay_request","action":"execute","userMessage":"Working.","workerPrompt":"Send an email."}"#,
            #"{"schemaVersion":1,"kind":"relay_request","action":"cancel","userMessage":"Cancelled.","taskID":"task-1"}"#,
            #"{"schemaVersion":1,"kind":"relay_request","action":"control","userMessage":"Saved.","control":{"operation":"preference_set","userQuote":"Remember concise replies","key":"style","value":"concise"}}"#,
            #"{"schemaVersion":1,"kind":"relay_request","action":"reply","userMessage":"Done.","workerPrompt":"Send an email."}"#,
            #"{"schemaVersion":1,"kind":"relay_request","action":"clarify","userMessage":"Which date?","control":{"operation":"schedule_list","userQuote":"List reminders"}}"#,
            #"{"schemaVersion":1,"kind":"relay_request","action":"refuse","userMessage":"Cannot do that.","memoryUpdates":[{"operation":"preference_set","userQuote":"Remember concise replies","key":"style","value":"concise"}]}"#
        ] {
            XCTAssertThrowsError(try AgentEnvelopeParser.deliveryPlan(from: payload), payload)
        }
    }

    func testRelayDeliveryCompatibilityRejectsMalformedTypesAndSchemas() throws {
        let invalidFields: [(String, Any)] = [("schemaVersion", 2), ("schemaVersion", "1"), ("schemaVersion", true),
            ("kind", "delivery_plan"), ("kind", "worker_result"), ("action", "unknown"), ("action", 1),
            ("userMessage", []), ("userMessage", "  "), ("userMessage", NSNull()), ("workerPrompt", true),
            ("control", ""), ("control", [:]), ("memoryUpdates", [:]), ("workerContextAction", "unknown"),
            ("taskID", 1), ("taskTitle", []), ("mode", ["computer"])]
        for (key, value) in invalidFields {
            var payload: [String: Any] = ["schemaVersion": 1, "kind": "relay_request", "action": "clarify", "userMessage": "Which date?"]
            payload[key] = value
            let text = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            XCTAssertThrowsError(try AgentEnvelopeParser.deliveryPlan(from: text), text)
        }
    }
}
