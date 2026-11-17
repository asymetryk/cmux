import Foundation

/// Removes rendered table furniture, not punctuation in prose or commands.
enum ReadAloudTableText {
    private static let verticalRules = "│┃┆┇┊┋║╎╏"
    private static let horizontalRules = "─━┄┅┈┉╌╍═"

    static func prepare(_ text: String) throws -> String {
        try Task.checkCancellation()
        guard text.unicodeScalars.contains(where: isBoxDrawing) else { return text }

        var output = String()
        output.reserveCapacity(text.utf8.count)
        var cells: [String] = []
        var changed = false
        var position = text.startIndex

        func flushRow() {
            guard !cells.isEmpty else { return }
            var needsSpace = false
            for cell in cells where !cell.isEmpty {
                if needsSpace { output.append(" ") }
                output.append(cell)
                if let last = cell.last, !".!?。！？:;,：；，".contains(last) {
                    output.append(".")
                }
                needsSpace = true
            }
            if needsSpace { output.append("\n") }
            cells.removeAll(keepingCapacity: true)
        }

        while position < text.endIndex {
            try Task.checkCancellation()
            let end = text[position...].firstIndex(where: \.isNewline) ?? text.endIndex
            let next = end < text.endIndex ? text.index(after: end) : end
            let line = text[position..<end].trimmingCharacters(in: .whitespaces)

            if isRule(line) {
                flushRow()
                changed = true
            } else if let row = tableCells(line) {
                changed = true
                // A blank leading cell is the conventional continuation of a
                // wrapped row. Rules flush the row, so distinct rows stay separate.
                if row.first == "", row.count == cells.count {
                    for index in row.indices where !row[index].isEmpty {
                        if !cells[index].isEmpty { cells[index].append(" ") }
                        cells[index].append(row[index])
                    }
                } else {
                    flushRow()
                    cells = row
                }
            } else {
                flushRow()
                output.append(contentsOf: text[position..<next])
            }
            position = next
        }
        flushRow()
        return changed ? output : text
    }

    private static func isBoxDrawing(_ scalar: Unicode.Scalar) -> Bool {
        (0x2500...0x257F).contains(scalar.value)
    }

    private static func isRule(_ line: String) -> Bool {
        line.contains(where: { horizontalRules.contains($0) })
            && line.unicodeScalars.allSatisfy { isBoxDrawing($0) || $0.properties.isWhitespace }
    }

    private static func tableCells(_ line: String) -> [String]? {
        guard let first = line.first, verticalRules.contains(first),
              line.dropFirst().contains(where: { verticalRules.contains($0) }) else {
            return nil
        }
        var parts = line.split(omittingEmptySubsequences: false) { verticalRules.contains($0) }
        parts.removeFirst() // The leading outer rule is not a column.
        if let last = line.last, verticalRules.contains(last) { parts.removeLast() }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
