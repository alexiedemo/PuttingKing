import Foundation
import CoreData
import Combine

/// Service for managing scan history persistence
final class ScanHistoryService: ObservableObject {
    private let persistenceController: PersistenceController

    @Published private(set) var recentScans: [ScanRecord] = []

    init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
        fetchRecentScans()
    }

    // MARK: - Fetch Operations

    func fetchRecentScans(limit: Int = 50) {
        let request: NSFetchRequest<ScanRecord> = ScanRecord.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ScanRecord.date, ascending: false)]
        request.fetchLimit = limit

        do {
            recentScans = try persistenceController.viewContext.fetch(request)
        } catch {
            print("Failed to fetch recent scans: \(error)")
            recentScans = []
        }
    }

    func fetchAllScans() -> [ScanRecord] {
        let request: NSFetchRequest<ScanRecord> = ScanRecord.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ScanRecord.date, ascending: false)]

        do {
            return try persistenceController.viewContext.fetch(request)
        } catch {
            print("Failed to fetch all scans: \(error)")
            return []
        }
    }

    func fetchScans(forCourse courseName: String) -> [ScanRecord] {
        let request: NSFetchRequest<ScanRecord> = ScanRecord.fetchRequest()
        request.predicate = NSPredicate(format: "courseName == %@", courseName)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ScanRecord.date, ascending: false)]

        do {
            return try persistenceController.viewContext.fetch(request)
        } catch {
            print("Failed to fetch scans for course: \(error)")
            return []
        }
    }

    // MARK: - Save Operations

    enum SaveError: Error, LocalizedError {
        case persistenceFailed(Error)
        
        var errorDescription: String? {
            switch self {
            case .persistenceFailed(let error):
                return "Failed to save scan: \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func saveScan(
        courseName: String,
        holeNumber: Int,
        distance: Float,
        totalBreak: Float,
        breakDirection: String,
        recommendedSpeed: String,
        confidence: Float,
        stimpmeterSpeed: Float,
        latitude: Double = 0,
        longitude: Double = 0
    ) -> Result<ScanRecord, SaveError> {
        let context = persistenceController.viewContext

        let scan = ScanRecord(context: context)
        scan.id = UUID()
        scan.courseName = courseName
        scan.holeNumber = Int16(holeNumber)
        scan.date = Date()
        scan.distance = distance
        scan.totalBreak = totalBreak
        scan.breakDirection = breakDirection
        scan.recommendedSpeed = recommendedSpeed
        scan.confidence = confidence
        scan.stimpmeterSpeed = stimpmeterSpeed
        scan.latitude = latitude
        scan.longitude = longitude

        do {
            try persistenceController.saveOrThrow()
            fetchRecentScans()
            return .success(scan)
        } catch {
            // Rollback the unsaved object
            context.rollback()
            return .failure(.persistenceFailed(error))
        }
    }

    func saveScan(from puttingLine: PuttingLine, courseName: String, holeNumber: Int, stimpmeterSpeed: Float) -> Result<ScanRecord, SaveError> {
        return saveScan(
            courseName: courseName,
            holeNumber: holeNumber,
            distance: puttingLine.distance,
            totalBreak: puttingLine.estimatedBreak.totalBreak,
            breakDirection: puttingLine.estimatedBreak.breakDirection.rawValue,
            recommendedSpeed: puttingLine.recommendedSpeed.rawValue,
            confidence: puttingLine.confidence,
            stimpmeterSpeed: stimpmeterSpeed
        )
    }

    // MARK: - Delete Operations

    func deleteScan(_ scan: ScanRecord) {
        let context = persistenceController.viewContext
        context.delete(scan)
        persistenceController.save()
        fetchRecentScans()
    }

    func deleteScans(at offsets: IndexSet) {
        for index in offsets {
            guard index >= 0 && index < recentScans.count else { continue }
            let scan = recentScans[index]
            persistenceController.viewContext.delete(scan)
        }
        persistenceController.save()
        fetchRecentScans()
    }

    func deleteAllScans() {
        let request: NSFetchRequest<NSFetchRequestResult> = ScanRecord.fetchRequest()
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
        deleteRequest.resultType = .resultTypeObjectIDs

        do {
            let result = try persistenceController.viewContext.execute(deleteRequest) as? NSBatchDeleteResult
            // Merge batch delete into the context so in-memory objects are invalidated
            if let objectIDs = result?.result as? [NSManagedObjectID] {
                NSManagedObjectContext.mergeChanges(
                    fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
                    into: [persistenceController.viewContext]
                )
            }
            fetchRecentScans()
        } catch {
            print("Failed to delete all scans: \(error)")
        }
    }

    // MARK: - Statistics

    var totalScansCount: Int {
        let request: NSFetchRequest<ScanRecord> = ScanRecord.fetchRequest()
        return (try? persistenceController.viewContext.count(for: request)) ?? 0
    }

    var averageDistance: Float {
        let scans = fetchAllScans()
        guard !scans.isEmpty else { return 0 }
        let total = scans.reduce(0) { $0 + $1.distance }
        return total / Float(scans.count)
    }

    var averageConfidence: Float {
        let scans = fetchAllScans()
        guard !scans.isEmpty else { return 0 }
        let total = scans.reduce(0) { $0 + $1.confidence }
        return total / Float(scans.count)
    }

    func uniqueCourseNames() -> [String] {
        let request: NSFetchRequest<NSDictionary> = NSFetchRequest(entityName: "ScanRecord")
        request.propertiesToFetch = ["courseName"]
        request.returnsDistinctResults = true
        request.resultType = .dictionaryResultType

        do {
            let results = try persistenceController.viewContext.fetch(request)
            return results.compactMap { $0["courseName"] as? String }
        } catch {
            print("Failed to fetch unique course names: \(error)")
            return []
        }
    }
}
