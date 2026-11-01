import XCTest
@testable import ComposeInspectCore

final class ExecutableResolverTests: XCTestCase {
    private func resolver(_ environment: [String: String], files: Set<String>) -> ExecutableResolver {
        ExecutableResolver(environment: environment, isExecutable: { files.contains($0) })
    }

    func testJavaHomePrecedesPath() {
        let resolver = resolver(["JAVA_HOME": "/Library/Java/jdk/Contents/Home", "PATH": "/usr/bin"],
                                files: ["/Library/Java/jdk/Contents/Home/bin/java", "/usr/bin/java"])
        XCTAssertEqual(resolver.resolve(.java).location,
                       ExecutableLocation(path: "/Library/Java/jdk/Contents/Home/bin/java", source: "环境变量 JAVA_HOME"))
    }

    func testSDKEnvironmentAndADBOverrideOrder() {
        let environment = ["ADB": "/custom/adb", "ANDROID_HOME": "/sdk", "ANDROID_SDK_ROOT": "/sdk2", "PATH": "/usr/bin"]
        let resolver = resolver(environment, files: ["/custom/adb", "/sdk/platform-tools/adb", "/sdk2/platform-tools/adb", "/usr/bin/adb", "/manual/adb"])
        XCTAssertEqual(resolver.resolve(.adb).location?.path, "/custom/adb")
        XCTAssertEqual(resolver.resolve(.adb, customPath: "/manual/adb").location?.source, "手动配置")
        let withoutExplicitADB = self.resolver(["ANDROID_HOME": "/sdk", "PATH": "/usr/bin"], files: ["/sdk/platform-tools/adb", "/usr/bin/adb"])
        XCTAssertEqual(withoutExplicitADB.resolve(.adb).location?.path, "/sdk/platform-tools/adb")
    }

    func testMissingEnvironmentCandidatesFallBackToPath() {
        let resolver = resolver(["JAVA_HOME": "/missing", "PATH": "/not-installed:/opt/java/bin:/usr/bin"], files: ["/opt/java/bin/java"])
        XCTAssertEqual(resolver.resolve(.java).location, ExecutableLocation(path: "/opt/java/bin/java", source: "环境变量 PATH"))
    }

    func testInvalidManualPathDoesNotSilentlyFallBack() {
        let resolver = resolver(["PATH": "/usr/bin"], files: ["/usr/bin/java", "/usr/bin/adb"])
        XCTAssertNil(resolver.resolve(.java, customPath: "/broken/java").location)
        XCTAssertNotNil(resolver.resolve(.java, customPath: "/broken/java").error)
        XCTAssertNil(resolver.resolve(.adb, customPath: "relative/adb").location)
    }

    func testManualJavaHomeOrJDKBundleAndPathsWithSpaces() {
        let resolver = resolver([:], files: ["/Library/My JDK.jdk/Contents/Home/bin/java", "/opt/jdk/bin/java"])
        XCTAssertEqual(resolver.resolve(.java, customPath: "/Library/My JDK.jdk").location?.path,
                       "/Library/My JDK.jdk/Contents/Home/bin/java")
        XCTAssertEqual(resolver.resolve(.java, customPath: " /opt/jdk ").location?.path, "/opt/jdk/bin/java")
    }

    func testBlankOverrideRestoresAutoDetectionAndEmptyPATHIsNotCWD() {
        let resolver = resolver(["PATH": ":relative:/usr/bin:"], files: ["/usr/bin/adb", "/cwd/java"])
        XCTAssertEqual(resolver.resolve(.adb, customPath: " \n ").location?.path, "/usr/bin/adb")
        XCTAssertNil(resolver.resolve(.java).location)
        XCTAssertNotNil(self.resolver([:], files: []).resolve(.java).error)
    }

    func testJDKHomeAndLegacySDKRootFallbacks() {
        let resolver = resolver(["JDK_HOME": "/jdk", "ANDROID_SDK_ROOT": "/sdk"], files: ["/jdk/bin/java", "/sdk/platform-tools/adb"])
        XCTAssertEqual(resolver.resolve(.java).location?.source, "环境变量 JDK_HOME")
        XCTAssertEqual(resolver.resolve(.adb).location?.source, "环境变量 ANDROID_SDK_ROOT")
    }
}
