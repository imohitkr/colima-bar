import Foundation
import Testing

@testable import ColimaBar

@Suite struct ShellTests {
    @Test func returnsAllOutput() async {
        let r = await Shell.run(["sh", "-c", "i=0; while [ $i -lt 2000 ]; do echo line$i; i=$((i+1)); done"])
        #expect(r.ok)
        let lines = r.out.split(separator: "\n")
        #expect(lines.count == 2000)
        #expect(lines.last == "line1999")
    }

    @Test func orphanHoldingThePipeDoesNotHang() async {
        let start = Date()
        let r = await Shell.run(["sh", "-c", "sleep 5 & echo hi"])
        #expect(r.ok)
        #expect(r.out == "hi\n")
        #expect(Date().timeIntervalSince(start) < 3)
    }
}
