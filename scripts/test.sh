#!/bin/zsh
set -eu
cd "${0:A:h}/.."
mkdir -p .build
swiftc -swift-version 5 -module-cache-path "${TMPDIR:-/tmp}/nightshift-swift-cache" Sources/Core.swift Sources/Integrations.swift Sources/Detection.swift Tests/CoreTests.swift -o .build/CoreTests
.build/CoreTests
swiftc -swift-version 5 -module-cache-path "${TMPDIR:-/tmp}/nightshift-swift-cache" Sources/Core.swift Sources/Integrations.swift Sources/Detection.swift Tests/DetectionTests.swift -o .build/DetectionTests
.build/DetectionTests
swiftc -swift-version 5 -module-cache-path "${TMPDIR:-/tmp}/nightshift-swift-cache" Sources/Core.swift Sources/LidCore.swift Tests/LidTests.swift -o .build/LidTests
.build/LidTests
python3 -m unittest discover -s Tests -p 'test_*.py'
