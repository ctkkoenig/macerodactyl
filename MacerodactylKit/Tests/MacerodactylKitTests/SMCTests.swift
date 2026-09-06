import Foundation
import Testing

@testable import MacerodactylKit

// Mirrors the guard on SMC.swift itself.
#if canImport(IOKit)

/// Covers the byte decoding, which is the part that can be wrong silently.
///
/// The IOKit conversation itself is not unit-testable without the hardware, and
/// it fails loudly (`SMC()` returns nil) rather than quietly, so the value here
/// is in pinning the type conversions.
@Suite struct SMCValueTests {

    /// `flt` is little-endian IEEE-754, and is what every sensor on Apple
    /// silicon reports. These are real captures: F0Mx (fan maximum) and a Tp
    /// die-temperature sensor.
    @Test func floatIsLittleEndian() {
        // 4900.0 rpm — bytes as read from F0Mx on an M4 Pro.
        #expect(SMC.value(bytes: [0x00, 0x20, 0x99, 0x45], type: "flt") == 4900.0)
    }

    @Test func floatDecodesTemperature() {
        // 72.1 C from TCMb.
        let decoded = SMC.value(bytes: [0x3E, 0x2E, 0x90, 0x42], type: "flt")
        #expect(decoded != nil)
        #expect(abs(decoded! - 72.1) < 0.05)
    }

    /// Fan mode: 0 auto, 1 forced. A single byte.
    @Test func singleByteTypes() {
        #expect(SMC.value(bytes: [0x01], type: "ui8") == 1.0)
        #expect(SMC.value(bytes: [0x00], type: "ui8") == 0.0)
        #expect(SMC.value(bytes: [0x01], type: "flag") == 1.0)
    }

    /// Integers are big-endian, unlike `flt`. Getting this backwards is the
    /// classic SMC bug — it reads plausibly rather than obviously wrong.
    @Test func integersAreBigEndian() {
        #expect(SMC.value(bytes: [0x00, 0x96], type: "ui16") == 150.0)
        #expect(SMC.value(bytes: [0x00, 0x00, 0x01, 0x00], type: "ui32") == 256.0)
    }

    /// Fixed point, 7 integer bits and 8 fractional — how Intel Macs reported
    /// temperature. Kept so the reader is not silently wrong on older hardware.
    @Test func sp78FixedPoint() {
        #expect(SMC.value(bytes: [0x2D, 0x80], type: "sp78") == 45.5)
        #expect(SMC.value(bytes: [0x14, 0x00], type: "sp78") == 20.0)
    }

    /// The type string arrives space-padded from a fixed-width field.
    @Test func paddedTypeNamesAreAccepted() {
        #expect(SMC.value(bytes: [0x01], type: "ui8 ") == 1.0)
    }

    @Test func unknownTypeIsNilRatherThanGarbage() {
        #expect(SMC.value(bytes: [0x01, 0x02, 0x03, 0x04], type: "ch8*") == nil)
    }

    @Test func truncatedPayloadIsNil() {
        #expect(SMC.value(bytes: [0x00, 0x20], type: "flt") == nil)
        #expect(SMC.value(bytes: [], type: "ui8") == nil)
    }
}

#endif
