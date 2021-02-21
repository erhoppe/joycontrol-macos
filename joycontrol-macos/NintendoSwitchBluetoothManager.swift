//
//  BluetoothManager.swift
//  joycontrol-macos
//
//  Created by Joey Jacobs on 2/15/21.
//
import BluetoothDarwin
import BluetoothHCI
import CBluetoothDarwin
import Foundation
import IOBluetooth
import os.log
import SwiftUI

class NintendoSwitchBluetoothManager: NSObject, IOBluetoothL2CAPChannelDelegate, ObservableObject, IOBluetoothHostControllerDelegate, ControllerProtocolDelgate {
    private static let controlPsm = BluetoothL2CAPPSM(kBluetoothL2CAPPSMHIDControl)
    private static let interruptPsm = BluetoothL2CAPPSM(kBluetoothL2CAPPSMHIDInterrupt)
    static let shared = NintendoSwitchBluetoothManager()
    private static let hostController = IOBluetoothHostController()
    private var controlChannel: IOBluetoothL2CAPChannel?
    private var interruptChannel: IOBluetoothL2CAPChannel?
    private var controlChannelOutgoing: IOBluetoothL2CAPChannel?
    private var interruptChannelOutgoing: IOBluetoothL2CAPChannel?
    private var serviceRecord: IOBluetoothSDPServiceRecord?
    private var hostAddress: BluetoothAddress?
    private let logger = Logger()
    var controllerProtocol: ControllerProtocol?
    @objc @Published var deviceAddress: String = ""
    private var connected: Bool = false

    override private init() {
        super.init()
        NintendoSwitchBluetoothManager.hostController.delegate = self
    }

