-- Isolated validation fixture, not production initialization or schema.apply().
-- Deliberately omits runtime constraints: this validator checks marker/table/columns.
CREATE TABLE personality_meta(singleton INTEGER, version INTEGER);
INSERT INTO personality_meta VALUES(1, 2);
CREATE TABLE personality_persona(id TEXT, name TEXT, identity_revision INTEGER, writable INTEGER);
INSERT INTO personality_persona VALUES('p', 'unchanged identity', 7, 1);
CREATE TABLE personality_revision(persona_id TEXT, revision INTEGER, document TEXT, actor TEXT, origin_session TEXT, call_id TEXT, created_at INTEGER);
INSERT INTO personality_revision VALUES('p', 7, 'unchanged document', 'user', 'fixture', 'edit-7', 123);
CREATE TABLE personality_default(singleton INTEGER, persona_id TEXT);
INSERT INTO personality_default VALUES(1, 'p');
CREATE TABLE personality_session(session TEXT, persona_id TEXT, mode TEXT, generation INTEGER, pre_binding_through INTEGER);
INSERT INTO personality_session VALUES('s', 'p', 'owner', 1, 0);
CREATE TABLE personality_binding_revision(session TEXT, generation INTEGER, persona_id TEXT, mode TEXT, pre_binding_through INTEGER, created_at INTEGER);
INSERT INTO personality_binding_revision VALUES('s', 1, 'p', 'owner', 0, 123);
CREATE TABLE personality_tool_receipt(session TEXT, call_id TEXT, persona_id TEXT, request TEXT, result TEXT, created_at INTEGER);
INSERT INTO personality_tool_receipt VALUES('s', 'edit-7', 'p', 'request sentinel', 'result sentinel', 123);
CREATE TABLE personality_setup_receipt(retry_key TEXT, request TEXT, result TEXT, created_at INTEGER);
INSERT INTO personality_setup_receipt VALUES('setup-1', 'request sentinel', 'p', 123);
CREATE TABLE unrelated_sentinel(id INTEGER, payload BLOB);
INSERT INTO unrelated_sentinel VALUES(1, X'000102FF');
