import Foundation
import Testing

import DataTables

// NaN-aware equality: `[Double] ==` is false whenever NaN is present,
// so every numeric assertion below goes through these helpers.
private func expectDoubles(_ actual: [Double]?, _ expected: [Double], sourceLocation: SourceLocation = #_sourceLocation) {
    guard let actual else {
        Issue.record("expected \(expected), got nil", sourceLocation: sourceLocation)
        return
    }
    #expect(actual.count == expected.count, sourceLocation: sourceLocation)
    for (a, e) in zip(actual, expected) {
        if a.isNaN, e.isNaN { continue }
        #expect(a == e, sourceLocation: sourceLocation)
    }
}

private func expectMatrix(_ actual: [[Double]]?, _ expected: [[Double]], sourceLocation: SourceLocation = #_sourceLocation) {
    guard let actual else {
        Issue.record("expected matrix \(expected), got nil", sourceLocation: sourceLocation)
        return
    }
    #expect(actual.count == expected.count, sourceLocation: sourceLocation)
    for (a, e) in zip(actual, expected) {
        expectDoubles(a, e, sourceLocation: sourceLocation)
    }
}

@Test func headerNamesAndRowCount() throws {
    let table = try CSVTable.parse("x,y\n1,2\n3,4\n")
    #expect(table.columnNames == ["x", "y"])
    #expect(table.rowCount == 2)
    expectDoubles(table.doubles(forColumn: "x"), [1, 3])
    expectDoubles(table.doubles(forColumn: 1), [2, 4])
}

@Test func quotingDelimitersEscapesAndNewlines() throws {
    let content = "a,b,c\r\n\"x,y\",\"p\"\"q\",\"line1\nline2\"\r\nplain,\" spaced \",end"
    let table = try CSVTable.parse(content)
    #expect(table.columnNames == ["a", "b", "c"])
    #expect(table.rowCount == 2)
    #expect(table.column("a")?.strings == ["x,y", "plain"])
    #expect(table.column("b")?.strings == ["p\"q", " spaced "])
    #expect(table.column("c")?.strings == ["line1\nline2", "end"])
}

@Test func customDelimiter() throws {
    var options = CSVOptions()
    options.delimiter = ";"
    let table = try CSVTable.parse("x;y\n1;2\n", options: options)
    #expect(table.columnNames == ["x", "y"])
    expectDoubles(table.doubles(forColumn: "y"), [2])
}

@Test func missingMarkersAndInference() throws {
    let table = try CSVTable.parse("i,d,s,e\n1,1.5,a,NA\n2,NA,b,\nNA,2.5,,NaN\n")
    #expect(table.inferredTypes == [.integer, .double, .string, .double])
    expectDoubles(table.doubles(forColumn: "i"), [1, 2, .nan])
    expectDoubles(table.doubles(forColumn: "d"), [1.5, .nan, 2.5])
    expectDoubles(table.doubles(forColumn: "e"), [.nan, .nan, .nan])
    #expect(table.doubles(forColumn: "s") == nil)  // string column: no numeric view
    #expect(table.strings(forColumn: "s") == ["a", "b", nil])
}

@Test func integerColumnDowngradesToDouble() throws {
    let table = try CSVTable.parse("v\n1\n2.5\n3\n")
    #expect(table.inferredTypes == [.double])
    expectDoubles(table.doubles(forColumn: "v"), [1, 2.5, 3])
}

@Test func noHeaderGeneratesNames() throws {
    var options = CSVOptions()
    options.hasHeader = false
    let table = try CSVTable.parse("1,2\n3,4\n", options: options)
    #expect(table.columnNames == ["column_1", "column_2"])
    #expect(table.rowCount == 2)
    expectDoubles(table.doubles(forColumn: "column_2"), [2, 4])
}

@Test func blankLinesSkipped() throws {
    let table = try CSVTable.parse("\nx,y\n\n1,2\n\n3,4\n\n")
    #expect(table.columnNames == ["x", "y"])
    #expect(table.rowCount == 2)
}

@Test func raggedRowThrowsWithLine() throws {
    #expect(throws: CSVError.raggedRow(line: 3, expected: 2, found: 3)) {
        try CSVTable.parse("x,y\n1,2\n3,4,5\n")
    }
}

@Test func unterminatedQuoteThrows() throws {
    #expect(throws: CSVError.unterminatedQuote(line: 2)) {
        try CSVTable.parse("x\n\"abc\n")
    }
}

@Test func textAfterClosingQuoteThrows() throws {
    #expect(throws: CSVError.unexpectedCharacterAfterQuote(line: 2)) {
        try CSVTable.parse("x\n\"a\"x\n")
    }
}

@Test func loneCarriageReturnEndsRow() throws {
    let table = try CSVTable.parse("x,y\r1,2\r3,4\r")
    #expect(table.rowCount == 2)
    expectDoubles(table.doubles(forColumn: "x"), [1, 3])
}

@Test func emptyInputThrows() throws {
    #expect(throws: CSVError.emptyInput) {
        try CSVTable.parse("\n\n")
    }
    #expect(throws: CSVError.emptyInput) {
        try CSVTable.parse("")
    }
}

@Test func whitespaceTrimming() throws {
    let content = "v\n 1 \n2\n"
    let trimmed = try CSVTable.parse(content)
    #expect(trimmed.inferredTypes == [.integer])
    var options = CSVOptions()
    options.trimsWhitespace = false
    let raw = try CSVTable.parse(content, options: options)
    // " 1 " survives verbatim, so the column is no longer numeric.
    #expect(raw.inferredTypes == [.string])
    #expect(raw.strings(forColumn: "v") == [" 1 ", "2"])
}

