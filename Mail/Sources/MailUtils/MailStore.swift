import Foundation

struct MailQuery {
    /// Inclusive Unix-second bounds.
    let from: Int64
    let to: Int64
    let includeDeleted: Bool
}

enum MailStore {
    /// Sent date, falling back to received/display date. Assumes Unix-epoch seconds.
    private static let timestamp = "COALESCE(NULLIF(m.date_sent, 0), m.date_received, m.display_date, 0)"

    /// Returns messages sorted chronologically, de-duplicated on `global_message_id`
    /// (the same message filed in several mailboxes becomes one `Message` with several copies).
    static func loadMessages(from database: SQLiteConnection, query: MailQuery) throws -> [Message] {
        let bindings: [SQLiteValue] = [
            .int(query.includeDeleted ? 1 : 0),
            .int(query.from),
            .int(query.to),
        ]

        var messages: [Message] = []
        var indexByGlobalID: [Int64: Int] = [:]
        var indexByRowID: [Int64: Int] = [:]

        let messageSQL = """
        SELECT m.ROWID,
               m.global_message_id,
               m.remote_id,
               mb.url,
               \(timestamp) AS ts,
               sa.address,
               sa.comment,
               COALESCE(m.subject_prefix, ''),
               s.subject,
               sm.summary,
               g.message_id_header,
               m.conversation_id
        FROM messages m
        JOIN subjects  s  ON s.ROWID  = m.subject
        JOIN mailboxes mb ON mb.ROWID = m.mailbox
        JOIN addresses sa ON sa.ROWID = m.sender
        LEFT JOIN summaries sm ON sm.ROWID = m.summary
        LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id
        WHERE (?1 = 1 OR m.deleted = 0)
          AND \(timestamp) BETWEEN ?2 AND ?3
        ORDER BY ts, m.ROWID
        """

        try database.forEachRow(messageSQL, bindings) { row in
            guard let rowID = row.int64(0), let senderRaw = row.string(5) else { return }

            let global = row.int64(1) ?? 0
            let copy = MessageCopy(rowID: rowID, remoteID: row.int64(2), mailboxURL: row.string(3) ?? "")
            let dedupeKey = global != 0 ? global : -rowID

            if let existing = indexByGlobalID[dedupeKey] {
                messages[existing].copies.append(copy)
                indexByRowID[rowID] = existing
                return
            }

            let message = Message(
                copies: [copy],
                globalID: global,
                conversationID: row.int64(11) ?? 0,
                timestamp: row.int64(4) ?? 0,
                senderEmail: senderRaw.trimmingCharacters(in: .whitespaces).lowercased(),
                senderName: row.string(6) ?? "",
                subject: (row.string(7) ?? "") + (row.string(8) ?? ""),
                snippet: row.string(9),
                messageIDHeader: row.string(10)
            )
            messages.append(message)
            indexByGlobalID[dedupeKey] = messages.count - 1
            indexByRowID[rowID] = messages.count - 1
        }

        let recipientSQL = """
        SELECT r.message,
               r.type,
               a.address,
               a.comment
        FROM recipients r
        JOIN addresses a ON a.ROWID = r.address
        JOIN messages  m ON m.ROWID = r.message
        WHERE (?1 = 1 OR m.deleted = 0)
          AND \(timestamp) BETWEEN ?2 AND ?3
        ORDER BY r.message, r.type, r.position
        """

        try database.forEachRow(recipientSQL, bindings) { row in
            guard let rowID = row.int64(0),
                  let index = indexByRowID[rowID],
                  messages[index].primaryRowID == rowID,   // recipients of the primary copy only
                  let addressRaw = row.string(2) else { return }

            messages[index].recipients.append(
                Recipient(
                    email: addressRaw.trimmingCharacters(in: .whitespaces).lowercased(),
                    name: row.string(3) ?? "",
                    type: row.int64(1) ?? 0
                )
            )
        }

        return messages
    }
}
