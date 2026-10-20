import CSQLite
import CryptoKit
import Foundation

private enum BackupError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case let .message(value): return value
        }
    }
}

private struct Options {
    var database = "~/Library/Containers/com.apple.Safari/Data/Library/Safari/SafariTabs.db"
    var backupDirectory = "~/Library/Mobile Documents/com~apple~CloudDocs/SafariTabGroupsBackups"
    var snapshotDirectory = "~/Library/Caches/safaritabsbackup"
    var logDirectory = "~/Library/Logs"
}

private func usage() -> String {
    """
    Usage: safari-tabs-backup [--database PATH] [--backup-dir DIR] [--snapshot-dir DIR] [--log-dir DIR]
    Snapshot Safari's tabs database and incrementally sync changed content.
      --database PATH     source database
      --backup-dir DIR    synchronized snapshot destination
      --snapshot-dir DIR  local snapshot and content hash directory
      --log-dir DIR       directory for safaritabsbackup.log and .err
      -h, --help          show this help
    """
}

private func parseArguments() throws -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let argument = args.removeFirst()
        switch argument {
        case "-h", "--help":
            print(usage())
            exit(0)
        case "--database", "--backup-dir", "--snapshot-dir", "--log-dir":
            guard !args.isEmpty else { throw BackupError.message("missing value for \(argument)") }
            let value = args.removeFirst()
            switch argument {
            case "--database": options.database = value
            case "--backup-dir": options.backupDirectory = value
            case "--snapshot-dir": options.snapshotDirectory = value
            default: options.logDirectory = value
            }
        default:
            throw BackupError.message("unexpected argument: \(argument)\n\n\(usage())")
        }
    }
    return options
}

private func expandedURL(_ path: String) -> URL {
    URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
}

private final class Logger {
    private let outputURL: URL
    private let errorURL: URL

    init(directory: URL) {
        outputURL = directory.appendingPathComponent("safaritabsbackup.log")
        errorURL = directory.appendingPathComponent("safaritabsbackup.err")
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    private func append(_ line: String, to url: URL, toStandardError: Bool) {
        let data = Data((line + "\n").utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: data) else {
                fputs("ERROR: unable to create log \(url.path)\n", Darwin.stderr)
                return
            }
        } else if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                fputs("ERROR: unable to write log \(url.path): \(error)\n", Darwin.stderr)
                return
            }
        } else {
            fputs("ERROR: unable to open log \(url.path) for writing\n", Darwin.stderr)
            return
        }
        if toStandardError {
            fputs(line + "\n", Darwin.stderr)
        } else {
            print(line)
        }
    }

    func log(_ message: String) { append("\(timestamp()) \(message)", to: outputURL, toStandardError: false) }
    func error(_ message: String) { append("\(timestamp()) ERROR: \(message)", to: errorURL, toStandardError: true) }

    func trimLogs() throws {
        for url in [outputURL, errorURL] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let contents = try String(contentsOf: url, encoding: .utf8)
            let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > 1000 {
                let retained = lines.suffix(500).joined(separator: "\n")
                try (retained + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

private func createSnapshot(from source: URL, at destination: URL) throws {
    var sourceHandle: OpaquePointer?
    let sourceResult = sqlite3_open_v2(source.path, &sourceHandle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
    guard sourceResult == SQLITE_OK, let sourceHandle else {
        let message = sourceHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open source database"
        if let sourceHandle { sqlite3_close(sourceHandle) }
        throw BackupError.message(message)
    }
    defer { sqlite3_close(sourceHandle) }

    var destinationHandle: OpaquePointer?
    let destinationResult = sqlite3_open_v2(destination.path, &destinationHandle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
    guard destinationResult == SQLITE_OK, let destinationHandle else {
        let message = destinationHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to create snapshot database"
        if let destinationHandle { sqlite3_close(destinationHandle) }
        throw BackupError.message(message)
    }
    defer { sqlite3_close(destinationHandle) }

    guard let backup = sqlite3_backup_init(destinationHandle, "main", sourceHandle, "main") else {
        throw BackupError.message(String(cString: sqlite3_errmsg(destinationHandle)))
    }
    var result = sqlite3_backup_step(backup, -1)
    while result == SQLITE_BUSY || result == SQLITE_LOCKED {
        Thread.sleep(forTimeInterval: 0.1)
        result = sqlite3_backup_step(backup, -1)
    }
    let finishResult = sqlite3_backup_finish(backup)
    guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
        throw BackupError.message(String(cString: sqlite3_errmsg(destinationHandle)))
    }
}

private func contentHash(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    _ = try handle.read(upToCount: 100)
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func runRsync(snapshot: URL, destination: URL, logger: Logger) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
    process.arguments = ["--stats", "-c", "-i", "--no-whole-file", "--inplace", snapshot.path, destination.path + "/"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        throw BackupError.message("could not launch rsync: \(error)")
    }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let lines = String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
    for line in lines { logger.log("rsync: \(line)") }
    guard process.terminationStatus == 0 else {
        throw BackupError.message("rsync failed (exit code \(process.terminationStatus))")
    }
}

@main
private enum SafariTabsBackup {
    static func main() {
        var logger: Logger?
        do {
            let options = try parseArguments()
            let source = expandedURL(options.database)
            let backupDirectory = expandedURL(options.backupDirectory)
            let snapshotDirectory = expandedURL(options.snapshotDirectory)
            let logDirectory = expandedURL(options.logDirectory)
            logger = Logger(directory: logDirectory)
            guard let logger else { throw BackupError.message("unable to initialize logger") }
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            try logger.trimLogs()

            guard FileManager.default.fileExists(atPath: source.path) else {
                throw BackupError.message("\(source.path) not found (missing Full Disk Access?)")
            }
            try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let snapshot = snapshotDirectory.appendingPathComponent("SafariTabs.db")
            let hashFile = snapshotDirectory.appendingPathComponent("content.sha")

            logger.log("Backing up...")
            try createSnapshot(from: source, at: snapshot)
            logger.log("... done")

            logger.log("Hashing...")
            let newHash = try contentHash(of: snapshot)
            logger.log("... done")
            if let previousHash = try? String(contentsOf: hashFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), previousHash == newHash {
                logger.log("No changes since last backup")
                return
            }

            logger.log("Syncing...")
            try runRsync(snapshot: snapshot, destination: backupDirectory, logger: logger)
            logger.log("... done")
            try (newHash + "\n").write(to: hashFile, atomically: true, encoding: .utf8)
            logger.log("Backup updated")
        } catch {
            fputs("ERROR: \(error)\n", Darwin.stderr)
            logger?.error(String(describing: error))
            exit(1)
        }
    }
}
