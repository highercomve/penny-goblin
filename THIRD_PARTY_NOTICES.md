# Third-party notices

Oriel 0.18.0 is fetched from https://github.com/highercomve/Oriel using the
release URL and package hash in `build.zig.zon`. Its LICENSE, NOTICE and
`licenses/` directory remain in the fetched package and apply to distributed
builds. The application has no open-source license assigned; this does not alter
third-party licenses.

Zig fetches the dependencies pinned by the Oriel package manifest, including
SQLite, llama.cpp, Yoga, QuickJS-ng, GTK bindings and zigimg. Python helper packages
are pinned in `scripts/helper-requirements.txt`; Android dependencies are declared
in `build.zig` and Oriel's Android template. Their licenses continue to apply.
Model weights are not distributed with the repository or build artifacts. Review
the chosen model's license before downloading or redistributing it.

The website is generated using Zine 0.14.0. Its generator is not bundled into the
served website. Penny Goblin brand assets were created for this application.
