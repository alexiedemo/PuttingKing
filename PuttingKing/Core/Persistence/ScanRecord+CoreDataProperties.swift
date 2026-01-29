import Foundation
import CoreData

// MARK: - Identifiable Conformance for SwiftUI
extension ScanRecord: Identifiable {
    // Uses the existing 'id: UUID?' property
}

extension ScanRecord {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<ScanRecord> {
        return NSFetchRequest<ScanRecord>(entityName: "ScanRecord")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var courseName: String?
    @NSManaged public var holeNumber: Int16
    @NSManaged public var date: Date?
    @NSManaged public var distance: Float
    @NSManaged public var totalBreak: Float
    @NSManaged public var breakDirection: String?
    @NSManaged public var recommendedSpeed: String?
    @NSManaged public var confidence: Float
    @NSManaged public var stimpmeterSpeed: Float
    @NSManaged public var latitude: Double
    @NSManaged public var longitude: Double

    // Computed properties for convenience
    var breakDescription: String {
        guard totalBreak > 0.01 else { return "Straight" }
        let breakCm = Int(totalBreak * 100)
        switch breakDirection {
        case "left":
            return "\(breakCm)cm left"
        case "right":
            return "\(breakCm)cm right"
        default:
            return "Straight"
        }
    }

    var speedDescription: String {
        switch recommendedSpeed {
        case "gentle":
            return "Gentle"
        case "firm":
            return "Firm"
        default:
            return "Medium"
        }
    }

    var confidencePercentage: Int {
        Int(confidence * 100)
    }
}
