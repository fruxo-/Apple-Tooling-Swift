import Foundation
import SQLite3
import Testing

@testable import VoiceMemosKit

// MARK: - Helpers

private func moment(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    Calendar.current.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func startOfDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.startOfDay(for: moment(year, month, day))
}

// MARK: - SearchExpression

@Suite("SearchExpression parsing")
struct SearchExpressionParsingTests {
    private static let foo = SearchExpression.term("foo")
    private static let bar = SearchExpression.term("bar")
    private static let alice = SearchExpression.term("alice")
    private static let bob = SearchExpression.term("bob")

    @Test func singleTerm() throws {
        #expect(try SearchExpression.parse("foo") == .term("foo"))
        #expect(try SearchExpression.parse("  foo  ") == .term("foo"))
    }

    @Test func andChainsAreFlattened() throws {
        let parsed = try SearchExpression.parse("foo and bar and alice")
        #expect(parsed == .and([Self.foo, Self.bar, Self.alice]))
    }

    @Test func orChainsAreFlattened() throws {
        let parsed = try SearchExpression.parse("foo or bar or alice")
        #expect(parsed == .or([Self.foo, Self.bar, Self.alice]))
    }

    @Test func andBindsTighterThanOr() throws {
        #expect(try SearchExpression.parse("foo or bar and alice") == .or([Self.foo, .and([Self.bar, Self.alice])]))
        #expect(try SearchExpression.parse("foo and bar or alice") == .or([.and([Self.foo, Self.bar]), Self.alice]))
    }

    @Test func parenthesesOverridePrecedence() throws {
        #expect(try SearchExpression.parse("(foo or bar) and alice") == .and([.or([Self.foo, Self.bar]), Self.alice]))
    }

    @Test func groupedExpressionFromTheRequirements() throws {
        let parsed = try SearchExpression.parse("(foo and bar) or (alice and bob)")
        #expect(parsed == .or([.and([Self.foo, Self.bar]), .and([Self.alice, Self.bob])]))
    }

    @Test func redundantParenthesesCollapse() throws {
        #expect(try SearchExpression.parse("((foo))") == Self.foo)
    }

    @Test func operatorsAreCaseInsensitive() throws {
        let parsed = try SearchExpression.parse("foo AND bar Or alice")
        #expect(parsed == .or([.and([Self.foo, Self.bar]), Self.alice]))
    }

    @Test func parenthesesNeedNoSurroundingSpaces() throws {
        #expect(try SearchExpression.parse("(foo)and(bar)") == .and([Self.foo, Self.bar]))
    }

    @Test func quotedPhrasesAreSingleTerms() throws {
        let parsed = try SearchExpression.parse("\"team meeting\" and budget")
        #expect(parsed == .and([.term("team meeting"), .term("budget")]))
    }

    @Test func quotedOperatorWordsAreOrdinaryTerms() throws {
        #expect(try SearchExpression.parse("\"and\" or foo") == .or([.term("and"), Self.foo]))
        #expect(try SearchExpression.parse("\"OR\"") == .term("OR"))
    }

    @Test func quotedPhrasesSupportEscapes() throws {
        #expect(try SearchExpression.parse(#""say \"hi\"""#) == .term(#"say "hi""#))
        #expect(try SearchExpression.parse(#""back\\slash""#) == .term(#"back\slash"#))
    }

    @Test func rejectsEmptyExpressions() {
        #expect(throws: SearchExpressionError.empty) { try SearchExpression.parse("") }
        #expect(throws: SearchExpressionError.empty) { try SearchExpression.parse("   ") }
    }

