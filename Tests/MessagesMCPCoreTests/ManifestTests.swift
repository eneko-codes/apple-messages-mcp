import Foundation
import Testing

@testable import MessagesMCPCore

/// The manifest is not documentation. Claude Desktop builds the per-tool permission
/// switches from its `tools` array, before this server has ever run, so a tool missing
/// from it has no switch and a tool listed there that no longer exists is a switch that
/// controls nothing. Nothing at runtime can detect either, which is why it is checked
/// here.
@Suite("Extension manifest")
struct ManifestTests {

    /// Derived from this file's own path: SwiftPM makes no promise about the working
    /// directory a test runs in, and these two files are deliberately outside the
    /// package's resources.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MessagesMCPCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repositoryRoot.appending(path: "extension/manifest.json"))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repositoryRoot.appending(path: "Resources/Info.plist"))
        return try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any] ?? [:]
    }

    private func declaredTools() throws -> [[String: Any]] {
        try manifest()["tools"] as? [[String: Any]] ?? []
    }

    @Test("Every tool the server exposes has a switch, and every switch has a tool")
    func manifestMatchesTheCatalogue() throws {
        let declared = Set(try declaredTools().compactMap { $0["name"] as? String })
        #expect(declared == Set(ToolCatalog.all().map(\.name)))
    }

    @Test("Every declared tool carries a description for its switch to be labelled with")
    func everyDeclaredToolIsDescribed() throws {
        for tool in try declaredTools() {
            let name = tool["name"] as? String ?? "(unnamed)"
            #expect((tool["description"] as? String)?.isEmpty == false, "\(name)")
        }
    }

    /// The version is read by three different things — the extension installer, the
    /// `initialize` response, and the embedded Info.plist that TCC shows. Two of them
    /// disagreeing is how a bug report ends up describing a build nobody has.
    @Test("The version matches the server and the embedded Info.plist")
    func versionsAgree() throws {
        #expect(try manifest()["version"] as? String == MessagesMCPServer.version)
        #expect(
            try infoPlist()["CFBundleShortVersionString"] as? String == MessagesMCPServer.version)
    }

    /// The send path runs a shortcut, and a prompt raised by it may be attributed to this
    /// binary. Without the key the consent is denied silently, with no dialog.
    @Test("The Info.plist declares the Apple events usage description")
    func usageDescriptionIsDeclared() throws {
        #expect((try infoPlist()["NSAppleEventsUsageDescription"] as? String)?.isEmpty == false)
    }
}
