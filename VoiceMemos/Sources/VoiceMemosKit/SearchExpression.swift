import Foundation

/// A boolean expression over title terms, such as `(foo and bar) or (alice and bob)`.
///
/// Grammar (operators are case-insensitive):
///
/// ```
/// expression  := conjunction ( "or" conjunction )*
/// conjunction := primary ( "and" primary )*
/// primary     := term | "(" expression ")"
/// term        := a bare word  |  a "double-quoted phrase"
/// ```
///
/// - `and` binds tighter than `or`, so `a or b and c` means `a or (b and c)`.
/// - Terms are case- and diacritic-insensitive substrings of the title.
/// - Adjacent terms need an explicit operator: `foo bar` is an error, `"foo bar"` is a phrase.
/// - Inside a quoted phrase, `\"` and `\\` are escapes. A quoted `"and"` or `"or"` is a plain term.
public enum SearchExpression: Sendable, Equatable {
    case term(String)
    case and([SearchExpression])
    case or([SearchExpression])

    public func matches(_ title: String) -> Bool {
        switch self {
        case .term(let text):
            return title.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .and(let operands):
            return operands.allSatisfy { $0.matches(title) }
        case .or(let operands):
            return operands.contains { $0.matches(title) }
        }
    }

    /// Parses `input`, throwing a `SearchExpressionError` that pinpoints the problem.
    public static func parse(_ input: String) throws -> SearchExpression {
        let lexemes = try Lexer.tokenize(input)
        guard !lexemes.isEmpty else { throw SearchExpressionError.empty }

        var parser = Parser(lexemes: lexemes, endColumn: input.count + 1)
        let expression = try parser.parseExpression()
        if let leftover = parser.current {
            throw Parser.trailingError(for: leftover)
        }
        return expression
    }
}

public enum SearchExpressionError: Error, LocalizedError, CustomStringConvertible, Equatable {
    case empty
    case unterminatedQuote(column: Int)
    case emptyQuotedTerm(column: Int)
    /// `found` is `nil` when the expression ended where a term was expected.
    case expectedTerm(found: String?, column: Int)
    case missingOperator(before: String, column: Int)
    case unmatchedOpeningParenthesis(column: Int)
    case unmatchedClosingParenthesis(column: Int)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "The search expression is empty."
        case .unterminatedQuote(let column):
            return "Unterminated quote starting at column \(column)."
        case .emptyQuotedTerm(let column):
            return "Empty quoted term at column \(column)."
        case .expectedTerm(let found, let column):
            if let found {
                return "Expected a search term at column \(column), but found \(found)."
            }
            return "Expected a search term at the end of the expression."
        case .missingOperator(let before, let column):
            return "Missing 'and' or 'or' before '\(before)' at column \(column). "
                + "Quote phrases that contain spaces, e.g. \"team meeting\"."
        case .unmatchedOpeningParenthesis(let column):
            return "Unmatched '(' at column \(column)."
        case .unmatchedClosingParenthesis(let column):
            return "Unmatched ')' at column \(column)."
        }
    }

    public var description: String { errorDescription ?? "Invalid search expression." }
}

// MARK: - Lexer

private enum Token: Equatable {
    case term(String)
    case and
    case or
    case open
    case close

    var display: String {
        switch self {
        case .term(let text): return "'\(text)'"
        case .and: return "'and'"
        case .or: return "'or'"
        case .open: return "'('"
        case .close: return "')'"
        }
    }
}

private struct Lexeme {
    let token: Token
    /// 1-based position in the original string, for error messages.
    let column: Int
}

private enum Lexer {
    static func tokenize(_ input: String) throws -> [Lexeme] {
        let chars = Array(input)
        var lexemes: [Lexeme] = []
        var i = 0

        while i < chars.count {
            let c = chars[i]
            let column = i + 1

            if c.isWhitespace {
                i += 1
            } else if c == "(" {
                lexemes.append(Lexeme(token: .open, column: column))
                i += 1
            } else if c == ")" {
                lexemes.append(Lexeme(token: .close, column: column))
                i += 1
            } else if c == "\"" {
                i += 1
                var text = ""
                var closed = false
                while i < chars.count {
                    let d = chars[i]
                    if d == "\\", i + 1 < chars.count, (chars[i + 1] == "\"" || chars[i + 1] == "\\") {
                        text.append(chars[i + 1])
                        i += 2
                    } else if d == "\"" {
                        closed = true
                        i += 1
                        break
                    } else {
                        text.append(d)
                        i += 1
                    }
                }
                guard closed else { throw SearchExpressionError.unterminatedQuote(column: column) }
                guard !text.isEmpty else { throw SearchExpressionError.emptyQuotedTerm(column: column) }
                // Quoted text is always a term, even if it spells an operator.
                lexemes.append(Lexeme(token: .term(text), column: column))
            } else {
                var word = ""
                while i < chars.count {
                    let d = chars[i]
                    if d.isWhitespace || d == "(" || d == ")" || d == "\"" { break }
                    word.append(d)
                    i += 1
                }
                switch word.lowercased() {
                case "and": lexemes.append(Lexeme(token: .and, column: column))
                case "or": lexemes.append(Lexeme(token: .or, column: column))
                default: lexemes.append(Lexeme(token: .term(word), column: column))
                }
            }
        }
        return lexemes
    }
}

// MARK: - Parser (recursive descent)

private struct Parser {
    let lexemes: [Lexeme]
    let endColumn: Int
    var position = 0

    var current: Lexeme? { position < lexemes.count ? lexemes[position] : nil }

    /// Lowest precedence: `or`.
    mutating func parseExpression() throws -> SearchExpression {
        var operands = [try parseConjunction()]
        while current?.token == .or {
            position += 1
            operands.append(try parseConjunction())
        }
        return operands.count == 1 ? operands[0] : .or(operands)
    }

    /// Higher precedence: `and`.
    mutating func parseConjunction() throws -> SearchExpression {
        var operands = [try parsePrimary()]
        while current?.token == .and {
            position += 1
            operands.append(try parsePrimary())
        }
        return operands.count == 1 ? operands[0] : .and(operands)
    }

    mutating func parsePrimary() throws -> SearchExpression {
        guard let lexeme = current else {
            throw SearchExpressionError.expectedTerm(found: nil, column: endColumn)
        }

        switch lexeme.token {
        case .term(let text):
            position += 1
            return .term(text)

        case .open:
            position += 1
            let inner = try parseExpression()
            guard let next = current else {
                throw SearchExpressionError.unmatchedOpeningParenthesis(column: lexeme.column)
            }
            if next.token == .close {
                position += 1
                return inner
            }
            throw Parser.trailingError(for: next)

        case .close, .and, .or:
            throw SearchExpressionError.expectedTerm(found: lexeme.token.display, column: lexeme.column)
        }
    }

    /// The error for a token that can't continue an otherwise complete expression.
    static func trailingError(for lexeme: Lexeme) -> SearchExpressionError {
        switch lexeme.token {
        case .term(let text):
            return .missingOperator(before: text, column: lexeme.column)
        case .open:
            return .missingOperator(before: "(", column: lexeme.column)
        case .close:
            return .unmatchedClosingParenthesis(column: lexeme.column)
        case .and, .or:
            return .expectedTerm(found: lexeme.token.display, column: lexeme.column)
        }
    }
}