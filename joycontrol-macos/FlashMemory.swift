//
//  FlashMemory.swift
//  joycontrol-macos
//
//  Created by Joey Jacobs on 1/30/21.
//

import Foundation

public class FlashMemory {
    public var data: Bytes
    private var defaultStickCal: Bool = false
    /// - Parameters:
    ///   - spiFlashMemoryData: data from a memory dump (can be created using dumpSpiFlash.py).
    ///   - size: size of the memory dump, should be constant
    public init(spiFlashMemoryData: Bytes? = nil, size: Int = 0x80000) throws {
        var tempData: Bytes
        if spiFlashMemoryData == nil {
            tempData = Array(repeating: 0xFF, count: size) // Blank data is all 0xFF
            defaultStickCal = true
        } else {
            tempData = spiFlashMemoryData!
        }
        if tempData.count != size {
            throw ApplicationError.general("Given data size {len(spiFlashMemoryData)} does not match size {size}.")
        }
        // set default controller stick calibration
        if defaultStickCal {
            // L-stick factory calibration
            tempData.replaceSubrange(0x603D ... 0x6045, with: [0x00, 0x07, 0x70, 0x00, 0x08, 0x80, 0x00, 0x07, 0x70])
            // R-stick factory calibration
            tempData.replaceSubrange(0x6046 ... 0x604E, with: [0x00, 0x08, 0x80, 0x00, 0x07, 0x70, 0x00, 0x07, 0x70])
        }
        data = tempData
    }

    public func getFactoryLStickCalibration() -> Bytes {
        return Array(data[0x603D ... 0x6045])
    }

    public func getFactoryRStickCalibration() -> Bytes {
        return Array(data[0x6046 ... 0x604E])
    }

    public func getUserLStickCalibration() -> Bytes? {
        // check if calibration data is available {
        if data[0x8010] == 0xB2, data[0x8011] == 0xA1 {
            return Array(data[0x8012 ... 0x801A])
        }
        return nil
    }

    public func getUserRStickCalibration() -> Bytes? {
        // check if calibration data is available {
        if data[0x801B] == 0xB2, data[0x801C] == 0xA1 {
            return Array(data[0x801D ... 0x8025])
        }
        return nil
    }
}
