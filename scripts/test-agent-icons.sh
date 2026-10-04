#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -parse-as-library Sources/HerdrMac/AgentIcon.swift Tests/HerdrMacTests/AgentIconTests.swift -o .build/AgentIconTests
.build/AgentIconTests Sources/HerdrMac/Resources/AgentIcons
