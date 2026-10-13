#!/usr/bin/env python3
"""Compile production Foundation catalog/projection and shared XCTest offline.

FolderDetail/FolderKind/ConversationSummary and the status model are extracted
from Conversation.swift, omitting status UI labels/tints that need SwiftUI.
Only AgentType is doubled. No grouping or loader implementation is doubled.
Native SwiftUI typechecking and simulator XCTest remain a macOS validation step.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "CodegiOS/Models/LogicalProject.swift",
    "CodegiOS/Features/Projects/ProjectCatalogModel.swift",
    "CodegiOS/Networking/ServerBindingLifetime.swift",
    "CodegiOS/Networking/APIError.swift",
    "CodegiOS/Networking/JSONCoding.swift",
]


def main():
    with tempfile.TemporaryDirectory(prefix="codeg-project-catalog-") as directory:
        package = Path(directory)
        target = package / "Tests/CatalogTests"
        target.mkdir(parents=True)
        (package / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Catalog", targets: [.testTarget(name: "CatalogTests")], swiftLanguageModes: [.v5])
''')
        for source in SOURCES:
            (target / Path(source).name).write_text((ROOT / source).read_text())
        conversation = (ROOT / "CodegiOS/Models/Conversation.swift").read_text()
        folder = conversation.split("/// Lifecycle status of a conversation row.")[0]
        status = conversation.split("enum ConversationStatus:", 1)[1].split("/// Posted (no payload)", 1)[0]
        status = status.split("    var label:", 1)[0] + "    var isLive:" + status.split("    var isLive:", 1)[1]
        summary = conversation.split("struct ConversationSummary:", 1)[1].split("/// Aggregate token/timing stats", 1)[0]
        folder += "enum ConversationStatus:" + status + "struct ConversationSummary:" + summary
        (target / "Folder.swift").write_text(folder.replace("import SwiftUI", "import Foundation"))
        (target / "AgentStub.swift").write_text('import Foundation\nenum AgentType: String, Codable, Hashable, Sendable { case claudeCode }\n')
        tests = (ROOT / "CodegiOSTests/LogicalProjectCatalogTests.swift").read_text().replace("@testable import Codeg\n", "")
        (target / "LogicalProjectCatalogTests.swift").write_text(tests)
        subprocess.run(["docker", "run", "--rm", "--network", "none", "-v", f"{package}:/input:ro", "-w", "/tmp",
                        "swift:6.2-jammy", "bash", "-lc",
                        "cp -R /input /tmp/package && cd /tmp/package && swift test --jobs 2"], check=True)


if __name__ == "__main__":
    main()
