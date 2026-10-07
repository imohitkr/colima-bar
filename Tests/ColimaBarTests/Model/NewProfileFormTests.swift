import Testing

@testable import ColimaBar

@Suite struct NewProfileFormTests {
    @Test func defaultsComeFromTheSelectedProfile() {
        var vm = VMInfo()
        vm.cpus = 4
        vm.memGB = 8
        vm.diskGB = 120
        let form = NewProfileForm.defaults(from: vm)
        #expect(form.cpus == 4 && form.memGB == 8 && form.diskGB == 120)
        #expect(form.runtime == "docker")
        #expect(form.name.isEmpty)
    }

    @Test func unknownValuesUseColimaDefaults() {
        let form = NewProfileForm.defaults(from: VMInfo())
        #expect(form.cpus == 2 && form.memGB == 2 && form.diskGB == 100)
    }

    @Test func theFormChecksNameSizesAndRuntime() {
        var form = NewProfileForm(name: "work", cpus: 2, memGB: 4, diskGB: 60)
        #expect(form.problem(existing: ["default"]) == nil)
        #expect(form.arguments == ["2", "4", "60", "docker"])
        #expect(form.problem(existing: ["work"]) != nil)
        form.diskGB = DiskShrink.minimumGB - 1
        #expect(form.problem(existing: []) != nil)
        form.diskGB = 60
        form.runtime = "incus"
        #expect(form.problem(existing: []) != nil)
        form.runtime = "containerd"
        form.cpus = 0
        #expect(form.problem(existing: []) != nil)
    }

    @Test func choicesStayBelowTheLimitAndKeepTheCurrentValue() {
        #expect(NewProfileForm.choices([1, 2, 4, 8, 16], limit: 8, including: 3) == [1, 2, 3, 4, 8])
        #expect(NewProfileForm.choices([1, 2, 4], limit: 2, including: 12) == [1, 2, 12])
    }
}
