-- Native store fixture: only host-owned facts needed by identity persistence.
-- Independent of production identity initialization and daemon composition.
PRAGMA foreign_keys=ON;
CREATE TABLE sessions(id TEXT PRIMARY KEY, config_revision INTEGER NOT NULL DEFAULT 0);
CREATE TABLE transcript(seq INTEGER PRIMARY KEY, session TEXT NOT NULL REFERENCES sessions(id));
CREATE TABLE session_family(session TEXT PRIMARY KEY REFERENCES sessions(id), parent TEXT REFERENCES sessions(id));
CREATE TABLE session_extensions(session TEXT NOT NULL REFERENCES sessions(id), name TEXT NOT NULL, enabled INTEGER NOT NULL, PRIMARY KEY(session,name));
INSERT INTO sessions(id) VALUES('owner'),('other'),('historical'),('child');
INSERT INTO session_family VALUES('child','owner');
INSERT INTO transcript VALUES(3,'historical'),(17,'historical');
