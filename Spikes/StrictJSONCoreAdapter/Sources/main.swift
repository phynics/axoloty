// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import _JSONCore

func name(_ reason: AdapterFailure.Reason) -> String { switch reason { case .size: return "size"; case .lexical: return "lexical"; case .utf8: return "utf8"; case .control: return "control"; case .escape: return "escape"; case .depth: return "depth"; case .duplicate: return "duplicate"; case .number: return "number"; case .trailing: return "trailing"; case .parser: return "parser" } }
func decode(_ input: [UInt8]) throws(AdapterFailure) -> AdapterResult { do { return try input.withUnsafeBufferPointer { var adapter = StrictJSONCoreAdapter(bytes: $0); return try adapter.decode() } } catch let error as AdapterFailure { throw error } catch { throw AdapterFailure(reason: .parser, offset: 0) } }
let asc = Array(#"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444","updateRate":250}"#.utf8)
let iov = Array(#"{"payload":{"temp":23.5,"unit":"C"}}"#.utf8)
let deep = "{\"payload\":" + String(repeating: "{\"a\":", count: 9) + "1" + String(repeating: "}", count: 9) + "}"
let malformed: [(String, [UInt8])] = [("empty", []), ("invalid-escape", Array(#"{"payload":"\x"}"#.utf8)), ("invalid-number", Array(#"{"payload":--}"#.utf8)), ("invalid-literal", Array(#"{"payload":tru}"#.utf8)), ("duplicate", Array(#"{"payload":1,"payload":2}"#.utf8)), ("leading-zero", Array(#"{"payload":01}"#.utf8)), ("lone-surrogate", Array(#"{"payload":"\uD800"}"#.utf8)), ("depth", Array(deep.utf8)), ("bad-utf8", [123,34,112,97,121,108,111,97,100,34,58,34,255,34,125]), ("trailing", Array(#"{"payload":1}extra"#.utf8))]
do { let a = try decode(asc); let v = try decode(iov); guard a.sourceID != nil, a.actorID != nil, a.updateRate != nil, v.payload?.lowerBound == 11, v.payload?.upperBound == 35 else { fatalError("representative range failure") }; print("PASS ASC tokens=\(a.tokenCount), IOV raw=\(v.payload!)") } catch { fatalError("valid: \(error)") }
for (label, bytes) in malformed { do { _ = try decode(bytes); fatalError("accepted \(label)") } catch let error { print("PASS \(label): \(name(error.reason)) at byte \(error.offset)") } }
