import Foundation
import CoreData

@objc(ScanRecord)
public class ScanRecord: NSManagedObject {
    public override func awakeFromInsert() {
        super.awakeFromInsert()
        if id == nil {
            id = UUID()
        }
    }
}
