import Foundation

public struct LengthPrefixedFramer {
    public static let maxPayloadSize: UInt32 = 16 * 1024 * 1024 // 16 MB limit

    public static func encode(payload: Data) throws -> Data {
        let length = UInt32(payload.count)
        guard length <= maxPayloadSize else {
            throw ComputerUseError.ipcError(reason: "Payload size \(length) exceeds maximum limit \(maxPayloadSize)")
        }
        var bigEndianLength = length.bigEndian
        var data = Data(bytes: &bigEndianLength, count: 4)
        data.append(payload)
        return data
    }

    public static func decode(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else {
            return nil
        }
        let lengthData = buffer.subdata(in: 0..<4)
        let payloadLength = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        guard payloadLength <= maxPayloadSize else {
            throw ComputerUseError.ipcError(reason: "Incoming payload header length \(payloadLength) exceeds maximum limit \(maxPayloadSize)")
        }

        let totalExpectedLength = 4 + Int(payloadLength)
        guard buffer.count >= totalExpectedLength else {
            return nil
        }

        let payload = buffer.subdata(in: 4..<totalExpectedLength)
        buffer.removeSubrange(0..<totalExpectedLength)
        return payload
    }
}
