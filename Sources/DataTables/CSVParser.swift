// CSVParser.swift
// DataTables
//
// Streaming RFC-4180-style byte parser. Internal: the public surface is
// `CSVTable.parse(_:)` / `CSVTable.load(contentsOf:)`.
//

import Foundation

/// Byte source with one-byte pushback, refilled in `chunkSize` blocks.
///
/// Structure characters (delimiter, quote, CR, LF) are all ASCII, and
/// UTF-8 continuation bytes are all ≥ 0x80, so a byte-level state machine
/// that only branches on ASCII bytes never misparses multibyte text —
/// even when a character straddles a refill boundary. Field bytes are
/// Byte source with one-byte pushback, refilled in `chunkSize` blocks.
///
/// Deliberately *not* `Sendable`: it wraps an `InputStream` and is
/// confined to the task driving the parse. Everything it produces
/// (`String` records) crosses isolation as plain values.
struct ByteFeeder {
    private var stream: InputStream
    private var buffer: [UInt8]
    private var pos: Int = 0
    private var count: Int = 0
    private var pushed: UInt8?
    private(set) var drained = false

    init(stream: InputStream, chunkSize: Int) {
        precondition(chunkSize > 0, "chunkSize must be positive")
        self.stream = stream
        self.buffer = [UInt8](repeating: 0, count: chunkSize)
        stream.open()
    }

    mutating func close() {
        stream.close()
    }

    mutating func nextByte() throws -> UInt8? {
        if let b = pushed {
            pushed = nil
            return b
        }
        if pos >= count {
            guard !drained else { return nil }
            pos = 0
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                return stream.read(base, maxLength: raw.count)
            }
            if n > 0 {
                count = n
            } else {
                drained = true
                if n < 0, let error = stream.streamError {
                    throw error
                }
                return nil
            }
        }
        let b = buffer[pos]
        pos += 1
        return b
    }

    mutating func pushBack(_ byte: UInt8) {
        precondition(pushed == nil, "ByteFeeder pushback slot already full")
        pushed = byte
    }
}

/// Incremental record parser over a `ByteFeeder`.
///
/// - Blank lines (zero bytes before the line break) are skipped.
/// - `\r\n`, lone `\r`, and lone `\n` all end a record outside quotes.
/// - Inside quotes, `""` is one literal quote; line breaks are field bytes.
/// - After a closing quote only delimiter, line break, or EOF may follow.
struct CSVRecordParser {
    private var feeder: ByteFeeder
    private let delimiter: UInt8
    private var line = 1

    /// 1-based physical line number where the most recently returned
    /// record starts. Read after `nextRow()` returns non-`nil`.
    private(set) var lastRecordLine = 1

    private enum State {
        case fieldStart, unquoted, quoted, afterQuote
    }

    init(feeder: ByteFeeder, delimiter: Character, trimsWhitespace: Bool = true) {
        precondition(delimiter.isASCII, "CSV delimiter must be ASCII")
        self.feeder = feeder
        self.delimiter = delimiter.asciiValue ?? 44
        self.trimsWhitespace = trimsWhitespace
    }

    mutating func close() {
        feeder.close()
    }

    /// Next non-blank record, or `nil` at end of input.
    mutating func nextRow() throws -> [String]? {
        while !feeder.drained {
            if let row = try readRecord() {
                return row
            }
        }
        return nil
    }

