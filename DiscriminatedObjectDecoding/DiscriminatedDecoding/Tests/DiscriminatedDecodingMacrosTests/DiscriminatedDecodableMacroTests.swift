#if os(macOS)
  import DiscriminatedDecodingMacros
  import MacroTesting
  import SwiftSyntaxMacroExpansion
  import Testing

  @Suite(
    .macros(
      [
        "DiscriminatedDecodable": MacroSpec(
          type: DiscriminatedDecodableMacro.self,
          conformances: ["Decodable", "CasePathable", "CasePathIterable"]
        )
      ],
      record: .failed
    )
  )
  struct DiscriminatedDecodableMacroTests {
    @Test func basics() {
      assertMacro {
        """
        @DiscriminatedDecodable
        enum Section {
          case first(First)
          case second(Second)
        }
        """
      } expansion: {
        #"""
        enum Section {
          case first(First)
          case second(Second)

          public struct AllCasePaths: CasePaths.CasePathReflectable, Swift.Sendable, Swift.Sequence {
            public subscript(root: Section) -> CasePaths.PartialCaseKeyPath<Section> {
              if root.is(\.first) {
                return \.first
              }
              if root.is(\.second) {
                return \.second
              }
              return \.never
            }
            public var first: CasePaths.AnyCasePath<Section, First> {
              ._$embed(Section.first) {
                guard case let .first(v0) = $0 else {
                  return nil
                }
                return v0
              }
            }
            public var second: CasePaths.AnyCasePath<Section, Second> {
              ._$embed(Section.second) {
                guard case let .second(v0) = $0 else {
                  return nil
                }
                return v0
              }
            }
            public func makeIterator() -> Swift.IndexingIterator<[CasePaths.PartialCaseKeyPath<Section>]> {
              var allCasePaths: [CasePaths.PartialCaseKeyPath<Section>] = []
              allCasePaths.append(\.first)
              allCasePaths.append(\.second)
              return allCasePaths.makeIterator()
            }
          }

          public static var allCasePaths: AllCasePaths {
            AllCasePaths()
          }
        }

        extension Section: CasePathable, CasePathIterable {
        }

        extension Section: Swift.Decodable {
          private enum CodingKeys: String, Swift.CodingKey {
            case kind, attributes
          }
          private enum Kind: String, Swift.Decodable {
            case first
            case second
          }
          init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .first:
              self = .first(try container.decode(First.self, forKey: .attributes))
            case .second:
              self = .second(try container.decode(Second.self, forKey: .attributes))
            }
          }
        }
        """#
      }
    }

    @Test func singleCase() {
      assertMacro {
        """
        @DiscriminatedDecodable
        enum Section {
          case only(Only)
        }
        """
      } expansion: {
        #"""
        enum Section {
          case only(Only)

          public struct AllCasePaths: CasePaths.CasePathReflectable, Swift.Sendable, Swift.Sequence {
            public subscript(root: Section) -> CasePaths.PartialCaseKeyPath<Section> {
              if root.is(\.only) {
                return \.only
              }
              return \.never
            }
            public var only: CasePaths.AnyCasePath<Section, Only> {
              ._$embed(Section.only) {
                guard case let .only(v0) = $0 else {
                  return nil
                }
                return v0
              }
            }
            public func makeIterator() -> Swift.IndexingIterator<[CasePaths.PartialCaseKeyPath<Section>]> {
              var allCasePaths: [CasePaths.PartialCaseKeyPath<Section>] = []
              allCasePaths.append(\.only)
              return allCasePaths.makeIterator()
            }
          }

          public static var allCasePaths: AllCasePaths {
            AllCasePaths()
          }
        }

        extension Section: CasePathable, CasePathIterable {
        }

        extension Section: Swift.Decodable {
          private enum CodingKeys: String, Swift.CodingKey {
            case kind, attributes
          }
          private enum Kind: String, Swift.Decodable {
            case only
          }
          init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .only:
              self = .only(try container.decode(Only.self, forKey: .attributes))
            }
          }
        }
        """#
      }
    }

    @Test func multipleCasesInOneDeclaration() {
      assertMacro {
        """
        @DiscriminatedDecodable
        enum Section {
          case first(First), second(Second)
        }
        """
      } expansion: {
        #"""
        enum Section {
          case first(First), second(Second)

          public struct AllCasePaths: CasePaths.CasePathReflectable, Swift.Sendable, Swift.Sequence {
            public subscript(root: Section) -> CasePaths.PartialCaseKeyPath<Section> {
              if root.is(\.first) {
                return \.first
              }
              if root.is(\.second) {
                return \.second
              }
              return \.never
            }
            public var first: CasePaths.AnyCasePath<Section, First> {
              ._$embed(Section.first) {
                guard case let .first(v0) = $0 else {
                  return nil
                }
                return v0
              }
            }
            public var second: CasePaths.AnyCasePath<Section, Second> {
              ._$embed(Section.second) {
                guard case let .second(v0) = $0 else {
                  return nil
                }
                return v0
              }
            }
            public func makeIterator() -> Swift.IndexingIterator<[CasePaths.PartialCaseKeyPath<Section>]> {
              var allCasePaths: [CasePaths.PartialCaseKeyPath<Section>] = []
              allCasePaths.append(\.first)
              allCasePaths.append(\.second)
              return allCasePaths.makeIterator()
            }
          }

          public static var allCasePaths: AllCasePaths {
            AllCasePaths()
          }
        }

        extension Section: CasePathable, CasePathIterable {
        }

        extension Section: Swift.Decodable {
          private enum CodingKeys: String, Swift.CodingKey {
            case kind, attributes
          }
          private enum Kind: String, Swift.Decodable {
            case first
            case second
          }
          init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .first:
              self = .first(try container.decode(First.self, forKey: .attributes))
            case .second:
              self = .second(try container.decode(Second.self, forKey: .attributes))
            }
          }
        }
        """#
      }
    }

    @Test func nonCaseMembersAreIgnored() {
      assertMacro {
        """
        @DiscriminatedDecodable
        enum Section {
          case first(First)
          case second(Second)

          var title: String { "" }
          struct First: Decodable {}
          struct Second: Decodable {}
        }
        """
      } expansion: {
        #"""
        enum Section {
          case first(First)
          case second(Second)

          var title: String { "" }
          struct First: Decodable {}
          struct Second: Decodable {}

          public struct AllCasePaths: CasePaths.CasePathReflectable, Swift.Sendable, Swift.Sequence {
            public subscript(root: Section) -> CasePaths.PartialCaseKeyPath<Section> {
              if root.is(\.first) {
                return \.first
              }
              if root.is(\.second) {
                return \.second
              }
              return \.never
            }
            public var first: CasePaths.AnyCasePath<Section, First> {
              ._$embed(Section.first) {
                guard case let .first(v0) = $0 else {
                  return nil
                }
                return v0
              }
            }
            public var second: CasePaths.AnyCasePath<Section, Second> {
              ._$embed(Section.second) {
                guard case let .second(v0) = $0 else {
                  return nil
                }
                return v0
              }
            }
            public func makeIterator() -> Swift.IndexingIterator<[CasePaths.PartialCaseKeyPath<Section>]> {
              var allCasePaths: [CasePaths.PartialCaseKeyPath<Section>] = []
              allCasePaths.append(\.first)
              allCasePaths.append(\.second)
              return allCasePaths.makeIterator()
            }
          }

          public static var allCasePaths: AllCasePaths {
            AllCasePaths()
          }
        }

        extension Section: CasePathable, CasePathIterable {
        }

        extension Section: Swift.Decodable {
          private enum CodingKeys: String, Swift.CodingKey {
            case kind, attributes
          }
          private enum Kind: String, Swift.Decodable {
            case first
            case second
          }
          init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .first:
              self = .first(try container.decode(First.self, forKey: .attributes))
            case .second:
              self = .second(try container.decode(Second.self, forKey: .attributes))
            }
          }
        }
        """#
      }
    }

    @Test func publicEnum() {
      assertMacro {
        """
        @DiscriminatedDecodable
        public enum Section {
          case first(First)
        }
        """
      } expansion: {
        #"""
        public enum Section {
          case first(First)

          public struct AllCasePaths: CasePaths.CasePathReflectable, Swift.Sendable, Swift.Sequence {
            public subscript(root: Section) -> CasePaths.PartialCaseKeyPath<Section> {
              if root.is(\.first) {
                return \.first
              }
              return \.never
            }
            public var first: CasePaths.AnyCasePath<Section, First> {
              ._$embed(Section.first) {
                guard case let .first(v0) = $0 else {
                  return nil
                }
                return v0
              }
            }
            public func makeIterator() -> Swift.IndexingIterator<[CasePaths.PartialCaseKeyPath<Section>]> {
              var allCasePaths: [CasePaths.PartialCaseKeyPath<Section>] = []
              allCasePaths.append(\.first)
              return allCasePaths.makeIterator()
            }
          }

          public static var allCasePaths: AllCasePaths {
            AllCasePaths()
          }
        }

        extension Section: CasePathable, CasePathIterable {
        }

        extension Section: Swift.Decodable {
          private enum CodingKeys: String, Swift.CodingKey {
            case kind, attributes
          }
          private enum Kind: String, Swift.Decodable {
            case first
          }
          init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .first:
              self = .first(try container.decode(First.self, forKey: .attributes))
            }
          }
        }
        """#
      }
    }

    @Test func nestedEnum() {
      assertMacro {
        """
        struct Screen {
          @DiscriminatedDecodable
          enum Section {
            case first(First)
          }
        }
        """
      } expansion: {
        #"""
        struct Screen {
          enum Section {
            case first(First)

            public struct AllCasePaths: CasePaths.CasePathReflectable, Swift.Sendable, Swift.Sequence {
              public subscript(root: Section) -> CasePaths.PartialCaseKeyPath<Section> {
                if root.is(\.first) {
                  return \.first
                }
                return \.never
              }
              public var first: CasePaths.AnyCasePath<Section, First> {
                ._$embed(Section.first) {
                  guard case let .first(v0) = $0 else {
                    return nil
                  }
                  return v0
                }
              }
              public func makeIterator() -> Swift.IndexingIterator<[CasePaths.PartialCaseKeyPath<Section>]> {
                var allCasePaths: [CasePaths.PartialCaseKeyPath<Section>] = []
                allCasePaths.append(\.first)
                return allCasePaths.makeIterator()
              }
            }

            public static var allCasePaths: AllCasePaths {
              AllCasePaths()
            }
          }
        }

        extension Screen.Section: CasePathable, CasePathIterable {
        }

        extension Screen.Section: Swift.Decodable {
          private enum CodingKeys: String, Swift.CodingKey {
            case kind, attributes
          }
          private enum Kind: String, Swift.Decodable {
            case first
          }
          init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .first:
              self = .first(try container.decode(First.self, forKey: .attributes))
            }
          }
        }
        """#
      }
    }

    @Test func qualifiedAndGenericPayloadTypes() {
      assertMacro {
        """
        @DiscriminatedDecodable
        enum Section {
          case first(Screen.First)
          case list([Item])
          case optional(Item?)
        }
        """
      } expansion: {
        #"""
        enum Section {
          case first(Screen.First)
          case list([Item])
          case optional(Item?)

          public struct AllCasePaths: CasePaths.CasePathReflectable, Swift.Sendable, Swift.Sequence {
            public subscript(root: Section) -> CasePaths.PartialCaseKeyPath<Section> {
              if root.is(\.first) {
                return \.first
              }
              if root.is(\.list) {
                return \.list
              }
              if root.is(\.optional) {
                return \.optional
              }
              return \.never
            }
            public var first: CasePaths.AnyCasePath<Section, Screen.First> {
              ._$embed(Section.first) {
                guard case let .first(v0) = $0 else {
                  return nil
                }
                return v0
              }
            }
            public var list: CasePaths.AnyCasePath<Section, [Item]> {
              ._$embed(Section.list) {
                guard case let .list(v0) = $0 else {
                  return nil
                }
                return v0
              }
            }
            public var optional: CasePaths.AnyCasePath<Section, Item?> {
              ._$embed(Section.optional) {
                guard case let .optional(v0) = $0 else {
                  return nil
                }
                return v0
              }
            }
            public func makeIterator() -> Swift.IndexingIterator<[CasePaths.PartialCaseKeyPath<Section>]> {
              var allCasePaths: [CasePaths.PartialCaseKeyPath<Section>] = []
              allCasePaths.append(\.first)
              allCasePaths.append(\.list)
              allCasePaths.append(\.optional)
              return allCasePaths.makeIterator()
            }
          }

          public static var allCasePaths: AllCasePaths {
            AllCasePaths()
          }
        }

        extension Section: CasePathable, CasePathIterable {
        }

        extension Section: Swift.Decodable {
          private enum CodingKeys: String, Swift.CodingKey {
            case kind, attributes
          }
          private enum Kind: String, Swift.Decodable {
            case first
            case list
            case optional
          }
          init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .first:
              self = .first(try container.decode(Screen.First.self, forKey: .attributes))
            case .list:
              self = .list(try container.decode([Item].self, forKey: .attributes))
            case .optional:
              self = .optional(try container.decode(Item?.self, forKey: .attributes))
            }
          }
        }
        """#
      }
    }

    @Test func labeledAssociatedValue() {
      assertMacro {
        """
        @DiscriminatedDecodable
        enum Section {
          case first(value: First)
        }
        """
      } expansion: {
        #"""
        enum Section {
          case first(value: First)

          public struct AllCasePaths: CasePaths.CasePathReflectable, Swift.Sendable, Swift.Sequence {
            public subscript(root: Section) -> CasePaths.PartialCaseKeyPath<Section> {
              if root.is(\.first) {
                return \.first
              }
              return \.never
            }
            public var first: CasePaths.AnyCasePath<Section, First> {
              ._$embed(Section.first) {
                guard case let .first(v0) = $0 else {
                  return nil
                }
                return v0
              }
            }
            public func makeIterator() -> Swift.IndexingIterator<[CasePaths.PartialCaseKeyPath<Section>]> {
              var allCasePaths: [CasePaths.PartialCaseKeyPath<Section>] = []
              allCasePaths.append(\.first)
              return allCasePaths.makeIterator()
            }
          }

          public static var allCasePaths: AllCasePaths {
            AllCasePaths()
          }
        }

        extension Section: CasePathable, CasePathIterable {
        }

        extension Section: Swift.Decodable {
          private enum CodingKeys: String, Swift.CodingKey {
            case kind, attributes
          }
          private enum Kind: String, Swift.Decodable {
            case first
          }
          init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .first:
              self = .first(try container.decode(First.self, forKey: .attributes))
            }
          }
        }
        """#
      }
    }

    @Test func availabilityIsPreserved() {
      assertMacro {
        """
        @available(macOS 13, *)
        @DiscriminatedDecodable
        enum Section {
          case first(First)
        }
        """
      } expansion: {
        #"""
        @available(macOS 13, *)
        enum Section {
          case first(First)

          public struct AllCasePaths: CasePaths.CasePathReflectable, Swift.Sendable, Swift.Sequence {
            public subscript(root: Section) -> CasePaths.PartialCaseKeyPath<Section> {
              if root.is(\.first) {
                return \.first
              }
              return \.never
            }
            public var first: CasePaths.AnyCasePath<Section, First> {
              ._$embed(Section.first) {
                guard case let .first(v0) = $0 else {
                  return nil
                }
                return v0
              }
            }
            public func makeIterator() -> Swift.IndexingIterator<[CasePaths.PartialCaseKeyPath<Section>]> {
              var allCasePaths: [CasePaths.PartialCaseKeyPath<Section>] = []
              allCasePaths.append(\.first)
              return allCasePaths.makeIterator()
            }
          }

          public static var allCasePaths: AllCasePaths {
            AllCasePaths()
          }
        }

        @available(macOS 13, *) extension Section: CasePathable, CasePathIterable {
        }

        @available(macOS 13, *) extension Section: Swift.Decodable {
          private enum CodingKeys: String, Swift.CodingKey {
            case kind, attributes
          }
          private enum Kind: String, Swift.Decodable {
            case first
          }
          init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .first:
              self = .first(try container.decode(First.self, forKey: .attributes))
            }
          }
        }
        """#
      }
    }

    @Test func enumWithInheritanceClause() {
      assertMacro {
        """
        @DiscriminatedDecodable
        enum Section: Equatable, Sendable {
          case first(First)
        }
        """
      } expansion: {
        #"""
        enum Section: Equatable, Sendable {
          case first(First)

          public struct AllCasePaths: CasePaths.CasePathReflectable, Swift.Sendable, Swift.Sequence {
            public subscript(root: Section) -> CasePaths.PartialCaseKeyPath<Section> {
              if root.is(\.first) {
                return \.first
              }
              return \.never
            }
            public var first: CasePaths.AnyCasePath<Section, First> {
              ._$embed(Section.first) {
                guard case let .first(v0) = $0 else {
                  return nil
                }
                return v0
              }
            }
            public func makeIterator() -> Swift.IndexingIterator<[CasePaths.PartialCaseKeyPath<Section>]> {
              var allCasePaths: [CasePaths.PartialCaseKeyPath<Section>] = []
              allCasePaths.append(\.first)
              return allCasePaths.makeIterator()
            }
          }

          public static var allCasePaths: AllCasePaths {
            AllCasePaths()
          }
        }

        extension Section: CasePathable, CasePathIterable {
        }

        extension Section: Swift.Decodable {
          private enum CodingKeys: String, Swift.CodingKey {
            case kind, attributes
          }
          private enum Kind: String, Swift.Decodable {
            case first
          }
          init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .first:
              self = .first(try container.decode(First.self, forKey: .attributes))
            }
          }
        }
        """#
      }
    }

    @Test func alreadyCasePathable() {
      assertMacro {
        """
        @CasePathable
        @DiscriminatedDecodable
        enum Section {
          case first(First)
        }
        """
      } expansion: {
        """
        @CasePathable
        enum Section {
          case first(First)
        }

        extension Section: Swift.Decodable {
          private enum CodingKeys: String, Swift.CodingKey {
            case kind, attributes
          }
          private enum Kind: String, Swift.Decodable {
            case first
          }
          init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .first:
              self = .first(try container.decode(First.self, forKey: .attributes))
            }
          }
        }
        """
      }
    }

    @Test func noAssociatedValue() {
      assertMacro {
        """
        @DiscriminatedDecodable
        enum Section {
          case first(First)
          case empty
        }
        """
      } diagnostics: {
        """
        @DiscriminatedDecodable
        enum Section {
          case first(First)
          case empty
               ┬────
               ╰─ 🛑 @DiscriminatedDecodable requires each case to have exactly one associated value
        }
        """
      }
    }

    @Test func multipleAssociatedValues() {
      assertMacro {
        """
        @DiscriminatedDecodable
        enum Section {
          case pair(First, Second)
        }
        """
      } diagnostics: {
        """
        @DiscriminatedDecodable
        enum Section {
          case pair(First, Second)
               ┬──────────────────
               ╰─ 🛑 @DiscriminatedDecodable requires each case to have exactly one associated value
        }
        """
      }
    }

    @Test func alreadyDecodableOnlyAddsCasePaths() {
      assertMacro(
        [
          "DiscriminatedDecodable": MacroSpec(
            type: DiscriminatedDecodableMacro.self,
            conformances: ["CasePathable", "CasePathIterable"]
          )
        ]
      ) {
        """
        @DiscriminatedDecodable
        enum Section: Decodable {
          case first(First)
        }
        """
      } expansion: {
        #"""
        enum Section: Decodable {
          case first(First)

          public struct AllCasePaths: CasePaths.CasePathReflectable, Swift.Sendable, Swift.Sequence {
            public subscript(root: Section) -> CasePaths.PartialCaseKeyPath<Section> {
              if root.is(\.first) {
                return \.first
              }
              return \.never
            }
            public var first: CasePaths.AnyCasePath<Section, First> {
              ._$embed(Section.first) {
                guard case let .first(v0) = $0 else {
                  return nil
                }
                return v0
              }
            }
            public func makeIterator() -> Swift.IndexingIterator<[CasePaths.PartialCaseKeyPath<Section>]> {
              var allCasePaths: [CasePaths.PartialCaseKeyPath<Section>] = []
              allCasePaths.append(\.first)
              return allCasePaths.makeIterator()
            }
          }

          public static var allCasePaths: AllCasePaths {
            AllCasePaths()
          }
        }

        extension Section: CasePathable, CasePathIterable {
        }
        """#
      }
    }

    @Test func dynamicMemberLookup() {
      assertMacro {
        """
        @DiscriminatedDecodable
        @dynamicMemberLookup
        enum Section {
          case first(First)
        }
        """
      } expansion: {
        #"""
        @dynamicMemberLookup
        enum Section {
          case first(First)

          public struct AllCasePaths: CasePaths.CasePathReflectable, Swift.Sendable, Swift.Sequence {
            public subscript(root: Section) -> CasePaths.PartialCaseKeyPath<Section> {
              if root.is(\.first) {
                return \.first
              }
              return \.never
            }
            public var first: CasePaths.AnyCasePath<Section, First> {
              ._$embed(Section.first) {
                guard case let .first(v0) = $0 else {
                  return nil
                }
                return v0
              }
            }
            public func makeIterator() -> Swift.IndexingIterator<[CasePaths.PartialCaseKeyPath<Section>]> {
              var allCasePaths: [CasePaths.PartialCaseKeyPath<Section>] = []
              allCasePaths.append(\.first)
              return allCasePaths.makeIterator()
            }
          }

          public static var allCasePaths: AllCasePaths {
            AllCasePaths()
          }
        }

        extension Section: CasePathable, CasePathIterable {
        }

        extension Section: Swift.Decodable {
          private enum CodingKeys: String, Swift.CodingKey {
            case kind, attributes
          }
          private enum Kind: String, Swift.Decodable {
            case first
          }
          init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .first:
              self = .first(try container.decode(First.self, forKey: .attributes))
            }
          }
        }
        """#
      }
    }

    @Test func notAnEnum() {
      assertMacro {
        """
        @DiscriminatedDecodable
        struct Section {}
        """
      } diagnostics: {
        """
        @DiscriminatedDecodable
        ╰─ 🛑 @DiscriminatedDecodable can only be applied to an enum
        struct Section {}
        """
      }
    }
  }
#endif
