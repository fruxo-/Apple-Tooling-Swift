import XCTest

@testable import MailUtils

// MARK: - Helpers

private func makeMessage(
    rowID: Int64,
    conversationID: Int64,
    timestamp: Int64 = 0,
    from sender: String,
    to recipients: [String] = [],
    subject: String = "Subject",
    mailboxURL: String = "",
    messageID: String? = nil
) -> Message {
    Message(
        copies: [MessageCopy(rowID: rowID, remoteID: nil, mailboxURL: mailboxURL)],
        globalID: rowID,
        conversationID: conversationID,
        timestamp: timestamp,
        senderEmail: sender,
        senderName: "",
        subject: subject,
        snippet: nil,
        messageIDHeader: messageID,
        recipients: recipients.map { Recipient(email: $0, name: "", type: 0) }
    )
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailutils-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// An .emlx file: a line with the message's byte count, the message, then a (dummy) plist.
private func emlx(_ message: String) -> String {
    "\(message.utf8.count)\n" + message + "<?xml version=\"1.0\"?><plist/>"
}

// MARK: - TextTools

final class TextToolsTests: XCTestCase {
    func testBaseSubjectStripsReplyAndForwardPrefixes() {
        XCTAssertEqual(TextTools.baseSubject("Re: Fwd: Project Kickoff"), "project kickoff")
        XCTAssertEqual(TextTools.baseSubject("RE:   hello"), "hello")
        XCTAssertEqual(TextTools.baseSubject("AW: Angebot"), "angebot")
    }

    func testBaseSubjectKeepsWordsThatMerelyStartWithAPrefix() {
        XCTAssertEqual(TextTools.baseSubject("Release notes"), "release notes")
        XCTAssertEqual(TextTools.baseSubject("Reminder: pay"), "reminder: pay")
    }

    func testOneLineJoinsNonEmptyTrimmedLines() {
        XCTAssertEqual(TextTools.oneLine("a\n  b \n\n c"), "a b c")
    }

    func testSlug() {
        XCTAssertEqual(TextTools.slug("Hello, World!"), "hello-world")
        XCTAssertEqual(TextTools.slug("  --Hi  "), "hi")
        XCTAssertEqual(TextTools.slug("!!!"), "no-subject")
        XCTAssertEqual(TextTools.slug(String(repeating: "a", count: 100)).count, 60)
    }

    func testFolderName() {
        XCTAssertEqual(TextTools.folderName(forParties: []), "all")
        XCTAssertEqual(TextTools.folderName(forParties: [], only: true), "all")
        XCTAssertEqual(TextTools.folderName(forParties: ["alice@example.com"]), "alice@example.com")
        XCTAssertEqual(
            TextTools.folderName(forParties: ["alice@example.com"], only: true),
            "alice@example.com__only")
        XCTAssertEqual(
            TextTools.folderName(forParties: ["alice@example.com", "bob@example.org"]),
            "alice@example.com__bob@example.org")
        XCTAssertEqual(TextTools.folderName(forParties: ["a/b"]), "a_b")
        XCTAssertEqual(TextTools.folderName(forParties: [".hidden"]), "hidden")
    }
}

// MARK: - PersonFormatter

final class PersonFormatterTests: XCTestCase {
    func testDisplay() {
        let people = PersonFormatter(names: ["alice@example.com": "Alice"])
        XCTAssertEqual(people.display("alice@example.com"), "Alice (alice@example.com)")
        XCTAssertEqual(
            people.display("alice@example.com", name: "Alice A."), "Alice A. (alice@example.com)")
        XCTAssertEqual(
            people.display("alice@example.com", name: "\"Alice\""), "Alice (alice@example.com)")
        XCTAssertEqual(people.display("bob@example.org"), "bob@example.org")
        XCTAssertEqual(
            people.display("bob@example.org", name: "bob@example.org"), "bob@example.org")
    }
}

// MARK: - MIME decoding

final class MIMEDecodingTests: XCTestCase {
    func testEncodedWords() {
        XCTAssertEqual(MIMEDecoding.decodeEncodedWords("=?utf-8?B?SGVsbG8=?="), "Hello")
        XCTAssertEqual(MIMEDecoding.decodeEncodedWords("=?utf-8?Q?Caf=C3=A9?="), "Café")
        XCTAssertEqual(MIMEDecoding.decodeEncodedWords("=?iso-8859-1?Q?Caf=E9?="), "Café")
        XCTAssertEqual(MIMEDecoding.decodeEncodedWords("=?utf-8?Q?a_b?="), "a b")
        XCTAssertEqual(
            MIMEDecoding.decodeEncodedWords("Re: =?utf-8?Q?Caf=C3=A9?= menu"), "Re: Café menu")
        XCTAssertEqual(MIMEDecoding.decodeEncodedWords("Plain subject"), "Plain subject")
    }

    func testWhitespaceBetweenAdjacentEncodedWordsIsDropped() {
        XCTAssertEqual(
            MIMEDecoding.decodeEncodedWords("=?utf-8?Q?foo?= =?utf-8?Q?bar?="), "foobar")
    }

    func testQuotedPrintable() {
        func decode(_ text: String) -> String {
            String(decoding: MIMEDecoding.decodeQuotedPrintable(Array(text.utf8)), as: UTF8.self)
        }
        XCTAssertEqual(decode("caf=C3=A9"), "café")
        XCTAssertEqual(decode("foo=\nbar"), "foobar")  // soft line break
    }

    func testParameterizedValues() {
        let value = MIMEDecoding.parseParameterized("Text/HTML; Charset=UTF-8; boundary=\"a;b\"")
        XCTAssertEqual(value.value, "text/html")
        XCTAssertEqual(value.parameters["charset"], "UTF-8")
        XCTAssertEqual(value.parameters["boundary"], "a;b")
    }

    func testParameterizedValuesResolveRFC2231Encoding() {
        let value = MIMEDecoding.parseParameterized("attachment; filename*=UTF-8''caf%C3%A9.txt")
        XCTAssertEqual(value.value, "attachment")
        XCTAssertEqual(value.parameters["filename"], "café.txt")
    }

    func testHTMLToText() {
        XCTAssertEqual(
            MIMEDecoding.htmlToText("<p>Hello <b>world</b></p><p>Second</p>"), "Hello world\nSecond"
        )
        XCTAssertEqual(MIMEDecoding.htmlToText("a<br>b"), "a\nb")
        XCTAssertEqual(MIMEDecoding.htmlToText("<style>x{}</style>Hi"), "Hi")
        XCTAssertEqual(MIMEDecoding.htmlToText("Tom &amp; Jerry"), "Tom & Jerry")
    }

    func testEntities() {
        XCTAssertEqual(MIMEDecoding.decodeEntities("&lt;b&gt; &#65; &#x42;"), "<b> A B")
    }
}

// MARK: - .emlx reading

final class EmlxReaderTests: XCTestCase {
    func testMessageBytesHonoursTheDeclaredLength() {
        let file = Array("5\nhelloTRAILER".utf8)
        XCTAssertEqual(
            String(decoding: EmlxReader.messageBytes(from: file), as: UTF8.self), "hello")
    }

    func testMessageBytesWithoutALengthLineReturnsEverything() {
        let file = Array("Subject: x\n\nbody".utf8)
        XCTAssertEqual(EmlxReader.messageBytes(from: file), file)
    }

    func testParsesAPlainTextMessage() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let message = [
            "Subject: Hello",
            "Message-ID: <abc@example.com>",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "Hi there",
            "",
        ].joined(separator: "\n")
        let url = directory.appendingPathComponent("1.emlx")
        try write(emlx(message), to: url)

        let parsed = try EmlxReader.parse(url: url)
        XCTAssertEqual(parsed.subject, "Hello")
        XCTAssertEqual(parsed.messageID, "<abc@example.com>")
        XCTAssertEqual(parsed.body, "Hi there")
        XCTAssertTrue(parsed.attachments.isEmpty)
    }

    func testParsesAMultipartMessageWithAnAttachment() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let message = [
            "Subject: Invoice",
            "Content-Type: multipart/mixed; boundary=\"XX\"",
            "",
            "--XX",
            "Content-Type: text/plain",
            "",
            "Hello",
            "--XX",
            "Content-Type: application/pdf; name=\"invoice.pdf\"",
            "Content-Disposition: attachment; filename=\"invoice.pdf\"",
            "Content-Transfer-Encoding: base64",
            "",
            "AAAA",
            "--XX--",
            "",
        ].joined(separator: "\n")
        let url = directory.appendingPathComponent("2.emlx")
        try write(emlx(message), to: url)

        let parsed = try EmlxReader.parse(url: url)
        XCTAssertEqual(parsed.body, "Hello")
        XCTAssertEqual(parsed.attachments, ["invoice.pdf"])
    }
}

