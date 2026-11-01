#if os(Windows)
import Foundation
import WinSDK

/// Windows' per-user data protection: what it encrypts can only be decrypted by the same Windows account on the same PC.
public enum Dpapi {
    private static let uiForbidden = DWORD(0x1)  // CRYPTPROTECT_UI_FORBIDDEN: fail instead of prompting

    public static func protect(_ data: Data) -> Data? {
        transform(data) { input, output in CryptProtectData(input, nil, nil, nil, nil, uiForbidden, output) }
    }

    public static func unprotect(_ data: Data) -> Data? {
        transform(data) { input, output in CryptUnprotectData(input, nil, nil, nil, nil, uiForbidden, output) }
    }

    private static func transform(_ data: Data, _ apply: (UnsafeMutablePointer<DATA_BLOB>, UnsafeMutablePointer<DATA_BLOB>) -> Bool) -> Data? {
        var bytes = [UInt8](data)
        return bytes.withUnsafeMutableBufferPointer { buffer in
            var input = DATA_BLOB(cbData: DWORD(buffer.count), pbData: buffer.baseAddress)
            var output = DATA_BLOB()
            guard apply(&input, &output), let pointer = output.pbData else { return nil }
            defer { LocalFree(pointer) }
            return Data(bytes: pointer, count: Int(output.cbData))
        }
    }
}
#endif
