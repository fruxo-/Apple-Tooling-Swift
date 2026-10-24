import Foundation

/// One-time scan of the Mail directory: numeric file name -> every .emlx / .partial.emlx with that name.
struct EmlxIndex {
    private(set) var filesByID: [Int64: [URL]] = [:]
    private(set) var fileCount = 0

    init(root: URL) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            if url.lastPathComponent == "MailData" {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "emlx" else { continue }
            guard let stem = url.lastPathComponent.split(separator: ".").first,
                  let id = Int64(stem) else { continue }
            filesByID[id, default: []].append(url)
            fileCount += 1
        }
    }
}

/// Matches a database message to its .emlx file.
///
/// File names are numeric IDs. On current macOS versions that is normally `messages.ROWID`, but
/// `remote_id` is tried too. A candidate is accepted when its Message-ID header matches the one in
/// `message_global_data`; failing that, a ROWID-named file inside the message's own mailbox folder
/// is accepted without verification.
struct EmlxLocator {
    let index: EmlxIndex

    private struct Candidate {
        let url: URL
        let viaRowID: Bool
        let mailboxMatch: Bool
    }

    func locate(_ message: Message) -> URL? {
        var seen = Set<URL>()
        var candidates: [Candidate] = []

        for copy in message.copies {
            let fragment = Self.mailboxPathFragment(copy.mailboxURL)
            var ids: [(id: Int64, viaRowID: Bool)] = [(copy.rowID, true)]
            if let remoteID = copy.remoteID {
                ids.append((remoteID, false))
            }
            for entry in ids {
                for url in index.filesByID[entry.id] ?? [] where !seen.contains(url) {
                    seen.insert(url)
                    let match = fragment.map { url.path.lowercased().contains($0) } ?? true
                    candidates.append(Candidate(url: url, viaRowID: entry.viaRowID, mailboxMatch: match))
                }
            }
        }

        // Prefer files in the right mailbox, and complete files over .partial.emlx.
        candidates.sort { lhs, rhs in
            if lhs.mailboxMatch != rhs.mailboxMatch { return lhs.mailboxMatch }
            let lhsPartial = lhs.url.lastPathComponent.contains("partial")
            let rhsPartial = rhs.url.lastPathComponent.contains("partial")
            return !lhsPartial && rhsPartial
        }

        if let header = message.messageIDHeader {
            let expected = Self.normalize(header)
            if !expected.isEmpty {
                for candidate in candidates {
                    if let found = EmlxReader.messageID(at: candidate.url), Self.normalize(found) == expected {
                        return candidate.url
                    }
                }
            }
        }

        return candidates.first { $0.viaRowID && $0.mailboxMatch }?.url
    }

    private static func normalize(_ messageID: String) -> String {
        messageID
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
            .lowercased()
    }

    /// `imap://UUID/Folder/Sub%20Folder` -> `/uuid/folder.mbox/sub folder.mbox/` (lowercased).
    private static func mailboxPathFragment(_ urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let host = components.host, !host.isEmpty else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        let folders = parts.map { $0 + ".mbox" }.joined(separator: "/")
        return "/\(host)/\(folders)/".lowercased()
    }
}
