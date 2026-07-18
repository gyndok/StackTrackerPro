#!/bin/bash
# Builds the seeder CLI against the app's own blind-structure parser,
# so parsing can never drift between the app and the pipeline.
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -enable-bare-slash-regex \
    ../../StackTrackerPro/Managers/BlindStructureParsing.swift \
    cloudkit-ws.swift \
    import-scrape.swift \
    main.swift \
    -o seeder
echo "built: $(pwd)/seeder"
