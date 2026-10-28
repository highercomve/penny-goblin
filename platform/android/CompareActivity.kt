package dev.oriel

/** Second ledger window, in a separate process because Oriel 0.18's app driver
 * has process-wide state. SQLite WAL/revisions remain the shared authority. */
class CompareActivity : OrielActivity()
