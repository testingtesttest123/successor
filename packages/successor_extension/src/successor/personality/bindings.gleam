//// No descendant binding inheritance is supported. The host's durable
//// requirement rejects child/fork/rewind independently of extension presence.

import albedo/daemon/store
import sqlight

/// Native deletion owns the transaction. The host requirement foreign key
/// cascades on session deletion; identity documents and immutable history stay.
pub fn forget_session_in(
  db: sqlight.Connection,
  session: String,
) -> Result(Nil, String) {
  store.forget_session(db, ["personality_session"], session)
}
