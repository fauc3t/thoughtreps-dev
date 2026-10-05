import Foundation
import SwiftData
import os

/// Read-only check that the search index holds exactly what the store implies. Like
/// `IntegrityChecker` it loads every thought, so it is for DEBUG launches and tests only.
@MainActor
enum SearchIndexChecker {
    private static let logger = Logger(subsystem: "com.thoughtreps", category: "integrity")

    static func logViolations(in context: ModelContext, index: SearchIndex = .shared) async {
        do {
            for violation in try await check(context, index: index) {
                logger.error("Search index violation: \(violation)")
            }
        } catch {
            logger.error("Search index check failed to fetch: \(error)")
        }
    }

    static func check(_ context: ModelContext, index: SearchIndex = .shared) async throws -> [String] {
        let documents = try context.fetch(FetchDescriptor<Thought>()).map { SearchDocument($0) }
        var found: [String] = []
        let entries = await index.entries()
        let expectedIDs = Set(documents.map(\.id))
        for id in Set(entries.keys).subtracting(expectedIDs) {
            found.append("Index row \(id) has no thought")
        }
        for document in documents {
            guard let stored = await index.document(for: document.id) else {
                found.append("Thought \(document.id) is not indexed")
                continue
            }
            if stored != document {
                found.append("Thought \(document.id) index row differs from the store: \(stored) != \(document)")
            }
        }
        return found
    }
}