// MARK: - Threads

final class ThreadTests: XCTestCase {
    private let messages = [
        makeMessage(
            rowID: 1, conversationID: 10, from: "alice@example.com", to: ["bob@example.com"]),
        makeMessage(
            rowID: 2, conversationID: 10, from: "bob@example.com", to: ["alice@example.com"]),
        makeMessage(
            rowID: 3, conversationID: 20, from: "carol@example.com", to: ["alice@example.com"]),
        makeMessage(rowID: 4, conversationID: 0, from: "dave@example.com"),
    ]

    func testGroupsByConversationAndKeepsUnassignedEmailsApart() {
        let threads = MailThread.build(from: messages, parties: [], minMessages: 1)
        XCTAssertEqual(threads.map(\.conversationID), [10, 20, 0])
        XCTAssertEqual(threads[0].messageIndexes, [0, 1])
        XCTAssertEqual(threads[1].messageIndexes, [2])
        XCTAssertEqual(threads[2].messageIndexes, [3])
    }

    func testMinMessages() {
        let threads = MailThread.build(from: messages, parties: [], minMessages: 2)
        XCTAssertEqual(threads.map(\.conversationID), [10])
    }

    func testPartyKeepsOnlyThreadsTheAddressTookPartIn() {
        let threads = MailThread.build(
            from: messages, parties: ["carol@example.com"], minMessages: 1)
        XCTAssertEqual(threads.map(\.conversationID), [20])
    }

