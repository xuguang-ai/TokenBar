import Dispatch
import Foundation
import Security

/// Code-signature checks with Security.framework (spec §5.6). The file is never executed. Checks run on a
/// dedicated serial queue and are bridged back with a continuation, keeping them off the cooperative pool.
public struct LiveCodeSignatureVerifier: CodeSignatureVerifying {
    private static let queue = DispatchQueue(label: "tokenbar.codesign", qos: .utility)

    public init() {}

    public func verify(_ url: URL, teamID: String) async -> Bool {
        guard let text = Self.requirementText(teamID: teamID) else { return false }
        let path = url.path
        return await withCheckedContinuation { continuation in
            Self.queue.async {
                guard let requirement = Self.requirement(text) else { return continuation.resume(returning: false) }
                continuation.resume(returning: Self.checkStatic(path: path, requirement: requirement))
            }
        }
    }

    public func verifyRunningProcess(pid: Int32, teamID: String) async -> Bool {
        guard pid > 0, let text = Self.requirementText(teamID: teamID) else { return false }
        return await withCheckedContinuation { continuation in
            Self.queue.async {
                guard let requirement = Self.requirement(text) else { return continuation.resume(returning: false) }
                continuation.resume(returning: Self.checkRunning(pid: pid, requirement: requirement))
            }
        }
    }

    /// The requirement text, or nil when `teamID` is not a plain Apple Team ID (no injection into the
    /// requirement language).
    static func requirementText(teamID: String) -> String? {
        guard !teamID.isEmpty, teamID.count <= 20,
              teamID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII })
        else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    private static func requirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    private static func checkStatic(path: String, requirement: SecRequirement) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        error?.release()  // never surfaced: it can name paths and signing details
        return status == errSecSuccess
    }

    private static func checkRunning(pid: Int32, requirement: SecRequirement) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
