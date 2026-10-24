import Foundation

// MARK: - Headers & parts

struct MIMEHeaders {
    private(set) var fields: [(name: String, value: String)] = []

    init(fields: [(name: String, value: String)] = []) {
        self.fields = fields
    }

    func first(_ name: String) -> String? {
        let lowered = name.lowercased()
        return fields.first { $0.name.lowercased() == lowered }?.value
    }

    /// Value with RFC 2047 encoded-words decoded.
    func decoded(_ name: String) -> String? {
        first(name).map { MIMEDecoding.decodeEncodedWords($0) }
    }
}

struct ParameterizedValue {
    /// Main value, lowercased (e.g. "text/plain", "attachment").
    var value: String
    /// Parameter names lowercased; values as written (RFC 2231 continuations/encodings resolved).
    var parameters: [String: String]
}

struct MIMEPart {
    let headers: MIMEHeaders
    let body: [UInt8]
    let children: [MIMEPart]

    var contentType: ParameterizedValue {
        MIMEDecoding.parseParameterized(headers.first("Content-Type") ?? "text/plain")
    }

    var disposition: ParameterizedValue? {
        headers.first("Content-Disposition").map { MIMEDecoding.parseParameterized($0) }
    }

    var filename: String? {
        let raw = disposition?.parameters["filename"] ?? contentType.parameters["name"]
        return raw.map { MIMEDecoding.decodeEncodedWords($0) }
    }
}

// MARK: - Parser

enum MIMEParser {
    static func parse(_ bytes: [UInt8], depth: Int = 0) -> MIMEPart {
        let (headerEnd, bodyStart) = findHeaderEnd(bytes)
        let headers = parseHeaderBlock(Array(bytes[0..<headerEnd]))
        let body = Array(bytes[bodyStart...])

        var children: [MIMEPart] = []
        let type = MIMEDecoding.parseParameterized(headers.first("Content-Type") ?? "")
        if type.value.hasPrefix("multipart/"), let boundary = type.parameters["boundary"], depth < 12 {
            children = splitMultipart(body, boundary: boundary).map { parse($0, depth: depth + 1) }
        }
        return MIMEPart(headers: headers, body: body, children: children)
    }

    /// Index of the blank line ending the headers, and where the body starts.
    static func findHeaderEnd(_ bytes: [UInt8]) -> (headerEnd: Int, bodyStart: Int) {
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A {
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                    return (i, i + 2)
                }
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A {
                    return (i, i + 3)
                }
            }
            i += 1
        }
        return (bytes.count, bytes.count)
    }

    static func parseHeaderBlock(_ bytes: [UInt8]) -> MIMEHeaders {
        let text = String(data: Data(bytes), encoding: .utf8)
            ?? String(data: Data(bytes), encoding: .isoLatin1)
            ?? ""

        var fields: [(name: String, value: String)] = []
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
            if let first = line.first, first == " " || first == "\t" {
                // Folded continuation of the previous header.
                if !fields.isEmpty {
                    fields[fields.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
                }
            } else if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                fields.append((name: name, value: value))
            }
        }
        return MIMEHeaders(fields: fields)
    }

    static func splitMultipart(_ body: [UInt8], boundary: String) -> [[UInt8]] {
        let delimiter = Array("--\(boundary)".utf8)
        var parts: [[UInt8]] = []
        var current: [UInt8] = []
        var inPart = false
        var position = 0

        while position < body.count {
            var end = position
            while end < body.count && body[end] != 0x0A { end += 1 }

            var lineEnd = end
            if lineEnd > position && body[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            let line = body[position..<lineEnd]
            let next = min(end + 1, body.count)

            if line.starts(with: delimiter) {
                let rest = line.dropFirst(delimiter.count)
                let isClose = rest.starts(with: [0x2D, 0x2D])
                if isClose || rest.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                    if inPart {
                        parts.append(current)
                        current = []
                    }
                    inPart = !isClose
                    if isClose { break }
                    position = next
                    continue
                }
            }

            if inPart {
                current.append(contentsOf: body[position..<next])
            }
            position = next
        }

        if inPart { parts.append(current) }
        return parts
    }

    /// Transfer-decoded bytes of a leaf part.
    static func decodedBody(of part: MIMEPart) -> Data {
        let encoding = (part.headers.first("Content-Transfer-Encoding") ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        switch encoding {
        case "base64":
            return MIMEDecoding.decodeBase64(part.body) ?? Data(part.body)
        case "quoted-printable":
            return Data(MIMEDecoding.decodeQuotedPrintable(part.body))
        default:
            return Data(part.body)
        }
    }
}