    func testSeveralPartiesMustAllTakePart() {
        let both = MailThread.build(
            from: messages, parties: ["carol@example.com", "alice@example.com"], minMessages: 1)
        XCTAssertEqual(both.map(\.conversationID), [20])

        let none = MailThread.build(
            from: messages, parties: ["carol@example.com", "dave@example.com"], minMessages: 1)
        XCTAssertTrue(none.isEmpty)
    }

    func testParticipantsAreSortedByEmailsSentWithRecipientsOnlyLast() throws {
        let thread = [
            makeMessage(
                rowID: 1, conversationID: 10, from: "alice@example.com",
                to: ["bob@example.com", "carol@example.com"]),
            makeMessage(
                rowID: 2, conversationID: 10, from: "alice@example.com", to: ["bob@example.com"]),
            makeMessage(
                rowID: 3, conversationID: 10, from: "bob@example.com", to: ["alice@example.com"]),
        ]
        let built = MailThread.build(from: thread, parties: [], minMessages: 1)
        let participants = try XCTUnwrap(built.first).participants(in: thread)
        XCTAssertEqual(
            participants.map(\.email),
            ["alice@example.com", "bob@example.com", "carol@example.com"])
        XCTAssertEqual(participants.map(\.sent), [2, 1, 0])
    }

    func testInvolvedAddressesCoverSenderAndRecipients() {
        let message = makeMessage(
            rowID: 1, conversationID: 1, from: "a@example.com",
            to: ["b@example.com", "c@example.com"])
        XCTAssertEqual(
            message.involvedAddresses, Set(["a@example.com", "b@example.com", "c@example.com"]))
    }
}

// MARK: - HTML helpers

final class HTMLRendererTests: XCTestCase {
    func testEscape() {
        XCTAssertEqual(
            HTMLRenderer.escape("<a href=\"x\">&</a>"),
            "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;")
    }

    func testBlankLineBetweenQuotedLinesBelongsToTheQuote() {
        let segments = HTMLRenderer.segments(of: "intro\n> quoted 1\n\n> quoted 2\noutro")
        XCTAssertEqual(segments.map(\.quoted), [false, true, false])
        XCTAssertEqual(segments[1].lines.count, 3)
    }

    func testLongQuotesAreFoldedWhenTheEmailHasOwnText() {
        let html = HTMLRenderer.bodyBlocks("Thanks\n> a\n> b\n> c")
        XCTAssertTrue(html.contains("<pre>Thanks</pre>"))
        XCTAssertTrue(html.contains("Show quoted text (3 lines)"))
        XCTAssertTrue(html.contains("&gt; a"))
    }

    func testShortQuotesAreNotFolded() {
        let html = HTMLRenderer.bodyBlocks("Hi\n> a\n> b")
        XCTAssertFalse(html.contains("<details"))
    }

    func testAnEmailThatIsEntirelyQuotedIsNotFolded() {
        let html = HTMLRenderer.bodyBlocks("> a\n> b\n> c")
        XCTAssertFalse(html.contains("<details"))
    }
}

// MARK: - Date input

final class DateInputTests: XCTestCase {
    func testDateOnly() throws {
        let input = try XCTUnwrap(DateInput(argument: "2024-03-02"))
        XCTAssertTrue(input.dateOnly)
        XCTAssertEqual(input.text, "2024-03-02")
    }

