// Print the text of each PDF page as one JSON line:
// {"file": PATH, "page": N, "text": TEXT}. Pages count from 1.
// Used by extract-terms.py; PDFKit ships with macOS, so nothing to install.
import Foundation
import PDFKit

for path in CommandLine.arguments.dropFirst() {
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)), !document.isLocked else {
        FileHandle.standardError.write(Data("Cannot read PDF: \(path)\n".utf8))
        continue
    }
    for index in 0..<document.pageCount {
        let line: [String: Any] = ["file": path, "page": index + 1, "text": document.page(at: index)?.string ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: line) else { continue }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