    /// One record, or `nil` for a blank line / end of input.
    private mutating func readRecord() throws -> [String]? {
        lastRecordLine = line
        var fields: [String] = []
        var fieldBytes: [UInt8] = []
        var fieldQuoted = false
        var byteCount = 0
        var state = State.fieldStart
        var quoteStartLine = 1

        // Decoded inline below (needs options + line); kept flat on purpose.
        while true {
            guard let b = try feeder.nextByte() else {
                // End of input.
                switch state {
                case .quoted:
                    throw CSVError.unterminatedQuote(line: quoteStartLine)
                case .fieldStart where fields.isEmpty && fieldBytes.isEmpty && !fieldQuoted && byteCount == 0:
                    return nil
                case .fieldStart, .unquoted, .afterQuote:
                    fields.append(try decode(fieldBytes, quoted: fieldQuoted))
                    return fields
                }
            }
            switch state {
            case .fieldStart:
                if b == 34 {  // "
                    state = .quoted
                    fieldQuoted = true
                    quoteStartLine = line
                    byteCount += 1
                } else if b == delimiter {
                    fields.append(try decode(fieldBytes, quoted: false))
                    fieldBytes.removeAll(keepingCapacity: true)
                    fieldQuoted = false
                    byteCount += 1
                } else if b == 10 {  // \n
                    line += 1
                    if fields.isEmpty && fieldBytes.isEmpty && !fieldQuoted && byteCount == 0 {
                        return nil  // blank line
                    }
                    fields.append(try decode(fieldBytes, quoted: fieldQuoted))
                    return fields
                } else if b == 13 {  // \r
                    try consumeOptionalLF()
                    line += 1
                    if fields.isEmpty && fieldBytes.isEmpty && !fieldQuoted && byteCount == 0 {
                        return nil  // blank line
                    }
                    fields.append(try decode(fieldBytes, quoted: fieldQuoted))
                    return fields
                } else {
                    state = .unquoted
                    fieldBytes.append(b)
                    byteCount += 1
                }
            case .unquoted:
                if b == delimiter {
                    fields.append(try decode(fieldBytes, quoted: false))
                    fieldBytes.removeAll(keepingCapacity: true)
                    fieldQuoted = false
                    state = .fieldStart
                } else if b == 10 {
                    line += 1
                    fields.append(try decode(fieldBytes, quoted: false))
                    return fields
                } else if b == 13 {
                    try consumeOptionalLF()
                    line += 1
                    fields.append(try decode(fieldBytes, quoted: false))
                    return fields
                } else {
                    fieldBytes.append(b)
                }
            case .quoted:
                if b == 34 {
                    guard let n = try feeder.nextByte() else {
                        state = .afterQuote
                        break  // EOF right after closing quote; loop re-reads nil
                    }
                    if n == 34 {
                        fieldBytes.append(34)  // escaped quote
                    } else {
                        feeder.pushBack(n)
                        state = .afterQuote
                    }
                } else {
                    if b == 10 || b == 13 {
                        // Line break inside quotes: kept verbatim, but still
                        // counted so later errors report sane line numbers.
                        if b == 13, let n = try feeder.nextByte() {
                            if n == 10 {
                                fieldBytes.append(contentsOf: [13, 10])
                            } else {
                                feeder.pushBack(n)
                                fieldBytes.append(13)
                            }
                        } else if b == 10 {
                            fieldBytes.append(10)
                        }
                        line += 1
                    } else {
                        fieldBytes.append(b)
                    }
                }
            case .afterQuote:
                if b == delimiter {
                    fields.append(try decode(fieldBytes, quoted: true))
                    fieldBytes.removeAll(keepingCapacity: true)
                    fieldQuoted = false
                    state = .fieldStart
                } else if b == 10 {
                    line += 1
                    fields.append(try decode(fieldBytes, quoted: true))
                    return fields
                } else if b == 13 {
                    try consumeOptionalLF()
                    line += 1
                    fields.append(try decode(fieldBytes, quoted: true))
                    return fields
                } else {
                    throw CSVError.unexpectedCharacterAfterQuote(line: line)
                }
            }
        }
    }

    private mutating func consumeOptionalLF() throws {
        guard let n = try feeder.nextByte() else { return }
        if n != 10 {
            feeder.pushBack(n)
        }
    }

    /// Whether unquoted fields are whitespace-trimmed before decoding
    /// completes. Fixed at init; the table driver forwards the option.
    private let trimsWhitespace: Bool

    private func decode(_ bytes: [UInt8], quoted: Bool) throws -> String {
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw CSVError.invalidUTF8(line: line)
        }
        if !quoted, trimsWhitespace {
            return text.trimmingCharacters(in: .whitespaces)
        }
        return text
    }
}
