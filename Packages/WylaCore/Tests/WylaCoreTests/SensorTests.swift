import Testing
import WylaCore

@Test func persistedIdentifiersAreStable() {
    #expect(Sensor.allCases.map(\.rawValue) == ["camera", "microphone", "screen"])
}