    func stopScan() {
        logger.info(#function)
        let host = HostController.default!
        try! host.writeScanEnable(scanEnable: HCIWriteScanEnable.ScanEnable.noScans)
    }

    func startScan() {
        logger.info(#function)
        let host = HostController.default!
        try! host.writeScanEnable(scanEnable: HCIWriteScanEnable.ScanEnable.inquiryAndPageScan)
    }

    func getIsScanEnabled() -> Bool {
        var readScanEnable: Int8 = 0
        NintendoSwitchBluetoothManager.hostController.bluetoothHCIReadScanEnable(&readScanEnable)
        return readScanEnable > 0
    }

    func controllerProtocolConnectionLost() {
        interruptChannel = nil
        controlChannel = nil
        controllerProtocol = nil
    }

    private func ensureBluetoothControllerConfigured() {
        let host = HostController.default!
        let deviceName = "Pro Controller"
        try! host.writeLocalName(deviceName)

        let controller = NintendoSwitchBluetoothManager.hostController
        let classNum = 0x000508
        controller.delegate = self
        controller.bluetoothHCIWriteClass(ofDevice: BluetoothClassOfDevice(classNum))
        controller.bluetoothHCIWriteAuthenticationEnable(Byte(kAuthenticationDisabled.rawValue))
        controller.bluetoothHCIWriteSimplePairingMode(Byte(kBluetoothHCISimplePairingModeEnabled.rawValue))
        controller.bluetoothHCIWriteSimplePairingDebugMode(Byte(kBluetoothHCISimplePairingDebugModeEnabled.rawValue))

        let data = HCIWriteExtendedInquiryResponseData(deviceName: deviceName, modelId: "", fecRequired: false)!.getTuple()

        var response = BluetoothHCIExtendedInquiryResponse(data: data)
        controller.bluetoothHCIWriteExtendedInquiryResponse(Byte(kBluetoothHCIFECNotRequired.rawValue), in: &response)
        hostAddress = try! host.readDeviceAddress()
    }

    private func addSdpRecord() {
        let serviceDictionary = NSMutableDictionary(contentsOfFile: Bundle.main.path(forResource: "NintendoSwitchControllerSDP", ofType: "plist")!)
        serviceRecord = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: serviceDictionary! as [NSObject: AnyObject])
        if serviceRecord == nil {
            logger.info("serviceRecord is nil")
            return
        }
        logger.info("\(self.serviceRecord!.debugDescription)")
    }

    private func onBluetoothPoweredOn() {
        ensureBluetoothControllerConfigured()
        addSdpRecord()
        registerChannelOpenDelegate()
    }

    private func onBluetoothPoweredOff() {}

    private func registerChannelOpenDelegate() {
        guard IOBluetoothL2CAPChannel
            .register(
                forChannelOpenNotifications: self,
                selector: #selector(newL2CAPChannelOpened),
                withPSM: NintendoSwitchBluetoothManager.controlPsm,
                direction: kIOBluetoothUserNotificationChannelDirectionIncoming
            ) != nil
        else {
            logger.info("failed to register for channel \(NintendoSwitchBluetoothManager.controlPsm) open notifications.")
            return
        }
        guard IOBluetoothL2CAPChannel
            .register(
                forChannelOpenNotifications: self,
                selector: #selector(newL2CAPChannelOpened),
                withPSM: NintendoSwitchBluetoothManager.interruptPsm,
                direction: kIOBluetoothUserNotificationChannelDirectionIncoming
            ) != nil
        else {
            logger.info("failed to register for channel \(NintendoSwitchBluetoothManager.interruptPsm) open notifications.")
            return
        }
    }

    func connectNintendoSwitch(_ address: String) {
        logger.debug(#function)
        DispatchQueue.main.async {
            let nintendoSwitch = IOBluetoothDevice(addressString: address)!
            nintendoSwitch.openConnection()
            self.openL2CAPChannelOrFail(nintendoSwitch, NintendoSwitchBluetoothManager.controlPsm, &self.controlChannelOutgoing)
            self.openL2CAPChannelOrFail(nintendoSwitch, NintendoSwitchBluetoothManager.interruptPsm, &self.interruptChannelOutgoing)
        }
    }

    func disconnectNintendoSwitch(_ address: String) {
        logger.debug(#function)
        DispatchQueue.main.async { [self] in
            let nintendoSwitch = IOBluetoothDevice(addressString: address)!
            guard nintendoSwitch.isConnected() else {
                self.logger.debug("Nintendo Switch isn't connected. Skipping disconnect.")
                return
            }
            self.interruptChannelOutgoing?.close()
            self.interruptChannelOutgoing = nil
            self.controlChannelOutgoing?.close()
            self.controlChannelOutgoing = nil
            nintendoSwitch.closeConnection()
        }
    }

    private func cleanup() {
        logger.info("Removing service record")
        serviceRecord?.remove()
    }

    private func openL2CAPChannelOrFail(_ device: IOBluetoothDevice, _ psm: BluetoothL2CAPPSM, _ channel: AutoreleasingUnsafeMutablePointer<IOBluetoothL2CAPChannel?>!) {
        let result = device.openL2CAPChannelSync(channel, withPSM: psm, delegate: self)
        guard result == kIOReturnSuccess else {
            fatalError("Failed to open l2cap channel PSM: \(psm) result: \(result)")
        }
    }

    @objc
    func newL2CAPChannelOpened(notification _: IOBluetoothUserNotification, channel: IOBluetoothL2CAPChannel) {
        logger.debug(#function)
        channel.setDelegate(self)
    }

    private func getDataFromChannel(data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) -> Bytes {
        let opaquePointer = OpaquePointer(dataPointer)
        let unsafePointer = UnsafeMutablePointer<Byte>(opaquePointer)
        return Array(UnsafeBufferPointer<Byte>(start: unsafePointer, count: dataLength))
    }

    func l2capChannelData(_ l2capChannel: IOBluetoothL2CAPChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        if l2capChannel == controllerProtocol?.transport {
            let data = getDataFromChannel(data: dataPointer, length: dataLength)
            controllerProtocol?.reportReceived(data)
        } else {
            fatalError("Received data from non-interrupt channel.")
        }
    }

    private func sendEmptyInputReport(l2capChannel: IOBluetoothL2CAPChannel) -> IOReturn {
        logger.debug(#function)
        var emptyInputReport = Bytes(repeating: 0, count: 364)
        emptyInputReport[0] = 0xA1
        return l2capChannel.writeSync(&emptyInputReport, length: UInt16(emptyInputReport.count))
    }

    private func triggerResponseFromSwitch(l2capChannel: IOBluetoothL2CAPChannel) {
        logger.info(#function)
        for _ in 1 ... 10 {
            let result = sendEmptyInputReport(l2capChannel: l2capChannel)
            guard result == kIOReturnSuccess else {
                fatalError("sentEmptyInputReport failed with result: \(result)")
            }
        }
    }

    func l2capChannelOpenComplete(_ l2capChannel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
        logger.info(#function)
        guard error == kIOReturnSuccess else {
            logger.error("Channel open failed: \(error)")
            return
        }

        logger.debug("\(l2capChannel.debugDescription)")
        switch l2capChannel.psm {
        case NintendoSwitchBluetoothManager.controlPsm:
            logger.info("Control PSM Channel Connected")
            controlChannel = l2capChannel

        case NintendoSwitchBluetoothManager.interruptPsm:
            logger.info("Interrupt PSM Channel Connected")
            interruptChannel = l2capChannel
            controllerProtocol = ControllerProtocol(controller: Controller.proController, spiFlash: try! FlashMemory(), hostAddress: hostAddress!, delegate: self)
            controllerProtocol?.connectionMade(l2capChannel)
            stopScan()
            triggerResponseFromSwitch(l2capChannel: l2capChannel)
            deviceAddress = l2capChannel.device.addressString.split(separator: "-").joined(separator: ":")

        default:
            return
        }
    }

    func l2capChannelClosed(_ l2capChannel: IOBluetoothL2CAPChannel!) {
        logger.debug(#function)
        logger.debug("\(l2capChannel.debugDescription)")
        if l2capChannel == interruptChannel {
            if controllerProtocol == nil {
                controllerProtocolConnectionLost()
            } else {
                controllerProtocol!.connectionLost()
            }
        }
    }

    func l2capChannelReconfigured(_ l2capChannel: IOBluetoothL2CAPChannel!) {
        logger.debug(#function)
        logger.debug("\(l2capChannel.debugDescription)")
    }

    func l2capChannelWriteComplete(_: IOBluetoothL2CAPChannel!, refcon _: UnsafeMutableRawPointer!, status _: IOReturn) {
        logger.debug(#function)
    }

    func l2capChannelQueueSpaceAvailable(_ l2capChannel: IOBluetoothL2CAPChannel!) {
        logger.debug(#function)
        logger.debug("\(l2capChannel.debugDescription)")
    }

    func bluetoothHCIEventNotificationMessage(_ controller: IOBluetoothHostController, in _: IOBluetoothHCIEventNotificationMessageRef) {
        let isConnected = controller.powerState == kBluetoothHCIPowerStateON
        if isConnected != connected {
            logger.debug("Detected powerState change: \(self.connected) -> \(isConnected)")
            connected = isConnected
            if connected {
                onBluetoothPoweredOn()
            } else {
                onBluetoothPoweredOff()
            }
        }
    }

    deinit {
        cleanup()
    }
}
