import CoreData

/// Core Data stack controller with programmatic model definition
final class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    init(inMemory: Bool = false) {
        // Create managed object model programmatically
        let model = Self.createManagedObjectModel()
        container = NSPersistentContainer(name: "PuttingKing", managedObjectModel: model)

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        container.loadPersistentStores { description, error in
            if let error = error {
                // Core Data must load successfully — the app cannot function without
                // persistence for scan history. A silent failure here causes crashes
                // later when saving/fetching records with no store loaded.
                fatalError("Core Data failed to load: \(error.localizedDescription)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    /// Create the Core Data model programmatically
    private static func createManagedObjectModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        // Create ScanRecord entity
        let scanRecordEntity = NSEntityDescription()
        scanRecordEntity.name = "ScanRecord"
        scanRecordEntity.managedObjectClassName = "ScanRecord"

        // Define attributes
        let idAttribute = NSAttributeDescription()
        idAttribute.name = "id"
        idAttribute.attributeType = .UUIDAttributeType
        idAttribute.isOptional = true

        let courseNameAttribute = NSAttributeDescription()
        courseNameAttribute.name = "courseName"
        courseNameAttribute.attributeType = .stringAttributeType
        courseNameAttribute.isOptional = true

        let holeNumberAttribute = NSAttributeDescription()
        holeNumberAttribute.name = "holeNumber"
        holeNumberAttribute.attributeType = .integer16AttributeType
        holeNumberAttribute.defaultValue = 0

        let dateAttribute = NSAttributeDescription()
        dateAttribute.name = "date"
        dateAttribute.attributeType = .dateAttributeType
        dateAttribute.isOptional = true

        let distanceAttribute = NSAttributeDescription()
        distanceAttribute.name = "distance"
        distanceAttribute.attributeType = .floatAttributeType
        distanceAttribute.defaultValue = 0.0

        let totalBreakAttribute = NSAttributeDescription()
        totalBreakAttribute.name = "totalBreak"
        totalBreakAttribute.attributeType = .floatAttributeType
        totalBreakAttribute.defaultValue = 0.0

        let breakDirectionAttribute = NSAttributeDescription()
        breakDirectionAttribute.name = "breakDirection"
        breakDirectionAttribute.attributeType = .stringAttributeType
        breakDirectionAttribute.isOptional = true

        let recommendedSpeedAttribute = NSAttributeDescription()
        recommendedSpeedAttribute.name = "recommendedSpeed"
        recommendedSpeedAttribute.attributeType = .stringAttributeType
        recommendedSpeedAttribute.isOptional = true

        let confidenceAttribute = NSAttributeDescription()
        confidenceAttribute.name = "confidence"
        confidenceAttribute.attributeType = .floatAttributeType
        confidenceAttribute.defaultValue = 0.0

        let stimpmeterSpeedAttribute = NSAttributeDescription()
        stimpmeterSpeedAttribute.name = "stimpmeterSpeed"
        stimpmeterSpeedAttribute.attributeType = .floatAttributeType
        stimpmeterSpeedAttribute.defaultValue = 0.0

        let latitudeAttribute = NSAttributeDescription()
        latitudeAttribute.name = "latitude"
        latitudeAttribute.attributeType = .doubleAttributeType
        latitudeAttribute.defaultValue = 0.0

        let longitudeAttribute = NSAttributeDescription()
        longitudeAttribute.name = "longitude"
        longitudeAttribute.attributeType = .doubleAttributeType
        longitudeAttribute.defaultValue = 0.0

        scanRecordEntity.properties = [
            idAttribute,
            courseNameAttribute,
            holeNumberAttribute,
            dateAttribute,
            distanceAttribute,
            totalBreakAttribute,
            breakDirectionAttribute,
            recommendedSpeedAttribute,
            confidenceAttribute,
            stimpmeterSpeedAttribute,
            latitudeAttribute,
            longitudeAttribute
        ]

        model.entities = [scanRecordEntity]

        return model
    }

    func save() {
        let context = container.viewContext

        guard context.hasChanges else { return }

        do {
            try context.save()
        } catch {
            print("Failed to save Core Data context: \(error)")
        }
    }

    /// Throwing variant for callers that need to handle save failures
    func saveOrThrow() throws {
        let context = container.viewContext
        guard context.hasChanges else { return }
        try context.save()
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        // Create sample data for previews
        for i in 0..<5 {
            let scan = ScanRecord(context: context)
            scan.id = UUID()
            scan.courseName = "Sample Course \(i + 1)"
            scan.holeNumber = Int16(i + 1)
            scan.date = Date().addingTimeInterval(-Double(i * 86400))
            scan.distance = Float.random(in: 2.0...10.0)
            scan.totalBreak = Float.random(in: 0.02...0.15)
            scan.breakDirection = ["left", "right", "straight"].randomElement()!
            scan.recommendedSpeed = ["gentle", "moderate", "firm"].randomElement()!
            scan.confidence = Float.random(in: 0.6...0.95)
            scan.stimpmeterSpeed = Float.random(in: 8.0...12.0)
        }

        try? context.save()

        return controller
    }()
}
