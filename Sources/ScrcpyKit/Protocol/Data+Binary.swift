import Foundation

extension Data {
    @inlinable
    public mutating func append<T>(value: T) {
        Swift.withUnsafeBytes(of: value) {
            self.append(contentsOf: $0)
        }
    }

    @inlinable
    public mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) {
            self.append(contentsOf: $0)
        }
    }

    @inlinable
    public mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) {
            self.append(contentsOf: $0)
        }
    }
}