// MARK: - Decoding helpers

enum MIMEDecoding {
    // MARK: RFC 2047 encoded words ("=?utf-8?B?...?=")

    static func decodeEncodedWords(_ input: String) -> String {
        guard input.contains("=?"),
              let regex = try? NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?]*)\?="#) else {
            return input
        }

        let ns = input as NSString
        var result = ""
        var cursor = 0
        var lastWasEncoded = false

        for match in regex.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            // Whitespace between two adjacent encoded words is not part of the text.
            if !(lastWasEncoded && between.allSatisfy { $0.isWhitespace }) {
                result += between
            }

            let charset = ns.substring(with: match.range(at: 1)).components(separatedBy: "*")[0]
            let kind = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))

            let bytes: Data?
            if kind == "B" {
                bytes = decodeBase64(Array(payload.utf8))
            } else {
                bytes = Data(decodeQuotedPrintable(Array(payload.utf8), underscoreIsSpace: true))
            }

            if let bytes {
                result += decode(bytes, charset: charset)
            } else {
                result += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
            lastWasEncoded = true
        }

        result += ns.substring(from: cursor)
        return result
    }

    // MARK: Transfer encodings

    static func decodeBase64(_ bytes: [UInt8]) -> Data? {
        var cleaned = bytes.filter {
            ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) ||
            ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2B || $0 == 0x2F
        }
        while cleaned.count % 4 != 0 { cleaned.append(0x3D) }
        return Data(base64Encoded: Data(cleaned))
    }

    static func decodeQuotedPrintable(_ input: [UInt8], underscoreIsSpace: Bool = false) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var i = 0
        while i < input.count {
            let byte = input[i]
            if byte == 0x3D { // "="
                if i + 1 < input.count, input[i + 1] == 0x0A {            // soft break "=\n"
                    i += 2
                    continue
                }
                if i + 2 < input.count, input[i + 1] == 0x0D, input[i + 2] == 0x0A { // "=\r\n"
                    i += 3
                    continue
                }
                if i + 2 < input.count, let high = hexValue(input[i + 1]), let low = hexValue(input[i + 2]) {
                    output.append(high << 4 | low)
                    i += 3
                    continue
                }
                output.append(byte)
                i += 1
            } else if underscoreIsSpace && byte == 0x5F {
                output.append(0x20)
                i += 1
            } else {
                output.append(byte)
                i += 1
            }
        }
        return output
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    static func percentDecode(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        var output = Data()
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25, i + 2 < bytes.count,
               let high = hexValue(bytes[i + 1]), let low = hexValue(bytes[i + 2]) {
                output.append(high << 4 | low)
                i += 3
            } else {
                output.append(bytes[i])
                i += 1
            }
        }
        return output
    }

    // MARK: Charsets

    static func stringEncoding(forCharset name: String) -> String.Encoding? {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(trimmed as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    static func decode(_ data: Data, charset: String?) -> String {
        let encoding = charset.flatMap { stringEncoding(forCharset: $0) } ?? .utf8
        if let text = String(data: data, encoding: encoding) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: Parameterised headers (Content-Type, Content-Disposition)

    static func parseParameterized(_ raw: String) -> ParameterizedValue {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        for character in raw {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == ";" && !inQuotes {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)

        let main = (pieces.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        var simple: [String: String] = [:]
        var segments: [String: [(index: Int, encoded: Bool, value: String)]] = [:]

        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }

            if let star = key.firstIndex(of: "*") {
                // RFC 2231: name*, name*0, name*0*
                let base = String(key[..<star])
                let after = String(key[key.index(after: star)...])
                let encoded = after.isEmpty || after.hasSuffix("*")
                let digits = after.hasSuffix("*") ? String(after.dropLast()) : after
                segments[base, default: []].append((index: Int(digits) ?? 0, encoded: encoded, value: value))
            } else {
                simple[key] = value
            }
        }

        for (base, parts) in segments {
            var bytes = Data()
            var charset: String?
            for (position, part) in parts.sorted(by: { $0.index < $1.index }).enumerated() {
                if part.encoded {
                    var text = part.value
                    if position == 0,
                       let firstQuote = text.firstIndex(of: "'"),
                       let secondQuote = text[text.index(after: firstQuote)...].firstIndex(of: "'") {
                        charset = String(text[..<firstQuote])
                        text = String(text[text.index(after: secondQuote)...])
                    }
                    bytes.append(percentDecode(text))
                } else {
                    bytes.append(Data(part.value.utf8))
                }
            }
            simple[base] = decode(bytes, charset: charset)
        }

        return ParameterizedValue(value: main, parameters: simple)
    }

    // MARK: HTML -> plain text (used only when a message has no text/plain part)

    static func htmlToText(_ html: String) -> String {
        var text = html
        text = replace(#"(?is)<(script|style|head)[^>]*>.*?</\1>"#, in: text, with: "")
        text = replace(#"(?i)<br\s*/?>"#, in: text, with: "\n")
        text = replace(#"(?i)</(p|div|tr|li|h[1-6]|table|blockquote)>"#, in: text, with: "\n")
        text = replace(#"(?i)<li[^>]*>"#, in: text, with: "- ")
        text = replace(#"<[^>]+>"#, in: text, with: "")
        text = decodeEntities(text)

        var lines: [String] = []
        var blankRun = 0
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                blankRun += 1
                if blankRun == 1 && !lines.isEmpty { lines.append("") }
            } else {
                blankRun = 0
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template
        )
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var result = text
        let named: [String: String] = [
            "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
            "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“",
            "&ndash;": "–", "&mdash;": "—", "&hellip;": "…",
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        if let regex = try? NSRegularExpression(pattern: "&#([xX]?)([0-9a-fA-F]+);") {
            let mutable = NSMutableString(string: result)
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: mutable.length))
            for match in matches.reversed() { // back to front so earlier ranges stay valid
                let isHex = mutable.substring(with: match.range(at: 1)).lowercased() == "x"
                let digits = mutable.substring(with: match.range(at: 2))
                if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    mutable.replaceCharacters(in: match.range, with: String(Character(scalar)))
                }
            }
            result = mutable as String
        }

        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - .emlx reader

struct ParsedEmail {
    let subject: String?
    let messageID: String?
    let body: String
    let attachments: [String]
}

enum EmlxReader {
    /// An .emlx file is: a line with the message's byte count, the RFC 822 message, then a plist.
    static func messageBytes(from file: [UInt8]) -> [UInt8] {
        guard let newline = file.firstIndex(of: 0x0A) else { return file }
        let firstLine = String(decoding: file[..<newline], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let declared = Int(firstLine), declared >= 0 else { return file }
        let start = newline + 1
        let end = min(start + declared, file.count)
        return Array(file[start..<end])
    }

    /// Cheap Message-ID lookup that reads only the start of the file.
    static func messageID(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }

        let bytes = messageBytes(from: [UInt8](data))
        let (headerEnd, _) = MIMEParser.findHeaderEnd(bytes)
        return MIMEParser.parseHeaderBlock(Array(bytes[0..<headerEnd])).first("Message-ID")
    }

    static func parse(url: URL) throws -> ParsedEmail {
        let data = try Data(contentsOf: url)
        let root = MIMEParser.parse(messageBytes(from: [UInt8](data)))

        var attachments: [String] = []
        let text = extractText(from: root, attachments: &attachments)

        let body: String
        if let plain = text.plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = plain
        } else if let html = text.html {
            body = MIMEDecoding.htmlToText(html)
        } else {
            body = ""
        }

        return ParsedEmail(
            subject: root.headers.decoded("Subject"),
            messageID: root.headers.first("Message-ID"),
            body: normalize(body),
            attachments: attachments
        )
    }

    private static func extractText(from part: MIMEPart,
                                    attachments: inout [String]) -> (plain: String?, html: String?) {
        if !part.children.isEmpty {
            var plains: [String] = []
            var htmls: [String] = []
            for child in part.children {
                let result = extractText(from: child, attachments: &attachments)
                if let plain = result.plain { plains.append(plain) }
                if let html = result.html { htmls.append(html) }
            }
            return (
                plains.isEmpty ? nil : plains.joined(separator: "\n\n"),
                htmls.isEmpty ? nil : htmls.joined(separator: "\n\n")
            )
        }

        let type = part.contentType.value
        if part.disposition?.value == "attachment" || part.filename != nil {
            attachments.append(part.filename ?? type)
            return (nil, nil)
        }

        switch type {
        case "text/plain", "text/html":
            let text = MIMEDecoding.decode(
                MIMEParser.decodedBody(of: part),
                charset: part.contentType.parameters["charset"]
            )
            return type == "text/plain" ? (text, nil) : (nil, text)
        default:
            return (nil, nil)
        }
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
