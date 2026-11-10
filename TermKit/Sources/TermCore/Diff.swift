import Foundation

/// Line diffs for showing file edits.
public enum Diff {
    struct Operation {
        var kind: Character
        var text: Substring
    }

    static func lines(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts
    }

    static func operations(_ old: [Substring], _ new: [Substring]) -> [Operation] {
        var start = 0
        while start < old.count, start < new.count, old[start] == new[start] { start += 1 }
        var oldEnd = old.count, newEnd = new.count
        while oldEnd > start, newEnd > start, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        let oldMiddle = Array(old[start..<oldEnd]), newMiddle = Array(new[start..<newEnd])
        var result = old[..<start].map { Operation(kind: " ", text: $0) }
        if oldMiddle.count * newMiddle.count > 4_000_000 {
            // Too big for the table: show the changed region as a plain replacement.
            result += oldMiddle.map { Operation(kind: "-", text: $0) } + newMiddle.map { Operation(kind: "+", text: $0) }
        } else {
            result += longestCommon(oldMiddle, newMiddle)
        }
        result += old[oldEnd...].map { Operation(kind: " ", text: $0) }
        return result
    }

    private static func longestCommon(_ old: [Substring], _ new: [Substring]) -> [Operation] {
        let rows = old.count, columns = new.count
        guard rows > 0, columns > 0 else {
            return old.map { Operation(kind: "-", text: $0) } + new.map { Operation(kind: "+", text: $0) }
        }
        let width = columns + 1
        var table = [Int32](repeating: 0, count: (rows + 1) * width)
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                table[row * width + column] = old[row] == new[column]
                    ? table[(row + 1) * width + column + 1] + 1
                    : max(table[(row + 1) * width + column], table[row * width + column + 1])
            }
        }
        var result: [Operation] = []
        var row = 0, column = 0
        while row < rows, column < columns {
            if old[row] == new[column] {
                result.append(Operation(kind: " ", text: old[row]))
                row += 1
                column += 1
            } else if table[(row + 1) * width + column] >= table[row * width + column + 1] {
                result.append(Operation(kind: "-", text: old[row]))
                row += 1
            } else {
                result.append(Operation(kind: "+", text: new[column]))
                column += 1
            }
        }
        while row < rows {
            result.append(Operation(kind: "-", text: old[row]))
            row += 1
        }
        while column < columns {
            result.append(Operation(kind: "+", text: new[column]))
            column += 1
        }
        return result
    }

    /// Changed lines with `context` unchanged lines around them. Each line starts with ` `, `+` or `-`;
    /// hunks start with an `@@` line. Empty when the texts are equal.
    public static func unified(old: String, new: String, context: Int = 2, maxLines: Int = 160) -> String {
        let operations = operations(lines(old), lines(new))
        var keep = [Bool](repeating: false, count: operations.count)
        var changed = false
        for (index, operation) in operations.enumerated() where operation.kind != " " {
            changed = true
            for neighbour in max(0, index - context)...min(operations.count - 1, index + context) {
                keep[neighbour] = true
            }
        }
        guard changed else { return "" }

        var output: [String] = []
        var oldLine = 1, newLine = 1
        var inHunk = false
        for (index, operation) in operations.enumerated() {
            if keep[index] {
                if !inHunk { output.append("@@ -\(oldLine) +\(newLine) @@") }
                output.append("\(operation.kind)\(operation.text)")
            }
            inHunk = keep[index]
            if operation.kind != "+" { oldLine += 1 }
            if operation.kind != "-" { newLine += 1 }
        }
        if output.count > maxLines {
            let extra = output.count - maxLines
            output = Array(output.prefix(maxLines)) + ["… \(extra) more lines"]
        }
        return output.joined(separator: "\n")
    }

    public static func stats(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in diff.split(separator: "\n") {
            if line.hasPrefix("+") { added += 1 }
            if line.hasPrefix("-") { removed += 1 }
        }
        return (added, removed)
    }
}
