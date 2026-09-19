import XCTest
@testable import JRCore

final class JRCoreTests: XCTestCase {
    func testPointer() {
        let s: JSONValue = .object(["user": .object(["name": .string("Ada")]), "todos": .array([.object(["title": .string("Buy")])])])
        XCTAssertEqual(getByPath(s, "/user/name"), .string("Ada"))
        XCTAssertEqual(getByPath(s, "/todos/0/title"), .string("Buy"))
        XCTAssertNil(getByPath(s, "/missing"))
        XCTAssertNil(getByPath(s, "no-slash"))
    }
    func testVisibility() {
        let ctx = EvalContext(state: ["role": .string("admin"), "n": .int(5)])
        XCTAssertTrue(evaluateVisibility(try? JSONDecoder().decode(VisibilityCondition.self, from: #"{"$state":"/role","eq":"admin"}"#.data(using: .utf8)!), ctx: ctx))
        XCTAssertFalse(evaluateVisibility(try? JSONDecoder().decode(VisibilityCondition.self, from: #"{"$state":"/n","gt":10}"#.data(using: .utf8)!), ctx: ctx))
        // precedence: only first op evaluated — decode keeps first
        XCTAssertTrue(evaluateVisibility(.and([.bool(true), .bool(true)]), ctx: ctx))
        XCTAssertTrue(evaluateVisibility(.or([.bool(false), .bool(true)]), ctx: ctx))
    }
    func testResolve() {
        let ctx = EvalContext(state: ["user": .object(["name": .string("Ada")])])
        XCTAssertEqual(resolvePropValue(.object(["$state": .string("/user/name")]), ctx: ctx).value, .string("Ada"))
        XCTAssertEqual(resolvePropValue(.object(["$template": .string("Hi ${\"/user/name\"}")]), ctx: ctx).value.stringValue?.isEmpty, false)
        XCTAssertEqual(resolvePropValue(.object(["$template": .string("Hi ${/user/name}!")]), ctx: ctx).value, .string("Hi Ada!"))
        XCTAssertEqual(resolvePropValue(.object(["$template": .string("x ${/missing} y")]), ctx: ctx).value, .string("x  y"))
    }
    func testStream() {
        let jsonl = """
        {"op":"add","path":"/root","value":"a"}
        {"op":"add","path":"/elements/a","value":{"type":"Text","props":{"content":"hi"}}}
        """
        let s = compileSpecStream(jsonl)
        XCTAssertEqual(s.root, "a")
        XCTAssertEqual(s.elements["a"]?.type, "Text")
    }
    func testValidation() {
        XCTAssertEqual(validateField(value: .string(""), checks: [.init(type: "required", message: "req")]), ["req"])
        XCTAssertEqual(validateField(value: .string("a@b.co"), checks: [.init(type: "email", message: "bad")]), [])
        XCTAssertEqual(validateField(value: .string("abc"), checks: [.init(type: "minLength", args: ["min": .int(5)], message: "short")]), ["short"])
    }
    func testSpecIssues() {
        var s = Spec(root: "a", elements: ["a": .init(type: "Text", props: ["content": .string("hi")])])
        XCTAssertTrue(validateSpec(s).valid)
        s.elements["b"] = .init(type: "Text", props: [:])
        XCTAssertFalse(validateSpec(s).valid) // unreachable
    }
}