@Test func customMissingMarkers() throws {
    var options = CSVOptions()
    options.missingMarkers = ["", "NULL"]
    let table = try CSVTable.parse("v\nNULL\nNA\n1\n", options: options)
    // "NA" is no longer missing here — it makes the column textual.
    #expect(table.inferredTypes == [.string])
    #expect(table.strings(forColumn: "v") == [nil, "NA", "1"])
}

@Test func chunkSizeNeverChangesResults() throws {
    let content = "name,x,y,note\n\"a,1\",1,1.5,\"héllo 🌍\"\nb,NA,2.5,\"multi\nline\"\nc,3,,\"q\"\"q\"\n"
    let sizes = [1, 2, 7, 64 * 1024]
    let reference = try CSVTable.parse(content)
    for size in sizes {
        var options = CSVOptions()
        options.chunkSize = size
        let table = try CSVTable.parse(content, options: options)
        #expect(table.columnNames == reference.columnNames)
        #expect(table.inferredTypes == reference.inferredTypes)
        for name in reference.columnNames {
            if let expected = reference.doubles(forColumn: name) {
                expectDoubles(table.doubles(forColumn: name), expected)
            } else {
                #expect(table.strings(forColumn: name) == reference.strings(forColumn: name))
            }
        }
    }
}

@Test func fileLoadMatchesStringParse() throws {
    let content = "x,y\n1,2\n3,NA\n"
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("datatables-\(UUID().uuidString).csv")
    try content.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let fromFile = try CSVTable.load(contentsOf: url)
    let fromString = try CSVTable.parse(content)
    #expect(fromFile.columnNames == fromString.columnNames)
    expectDoubles(fromFile.doubles(forColumn: "y"), [2, .nan])
    expectMatrix(
        fromFile.numericMatrix(columns: ["x", "y"]),
        [[1, 2], [3, .nan]]
    )
}

@Test func fileLoadStreamsInTinyChunks() throws {
    // Same bytes through the file path with a 3-byte buffer: multibyte
    // characters and quotes straddle refill boundaries by construction.
    let content = "id,label\n1,\"日本語テスト 🌍, ok\"\n2,plain\n"
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("datatables-\(UUID().uuidString).csv")
    try content.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    var options = CSVOptions()
    options.chunkSize = 3
    let table = try CSVTable.load(contentsOf: url, options: options)
    #expect(table.strings(forColumn: "label") == ["日本語テスト 🌍, ok", "plain"])
    expectDoubles(table.doubles(forColumn: "id"), [1, 2])
}

@Test func missingFileThrows() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("datatables-\(UUID().uuidString)-absent.csv")
    #expect(throws: (any Error).self) {
        try CSVTable.load(contentsOf: url)
    }
}

@Test func numericMatrixShapeAndNilCases() throws {
    let table = try CSVTable.parse("x,y,label\n1,2,a\n3,4,b\n")
    expectMatrix(
        table.numericMatrix(columns: ["y", "x"]),
        [[2, 1], [4, 3]]
    )
    expectMatrix(table.numericMatrix(columnIndices: [0]), [[1], [3]])
    #expect(table.numericMatrix(columns: ["x", "label"]) == nil)  // string column
    #expect(table.numericMatrix(columns: ["x", "nope"]) == nil)  // unknown name
    #expect(table.numericMatrix(columnIndices: [0, 9]) == nil)  // out of range
}

@Test func streamsLargeFileWithoutWholeStringLoad() throws {
    // 100k rows written incrementally (never one big String on either
    // side), then streamed back: the large-dataset contract.
    let n = 100_000
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("datatables-\(UUID().uuidString)-large.csv")
    defer { try? FileManager.default.removeItem(at: url) }
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    func append(_ s: String) throws {
        try handle.write(contentsOf: Data(s.utf8))
    }
    try append("x,y\n")
    var batch = ""
    batch.reserveCapacity(256 * 1024)
    for i in 0..<n {
        let x = Double(i) * 0.001
        let y = sin(x) + 0.01 * sin(13.0 * x)
        if i % 97 == 0 {
            batch += "\(x),NA\n"
        } else if i % 131 == 0 {
            batch += "NA,\(y)\n"
        } else {
            batch += "\(x),\(y)\n"
        }
        if i % 5000 == 4999 {
            try append(batch)
            batch = ""
        }
    }
    try append(batch)

    let table = try CSVTable.load(contentsOf: url)
    #expect(table.columnNames == ["x", "y"])
    #expect(table.rowCount == n)
    #expect(table.inferredTypes == [.double, .double])
    guard let xs = table.doubles(forColumn: "x"),
          let ys = table.doubles(forColumn: "y")
    else {
        Issue.record("numeric extraction returned nil")
        return
    }
    // Missing markers land exactly where the generator put them
    // (97-rule drops y, 131-rule drops x; i=0 hits the 97-rule).
    #expect(!xs[0].isNaN && ys[0].isNaN)
    #expect(!xs[97].isNaN && ys[97].isNaN)
    #expect(xs[131].isNaN && ys[131].isFinite)
    let expectedY = sin(1.0) + 0.01 * sin(13.0)
    #expect(abs(xs[1000] - 1.0) <= 1e-12)
    #expect(abs(ys[1000] - expectedY) <= 1e-12)
    // Row-major matrix has the full shape DataLens eats.
    let matrix = table.numericMatrix(columns: ["x", "y"])
    #expect(matrix?.count == n)
}
