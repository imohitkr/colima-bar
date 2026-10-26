import Testing

@testable import ColimaBar

@Suite struct KubeConfigTests {
    private let view = """
        {"apiVersion":"v1","kind":"Config","current-context":"colima",
         "contexts":[
           {"name":"colima","context":{"cluster":"colima","user":"colima"}},
           {"name":"prod","context":{"cluster":"prod","user":"me","namespace":"shop"}},
           {"name":"-bad","context":{"cluster":"x"}},
           {"context":{"cluster":"nameless"}}],
         "clusters":[],"users":[]}
        """

    @Test func readsContextsWithTheirNamespaces() throws {
        let config = try #require(KubeConfig.parse(view))
        #expect(config.current == "colima")
        #expect(config.contexts.map(\.name) == ["colima", "prod"])
        #expect(config.contexts[0].namespace == "default")
        #expect(config.contexts[1].namespace == "shop")
        #expect(config.contexts[1].cluster == "prod")
        #expect(config.currentContext?.name == "colima")
        #expect(config.namespaces == ["default", "shop"])
    }

    @Test func aConfigWithoutContextsParses() throws {
        let config = try #require(KubeConfig.parse(#"{"apiVersion":"v1","current-context":""}"#))
        #expect(config.current == nil)
        #expect(config.contexts.isEmpty)
        #expect(config.currentContext == nil)
    }

    @Test func textThatIsNotAnObjectIsNotAConfig() {
        #expect(KubeConfig.parse("") == nil)
        #expect(KubeConfig.parse("error: no config") == nil)
        #expect(KubeConfig.parse("[]") == nil)
    }
}
