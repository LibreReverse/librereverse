#if os(macOS)
import CSQLCipher
import Foundation
import XCTest
@testable import LibreReverseCore

/// Persistent keyed readers must agree with direct queries and retain their
/// connection across timeline interactions.
final class LibraryDatabaseSessionTests: XCTestCase {
    private var root: URL!
    private var configuration: LibraryDatabaseConfiguration!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-session-test-\(UUID().uuidString)", isDirectory: true)
        let library = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media", isDirectory: true)
        )
        try LibreReverseLibraryStore.initialize(library)
        try seed(library)
        configuration = LibraryDatabaseConfiguration(
            databaseURL: library.databaseURL,
            keyFileURL: library.keyFileURL,
            mediaRoot: library.mediaRoot
        )
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testAuditOCRPageAdvertisesUnreturnedEligibleResults() async throws {
        try auditSeedOCRCandidates(count: 100)
        let session = LibraryDatabaseSession(configuration: configuration)
        let all = try await session.recencyOCRSearchPage(query: "auditneedle", pageSize: 1000)
        XCTAssertEqual(all.results.count, 100, "Fixture must survive actual OCR-node population and deduplication")
        let page = try await session.recencyOCRSearchPage(query: "auditneedle")
        XCTAssertEqual(page.results.count, 30)
        XCTAssertTrue(page.hasMore, "70 eligible results remain after rendering 30")
        XCTAssertEqual(page.nextCursor?.documentID, page.results.last?.result.candidate.docID,
            "The cursor must not advance past eligible results which were never returned")
        await session.closeConnection()
    }

    func testAuditOCRCursorDoesNotSkipAmplifiedCandidates() async throws {
        try auditSeedOCRCandidates(count: 500)
        let session = LibraryDatabaseSession(configuration: configuration)
        let first = try await session.recencyOCRSearchPage(query: "auditneedle")
        XCTAssertEqual(first.results.map { $0.result.candidate.docID }, Array((1470...1499).reversed()).map(Int64.init))
        XCTAssertTrue(first.hasMore)
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try await session.recencyOCRSearchPage(query: "auditneedle", before: cursor,
            previousResults: first.results)
        XCTAssertEqual(second.results.first?.result.candidate.docID, 1469,
            "Page two should continue immediately after the last displayed result, not candidate 450")
        await session.closeConnection()
    }

    func testTranscriptBrowsingDoesNotMixSyntheticAndPersistedDocumentIDs() async throws {
        try execute("""
            INSERT INTO segment(id,bundleID,startDate,endDate,windowName,type)
            VALUES(900,'com.example.Meeting','2027-01-01T12:00:00.000','2027-01-01T12:01:00.000','Indexed meeting',1),
                  (901,'com.example.Meeting','2027-01-01T12:00:00.000','2027-01-01T12:01:00.000','Pending meeting',1);
            INSERT INTO searchRanking(rowid,text,otherText,title) VALUES(-901,'indexed words','','Indexed meeting');
            INSERT INTO doc_segment(docid,segmentId,frameId) VALUES(-901,900,NULL);
            """)
        let session = LibraryDatabaseSession(configuration: configuration)
        let results = try await session.recencySearchCandidates(query: "", facets: .init(isTranscript: true))
        XCTAssertTrue(results.contains { $0.segmentID == 900 && $0.docID == -900 })
        XCTAssertTrue(results.contains { $0.segmentID == 901 && $0.docID == -901 })
        XCTAssertEqual(results.prefix(2).map(\.segmentID), [901, 900],
            "Synthetic negative IDs must preserve newest meeting order for tied dates")
        let first = try await session.recencyTranscriptSearchPage(query: "", pageSize: 1, amplifiedLimit: 1)
        XCTAssertEqual(first.results.first?.result.candidate.segmentID, 901)
        let cursor = try XCTUnwrap(first.nextCursor)
        let next = try await session.recencyTranscriptSearchPage(query: "", before: cursor,
            pageSize: 1, amplifiedLimit: 1, previousResults: first.results)
        XCTAssertEqual(next.results.first?.result.candidate.segmentID, 900)
        let identifierOnly = try await session.recencySearchCandidates(query: "", facets: .init(isTranscript: true),
            before: .init(documentID: -901, instant: nil), amplifiedLimit: 1)
        XCTAssertEqual(identifierOnly.first?.segmentID, 900)
        let indexed = try await session.recencySearchCandidates(query: "indexed", facets: .init(isTranscript: true))
        XCTAssertEqual(indexed.first?.docID, -901, "Keyword search must retain the actual FTS identity")
        await session.closeConnection()
    }

    private func auditSeedOCRCandidates(count: Int) throws {
        let base = try date("2027-01-01T00:00:00.000")
        var sql = "BEGIN;"
        for index in 0..<count {
            let id = 1000 + index
            let instant = Self.formatter.string(from: base.addingTimeInterval(Double(index)))
            let width = Double(index % 40 + 1) * 0.02
            sql += """
            INSERT INTO segment(id,bundleID,startDate,endDate,windowName,type)
            VALUES(\(id),'com.example.Audit','\(instant)','\(instant)','Distinct title \(id)',0);
            INSERT INTO frame(id,createdAt,imageFileName,segmentId,encodingStatus)
            VALUES(\(id),'\(instant)','audit-\(id).png',\(id),'deferred');
            INSERT INTO searchRanking(rowid,text,otherText,title)
            VALUES(\(id),'auditneedle result \(id)','','Distinct title \(id)');
            INSERT INTO searchOffsets(rowid,text,otherText)
            VALUES(\(id),'auditneedle result \(id)','');
            INSERT INTO doc_segment(docid,segmentId,frameId) VALUES(\(id),\(id),\(id));
            INSERT INTO node(frameId,nodeOrder,textOffset,textLength,leftX,topY,width,height,windowIndex)
            VALUES(\(id),0,0,11,0,0,\(width),0.05,0);
            """
        }
        sql += "COMMIT;"
        try execute(sql)
    }


    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(Self.formatter.date(from: value))
    }

    func testFailedPageReadDoesNotBecomeSuccessfulEmptyHistory() async throws {
        // Bounds still read correctly; only decoding a page is invalid.
        try execute("UPDATE segment SET startDate = 'invalid-date' WHERE id = (SELECT MIN(id) FROM segment)")
        let session = LibraryDatabaseSession(configuration: configuration)
        do {
            _ = try await session.recentTimelineWindow(duration: 100_000)
            XCTFail("A failed page must preserve the caller's existing history, not erase it")
        } catch { }
        do {
            _ = try await session.timelineWindow(around: try date("2026-08-22T12:00:01.000"), duration: 100_000)
            XCTFail("A failed scrolling page must propagate its error")
        } catch { }
        await session.closeConnection()
    }

    /// Every timestamp must resolve identically through both paths, including
    /// the before-first-frame edge and exact frame boundaries.
    func testSessionMatchesOneShotPathAcrossTimestamps() async throws {
        let session = LibraryDatabaseSession(configuration: configuration)
        let timestamps = [
            "2026-08-22T11:59:59.999",
            "2026-08-22T12:00:00.000",
            "2026-08-22T12:00:00.499",
            "2026-08-22T12:00:00.500",
            "2026-08-22T12:00:01.000",
            "2026-08-22T12:00:01.500",
            "2026-08-22T12:00:09.000",
        ]
        for value in timestamps {
            let requested = try date(value)
            let expected = try LibraryDatabase.nearestMoment(
                to: requested, configuration: configuration
            )
            let actual = try await session.nearestMoment(to: requested)
            XCTAssertEqual(actual, expected, "mismatch at \(value)")
        }
        await session.closeConnection()
    }

    /// Repeated queries must reuse one connection rather
    /// than re-running SQLCipher key derivation per seek.
    func testRepeatedQueriesReuseASingleConnection() async throws {
        let session = LibraryDatabaseSession(configuration: configuration)
        var hasConnection = await session.hasConnection
        XCTAssertFalse(hasConnection, "must connect lazily")

        _ = try await session.nearestMoment(to: try date("2026-08-22T12:00:01.000"))
        hasConnection = await session.hasConnection
        XCTAssertTrue(hasConnection)
        let firstConnectedAt = await session.connectedAt
        XCTAssertNotNil(firstConnectedAt)

        for _ in 0..<50 {
            _ = try await session.nearestMoment(to: try date("2026-08-22T12:00:01.500"))
        }
        let laterConnectedAt = await session.connectedAt
        XCTAssertEqual(laterConnectedAt, firstConnectedAt, "reconnected mid-scrub")

        await session.closeConnection()
        hasConnection = await session.hasConnection
        XCTAssertFalse(hasConnection)
        let disconnectedAt = await session.disconnectedAt
        XCTAssertNotNil(disconnectedAt)
    }

    /// A closed session must be usable again, since the explorer opens and
    /// closes across presentations.
    func testReconnectsAfterClose() async throws {
        let session = LibraryDatabaseSession(configuration: configuration)
        let requested = try date("2026-08-22T12:00:01.000")
        let first = try await session.nearestMoment(to: requested)
        await session.closeConnection()
        let second = try await session.nearestMoment(to: requested)
        XCTAssertEqual(first, second)
        let connected = await session.hasConnection
        XCTAssertTrue(connected)
        await session.closeConnection()
    }

    func testExactIntervalSegmentFeedUsesHalfOpenIntersectionAndStableOrder() async throws {
      try execute(
        """
        INSERT INTO segment(id,bundleID,startDate,endDate,windowName,type)
        VALUES
          (10,'com.example.Before','2026-08-22T11:59:00.000','2026-08-22T12:00:00.500','Before',0),
          (11,'com.example.Crossing','2026-08-22T12:00:00.250','2026-08-22T12:00:00.750','Crossing',2),
          (12,'com.example.After','2026-08-22T12:00:02.500','2026-08-22T12:00:03.000','After',0),
          (13,'com.example.Unknown','2026-08-22T12:00:01.000','2026-08-22T12:00:01.250','Unknown',99);
        """)
      let session = LibraryDatabaseSession(configuration: configuration)
      let segments = try await session.timelineSegments(
        intersecting: DateInterval(
          start: try date("2026-08-22T12:00:00.500"),
          end: try date("2026-08-22T12:00:02.500")
        )
      )

      XCTAssertEqual(segments.map(\.rawID), [1, 11, 2])
      XCTAssertEqual(
        segments.map(\.rawType), [.capturedScreen, .importedScreenshot, .capturedScreen])
      XCTAssertEqual(segments.map(\.windowName), ["Doc", "Crossing", "Doc"])
      let emptySegments = try await session.timelineSegments(
        intersecting: DateInterval(
          start: try date("2026-08-22T12:00:00.500"),
          end: try date("2026-08-22T12:00:00.500")
        )
      )
      XCTAssertEqual(emptySegments, [])
      await session.closeConnection()
    }

    func testDailyRecapMeetingFeedUsesCompactCatalogMetadataAndSummary() async throws {
        try execute(
            """
            INSERT INTO segment(id,bundleID,startDate,endDate,windowName,browserUrl,type)
            VALUES
              (20,'ai.librereverse.meeting','2026-08-22T14:00:00.000','2026-08-22T15:00:00.000',
               'Fallback title','https://meet.google.com/abc-defg-hij',1),
              (21,'ai.librereverse.meeting','2026-08-22T16:00:00.000','2026-08-22T16:30:00.000',
               'Ad hoc review',NULL,1),
              (22,'ai.librereverse.meeting','2026-08-23T00:00:00.000','2026-08-23T01:00:00.000',
               'Boundary excluded',NULL,1);
            INSERT INTO event(
              id,type,status,title,participants,detailsJSON,calendarID,calendarEventID,
              calendarSeriesID,segmentID
            ) VALUES(
              20,'meeting','completed','Product review','["Ada","Grace"]',
              '{"calendarTitle":"Product","futureField":"preserved"}',
              'work','event-20','series-20',20
            );
            INSERT INTO summary(id,status,text,eventId)
            VALUES(20,'complete','Decisions and next steps',20);
            """)
        let session = LibraryDatabaseSession(configuration: configuration)
        let meetings = try await session.dailyRecapRecordedMeetings(
            intersecting: DateInterval(
                start: try date("2026-08-22T00:00:00.000"),
                end: try date("2026-08-23T00:00:00.000")
            )
        )

        XCTAssertEqual(meetings.map(\.segmentID), [21, 20])
        XCTAssertEqual(meetings.map(\.title), ["Ad hoc review", "Product review"])
        XCTAssertEqual(meetings[1].calendarEventID, "event-20")
        XCTAssertEqual(meetings[1].calendarTitle, "Product")
        XCTAssertEqual(meetings[1].participants, ["Ada", "Grace"])
        XCTAssertEqual(meetings[1].meetingURL?.host, "meet.google.com")
        let summary = try await session.meetingSummary(segmentID: 20)
        let missingSummary = try await session.meetingSummary(segmentID: 21)
        XCTAssertEqual(summary, "Decisions and next steps")
        XCTAssertNil(missingSummary)
        await session.closeConnection()
    }

    func testRecencySearchUsesCapturedExpressionAndDocumentOrder() async throws {
      try execute(
        """
        INSERT INTO searchRanking(rowid,text,otherText,title) VALUES
          (40,'google drive settings','','Doc'),
          (41,'google cloud console','','Doc'),
          (42,'drive without the first term','','Doc');
        INSERT INTO doc_segment(docid,segmentId,frameId) VALUES
          (40,1,1),(41,1,2),(42,2,5);
        """)
        let session = LibraryDatabaseSession(configuration: configuration)

        let oneTerm = try await session.recencySearchCandidates(query: "google")
        XCTAssertEqual(oneTerm.map(\.docID), [41, 40])
        XCTAssertEqual(oneTerm.map(\.frameID), [2, 1])
        XCTAssertEqual(oneTerm.first?.frameDate, try date("2026-08-22T12:00:00.500"))
        XCTAssertEqual(oneTerm.first?.bundleID, "com.example.Editor")

        let allTerms = try await session.recencySearchCandidates(query: "google drive")
        XCTAssertEqual(allTerms.map(\.docID), [40])
        let phrase = try await session.recencySearchCandidates(query: "\"google drive\"")
        XCTAssertEqual(phrase.map(\.docID), [40])
        let empty = try await session.recencySearchCandidates(query: "   ")
        XCTAssertEqual(empty, [])
        await session.closeConnection()
    }

    func testRecencySearchAppliesFacetsAndExclusiveCursor() async throws {
      try execute(
        """
        UPDATE segment SET bundleID='com.example.Browser' WHERE id=2;
        INSERT INTO segment(id,bundleID,startDate,endDate,windowName,type)
        VALUES(3,'ai.rewind.audiorecorder','2026-08-22T12:00:04.000',
               '2026-08-22T12:00:06.000','Meeting',1);
        INSERT INTO frame(id,createdAt,imageFileName,segmentId,isStarred,encodingStatus)
        VALUES(6,'2026-08-22T12:00:04.000','meeting',3,1,'deferred');
        INSERT INTO searchRanking(rowid,text,otherText,title) VALUES
          (40,'facet needle','','Editor'),
          (41,'facet needle','','Editor star'),
          (42,'facet needle','','Browser'),
          (43,'facet needle','','Meeting');
        INSERT INTO doc_segment(docid,segmentId,frameId) VALUES
          (40,1,1),(41,1,2),(42,2,5),(43,3,6);
        """)
        let session = LibraryDatabaseSession(configuration: configuration)

        let orderedApps = try await session.recencySearchCandidates(
            query: "facet",
            facets: .init(applicationBundleIDs: [
                "com.example.Editor", "com.example.Browser",
            ])
        )
        XCTAssertEqual(orderedApps.map(\.docID), [42, 41, 40])

        let starredApps = try await session.recencySearchCandidates(
            query: "facet",
            facets: .init(
                applicationBundleIDs: ["com.example.Editor"],
                isStarred: true
            )
        )
        XCTAssertEqual(starredApps.map(\.docID), [41])

        let meeting = try await session.recencySearchCandidates(
            query: "facet",
            facets: .init(
                applicationBundleIDs: ["com.example.Editor"],
                isStarred: true,
                isTranscript: true
            )
        )
        XCTAssertEqual(meeting.map(\.docID), [43])
        XCTAssertEqual(meeting.first?.bundleID, SearchFacets.meetingRecorderBundleID)

        let continued = try await session.recencySearchCandidates(
            query: "facet",
            before: .init(documentID: 42)
        )
        XCTAssertEqual(continued.map(\.docID), [41, 40])

        let counts = try await session.searchApplicationCounts(query: "facet")
      XCTAssertEqual(
        counts,
        [
            .init(bundleID: "com.example.Editor", count: 2),
            .init(bundleID: "ai.rewind.audiorecorder", count: 1),
            .init(bundleID: "com.example.Browser", count: 1),
        ])
        await session.closeConnection()
    }

    func testBatchOffsetsUsesExactLegacyFTS4Projection() async throws {
      try execute(
        """
        INSERT INTO searchOffsets(rowid,text,otherText) VALUES
          (40,'café google',''),
          (41,'','google');
        """)
        let session = LibraryDatabaseSession(configuration: configuration)
        let offsets = try await session.batchSearchOffsets(query: "google")
        XCTAssertEqual(offsets, [40: "0 0 6 6", 41: "1 0 0 6"])
        let empty = try await session.batchSearchOffsets(query: "   ")
        XCTAssertEqual(empty, [:])
        await session.closeConnection()
    }

    func testRecencyOCRPopulationJoinsOffsetsNodesAndReducer() async throws {
      try execute(
        """
        INSERT INTO searchRanking(rowid,text,otherText,title) VALUES
          (50,'first needle','','Doc'),
          (51,'front','second needle','Doc');
        INSERT INTO searchOffsets(rowid,text,otherText) VALUES
          (50,'first needle',''),
          (51,'front','second needle');
        INSERT INTO doc_segment(docid,segmentId,frameId) VALUES
          (50,1,1),(51,1,2);
        INSERT INTO node(
          frameId,nodeOrder,textOffset,textLength,leftX,topY,width,height,windowIndex
        ) VALUES
          (1,0,6,6,0.1,0.2,0.20,0.05,0),
          (2,0,12,6,0.3,0.4,0.35,0.08,1);
        """)
        let session = LibraryDatabaseSession(configuration: configuration)
        let results = try await session.recencyOCRSearchResults(query: "needle")

        // Descending row ID populates frame 2 first. Frame 1 is the same
        // app/title/type within five minutes, so the exact reducer drops it.
        XCTAssertEqual(results.map(\.result.candidate.docID), [51])
        XCTAssertEqual(results.first?.result.resolvedTitle, "Doc")
        XCTAssertEqual(results.first?.firstNode.windowIndex, 1)
        XCTAssertEqual(results.first?.firstNode.textOffset, 12)
        XCTAssertTrue(results.first?.result.candidate.isStarred == true)

        let preloadedOffsets = try await session.batchSearchOffsets(query: "needle")
        try execute("DELETE FROM searchOffsets")
        let page = try await session.recencyOCRSearchPage(
            query: "needle",
            pageSize: 1,
            amplifiedLimit: 1,
            preloadedOffsetsByDocument: preloadedOffsets
        )
        XCTAssertEqual(page.results.map { $0.result.candidate.docID }, [51])
        // The cursor carries the instant as well as the identifier: identifier
        // order only tracks recency inside a single database, and paging spans
        // the primary and every sealed shard.
        // The cursor carries the instant as well as the identifier: identifier
        // order only tracks recency inside a single database, and paging spans
        // the primary and every sealed shard.
        XCTAssertEqual(
            page.nextCursor,
            .init(documentID: 51, instant: try date("2026-08-22T12:00:00.500"))
        )
        XCTAssertTrue(page.hasMore)
        await session.closeConnection()
    }

    func testFirstMatchUsesExactShiftOverlapWindowAndNodeOrderContract() async throws {
      try execute(
        """
        INSERT INTO node(
          frameId,nodeOrder,textOffset,textLength,leftX,topY,width,height,windowIndex
        ) VALUES
          (1,0,8,4,0.10,0.20,0.30,0.04,0),
          (1,1,18,5,0.20,0.30,0.40,0.05,0),
          (1,2,25,3,0.30,0.40,0.50,0.06,1),
          (1,3,25,3,0.40,0.50,0.60,0.07,2),
          (1,4,25,3,0.50,0.60,0.70,0.08,0);
        """)
        let session = LibraryDatabaseSession(configuration: configuration)

        // The first node ends exactly at the lower match bound. The resolver
        // uses >=, so it overlaps and wins by nodeOrder over the node starting
        // exactly at the upper bound.
        let primary = try await session.firstMatchingOCRNode(
            frameID: 1,
            primaryTextUTF16Length: 20,
            offset: .init(column: .primaryText, term: 0, lowerBound: 12, upperBound: 18)
        )
        XCTAssertEqual(primary?.nodeOrder, 0)
        XCTAssertEqual(primary?.windowIndex, 0)

        // Other-text offsets are shifted by the primary UTF-16 count. Any
        // nonzero window participates, while the geometrically identical
        // window-zero node is excluded.
        let other = try await session.firstMatchingOCRNode(
            frameID: 1,
            primaryTextUTF16Length: 20,
            offset: .init(column: .otherText, term: 0, lowerBound: 5, upperBound: 11)
        )
        XCTAssertEqual(other?.nodeOrder, 2)
        XCTAssertEqual(other?.windowIndex, 1)
        XCTAssertEqual(other?.leftX, 0.30)

        let missing = try await session.firstMatchingOCRNode(
            frameID: 1,
            primaryTextUTF16Length: 20,
            offset: .init(column: .primaryText, term: 0, lowerBound: 100, upperBound: 106)
        )
        XCTAssertNil(missing)

        // Raw FTS order places an otherText hit first. The offset parser sorts by
        // column and corrected lower bound before resolving just one node, so
        // this still chooses the earliest primary node.
        let assembled = try await session.firstMatchingOCRNode(
            frameID: 1,
            offsetString: "1 0 5 3 0 1 18 1 0 0 12 2",
            primaryText: "01234567890123456789",
            otherText: "other text"
        )
        XCTAssertEqual(assembled?.nodeOrder, 0)

        let allNodes = try await session.ocrNodes(frameID: 1)
        XCTAssertEqual(allNodes.map(\.nodeOrder), [0, 1, 2, 3, 4])
        XCTAssertEqual(allNodes.map(\.windowIndex), [0, 0, 1, 2, 0])
        XCTAssertEqual(allNodes.last?.leftX, 0.50)
        await session.closeConnection()
    }

    func testShardedSessionRoutesHistoricalMomentsAndKeepsPrimaryLive() async throws {
        let library = LibreReverseLibraryConfiguration(
            databaseURL: configuration.databaseURL,
            keyFileURL: configuration.keyFileURL,
            mediaRoot: configuration.mediaRoot
        )
      try execute(
        """
        INSERT INTO searchRanking(rowid,text,otherText,title) VALUES
          (40,'google historical one','','Doc'),
          (41,'google historical two','','Doc');
        INSERT INTO doc_segment(docid,segmentId,frameId) VALUES
          (40,1,1),(41,1,2);
        INSERT INTO node(
          frameId,nodeOrder,textOffset,textLength,leftX,topY,width,height,windowIndex
        ) VALUES
          (1,1,6,10,0.11,0.22,0.33,0.04,0),
          (1,0,0,5,0.05,0.10,0.20,0.03,0),
          (2,0,0,8,0.44,0.55,0.22,0.06,1);
        """)
        // The fixture inserts rows directly; production finalization
        // maintains this compact catalog atomically.
        try LibreReverseShardStore.initialize(library)
        let epoch = try LibreReverseShardStore.epochStart(configuration: library)
        let ordinal = LibreReverseShardInterval.ordinal(
            containing: try date("2026-08-22T12:00:00.000"),
            epochStart: epoch
        )
        let interval = LibreReverseShardInterval(ordinal: ordinal, epochStart: epoch)
        let shardURL = configuration.databaseURL.deletingLastPathComponent().appendingPathComponent("Shards").appendingPathComponent(interval.fileName)
        let manifest = try LibreReverseShardBuilder.buildToCompletion(
            source: library,
            destinationURL: shardURL,
            interval: interval,
            batchSize: 1
        )
        let shardID = try LibreReverseShardStore.registerBuildingShard(
            interval: interval,
            relativePath: "Shards/\(interval.fileName)",
            configuration: library
        )
        try LibreReverseShardStore.markSealedLocal(
            shardID: shardID,
            byteCount: manifest.byteCount,
            sha256: manifest.sha256,
            frameCount: manifest.frameCount,
            nodeCount: manifest.nodeCount,
            documentCount: manifest.documentCount,
            minFrameID: manifest.minFrameID,
            maxFrameID: manifest.maxFrameID,
            configuration: library
        )

        let activeDate = interval.end.addingTimeInterval(1)
      try execute(
        """
        DELETE FROM frame WHERE createdAt>='\(Self.formatter.string(from: interval.start))'
                           AND createdAt<'\(Self.formatter.string(from: interval.end))';
        DELETE FROM node WHERE frameId IN (1,2);
        DELETE FROM doc_segment WHERE docid IN (40,41);
        DELETE FROM searchRanking WHERE rowid IN (40,41);
        INSERT INTO segment(id,bundleID,startDate,endDate,type)
        VALUES(99,'com.example.Live','\(Self.formatter.string(from: activeDate))',
               '\(Self.formatter.string(from: activeDate.addingTimeInterval(2)))',0);
        INSERT INTO frame(id,createdAt,imageFileName,segmentId,isStarred,encodingStatus)
        VALUES(99,'\(Self.formatter.string(from: activeDate))','live',99,0,'deferred');
        INSERT INTO searchRanking(rowid,text,otherText,title)
        VALUES(99,'google active','','Live');
        INSERT INTO doc_segment(docid,segmentId,frameId) VALUES(99,99,99);
        UPDATE shard_metadata
           SET routingState='sharded',activeOrdinal=\(ordinal + 1) WHERE id=1;
        """)

        let session = LibraryDatabaseSession(configuration: configuration)
        let historical = try await session.nearestMoment(
            to: try date("2026-08-22T12:00:00.500")
        )
        XCTAssertEqual(historical?.frameID, 2)
        XCTAssertEqual(historical?.wallDate, try date("2026-08-22T12:00:00.500"))
        XCTAssertEqual(historical?.databaseVideoID, 1)
        let live = try await session.nearestMoment(to: activeDate)
        XCTAssertEqual(live?.wallDate, activeDate)
        XCTAssertTrue(live?.isPendingImage == true)
        let crossedForward = try await session.neighbourMoment(
            of: try date("2026-08-22T12:00:01.500"),
            forward: true
        )
        XCTAssertEqual(crossedForward?.wallDate, activeDate)
        let crossedBackward = try await session.neighbourMoment(of: activeDate, forward: false)
        XCTAssertEqual(crossedBackward?.wallDate, try date("2026-08-22T12:00:01.500"))
        let search = try await session.recencySearchCandidates(query: "google")
        XCTAssertEqual(search.map(\.docID), [99, 41, 40])
        XCTAssertEqual(search.map(\.frameID), [99, 2, 1])

        // Imported history keeps the original app's document identifiers,
        // which run far above anything the primary has issued since it started
        // numbering at one. Ordering the merged set by identifier therefore
        // ranks every imported document above every newly recorded one, and
        // nothing captured since the import can reach a result page at all.
        // Recency has to come from the recorded instant.
      try execute(
        """
        INSERT INTO searchRanking(rowid,text,otherText,title)
        VALUES(5000000,'google imported ancient','','Imported');
        INSERT INTO doc_segment(docid,segmentId,frameId) VALUES(5000000,99,99);
        """)
        let mixed = try await session.recencySearchCandidates(query: "google")
        XCTAssertEqual(
            mixed.first?.docID,
            5_000_000,
            "the highest identifier here is also the most recent frame"
        )

        // The real shape of the defect: the largest identifier belongs to the
        // oldest frame, exactly as an imported library looks next to a primary
        // that started numbering at one.
      try execute(
        """
        INSERT INTO frame(id,createdAt,imageFileName,segmentId,isStarred,encodingStatus)
        VALUES(77,'\(Self.formatter.string(from: try date("2026-08-20T09:00:00.000")))',
               'old',99,0,'success');
        UPDATE doc_segment SET frameId=77 WHERE docid=5000000;
        """)
        let inverted = try await session.recencySearchCandidates(query: "google")
        XCTAssertEqual(
            inverted.map(\.docID),
            [99, 41, 40, 5_000_000],
            "recency, not identifier: the largest id is the oldest frame"
        )
        let shardNodes = try await session.ocrNodes(frameID: 1)
        XCTAssertEqual(shardNodes.map(\.nodeOrder), [0, 1])
        XCTAssertEqual(shardNodes.map(\.textOffset), [0, 6])
        XCTAssertEqual(shardNodes.last?.leftX, 0.11)

        // The frame's own timestamp selects the shard that can hold it, which
        // is what keeps a search from probing every sealed shard per result.
        let targeted = try await session.ocrNodes(
            frameID: 1,
            instant: try date("2026-08-22T12:00:00.500")
        )
        XCTAssertEqual(targeted.map(\.nodeOrder), [0, 1])

        // An instant that points at the wrong shard -- or at no shard at all
        // -- must still find the frame. The hint only reorders the sweep; it
        // never truncates it, so a stale or disagreeing interval costs time
        // rather than results.
        let misdirected = try await session.ocrNodes(frameID: 1, instant: activeDate)
        XCTAssertEqual(misdirected.map(\.nodeOrder), [0, 1])
        let unmatched = try await session.ocrNodes(
            frameID: 1,
            instant: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(unmatched.map(\.nodeOrder), [0, 1])
        await session.closeConnection()

        try LibreReverseShardStore.indexCalendarHoursBeforeEviction(
            shardID: shardID,
            relativePath: "Shards/\(interval.fileName)",
            configuration: library
        )
        try execute("UPDATE library_shard SET state='remote_only' WHERE id=\(shardID)")
        let remoteSession = LibraryDatabaseSession(configuration: configuration)
        let unavailableShards = try await remoteSession.unavailableShards()
        XCTAssertEqual(
            unavailableShards,
            [HistoricalUnavailableShard(ordinal: ordinal, interval: interval)]
        )
      let remoteHours = try await remoteSession.availableFrameHours(
        in: DateInterval(
            start: interval.start,
            end: interval.end
        ))
        XCTAssertEqual(remoteHours, [try date("2026-08-22T12:00:00.000")])
        let catalogMoment = try await remoteSession.catalogMoment(
            to: try date("2026-08-22T12:00:00.500")
        )
        XCTAssertEqual(catalogMoment?.databaseVideoID, 1)
        XCTAssertEqual(catalogMoment?.wallDate, try date("2026-08-22T12:00:00.500"))
        XCTAssertEqual(catalogMoment?.videoFrameIndex, 15)
        XCTAssertEqual(catalogMoment?.chunkURL?.lastPathComponent, "chunk")
        do {
            _ = try await remoteSession.nearestMoment(
                to: try date("2026-08-22T12:00:00.500")
            )
            XCTFail("remote shard must not become a silent empty period")
        } catch {
            XCTAssertEqual(
                error as? LibraryDatabaseError,
                .shardUnavailable(ordinal: ordinal, state: "remote_only")
            )
        }
        // Hydration must invalidate the already-warm routing catalog and use
        // persisted frame indexes, including duplicate wall-clock timestamps.
        try execute("UPDATE library_shard SET state='sealed_local' WHERE id=\(shardID)")
        let connectedAt = await remoteSession.connectedAt
        await remoteSession.reloadShardCatalog()
        let restoredUnavailable = try await remoteSession.unavailableShards()
        XCTAssertTrue(restoredUnavailable.isEmpty)
        let restored = try await remoteSession.nearestMoment(
            to: try date("2026-08-22T12:00:01.500")
        )
        XCTAssertEqual(restored?.frameID, 5)
        XCTAssertEqual(restored?.videoFrameIndex, 46,
                       "Wall-clock interpolation would incorrectly seek to frame 45")
        XCTAssertEqual(restored?.mediaTime, 46.0 / 30.0)
        let stillConnectedAt = await remoteSession.connectedAt
        XCTAssertEqual(stillConnectedAt, connectedAt)
        await remoteSession.closeConnection()
    }

    /// A point lookup must not leave its prepared statement at SQLITE_ROW.
    /// Doing so holds an implicit read transaction open on the shared
    /// connection and makes every later window fetch observe the old WAL
    /// snapshot even though recording has committed newer segments.
    func testPointLookupDoesNotPinLaterWindowFetchToStaleWALSnapshot() async throws {
        let session = LibraryDatabaseSession(configuration: configuration)
        _ = try await session.nearestMoment(to: try date("2026-08-22T12:00:01.000"))

      try execute(
        """
        INSERT INTO segment(id,bundleID,startDate,endDate,windowName,browserUrl,browserProfile,type)
        VALUES
          (99,'com.example.Live','2026-08-22T12:01:00.000','2026-08-22T12:01:02.000','Live',NULL,NULL,0);
        """)

        let window = try await session.recentTimelineWindow(duration: 100_000)
        XCTAssertTrue(window.segments.contains { $0.rawID == 99 })
        XCTAssertEqual(window.validSeekInterval?.end, try date("2026-08-22T12:01:02.000"))
        await session.closeConnection()
    }

    /// The query has no ordering operator. Both access paths must
    /// preserve SQLite's returned order rather than sorting stars by date.
    /// The global valid-seek interval is
    /// `DateInterval(min(segment.startDate), max(segment.endDate))`.
    ///
    /// It is computed as two single-aggregate statements rather than the
    /// combined selection, purely so SQLite can apply its
    /// min/max index optimisation instead of scanning. This pins the values so
    /// the optimisation cannot change the published interval, including the
    /// case where the newest `endDate` does not belong to the newest
    /// `startDate` row.
    func testGlobalIntervalSpansMinStartAndMaxEndAcrossDifferentRows() async throws {
        // The minimum start and the maximum end deliberately belong to
        // different rows, and neither is the newest row. A single-column
        // shortcut such as "newest startDate row" would fail this.
      try execute(
        """
        INSERT INTO segment(id,bundleID,startDate,endDate,windowName,browserUrl,browserProfile,type)
        VALUES
          (3,'com.example.Editor','2026-08-22T11:00:00.000','2026-08-22T11:00:01.000','Doc',NULL,NULL,0),
          (4,'com.example.Editor','2026-08-22T12:00:03.000','2026-08-22T13:00:00.000','Doc',NULL,NULL,0);
        """)
        let session = LibraryDatabaseSession(configuration: configuration)
        let window = try await session.recentTimelineWindow(duration: 100_000)
        let interval = try XCTUnwrap(window.validSeekInterval)
        XCTAssertEqual(interval.start, try date("2026-08-22T11:00:00.000"))
        XCTAssertEqual(interval.end, try date("2026-08-22T13:00:00.000"))
        await session.closeConnection()
    }

    func testBulkStarFeedPreservesDatabaseResultOrder() async throws {
      try execute(
        """
        INSERT INTO frame(id,createdAt,imageFileName,segmentId,videoId,videoFrameIndex,isStarred,encodingStatus)
        VALUES
          (9,'2026-08-22T12:00:01.250','star-later',1,1,38,1,'success'),
          (10,'2026-08-22T12:00:00.750','star-earlier',1,1,23,1,'success');
        """)
        let expected = try nativeStarDates()
        XCTAssertNotEqual(expected, expected.sorted(), "fixture must witness unsorted native order")

        XCTAssertEqual(
            try LibraryDatabase.loadStarredFrameDates(configuration: configuration),
            expected
        )
        let session = LibraryDatabaseSession(configuration: configuration)
        let sessionDates = try await session.starredFrameDates()
        XCTAssertEqual(sessionDates, expected)
        await session.closeConnection()
    }

    func testAvailableFrameHoursReturnsOneIndexedSamplePerOccupiedHour() async throws {
      try execute(
        """
        INSERT INTO segment(id,bundleID,startDate,endDate,type)
        VALUES
          (20,'com.example.Editor','2026-08-22T12:59:59.000','2026-08-22T12:59:59.500',0),
          (21,'com.example.Editor','2026-08-22T13:00:00.000','2026-08-22T13:00:00.500',0),
          (22,'com.example.Editor','2026-08-23T07:12:00.000','2026-08-23T07:12:00.500',0);
        """)
        let session = LibraryDatabaseSession(configuration: configuration)
      let hours = try await session.availableFrameHours(
        in: DateInterval(
            start: try date("2026-08-22T12:00:00.000"),
            end: try date("2026-08-24T00:00:00.000")
        ))
      XCTAssertEqual(
        hours,
        [
            try date("2026-08-22T12:00:00.000"),
            try date("2026-08-22T13:00:00.000"),
            try date("2026-08-23T07:12:00.000"),
        ])
        await session.closeConnection()
    }

    func testFirstRecordingInPeriodsReturnsFirstSegmentInsideEachBucket() async throws {
      try execute(
        """
        INSERT INTO segment(id,bundleID,startDate,endDate,type)
        VALUES
          (30,'com.example.Editor','2026-08-22T13:55:23.743','2026-08-22T13:56:00.000',0),
          (31,'com.example.Editor','2026-08-22T13:58:00.000','2026-08-22T13:59:00.000',0);
        """)
        let session = LibraryDatabaseSession(configuration: configuration)
        let samples = try await session.firstRecordingInPeriods([
            DateInterval(
                start: try date("2026-08-22T12:00:00.000"),
                end: try date("2026-08-22T13:00:00.000")
            ),
            DateInterval(
                start: try date("2026-08-22T13:00:00.000"),
                end: try date("2026-08-22T14:00:00.000")
            ),
            DateInterval(
                start: try date("2026-08-22T14:00:00.000"),
                end: try date("2026-08-22T15:00:00.000")
            ),
        ])

      XCTAssertEqual(
        samples,
        [
            try date("2026-08-22T12:00:00.000"),
            try date("2026-08-22T13:55:23.743"),
        ])
        await session.closeConnection()
    }

    func testRecentWindowRetainsWholeThresholdPageAndUsesDescendingIDTieOrder() async throws {
        let tiedDate = "2027-01-01T00:00:00.000"
        let endDate = "2027-01-01T00:00:02.000"
        let values = (0..<205).map { offset in
            "(\(1_000 + offset),'com.example.Window','\(tiedDate)','\(endDate)',NULL,NULL,NULL,0)"
        }.joined(separator: ",")
      try execute(
        """
        INSERT INTO segment(id,bundleID,startDate,endDate,windowName,browserUrl,browserProfile,type)
        VALUES \(values);
        """)

        let session = LibraryDatabaseSession(configuration: configuration)
        let window = try await session.recentTimelineWindow(duration: 1)

        // A single row crosses the threshold, but the full first 100-row page
        // is retained and then reversed into chronological/id-ascending order.
        XCTAssertEqual(window.segments.count, 100)
        XCTAssertEqual(window.segments.map(\.rawID), Array(1_105...1_204).map(Int64.init))
        XCTAssertEqual(window.validSeekInterval?.start, try date("2026-08-22T12:00:00.000"))
        XCTAssertEqual(window.validSeekInterval?.end, try date(endDate))
        await session.closeConnection()
    }

    func testAroundWindowPagesBothDirectionsWithoutLosingCursorRows() async throws {
        let base = try date("2027-02-01T00:00:00.000")
        let formatter = Self.formatter
        let values = (0..<205).map { offset -> String in
            let value = formatter.string(from: base.addingTimeInterval(TimeInterval(offset)))
            return "(\(2_000 + offset),'com.example.Window','\(value)','\(value)',NULL,NULL,NULL,0)"
        }.joined(separator: ",")
      try execute(
        """
        INSERT INTO segment(id,bundleID,startDate,endDate,windowName,browserUrl,browserProfile,type)
        VALUES \(values);
        """)

        let session = LibraryDatabaseSession(configuration: configuration)
        let anchor = base.addingTimeInterval(102)
        let window = try await session.timelineWindow(around: anchor, duration: 1)

        // Zero-duration rows force continuation beyond page 100. The inclusive
        // before half owns the anchor; the strict after half starts at +103.
      XCTAssertEqual(
        window.segments.map(\.rawID),
                       [Int64(1), Int64(2)] + Array(2_000...2_204).map(Int64.init))
        XCTAssertEqual(
            window.segments.filter { $0.startDate == anchor }.map(\.rawID),
            [Int64(2_102)]
        )
        await session.closeConnection()
    }

    func testPagerContinuationCountsRawRowsWhenUnknownTypesAreSkipped() async throws {
        let unknownValues = (0..<100).map { offset in
            let id = 3_000 + offset
        return
          "(\(id),'unknown','2028-01-01T00:00:00.000','2028-01-01T00:00:00.000',NULL,NULL,NULL,99)"
        }.joined(separator: ",")
      try execute(
        """
        INSERT INTO segment(id,bundleID,startDate,endDate,windowName,browserUrl,browserProfile,type)
        VALUES \(unknownValues),
          (2_999,'known','2027-12-31T23:59:59.000','2027-12-31T23:59:59.000',NULL,NULL,NULL,0);
        """)

        let session = LibraryDatabaseSession(configuration: configuration)
        let window = try await session.recentTimelineWindow(duration: 1)

        // The first raw page is full even though none of its rows decode. Its
        // raw cursor must advance to the next page where the known row lives.
        XCTAssertTrue(window.segments.contains { $0.rawID == Int64(2_999) })
        XCTAssertFalse(window.segments.contains { $0.rawID >= Int64(3_000) })
        await session.closeConnection()
    }

    private func execute(_ sql: String) throws {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(configuration.databaseURL.path, &raw), SQLITE_OK)
        let database = try XCTUnwrap(raw)
        defer { sqlite3_close(database) }
        let key = try Data(contentsOf: configuration.keyFileURL)
      XCTAssertEqual(
        key.withUnsafeBytes {
            sqlite3_key(database, $0.baseAddress, Int32($0.count))
        }, SQLITE_OK)
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &error)
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite error \(status)"
            sqlite3_free(error)
            XCTFail(message)
            return
        }
    }

    private func nativeStarDates() throws -> [Date] {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(configuration.databaseURL.path, &raw), SQLITE_OK)
        let database = try XCTUnwrap(raw)
        defer { sqlite3_close(database) }
        let key = try Data(contentsOf: configuration.keyFileURL)
      XCTAssertEqual(
        key.withUnsafeBytes {
            sqlite3_key(database, $0.baseAddress, Int32($0.count))
        }, SQLITE_OK)
        return try LibraryDatabase.query(
            database: database,
            sql: LibraryDatabase.starredFrameDatesSQL
        ) { statement in
            try LibraryDatabase.databaseDate(
                LibraryDatabase.string(statement, column: 0) ?? ""
            )
        }
    }

    private func seed(_ configuration: LibreReverseLibraryConfiguration) throws {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(configuration.databaseURL.path, &raw), SQLITE_OK)
        let database = try XCTUnwrap(raw)
        defer { sqlite3_close(database) }
        let key = try Data(contentsOf: configuration.keyFileURL)
      XCTAssertEqual(
        key.withUnsafeBytes {
            sqlite3_key(database, $0.baseAddress, Int32($0.count))
        }, SQLITE_OK)
        var error: UnsafeMutablePointer<CChar>?
      let status = sqlite3_exec(
        database,
        """
        INSERT INTO segment(id,bundleID,startDate,endDate,windowName,browserUrl,browserProfile,type)
        VALUES
          (1,'com.example.Editor','2026-08-22T12:00:00.000','2026-08-22T12:00:02.000','Doc',NULL,NULL,0),
          (2,'com.example.Editor','2026-08-22T12:00:02.000','2026-08-22T12:00:04.000','Doc',NULL,NULL,0);
        INSERT INTO video(id,height,width,path,fileSize,frameRate,local,xid,processingState)
        VALUES(1,1080,1920,'2026/08/chunk',100,30.0,1,'fixture-video',2);
        INSERT INTO frame(id,createdAt,imageFileName,segmentId,videoId,videoFrameIndex,isStarred,encodingStatus)
        VALUES
          (1,'2026-08-22T12:00:00.000','f0',1,1,0,0,'success'),
          (2,'2026-08-22T12:00:00.500','f15',1,1,15,1,'success'),
          (3,'2026-08-22T12:00:01.000','f30',1,1,30,0,'success'),
          (4,'2026-08-22T12:00:01.500','f45',1,1,45,0,'success'),
          (5,'2026-08-22T12:00:01.500','f46',2,1,46,0,'success');
        """, nil, nil, &error)
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite error \(status)"
            sqlite3_free(error)
        throw NSError(
          domain: "LibraryDatabaseSessionTests", code: Int(status),
          userInfo: [
            NSLocalizedDescriptionKey: message
            ])
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter
    }()
}
#endif
