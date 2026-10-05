import Foundation
import Testing
@testable import ThoughtReps

@Suite("SearchQuery")
struct SearchQueryTests {
    @Test func eachWordBecomesAQuotedPrefixTerm() {
        #expect(SearchQuery.matchExpression(for: "swift") == "\"swift\"*")
        #expect(SearchQuery.matchExpression(for: "swift ui  data") == "\"swift\"* \"ui\"* \"data\"*")
    }

    @Test func emptyOrPunctuationOnlyInputHasNoQuery() {
        #expect(SearchQuery.matchExpression(for: "") == nil)
        #expect(SearchQuery.matchExpression(for: "   \n\t") == nil)
        #expect(SearchQuery.matchExpression(for: "\"*()-:^") == nil)
    }

    @Test func quotesAndSyntaxCharactersNeverReachTheExpression() {
        #expect(SearchQuery.matchExpression(for: "say \"hello\" world") == "\"say\"* \"hello\"* \"world\"*")
        #expect(SearchQuery.matchExpression(for: "title:foo* -bar (baz) ^qux") == "\"title\"* \"foo\"* \"bar\"* \"baz\"* \"qux\"*")
        #expect(SearchQuery.matchExpression(for: "a\" OR \"1\"=\"1") == "\"a\"* \"OR\"* \"1\"* \"1\"*")
    }

    @Test func operatorWordsAreSearchedAsPlainWords() {
        #expect(SearchQuery.matchExpression(for: "cats AND dogs") == "\"cats\"* \"AND\"* \"dogs\"*")
        #expect(SearchQuery.matchExpression(for: "NOT NEAR OR") == "\"NOT\"* \"NEAR\"* \"OR\"*")
    }

    @Test func privateUseCharactersCountAsWordCharacters() {
        #expect(SearchQuery.terms("a\u{E000}b") == ["a\u{E000}b"])
    }

    @Test func accentsAndOtherScriptsAreKept() {
        #expect(SearchQuery.terms("caf\u{E9} \u{65E5}\u{672C}\u{8A9E} \u{43F}\u{440}\u{438}\u{432}\u{435}\u{442}") == ["caf\u{E9}", "\u{65E5}\u{672C}\u{8A9E}", "\u{43F}\u{440}\u{438}\u{432}\u{435}\u{442}"])
        #expect(SearchQuery.terms("cafe\u{301}") == ["cafe\u{301}"])
    }

    @Test func hashtagsSearchByTheirWord() {
        #expect(SearchQuery.terms("#swift-ui") == ["swift", "ui"])
    }

    @Test func termCountAndLengthAreCapped() {
        let many = (1...20).map { "w\($0)" }.joined(separator: " ")
        #expect(SearchQuery.terms(many).count == SearchQuery.maxTerms)
        #expect(SearchQuery.terms(String(repeating: "a", count: 500))[0].count == SearchQuery.maxTermLength)
    }
}
