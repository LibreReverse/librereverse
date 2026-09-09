/// Native recording, OCR, meeting, and search tables.
enum LibrarySchema {
    static let schemaSQL = """
    PRAGMA user_version=41;
    CREATE TABLE IF NOT EXISTS segment(
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, bundleID TEXT, startDate TEXT NOT NULL,
      endDate TEXT NOT NULL, windowName TEXT, browserUrl TEXT, browserProfile TEXT,
      type INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS video(
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, height INTEGER NOT NULL, width INTEGER NOT NULL,
      path TEXT NOT NULL DEFAULT '', captureType TEXT, fileSize INTEGER,
      frameRate REAL NOT NULL DEFAULT 0.0, local INTEGER NOT NULL DEFAULT 1,
      uploadedAt TEXT, xid TEXT, processingState INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS frame(
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, createdAt TEXT NOT NULL,
      imageFileName TEXT NOT NULL, segmentId INTEGER REFERENCES segment(id),
      videoId INTEGER REFERENCES video(id), videoFrameIndex INTEGER,
      isStarred INTEGER NOT NULL DEFAULT 0, encodingStatus TEXT
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts4(text, otherText, tokenize=porter);
    CREATE VIRTUAL TABLE IF NOT EXISTS searchOffsets USING fts4(text, otherText, tokenize=porter);
    CREATE VIRTUAL TABLE IF NOT EXISTS searchRanking USING fts5(text, otherText, title, tokenize=porter);
    CREATE TABLE IF NOT EXISTS doc_segment(
      docid INTEGER NOT NULL UNIQUE, segmentId INTEGER NOT NULL REFERENCES segment(id),
      frameId INTEGER REFERENCES frame(id)
    );
    CREATE TABLE IF NOT EXISTS node(
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, frameId INTEGER NOT NULL REFERENCES frame(id),
      nodeOrder INTEGER NOT NULL, textOffset INTEGER NOT NULL, textLength INTEGER NOT NULL,
      leftX REAL NOT NULL, topY REAL NOT NULL, width REAL NOT NULL, height REAL NOT NULL,
      windowIndex INTEGER
    );
    CREATE TABLE IF NOT EXISTS event(
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, type TEXT NOT NULL, status TEXT NOT NULL,
      title TEXT, participants TEXT, detailsJSON TEXT, calendarID TEXT, calendarEventID TEXT,
      calendarSeriesID TEXT, segmentID INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS audio(
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, segmentId INTEGER NOT NULL REFERENCES segment(id),
      path TEXT NOT NULL, startTime TEXT NOT NULL, duration REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS transcript_word(
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, segmentId INTEGER NOT NULL REFERENCES segment(id),
      speechSource TEXT NOT NULL, word TEXT NOT NULL, timeOffset INTEGER NOT NULL,
      fullTextOffset INTEGER, duration INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS summary(
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, status TEXT NOT NULL, text TEXT,
      eventId INTEGER NOT NULL UNIQUE
    );
    CREATE INDEX IF NOT EXISTS index_frame_on_createdat ON frame(createdAt);
    CREATE INDEX IF NOT EXISTS index_frame_on_segmentid_createdat ON frame(segmentId,createdAt);
    CREATE INDEX IF NOT EXISTS index_frame_on_videoid ON frame(videoId);
    CREATE INDEX IF NOT EXISTS index_segment_on_appid ON segment(bundleID);
    CREATE INDEX IF NOT EXISTS index_segment_on_starttime ON segment(startDate);
    CREATE INDEX IF NOT EXISTS index_segment_on_endtime ON segment(endDate);
    CREATE INDEX IF NOT EXISTS index_node_on_frameid ON node(frameId);
    CREATE INDEX IF NOT EXISTS index_doc_segment_on_frameid_docid ON doc_segment(frameId,docid);
    CREATE INDEX IF NOT EXISTS index_doc_segment_on_segmentid_docid ON doc_segment(segmentId,docid);
    CREATE INDEX IF NOT EXISTS index_transcript_word_on_segmentid_fulltextoffset
      ON transcript_word(segmentId,fullTextOffset);
    """
}
