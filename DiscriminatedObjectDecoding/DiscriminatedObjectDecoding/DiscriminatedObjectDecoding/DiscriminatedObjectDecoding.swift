import CasePaths
import DiscriminatedDecoding
import Foundation

@main
struct DiscriminatedObjectDecoding {
    static func main() async throws {
        try print(JSONDecoder().decode(Screen.self, from: screenJSON))
    }
}

struct Screen {
    var sections: [Section]

    @DiscriminatedDecodable
    @dynamicMemberLookup
    enum Section {
        case first(First)
        case second(Second)

        struct First: Decodable {
            var id: UUID
            var description: String
        }

        struct Second: Decodable {
            var id: UUID
            var title: String
        }
    }
}

extension Screen.Section: Identifiable {
    var id: UUID {
        switch self {
        case let .first(first): first.id
        case let .second(second): second.id
        }
    }
}

extension Screen: Decodable {}

let screenJSON = Data("""
{
  "sections": [
    { "kind": "first", "attributes": { "id": "1B4E28BA-2FA1-4D3B-8C5E-0A1F6E3D9A01", "description": "The first section" } },
    { "kind": "second", "attributes": { "id": "7C9E6679-7425-40DE-944B-E07FC1F90AE7", "title": "The second section" } },
    { "kind": "first", "attributes": { "id": "A3F1C2D4-5B6E-4F70-9A81-B2C3D4E5F607", "description": "Another first section" } }
  ]
}
""".utf8)
