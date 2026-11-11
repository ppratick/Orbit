import XCTest
@testable import OrbitKit

final class OrbitKitTests: XCTestCase {
    func testDecodesSyncPayloadWithSnakeCaseAndNestedParams() throws {
        let json = """
        {"cursor":42,"reset":false,"has_more":false,"deleted":{"message":["msg_x"]},
         "changes":{"task":[{"id":"task_1","action":"calendar.create_event","target":"apple","status":"queued","summary":"Add",
           "params":{"title":"Dentist","start":"2026-11-13T09:00:00-05:00","all_day":true},"result":null,"error":null,
           "approval_id":null,"conversation_id":"conv_1","lease_device_id":null,"attempts":0,"created_at":1,"updated_at":2,"completed_at":null}],
          "memory":[{"id":"mem_1","kind":"fact","content":"x","source":"user","source_ref":null,"created_at":1,"updated_at":1,"deleted_at":null}]}}
        """
        let r = try JSONDecoder.orbit.decode(SyncResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.cursor, 42)
        let t = try XCTUnwrap(r.changes.task?.first)
        // Snake-case keys inside arbitrary JSON are camel-cased by the decoder; lookups accept both.
        XCTAssertEqual(t.params["all_day"]?.bool, true)
        XCTAssertEqual(t.params["title"]?.string, "Dentist")
        XCTAssertEqual(r.deleted["message"], ["msg_x"])
    }

    func testISOParsing() {
        XCTAssertNotNil(ISO.parse("2026-11-13T09:00:00-05:00"))
        XCTAssertNotNil(ISO.parse("2026-11-13T14:00:00.123Z"))
        XCTAssertNil(ISO.parse("tomorrow"))
    }

    func testCamelCase() {
        XCTAssertEqual(JSONValue.camelCase("in_reply_to"), "inReplyTo")
        XCTAssertEqual(JSONValue.camelCase("title"), "title")
    }
}
