import Testing
@testable import TitleCutCore

struct ScaffoldTests {
    @Test func coreModuleLinks() {
        #expect(TitleCutCore.moduleName == "TitleCutCore")
    }
}
