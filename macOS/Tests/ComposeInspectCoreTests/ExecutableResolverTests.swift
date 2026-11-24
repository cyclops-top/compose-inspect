import XCTest
@testable import ComposeInspectCore

final class ExecutableResolverTests: XCTestCase {
    private func resolver(_ environment: [String: String], files: Set<String>) -> ExecutableResolver {
        ExecutableResolver(environment: environment, isExecutable: { files.contains($0) })
    }

    func testSDKEnvironmentAndADBOverrideOrder() {
        let environment = ["ADB": "/custom/adb", "ANDROID_HOME": "/sdk", "ANDROID_SDK_ROOT": "/sdk2", "PATH": "/usr/bin"]
        let resolver = resolver(environment, files: ["/custom/adb", "/sdk/platform-tools/adb", "/sdk2/platform-tools/adb", "/usr/bin/adb", "/manual/adb"])
        XCTAssertEqual(resolver.resolveADB().location?.path, "/custom/adb")
        XCTAssertEqual(resolver.resolveADB(customPath: "/manual/adb").location?.source, "手动配置")
        let withoutExplicitADB = self.resolver(["ANDROID_HOME": "/sdk", "PATH": "/usr/bin"], files: ["/sdk/platform-tools/adb", "/usr/bin/adb"])
        XCTAssertEqual(withoutExplicitADB.resolveADB().location?.path, "/sdk/platform-tools/adb")
    }

    func testMissingEnvironmentCandidatesFallBackToPath() {
        let resolver = resolver(["ADB": "/missing", "PATH": "/not-installed:/opt/bin:/usr/bin"], files: ["/opt/bin/adb"])
        XCTAssertEqual(resolver.resolveADB().location, ExecutableLocation(path: "/opt/bin/adb", source: "环境变量 PATH"))
    }

    func testInvalidManualPathDoesNotSilentlyFallBack() {
        let resolver = resolver(["PATH": "/usr/bin"], files: ["/usr/bin/adb"])
        XCTAssertNil(resolver.resolveADB(customPath: "/broken/adb").location)
        XCTAssertNotNil(resolver.resolveADB(customPath: "/broken/adb").error)
        XCTAssertNil(resolver.resolveADB(customPath: "relative/adb").location)
    }

    func testBlankOverrideRestoresAutoDetectionAndEmptyPATHIsNotCWD() {
        let resolver = resolver(["PATH": ":relative:/usr/bin:"], files: ["/usr/bin/adb", "relative/adb"])
        XCTAssertEqual(resolver.resolveADB(customPath: " \n ").location?.path, "/usr/bin/adb")
        XCTAssertNil(self.resolver(["PATH": ":relative:"], files: ["relative/adb"]).resolveADB().location)
        XCTAssertNotNil(self.resolver([:], files: []).resolveADB().error)
    }

    func testLegacySDKRootFallback() {
        let resolver = resolver(["ANDROID_SDK_ROOT": "/sdk"], files: ["/sdk/platform-tools/adb"])
        XCTAssertEqual(resolver.resolveADB().location?.source, "环境变量 ANDROID_SDK_ROOT")
    }
}