    @Test func rejectsAdjacentTermsWithoutAnOperator() {
        #expect(throws: SearchExpressionError.missingOperator(before: "bar", column: 5)) {
            try SearchExpression.parse("foo bar")
        }
        #expect(throws: SearchExpressionError.missingOperator(before: "bar", column: 6)) {
            try SearchExpression.parse("(foo bar)")
        }
    }

    @Test func rejectsDanglingOrLeadingOperators() {
        #expect(throws: SearchExpressionError.expectedTerm(found: nil, column: 8)) {
            try SearchExpression.parse("foo and")
        }
        #expect(throws: SearchExpressionError.expectedTerm(found: "'and'", column: 1)) {
            try SearchExpression.parse("and foo")
        }
        #expect(throws: SearchExpressionError.expectedTerm(found: "'or'", column: 9)) {
            try SearchExpression.parse("foo and or bar")
        }
    }

    @Test func rejectsUnbalancedParentheses() {
        #expect(throws: SearchExpressionError.unmatchedOpeningParenthesis(column: 1)) {
            try SearchExpression.parse("(foo")
        }
        #expect(throws: SearchExpressionError.unmatchedClosingParenthesis(column: 4)) {
            try SearchExpression.parse("foo)")
        }
    }

    @Test func rejectsBadQuotes() {
        #expect(throws: SearchExpressionError.unterminatedQuote(column: 1)) {
            try SearchExpression.parse("\"foo")
        }
        #expect(throws: SearchExpressionError.emptyQuotedTerm(column: 1)) {
            try SearchExpression.parse("\"\"")
        }
    }
}

@Suite("SearchExpression matching")
struct SearchExpressionMatchingTests {
    private func matches(_ expression: String, _ title: String) throws -> Bool {
        try SearchExpression.parse(expression).matches(title)
    }

    @Test func andRequiresEveryTerm() throws {
        #expect(try matches("meeting and budget", "Budget MEETING Q4"))
        #expect(try !matches("meeting and budget", "Budget review"))
    }

    @Test func orRequiresAtLeastOneTerm() throws {
        #expect(try matches("idea or lyrics", "Song lyrics"))
        #expect(try matches("idea or lyrics", "Big idea"))
        #expect(try !matches("idea or lyrics", "Groceries"))
    }

    @Test func groupedExpression() throws {
        let expression = "(foo and bar) or (alice and bob)"
        #expect(try matches(expression, "foo then bar"))
        #expect(try matches(expression, "Alice met Bob"))
        #expect(try !matches(expression, "foo and alice"))  // one from each side, neither complete
        #expect(try !matches(expression, "only bob"))
    }

    @Test func mixedOperatorsFollowPrecedence() throws {
        // "foo or bar and alice" == "foo or (bar and alice)"
        #expect(try matches("foo or bar and alice", "just foo"))
        #expect(try !matches("foo or bar and alice", "just bar"))
        #expect(try matches("foo or bar and alice", "bar with alice"))
    }

    @Test func quotedPhrasesMatchAsAWhole() throws {
        #expect(try matches("\"team meeting\"", "Weekly team meeting"))
        #expect(try !matches("\"team meeting\"", "meeting of the team"))
    }

    @Test func ignoresCaseAndDiacritics() throws {
        #expect(try matches("cafe", "Café notes"))
        #expect(try matches("CAFÉ", "cafe notes"))
    }
}

// MARK: - DateFilter & DayParser

@Suite("DateFilter")
struct DateFilterTests {
    @Test func dayCoversExactlyOneCalendarDay() {
        let bounds = DateFilter.day(moment(2026, 10, 23, 15)).bounds()
        #expect(bounds.start == startOfDay(2026, 10, 23))
        #expect(bounds.end == startOfDay(2026, 10, 24))
    }

    @Test func rangeIncludesTheWholeLastDay() {
        let bounds = DateFilter.range(from: moment(2026, 10, 1), to: moment(2026, 10, 31)).bounds()
        #expect(bounds.start == startOfDay(2026, 10, 1))
        #expect(bounds.end == startOfDay(2026, 11, 1))
    }

    @Test func rangeMayBeOpenEnded() {
        let fromOnly = DateFilter.range(from: moment(2026, 10, 1), to: nil).bounds()
        #expect(fromOnly.start == startOfDay(2026, 10, 1))
        #expect(fromOnly.end == nil)

        let toOnly = DateFilter.range(from: nil, to: moment(2026, 10, 31)).bounds()
        #expect(toOnly.start == nil)
        #expect(toOnly.end == startOfDay(2026, 11, 1))
    }

