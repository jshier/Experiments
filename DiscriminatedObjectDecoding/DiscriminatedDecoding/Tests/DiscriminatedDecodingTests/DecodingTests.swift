import DiscriminatedDecoding
import Foundation
import Testing

@DiscriminatedDecodable
private enum Section: Equatable {
    case first(First)
    case second(Second)

    struct First: Decodable, Equatable {
        var id: UUID
        var description: String
    }

    struct Second: Decodable, Equatable {
        var id: UUID
        var title: String
    }
}

@DiscriminatedDecodable
@dynamicMemberLookup
private enum DynamicSection {
    case first(Section.First)
    case second(Section.Second)
}

@Suite struct DecodingTests {
    let firstID = UUID()
    let secondID = UUID()

    @Test func decodesDiscriminatedSections() throws {
        let json = Data("""
        [
          { "kind": "first", "attributes": { "id": "\(firstID)", "description": "one" } },
          { "kind": "second", "attributes": { "id": "\(secondID)", "title": "two" } }
        ]
        """.utf8)

        let sections = try JSONDecoder().decode([Section].self, from: json)

        #expect(sections == [
            .first(.init(id: firstID, description: "one")),
            .second(.init(id: secondID, title: "two")),
        ])
    }

    @Test func appliesCasePathable() throws {
        let section = Section.first(.init(id: firstID, description: "one"))

        #expect(section[case: \.first]?.description == "one")
        #expect(section[case: \.second] == nil)
        #expect(Array(Section.allCasePaths).count == 2)
    }

    @Test func supportsExplicitDynamicMemberLookup() throws {
        let section = DynamicSection.first(.init(id: firstID, description: "one"))

        #expect(section.first?.description == "one")
        #expect(section.second == nil)
        #expect([section].compactMap(\.first).count == 1)
    }

    @Test func throwsOnUnknownKind() {
        let json = Data(#"{ "kind": "third", "attributes": {} }"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Section.self, from: json)
        }
    }
}
