import Darwin

public extension String {

    var terminalColumnWidth: UInt32 {
        unicodeScalars.reduce(UInt32(0)) { width, scalar in
            let scalarWidth = wcwidth(wchar_t(scalar.value))
            return width + UInt32(scalarWidth >= 0 ? scalarWidth : 1)
        }
    }

}
