import Foundation
import Testing
import WylaCore

@Test func persistedIdentifiersAreStable() {
    #expect(Sensor.allCases.map(\.rawValue) == ["camera", "microphone", "screen"])
}

@Test func displayNamesAreUserFacingTitles() {
    #expect(Sensor.allCases.map(\.displayName) == ["Camera", "Microphone", "Screen"])
}

@Test func encodesAsPersistedIdentifier() throws {
    let data = try JSONEncoder().encode([Sensor.microphone])
    #expect(String(bytes: data, encoding: .utf8) == #"["microphone"]"#)
    #expect(try JSONDecoder().decode([Sensor].self, from: data) == [.microphone])
}

@Test func rejectsUnknownStoredIdentifier() {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Sensor.self, from: Data(#""lidar""#.utf8))
    }
}