    @Test func parserAcceptsValidAndRejectsInvalidDays() {
        #expect(DayParser.parse("2026-10-23") == startOfDay(2026, 10, 23))
        #expect(DayParser.parse("23/10/2026") == nil)
        #expect(DayParser.parse("2026-13-01") == nil)
        #expect(DayParser.parse("2026-02-30") == nil)
        #expect(DayParser.parse("") == nil)
    }
}

// MARK: - Recording

@Suite("Recording")
struct RecordingTests {
    private func recording(title: String) -> Recording {
        Recording(date: Date(), title: title, audioURL: URL(fileURLWithPath: "/tmp/20261023 090000-ABCD.m4a"))
    }

    @Test func displayNameIsTheTitle() {
        #expect(recording(title: "Team meeting").displayName == "Team meeting")
    }

    @Test func displayNameTrimsSurroundingWhitespace() {
        #expect(recording(title: "  Team meeting \n").displayName == "Team meeting")
    }

    @Test func displayNameFallsBackToFileNameWithoutExtension() {
        #expect(recording(title: "").displayName == "20261023 090000-ABCD")
        #expect(recording(title: "   ").displayName == "20261023 090000-ABCD")
    }
}

// MARK: - Search against a fixture database

private struct Fixture {
    let directory: URL
    let library: VoiceMemosLibrary

    struct Row {
        let date: Date
        let title: String?
        let path: String
        var encryptedTitle: String? = nil
    }

    init(rows: [Row]) throws {
        let fm = FileManager.default
        directory = fm.temporaryDirectory
            .appendingPathComponent("vm-fixture-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let databaseURL = directory.appendingPathComponent("CloudRecordings.db")
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            throw FixtureError.sqlite("open")
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw FixtureError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        }
        func quoted(_ string: String) -> String {
            "'" + string.replacingOccurrences(of: "'", with: "''") + "'"
        }

        try exec(
            "CREATE TABLE ZCLOUDRECORDING (Z_PK INTEGER PRIMARY KEY, ZDATE TIMESTAMP, ZCUSTOMLABEL VARCHAR, ZENCRYPTEDTITLE VARCHAR, ZPATH VARCHAR)"
        )
        for row in rows {
            let title = row.title.map(quoted) ?? "NULL"
            let encryptedTitle = row.encryptedTitle.map(quoted) ?? "NULL"
            try exec(
                "INSERT INTO ZCLOUDRECORDING (ZDATE, ZCUSTOMLABEL, ZENCRYPTEDTITLE, ZPATH) VALUES (\(row.date.timeIntervalSinceReferenceDate), \(title), \(encryptedTitle), \(quoted(row.path)))"
            )
        }

        library = VoiceMemosLibrary(databaseURL: databaseURL)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    enum FixtureError: Error { case sqlite(String) }

    /// Inserted out of chronological order on purpose, to verify sorting.
    static func standard() throws -> Fixture {
        try Fixture(rows: [
            Row(date: moment(2026, 10, 23, 18, 30), title: "Lyrics idea", path: "relative.m4a"),
            Row(date: moment(2026, 10, 1, 10), title: "Team meeting budget", path: "/tmp/a.m4a"),
            Row(date: moment(2026, 10, 23, 9), title: "Meeting notes", path: "/tmp/b.m4a"),
            Row(date: moment(2026, 10, 15), title: "Song idea", path: "/tmp/c.m4a"),
            // Sonoma+ layout: the visible title is in ZENCRYPTEDTITLE, the old label is stale.
            Row(date: moment(2026, 10, 20), title: "stale label", path: "/tmp/d.m4a", encryptedTitle: "Modern title"),
            Row(date: moment(2026, 10, 23, 8), title: nil, path: "/tmp/untitled.m4a"),
        ])
    }
}

@Suite("VoiceMemosLibrary.search")
struct SearchTests {
    @Test func noFiltersReturnsEverythingOldestFirst() throws {
        let fixture = try Fixture.standard()
        defer { fixture.cleanup() }

        let titles = try fixture.library.search(SearchCriteria()).map(\.title)
        #expect(titles == ["Team meeting budget", "Song idea", "Modern title", "", "Meeting notes", "Lyrics idea"])
    }

