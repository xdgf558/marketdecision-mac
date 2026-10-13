import Foundation
import GRDB
import PortfolioEngine

extension LedgerArchiveStore {
    /// Independent audit sequence numbers are local indexes, not economic IDs.
    /// Their explicit derived batches point to the complete original package.
    static func merge(current:LedgerArchiveState,incoming:LedgerArchiveState,raw:Data) throws -> LedgerArchiveState {
        let originHash = LedgerCSV.hash(raw)
        if let existing = try current.rows("ledger_archive_origins").first(where: { try $0[0].text() == originHash }) {
            guard try existing[1].blob() == raw else { throw LedgerArchiveError.corruptedArchive }
            return current
        }
        let scratch = try DatabaseStore(path:":memory:",purpose:.portfolioLedger)
        return try scratch.transaction { db in
            try current.insert(db)
            try db.execute(sql:"UPDATE ledger_metadata SET revision = ?",arguments:[current.ledgerRevision.uuidString])
            try db.execute(sql:"UPDATE performance_metadata SET revision = ?",arguments:[current.performanceRevision.uuidString])
            func definition(_ name:String)throws->LedgerArchiveTableDefinition {
                guard let value = LedgerArchiveState.definitions.first(where: { $0.name == name }) else { throw LedgerArchiveError.corruptedArchive }; return value
            }
            func upsertIdentical(_ row:[LedgerArchiveValue],_ table:String) throws {
                let def = try definition(table)
                if let old = try Row.fetchOne(db,sql:"SELECT \(def.columns.joined(separator:",")) FROM \(table) WHERE \(def.columns[0]) = ?",arguments:[row[0].sqlValue]) {
                    guard old.count == row.count,zip(0..<old.count,row).allSatisfy({ index,value in
                        let oldValue:DatabaseValue = old[index]
                        return oldValue == value.sqlValue
                    }) else { throw LedgerArchiveError.identityConflict }
                } else { try LedgerArchiveState.insert(row,definition:def,db:db) }
            }
            for row in try incoming.rows("ledger_accounts") { try upsertIdentical(row,"ledger_accounts") }
            for row in try incoming.rows("ledger_sources") { try upsertIdentical(row,"ledger_sources") }
            // The original whole package retains even rows deduplicated in the
            // active ledger, all original mapping bytes, and frozen report IDs.
            try upsertIdentical([.text(originHash),.blob(raw)],"ledger_archive_origins")
            let sourceRows = try Dictionary(uniqueKeysWithValues:incoming.rows("ledger_sources").map { (try $0[0].text(),$0) })
            let eventRows = try Dictionary(uniqueKeysWithValues:incoming.rows("ledger_events").map { (try $0[0].text(),$0) })
            var batches:[([LedgerArchiveValue],LedgerStore.Batch)] = []
            for row in try incoming.rows("ledger_batches") {
                let bytes = try row[3].blob()
                let batch = try JSONDecoder().decode(LedgerStore.Batch.self,from:bytes)
                batches.append((row,batch))
            }
            batches.sort { a,b in
                if a.1.appendBaseCount == b.1.appendBaseCount { return a.1.id < b.1.id }
                return a.1.appendBaseCount < b.1.appendBaseCount
            }
            for (rawBatch,original) in batches {
                try Task.checkCancellation()
                if let existing:Data = try Data.fetchOne(db,sql:"SELECT batch_json FROM ledger_batches WHERE batch_id = ?",arguments:[original.id]),existing == (try rawBatch[3].blob()) { continue }
                guard let sourceRow = sourceRows[original.sourceID] else { throw LedgerArchiveError.corruptedArchive }
                let metadata = try JSONDecoder().decode(LedgerStore.SourceMetadata.self,from:sourceRow[3].blob())
                let source = try LedgerStore.Source(metadata:metadata,bytes:sourceRow[4].blob())
                let snapshot = try LedgerStore.load(db)
                let classified = try LedgerStore.classify(LedgerStore.candidates(source:source),current:snapshot)
                guard classified.message == nil,classified.state != nil else { throw LedgerArchiveError.identityConflict }
                let derived = LedgerStore.Batch(id:UUID().uuidString.lowercased(),sourceID:original.sourceID,appendBaseCount:snapshot.events.count,
                    rows:classified.rows.map { .init(rowIndex:$0.rowIndex,eventID:$0.event?.id,disposition:$0.disposition.rawValue) })
                let batchBytes = try LedgerArchiveCodec.canonical(derived)
                try upsertIdentical([.text(derived.id),.text(derived.sourceID),.text(LedgerCSV.hash(batchBytes)),.blob(batchBytes)],"ledger_batches")
                var sequence = snapshot.events.count
                for item in classified.rows where item.disposition == .new {
                    guard let event = item.event,var row = eventRows[event.id],
                          try row[5].text() == original.sourceID,(try row[6].integer()) == Int64(item.rowIndex) else { throw LedgerArchiveError.identityConflict }
                    sequence += 1; row[3] = .integer(Int64(sequence)); row[7] = .text(derived.id)
                    // All other columns, notably event_json and precise timestamp
                    // bytes, are copied verbatim from the validated original row.
                    try upsertIdentical(row,"ledger_events")
                }
                try upsertIdentical([.text(derived.id),.text(originHash),.text(original.id)],"ledger_archive_batch_links")
                _ = try LedgerStore.load(db)
            }
            // Original ancestry stays inside the preserved origin package. Local
            // links point to the direct incoming batch, never to rewritten bytes.
            for row in try incoming.rows("ledger_archive_conflicts") {
                let hash = try row[1].text()
                if let existing = try Row.fetchOne(db,sql:"SELECT archive_bytes FROM ledger_archive_conflicts WHERE archive_hash = ?",arguments:[hash]) {
                    let bytes:Data = existing[0]
                    guard bytes == (try row[4].blob()) else { throw LedgerArchiveError.identityConflict }
                } else { try upsertIdentical(row,"ledger_archive_conflicts") }
            }
            let inputs = try Dictionary(uniqueKeysWithValues:incoming.rows("performance_inputs").map { (try $0[0].text(),$0) })
            let documents = try Dictionary(uniqueKeysWithValues:incoming.rows("performance_report_documents").map { (try $0[0].text(),$0) })
            for report in try incoming.rows("performance_report_catalog") {
                let id = try report[0].text(),inputHash = try report[3].text()
                guard let input = inputs[inputHash],let document = documents[id] else { throw LedgerArchiveError.corruptedArchive }
                if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM performance_report_catalog WHERE report_id = ?)",arguments:[id]) == true {
                    try upsertIdentical(report,"performance_report_catalog")
                    try upsertIdentical(document,"performance_report_documents")
                }
                if let existingID = try String.fetchOne(db,sql:"SELECT report_id FROM performance_report_catalog WHERE input_hash = ?",arguments:[inputHash]),existingID != id {
                    // Exact same frozen input/result may already have a different
                    // local report ID. Keep its untouched original in the origin.
                    let existingHash = try String.fetchOne(db,sql:"SELECT report_hash FROM performance_report_catalog WHERE report_id = ?",arguments:[existingID])
                    guard existingHash == (try report[4].text()) else { throw LedgerArchiveError.identityConflict }
                    try upsertIdentical(input,"performance_inputs")
                    continue
                }
                try upsertIdentical(input,"performance_inputs")
                try upsertIdentical(report,"performance_report_catalog")
                try upsertIdentical(document,"performance_report_documents")
            }
            let state = try LedgerArchiveState.capture(db)
            try LedgerArchiveValidation().validate(state)
            return state
        }
    }
}
