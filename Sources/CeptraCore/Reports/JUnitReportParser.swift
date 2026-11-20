import Foundation

public enum JUnitReportParser {
    public static func parse(xmlData: Data) -> [ExecutedScenarioRecord] {
        let delegate = JUnitXMLDelegate()
        let parser = XMLParser(data: xmlData)
        parser.delegate = delegate
        guard parser.parse() else {
            return []
        }
        return delegate.records
    }

    public static func parse(fileURL: URL) -> [ExecutedScenarioRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return parse(xmlData: data)
    }

    /// Parses CodeceptJS 4.x `junitReporter` `<system-out>` indented step trace lines.
    public static func parseSystemOutSteps(_ text: String) -> [ExecutedStepRecord] {
        let lines = text.components(separatedBy: .newlines)
        var steps: [ExecutedStepRecord] = []
        let durationRegex = try? NSRegularExpression(pattern: #"\s*\((\d+)ms\)\s*$"#)

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let leadingSpaces = rawLine.prefix(while: { $0 == " " }).count
            let depth = leadingSpaces / 2

            var working = trimmed
            var status: ExecutionStatus = .passed
            if working.hasPrefix("[FAILED] ") {
                status = .failed
                working = String(working.dropFirst("[FAILED] ".count))
            }

            var durationMs: Int? = nil
            if let regex = durationRegex {
                let ns = working as NSString
                if let match = regex.firstMatch(in: working, range: NSRange(location: 0, length: ns.length)) {
                    durationMs = Int(ns.substring(with: match.range(at: 1)))
                    working = ns.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
                }
            }

            steps.append(ExecutedStepRecord(
                text: working,
                depth: depth,
                status: status,
                durationMs: durationMs
            ))
        }
        return steps
    }

    private final class JUnitXMLDelegate: NSObject, XMLParserDelegate {
        var records: [ExecutedScenarioRecord] = []

        private var currentSuiteName: String = "Suite"
        private var currentSuiteFile: String? = nil

        private var inTestCase = false
        private var tcName = ""
        private var tcClassName = ""
        private var tcFile: String? = nil
        private var tcDurationMs = 0
        private var tcStatus: ExecutionStatus = .passed
        private var tcTags: [String] = []
        private var tcErrorMessage: String? = nil
        private var tcErrorStack: String? = nil
        private var tcSteps: [ExecutedStepRecord] = []

        private var currentElement = ""
        private var textBuffer = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            currentElement = elementName
            textBuffer = ""

            switch elementName {
            case "testsuite":
                if let name = attributeDict["name"], !name.isEmpty {
                    currentSuiteName = name
                }
                currentSuiteFile = attributeDict["file"]

            case "testcase":
                inTestCase = true
                tcName = attributeDict["name"] ?? "Scenario"
                tcClassName = attributeDict["classname"] ?? currentSuiteName
                tcFile = attributeDict["file"] ?? currentSuiteFile
                if let timeStr = attributeDict["time"], let seconds = Double(timeStr) {
                    tcDurationMs = Int((seconds * 1000.0).rounded())
                } else {
                    tcDurationMs = 0
                }
                tcStatus = .passed
                tcTags = []
                tcErrorMessage = nil
                tcErrorStack = nil
                tcSteps = []

            case "property":
                if inTestCase, attributeDict["name"] == "tags", let val = attributeDict["value"] {
                    let parsedTags = val.split(separator: " ").map(String.init).filter { !$0.isEmpty }
                    tcTags.append(contentsOf: parsedTags)
                }

            case "failure", "error":
                if inTestCase {
                    tcStatus = .failed
                    tcErrorMessage = attributeDict["message"]
                }

            case "skipped":
                if inTestCase {
                    tcStatus = .skipped
                    if let msg = attributeDict["message"], !msg.isEmpty {
                        tcErrorMessage = msg
                    }
                }

            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            textBuffer.append(string)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            switch elementName {
            case "failure", "error":
                let trimmed = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    tcErrorStack = trimmed
                    if tcErrorMessage == nil || tcErrorMessage?.isEmpty == true {
                        tcErrorMessage = trimmed.components(separatedBy: .newlines).first
                    }
                }

            case "system-out":
                if inTestCase {
                    tcSteps = JUnitReportParser.parseSystemOutSteps(textBuffer)
                }

            case "testcase":
                let featureTitle = tcClassName.isEmpty ? currentSuiteName : tcClassName
                let inlineTags = tcName.split(separator: " ").map(String.init).filter { $0.hasPrefix("@") }
                let allTags = Array(Set(tcTags + inlineTags)).sorted()
                records.append(ExecutedScenarioRecord(
                    featureTitle: featureTitle,
                    scenarioTitle: tcName,
                    filePath: tcFile,
                    status: tcStatus,
                    durationMs: tcDurationMs,
                    tags: allTags,
                    steps: tcSteps,
                    errorMessage: tcErrorMessage,
                    errorStack: tcErrorStack
                ))
                inTestCase = false

            default:
                break
            }
            textBuffer = ""
            currentElement = ""
        }
    }
}
