/// Counts how many calls run at the same time.
actor Gauge {
    var now = 0
    var peak = 0
    func enter() {
        now += 1
        peak = max(peak, now)
    }
    func leave() { now -= 1 }
}
