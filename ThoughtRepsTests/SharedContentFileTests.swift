import Foundation
import Testing
@testable import ThoughtReps

@Suite struct SharedFileTextTests {
    @Test func decodesVerbatim() throws {
        let text = try SharedContent.text(fromFileData: Data("# Title\n\n- a\n  - b\n".utf8))
        #expect(text == "# Title\n\n- a\n  - b\n")
    }

    @Test func stripsBOM() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("hi".utf8)
        #expect(try SharedContent.text(fromFileData: data) == "hi")
    }

    @Test func normalizesLineEndings() throws {
        #expect(try SharedContent.text(fromFileData: Data("a\r\nb\rc\nd".utf8)) == "a\nb\nc\nd")
    }

    @Test func stripsBOMAndNormalizesCRLF() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb\r\n".utf8)
        #expect(try SharedContent.text(fromFileData: data) == "a\nb\n")
    }

    @Test func classifiesProviders() {
        #expect(SharedContent.textType(in: ["public.plain-text"]) != nil)
        #expect(SharedContent.textType(in: ["net.daringfireball.markdown"]) != nil)
        #expect(SharedContent.textType(in: ["public.jpeg"]) == nil)
        #expect(!SharedContent.isFile(typeIdentifiers: ["public.utf8-plain-text", "public.plain-text"]))
        #expect(SharedContent.isFile(typeIdentifiers: ["net.daringfireball.markdown"]))
        #expect(SharedContent.isFile(typeIdentifiers: ["public.plain-text", "public.file-url"]))
    }

    @Test func rejectsInvalidUTF8() {
        #expect(throws: SharedContent.FileError.notUTF8) {
            try SharedContent.text(fromFileData: Data([0xFF, 0xFE, 0x41]))
        }
    }

    @Test func sizeLimit() throws {
        let ok = Data(repeating: 0x61, count: SharedContent.maxFileBytes)
        #expect(try SharedContent.text(fromFileData: ok).count == SharedContent.maxFileBytes)
        #expect(throws: SharedContent.FileError.tooLarge) {
            try SharedContent.text(fromFileData: ok + Data([0x61]))
        }
    }
}
