import WylaCore
import os

let logger = Logger(subsystem: "io.github.drawmeanelephant.wyla", category: "agent")
let sensors = Sensor.allCases.map(\.rawValue).joined(separator: ", ")
logger.notice("WylaAgent started (collectors not implemented yet; sensors: \(sensors, privacy: .public))")

dispatchMain()
