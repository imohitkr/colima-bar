import Testing

@testable import ColimaBar

@Suite struct VMRecreateProgressTests {
    private func progress(_ step: VMRecreateProgress.Step) -> VMRecreateProgress {
        VMRecreateProgress(profile: "work", step: step)
    }

    @Test func eachStepHasItsLine() {
        var p = progress(.preparing)
        #expect(p.text == "Preparing…")
        p = progress(.backingUp)
        p.volume = "pgdata"
        p.bytes = 1 << 20
        p.total = Double(4 << 20)
        p.position = 2
        p.count = 5
        #expect(p.text == "Backing up pgdata (2 of 5)… 1.0 MB of about 4.0 MB")
        p = progress(.savingImages)
        p.bytes = 1 << 20
        #expect(p.text == "Saving images… 1.0 MB")
        #expect(progress(.recreating).text == "Recreating the VM…")
        #expect(progress(.waiting).text == "Waiting for Docker…")
        p = progress(.restoring)
        p.volume = "pgdata"
        p.position = 1
        p.count = 3
        #expect(p.text == "Restoring pgdata (1 of 3)…")
        p = progress(.loadingImages)
        p.bytes = 50
        p.total = 200
        #expect(p.text == "Loading images… 25%")
        p.isCancelling = true
        #expect(p.text == "Stopping…")
    }

    @Test func aByteStepHasAFractionOnlyWithAKnownSize() {
        var p = progress(.backingUp)
        p.bytes = 50
        #expect(p.fraction == nil)
        p.total = 100
        #expect(p.fraction == 0.5)
        p.bytes = 500
        #expect(p.fraction == 0.99)
        p = progress(.loadingImages)
        p.total = 100
        p.bytes = 100
        #expect(p.fraction == 1)
        for step in [VMRecreateProgress.Step.preparing, .recreating, .waiting] {
            #expect(progress(step).fraction == nil)
        }
    }

    @Test func theScriptAndTheWaitForDockerCannotBeCancelled() {
        for step in [VMRecreateProgress.Step.preparing, .backingUp, .savingImages, .restoring, .loadingImages] {
            #expect(progress(step).canCancel)
        }
        for step in [VMRecreateProgress.Step.recreating, .waiting] { #expect(!progress(step).canCancel) }
        var p = progress(.backingUp)
        p.isCancelling = true
        #expect(!p.canCancel)
    }
}