    @Test func exactDay() throws {
        let fixture = try Fixture.standard()
        defer { fixture.cleanup() }

        let criteria = SearchCriteria(date: .day(moment(2026, 10, 23)))
        let titles = try fixture.library.search(criteria).map(\.title)
        #expect(titles == ["", "Meeting notes", "Lyrics idea"])
    }

    @Test func dateRangeIsInclusive() throws {
        let fixture = try Fixture.standard()
        defer { fixture.cleanup() }

        let criteria = SearchCriteria(date: .range(from: moment(2026, 10, 15), to: moment(2026, 10, 23)))
        let titles = try fixture.library.search(criteria).map(\.title)
        #expect(titles == ["Song idea", "Modern title", "", "Meeting notes", "Lyrics idea"])
    }

    @Test func searchWithAnd() throws {
        let fixture = try Fixture.standard()
        defer { fixture.cleanup() }

        let criteria = try SearchCriteria(titleExpression: .parse("meeting and budget"))
        let titles = try fixture.library.search(criteria).map(\.title)
        #expect(titles == ["Team meeting budget"])
    }

    @Test func searchWithOr() throws {
        let fixture = try Fixture.standard()
        defer { fixture.cleanup() }

        let criteria = try SearchCriteria(titleExpression: .parse("idea or notes"))
        let titles = try fixture.library.search(criteria).map(\.title)
        #expect(titles == ["Song idea", "Meeting notes", "Lyrics idea"])
    }

    @Test func searchWithGroupedExpression() throws {
        let fixture = try Fixture.standard()
        defer { fixture.cleanup() }

        let criteria = try SearchCriteria(
            titleExpression: .parse("(lyrics and idea) or (team and budget)"))
        let titles = try fixture.library.search(criteria).map(\.title)
        #expect(titles == ["Team meeting budget", "Lyrics idea"])
    }

    @Test func dateAndSearchCombine() throws {
        let fixture = try Fixture.standard()
        defer { fixture.cleanup() }

        let criteria = try SearchCriteria(
            date: .day(moment(2026, 10, 23)),
            titleExpression: .parse("idea")
        )
        let titles = try fixture.library.search(criteria).map(\.title)
        #expect(titles == ["Lyrics idea"])
    }

    @Test func prefersEncryptedTitleOverCustomLabel() throws {
        let fixture = try Fixture.standard()
        defer { fixture.cleanup() }

        let modern = try fixture.library.search(SearchCriteria(titleExpression: .parse("modern")))
        #expect(modern.map(\.title) == ["Modern title"])

        // The stale ZCUSTOMLABEL must not be used when ZENCRYPTEDTITLE is present.
        let stale = try fixture.library.search(SearchCriteria(titleExpression: .parse("stale")))
        #expect(stale.isEmpty)
    }

    @Test func fallsBackToCustomLabelWhenEncryptedTitleIsMissing() throws {
        let fixture = try Fixture.standard()
        defer { fixture.cleanup() }

        let result = try fixture.library.search(SearchCriteria(titleExpression: .parse("\"meeting notes\"")))
        #expect(result.map(\.title) == ["Meeting notes"])
    }

    @Test func resolvesRelativePathsAgainstDatabaseFolder() throws {
        let fixture = try Fixture.standard()
        defer { fixture.cleanup() }

        let criteria = try SearchCriteria(titleExpression: .parse("lyrics"))
        let recording = try #require(try fixture.library.search(criteria).first)
        #expect(recording.audioURL == fixture.directory.appendingPathComponent("relative.m4a"))
    }

    @Test func absolutePathsAreKeptAsIs() throws {
        let fixture = try Fixture.standard()
        defer { fixture.cleanup() }

        let criteria = try SearchCriteria(titleExpression: .parse("song"))
        let recording = try #require(try fixture.library.search(criteria).first)
        #expect(recording.audioURL.path == "/tmp/c.m4a")
    }

    @Test func missingDatabaseThrows() {
        let library = VoiceMemosLibrary(databaseURL: URL(fileURLWithPath: "/nonexistent/CloudRecordings.db"))
        #expect(throws: VoiceMemosError.self) {
            try library.search(SearchCriteria())
        }
    }
}