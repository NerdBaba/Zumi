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

    func testPointerEscapingAndStrictArrayIndices() {
        let value: JSONValue = .object(["a/b~c": .array([.string("first"), .string("second")])])
        XCTAssertEqual(getByPath(value, "/a~1b~0c/1"), .string("second"))
        XCTAssertNil(getByPath(value, "/a~1b~0c/01"))
        XCTAssertNil(getByPath(value, "/a~1b~2c"))
    }

    func testJSONPatchUsesRFC6902ArrayAndFailureSemantics() {
        var value: JSONValue = .object(["items": .array([.string("a"), .string("c")])])
        XCTAssertTrue(applyJSONPatch(&value, .init(op: "add", path: "/items/1", value: .string("b"), from: nil)))
        XCTAssertEqual(getByPath(value, "/items"), .array([.string("a"), .string("b"), .string("c")]))

        XCTAssertTrue(applyJSONPatch(&value, .init(op: "move", path: "/items/0", value: nil, from: "/items/2")))
        XCTAssertEqual(getByPath(value, "/items"), .array([.string("c"), .string("a"), .string("b")]))

        let before = value
        XCTAssertFalse(applyJSONPatch(&value, .init(op: "add", path: "/missing/child", value: .bool(true), from: nil)))
        XCTAssertEqual(value, before)
    }

    func testDiffEscapesPointerKeysAndRoundTrips() {
        let old: JSONValue = .object(["a/b~c": .string("old")])
        let new: JSONValue = .object(["a/b~c": .string("new")])
        let patches = diffToPatches(old: old, new: new)
        XCTAssertEqual(patches.first?.path, "/a~1b~0c")
        var result = old
        for patch in patches { XCTAssertTrue(applyJSONPatch(&result, patch)) }
        XCTAssertEqual(result, new)
    }

    func testValidationRejectsSharedChildren() {
        let spec = Spec(
            root: "root",
            elements: [
                "root": .init(type: "VStack", children: ["leaf", "leaf"]),
                "leaf": .init(type: "Text", props: ["content": .string("hi")]),
            ]
        )
        XCTAssertFalse(validateSpec(spec).valid)
        XCTAssertTrue(validateSpec(spec).issues.contains { $0.message.contains("more than once") })
    }

}
