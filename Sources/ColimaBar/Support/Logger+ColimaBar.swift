import os

extension Logger {
    /// The unified log subsystem for every ColimaBar logger.
    static let subsystem = "com.imohitkr.ColimaBar"

    /// A logger in ColimaBar's subsystem.
    init(category: String) {
        self.init(subsystem: Self.subsystem, category: category)
    }
}
