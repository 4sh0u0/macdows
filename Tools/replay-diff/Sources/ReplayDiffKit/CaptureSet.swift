import Foundation

/// Errors the differ raises about its *inputs*, as opposed to differences it found between
/// them. Kept separate so a caller can give input problems their own exit code: "the gate
/// could not run" and "the gate ran and failed" are different outcomes for a drill record.
public enum CaptureSetError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case notReadable(path: String, reason: String)
    case emptyDirectory(String)
    case mismatchedKinds

    public var description: String {
        switch self {
        case .notFound(let path):
            return "input does not exist: \(path)"
        case .notReadable(let path, let reason):
            return "cannot read \(path): \(reason)"
        case .emptyDirectory(let path):
            return "no .jsonl captures in directory: \(path)"
        case .mismatchedKinds:
            return "baseline and candidate must both be files or both be directories"
        }
    }
}

/// Resolves a file-or-directory pair into ``ReplayStream`` pairs and runs the differ over
/// them.
public enum CaptureSet {
    /// Compares two `.jsonl` captures, or two directories of them.
    ///
    /// Directory mode pairs by *base name*: `s1-baseline.jsonl` on one side is only ever
    /// compared with `s1-baseline.jsonl` on the other. A capture present on one side only
    /// is reported as unpaired rather than diffed against nothing, because a missing
    /// scenario file is a gate-input problem and must not read as "no differences".
    public static func compare(
        baselinePath: String,
        candidatePath: String,
        differ: SemanticDiffer
    ) throws -> DiffReportSet {
        let fileManager = FileManager.default
        var baselineIsDirectory: ObjCBool = false
        var candidateIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: baselinePath, isDirectory: &baselineIsDirectory) else {
            throw CaptureSetError.notFound(baselinePath)
        }
        guard fileManager.fileExists(atPath: candidatePath, isDirectory: &candidateIsDirectory) else {
            throw CaptureSetError.notFound(candidatePath)
        }
        guard baselineIsDirectory.boolValue == candidateIsDirectory.boolValue else {
            throw CaptureSetError.mismatchedKinds
        }

        if !baselineIsDirectory.boolValue {
            let baseline = try loadStream(atPath: baselinePath)
            let candidate = try loadStream(atPath: candidatePath)
            return DiffReportSet(reports: [differ.diff(baseline: baseline, candidate: candidate)])
        }

        let baselineFiles = try captureFiles(inDirectory: baselinePath)
        let candidateFiles = try captureFiles(inDirectory: candidatePath)
        let baselineNames = Set(baselineFiles.keys)
        let candidateNames = Set(candidateFiles.keys)

        var reports: [DiffReport] = []
        for name in baselineNames.intersection(candidateNames).sorted() {
            let baseline = try loadStream(atPath: baselineFiles[name]!)
            let candidate = try loadStream(atPath: candidateFiles[name]!)
            reports.append(differ.diff(baseline: baseline, candidate: candidate))
        }
        return DiffReportSet(
            reports: reports,
            unpairedBaselines: baselineNames.subtracting(candidateNames).sorted(),
            unpairedCandidates: candidateNames.subtracting(baselineNames).sorted()
        )
    }

    static func loadStream(atPath path: String) throws -> ReplayStream {
        let url = URL(fileURLWithPath: path)
        do {
            return try ReplayStream.parse(fileAt: url)
        } catch {
            throw CaptureSetError.notReadable(path: url.lastPathComponent, reason: "\(error)")
        }
    }

    /// Base name → full path, for every `.jsonl` directly inside `directory`. Not
    /// recursive: a captures directory is flat, and recursing would silently pull in
    /// whatever an operator left in a subdirectory.
    static func captureFiles(inDirectory directory: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch {
            throw CaptureSetError.notReadable(path: directory, reason: "\(error)")
        }
        let captures = contents.filter { $0.pathExtension.lowercased() == "jsonl" }
        guard !captures.isEmpty else { throw CaptureSetError.emptyDirectory(directory) }
        return Dictionary(uniqueKeysWithValues: captures.map { ($0.lastPathComponent, $0.path) })
    }
}
