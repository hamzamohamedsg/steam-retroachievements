#if os(Windows)
import Foundation
import Testing
@testable import RACore

@Test func dpapiRoundTripsAndHidesTheKey() throws {
    let secret = Data("0123456789abcdef-api-key".utf8)
    let blob = try #require(Dpapi.protect(secret))
    #expect(blob != secret)
    #expect(blob.range(of: secret) == nil)
    #expect(Dpapi.unprotect(blob) == secret)
}

@Test func dpapiRejectsGarbage() {
    #expect(Dpapi.unprotect(Data("not encrypted".utf8)) == nil)
}
#endif