    func testISO8601DateTime() throws {
        let input = try XCTUnwrap(DateInput(argument: "2024-03-02T09:15:00Z"))
        XCTAssertFalse(input.dateOnly)
        XCTAssertEqual(input.date.timeIntervalSince1970, 1_709_370_900, accuracy: 0.5)
    }

    func testLocalDateTimeIsNotDateOnly() throws {
        let input = try XCTUnwrap(DateInput(argument: "2024-03-02 09:15"))
        XCTAssertFalse(input.dateOnly)
    }

    func testRejectsGarbage() {
        XCTAssertNil(DateInput(argument: "yesterday"))
    }
}

// MARK: - Mail location

final class MailLocationTests: XCTestCase {
    private func makeMailFolder(versions: [String]) throws -> URL {
        let base = try makeTemporaryDirectory()
        for version in versions {
            try write("", to: base.appendingPathComponent("\(version)/MailData/Envelope Index"))
        }
        return base
    }

    func testPicksTheNewestVersionFolder() throws {
        let base = try makeMailFolder(versions: ["V9", "V10"])
        defer { try? FileManager.default.removeItem(at: base) }

        let location = try MailLocation.resolve(override: base.path)
        XCTAssertEqual(location.root.lastPathComponent, "V10")
    }

    func testAcceptsAVersionFolderDirectly() throws {
        let base = try makeMailFolder(versions: ["V9", "V10"])
        defer { try? FileManager.default.removeItem(at: base) }

        let location = try MailLocation.resolve(override: base.appendingPathComponent("V9").path)
        XCTAssertEqual(location.root.lastPathComponent, "V9")
    }

    func testThrowsWhenThereIsNoDatabase() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertThrowsError(try MailLocation.resolve(override: base.path))
    }
}

// MARK: - Matching emails to .emlx files

final class EmlxLocatorTests: XCTestCase {
    private let rawMessage = [
        "Message-ID: <abc@example.com>",
        "Subject: Hello",
        "",
        "Body",
        "",
    ].joined(separator: "\n")

    func testIndexMapsNumericFileNamesAndSkipsMailData() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("x", to: root.appendingPathComponent("UUID/INBOX.mbox/Messages/123.emlx"))
        try write("x", to: root.appendingPathComponent("UUID/INBOX.mbox/Messages/456.partial.emlx"))
        try write("x", to: root.appendingPathComponent("UUID/INBOX.mbox/Messages/789.txt"))
        try write("x", to: root.appendingPathComponent("MailData/999.emlx"))

        let index = EmlxIndex(root: root)
        XCTAssertEqual(index.fileCount, 2)
        XCTAssertEqual(index.filesByID[123]?.count, 1)
        XCTAssertEqual(index.filesByID[456]?.count, 1)
        XCTAssertNil(index.filesByID[789])
        XCTAssertNil(index.filesByID[999])
    }

    func testLocatesTheFileInTheRightMailboxAndConfirmsTheMessageID() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            emlx(rawMessage), to: root.appendingPathComponent("UUID/INBOX.mbox/Messages/123.emlx"))

        let locator = EmlxLocator(index: EmlxIndex(root: root))
        let message = makeMessage(
            rowID: 123, conversationID: 1, from: "a@example.com",
            mailboxURL: "imap://UUID/INBOX", messageID: "<ABC@example.com>")
        XCTAssertEqual(locator.locate(message)?.lastPathComponent, "123.emlx")
    }

    func testFallsBackToTheRowIDFileInTheRightMailboxWithoutAMessageID() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            emlx(rawMessage), to: root.appendingPathComponent("UUID/INBOX.mbox/Messages/123.emlx"))

        let locator = EmlxLocator(index: EmlxIndex(root: root))
        let message = makeMessage(
            rowID: 123, conversationID: 1, from: "a@example.com", mailboxURL: "imap://UUID/INBOX")
        XCTAssertEqual(locator.locate(message)?.lastPathComponent, "123.emlx")
    }

    func testRejectsAFileInAnotherMailboxWithADifferentMessageID() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = rawMessage.replacingOccurrences(of: "abc@", with: "other@")
        try write(emlx(other), to: root.appendingPathComponent("Other/Foo.mbox/Messages/123.emlx"))

        let locator = EmlxLocator(index: EmlxIndex(root: root))
        let message = makeMessage(
            rowID: 123, conversationID: 1, from: "a@example.com",
            mailboxURL: "imap://UUID/INBOX", messageID: "<abc@example.com>")
        XCTAssertNil(locator.locate(message))
    }
}
