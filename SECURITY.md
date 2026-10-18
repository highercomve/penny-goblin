# Security and private data

The repository is private. Report a vulnerability privately to the maintainer,
including affected versions and a synthetic reproducer. Do not attach real bank
statements, receipts, database files, pairing URLs, bearer tokens or private keys.

Ledger data and model files belong in the platform app-data directory, not in
Git. Pairing authenticates the desktop and pins its TLS certificate. Never bypass
certificate pinning to work around connectivity errors. Tailscale is an optional
network path, not a replacement for pairing authentication.

CI artifacts contain application code only. APKs are development builds; trusted
release signing and distribution are separate from successful compilation.
The CI sandbox override is restricted to the isolated synthetic WebKit UI tests;
production builds retain their normal browser protections.
