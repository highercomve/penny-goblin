# Synchronization contract

One paired desktop coordinates protocol v1. QR pairing is explicit, short-lived
and single-use; it carries a 256-bit secret and the SHA-256 certificate pin.
Each phone gets an independently revocable random credential. Discovery is
untrusted routing information. Credentials never enter the frontend or logs.

The shared Zig domain owns all ledger writes. The desktop HTTPS transport is
a packaged Python helper using standard TLS plus cryptography; it passes
authenticated requests over local pipes to the Zig worker. Android uses a
Kotlin extension, Android Keystore and WorkManager. No database file is synced.

Entities are immutable content-addressed documents, statements, immutable
statement observations with review state, reviewed payments and budget/rules.
A payment includes its evidence hashes and statement-observation IDs. This
makes evidence ownership part of the same conflict boundary as the payment.
Attachments transfer once by hash; subsequent payment edits carry only hashes.

SQLite triggers queue local intent atomically with domain writes. Preparing a
request freezes one durable operation per entity; newer local edits remain
queued separately. Operation IDs and payload digests make lost replies safe
to retry. The desktop assigns authoritative per-entity revisions and an ordered
change sequence. Local UI revisions remain independent optimistic-lock tokens.

Pulls and acknowledgements commit with their cursor. Incoming changes never
overwrite pending local edits: both versions become visible conflicts. Choosing
a version is explicit. Deletion tombstones cannot be resurrected. Full recovery
replays retained history and preserves outgoing operations. Bounded HTTPS
requests require device authentication, including attachment data.

Desktop stays available in the tray. Phone sync runs on app opening, network
availability and constrained WorkManager retries; Android scheduling remains
best effort. Offline capture never waits for networking.
