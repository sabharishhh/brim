import Foundation

public struct BTMParser: Sendable {
    public init() {}
    
    public func parse(dump: String) -> [BTMRecord] {
        var records = [BTMRecord]()
        
        let lines = dump.components(separatedBy: .newlines)
        var currentUUID: String?
        var currentName: String?
        var currentDeveloperName: String?
        var currentType: String?
        var currentDisposition: String?
        var currentIdentifier: String?
        var currentURL: URL?
        var currentBundleIdentifier: String?
        
        func commitRecord() {
            if let uuid = currentUUID {
                let record = BTMRecord(
                    uuid: uuid,
                    name: currentName,
                    developerName: currentDeveloperName,
                    type: currentType,
                    disposition: currentDisposition,
                    identifier: currentIdentifier,
                    url: currentURL,
                    bundleIdentifier: currentBundleIdentifier
                )
                records.append(record)
            }
            currentUUID = nil
            currentName = nil
            currentDeveloperName = nil
            currentType = nil
            currentDisposition = nil
            currentIdentifier = nil
            currentURL = nil
            currentBundleIdentifier = nil
        }
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.starts(with: "#") && trimmed.hasSuffix(":") && !trimmed.contains(" ") {
                // New item block starts (e.g., "#1:")
                // Wait, it could be "Embedded Item Identifiers:" followed by "#1:"
                // So if we see UUID: we start a new record if we already have one.
                continue
            }
            
            if trimmed.starts(with: "UUID:") {
                commitRecord()
                currentUUID = trimmed.replacingOccurrences(of: "UUID:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.starts(with: "Name:") {
                currentName = trimmed.replacingOccurrences(of: "Name:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.starts(with: "Developer Name:") {
                currentDeveloperName = trimmed.replacingOccurrences(of: "Developer Name:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.starts(with: "Type:") {
                let val = trimmed.replacingOccurrences(of: "Type:", with: "").trimmingCharacters(in: .whitespaces)
                currentType = val.components(separatedBy: " ").first
            } else if trimmed.starts(with: "Disposition:") {
                currentDisposition = trimmed.replacingOccurrences(of: "Disposition:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.starts(with: "Identifier:") {
                currentIdentifier = trimmed.replacingOccurrences(of: "Identifier:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.starts(with: "URL:") {
                let path = trimmed.replacingOccurrences(of: "URL:", with: "").trimmingCharacters(in: .whitespaces)
                if !path.isEmpty {
                    currentURL = URL(fileURLWithPath: path)
                }
            } else if trimmed.starts(with: "Bundle Identifier:") {
                currentBundleIdentifier = trimmed.replacingOccurrences(of: "Bundle Identifier:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        commitRecord()
        return records
    }
}
