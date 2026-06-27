import AppKit
import Foundation
import Security

func logCodeSigningDiagnostics() {
    print("=== TABDISPLAY DIAGNOSTICS ===")
    
    let bundleID = Bundle.main.bundleIdentifier ?? "N/A (No Bundle ID)"
    let executablePath = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "Unknown"
    let bundleURL = Bundle.main.bundleURL.path
    
    print("Bundle Identifier: \(bundleID)")
    print("Executable Path:   \(executablePath)")
    print("Bundle URL:         \(bundleURL)")
    
    var selfCode: SecCode?
    let status = SecCodeCopySelf(SecCSFlags(rawValue: 0), &selfCode)
    
    if status == errSecSuccess, let code = selfCode {
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode)
        
        if staticStatus == errSecSuccess, let sCode = staticCode {
            var signingInfo: CFDictionary?
            let infoStatus = SecCodeCopySigningInformation(sCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo)
            
            if infoStatus == errSecSuccess, let info = signingInfo as? [String: Any] {
                if let identifier = info[kSecCodeInfoIdentifier as String] as? String {
                    print("Code Identifier:   \(identifier)")
                }
                if let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String {
                    print("Team Identifier:   \(teamID)")
                } else {
                    print("Team Identifier:   Not Set")
                }
                if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate], !certificates.isEmpty {
                    print("Signing Identity Certificates count: \(certificates.count)")
                    for (index, cert) in certificates.enumerated() {
                        var commonName: CFString?
                        SecCertificateCopyCommonName(cert, &commonName)
                        let name = (commonName as String?) ?? "Unknown Certificate"
                        print("  [\(index)] Common Name: \(name)")
                    }
                } else {
                    print("Signing Identity:  Ad-hoc or Unsigned")
                }
            } else {
                print("Signing Info:      Not readable (SecCodeCopySigningInformation error \(infoStatus))")
            }
        } else {
            print("Static Code Object: Failed to retrieve (SecCodeCopyStaticCode error \(staticStatus))")
        }
    } else {
        print("Self Code Object:  Failed to retrieve (SecCodeCopySelf error \(status))")
    }
    
    let hasAccess = CGPreflightScreenCaptureAccess()
    print("CGPreflightScreenCaptureAccess: \(hasAccess ? "GRANTED" : "NOT GRANTED")")
    print("==============================\n")
}

// Disable stdout buffering to allow real-time console logs in remote background processes
setbuf(stdout, nil)

logCodeSigningDiagnostics()

if CommandLine.arguments.contains("--test-client") {
    runTestClient()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    if CommandLine.arguments.contains("--auto-start") {
        delegate.autoStart = true
    }

    if let recordIndex = CommandLine.arguments.firstIndex(of: "--record-to-file"),
       recordIndex + 1 < CommandLine.arguments.count {
        delegate.recordFilePath = CommandLine.arguments[recordIndex + 1]
    }

    app.run()
}
