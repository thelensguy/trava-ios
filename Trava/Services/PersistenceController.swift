//  Services/PersistenceController.swift
//  Trava
//
//  Singleton NSPersistentContainer.
//  The CoreData model is defined programmatically — no .xcdatamodeld file required.

import CoreData

final class PersistenceController {

    static let shared = PersistenceController()

    /// In-memory store for SwiftUI previews.
    static let preview = PersistenceController(inMemory: true)

    /// Broadcast after resetStore() completes so services can clear their caches.
    static let didResetNotification = Notification.Name("PersistenceControllerDidReset")

    let container: NSPersistentContainer

    // MARK: - Init

    private init(inMemory: Bool = false) {
        container = NSPersistentContainer(
            name: "Trava",
            managedObjectModel: Self.makeModel()
        )

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        } else {
            // Allow lightweight migration so adding new optional attributes
            // (e.g. administrativeArea) doesn't crash existing installs.
            let desc = container.persistentStoreDescriptions.first
            desc?.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            desc?.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        }

        container.loadPersistentStores { _, error in
            if let error {
                // In production, surface this to the user rather than crashing.
                fatalError("CoreData failed to load store: \(error)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    // MARK: - Programmatic model (no .xcdatamodeld file)

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        // -- TrackEntity --
        let entity = NSEntityDescription()
        entity.name = "TrackEntity"
        entity.managedObjectClassName = NSStringFromClass(TrackEntity.self)

        func attr(
            _ name: String,
            _ type: NSAttributeType,
            optional: Bool = false,
            defaultValue: Any? = nil
        ) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = optional
            if let def = defaultValue { a.defaultValue = def }
            return a
        }

        entity.properties = [
            attr("trackId",         .stringAttributeType),
            attr("userId",          .stringAttributeType),
            attr("coordinatesData", .binaryDataAttributeType),
            attr("startedAt",       .dateAttributeType),
            attr("endedAt",         .dateAttributeType,   optional: true),
            attr("distanceKm",      .doubleAttributeType,  defaultValue: 0.0),
            attr("cityName",        .stringAttributeType,  defaultValue: ""),
            attr("isPublic",        .booleanAttributeType, defaultValue: false),
            attr("isSynced",        .booleanAttributeType, defaultValue: false),
        ]

        // -- CityEntity --
        let cityEntity = NSEntityDescription()
        cityEntity.name = "CityEntity"
        cityEntity.managedObjectClassName = NSStringFromClass(CityEntity.self)

        cityEntity.properties = [
            attr("cityId",              .stringAttributeType),
            attr("userId",              .stringAttributeType),
            attr("cityName",            .stringAttributeType),
            attr("country",             .stringAttributeType,    defaultValue: ""),
            attr("countryCode",         .stringAttributeType,    defaultValue: ""),
            attr("administrativeArea",  .stringAttributeType,    defaultValue: ""),
            attr("firstVisitedAt",      .dateAttributeType),
            attr("lastVisitedAt",       .dateAttributeType),
            attr("coordinatesData",     .binaryDataAttributeType),
            attr("totalDistanceKm",     .doubleAttributeType,    defaultValue: 0.0),
            attr("totalSessions",       .integer32AttributeType, defaultValue: 0),
            attr("coveragePercent",     .doubleAttributeType,    defaultValue: 0.0),
            attr("isPublic",            .booleanAttributeType,   defaultValue: false),
            attr("isSynced",            .booleanAttributeType,   defaultValue: false),
        ]

        // -- CityBoundaryEntity --
        // Shared cache table (NOT per-user), keyed by cityName + country.
        let boundaryEntity = NSEntityDescription()
        boundaryEntity.name = "CityBoundaryEntity"
        boundaryEntity.managedObjectClassName = NSStringFromClass(CityBoundaryEntity.self)

        boundaryEntity.properties = [
            attr("cityName",        .stringAttributeType),
            attr("country",         .stringAttributeType, defaultValue: ""),
            attr("coordinatesData", .binaryDataAttributeType),
            attr("fetchedAt",       .dateAttributeType),
        ]

        model.entities = [entity, cityEntity, boundaryEntity]
        return model
    }

    // MARK: - Store reset

    /// Destroys and recreates the persistent store, clearing all data including
    /// WAL / SHM journal files. Broadcasts `didResetNotification` so that
    /// in-memory service caches are cleared. Must be called on the main thread.
    func resetStore() {
        let coordinator = container.persistentStoreCoordinator
        do {
            for store in coordinator.persistentStores {
                guard let url = store.url, url.path != "/dev/null" else {
                    // In-memory preview store — just wipe the context.
                    container.viewContext.reset()
                    continue
                }
                try coordinator.remove(store)
                try coordinator.destroyPersistentStore(
                    at: url, ofType: NSSQLiteStoreType, options: nil
                )
                try coordinator.addPersistentStore(
                    ofType: NSSQLiteStoreType,
                    configurationName: nil,
                    at: url,
                    options: [
                        NSMigratePersistentStoresAutomaticallyOption: true,
                        NSInferMappingModelAutomaticallyOption: true,
                    ]
                )
            }
            container.viewContext.reset()
        } catch {
            print("[CoreData] resetStore failed: \(error)")
        }
        NotificationCenter.default.post(name: Self.didResetNotification, object: nil)
    }

    // MARK: - Save helper

    func save() {
        let ctx = container.viewContext
        guard ctx.hasChanges else { return }
        do {
            try ctx.save()
        } catch {
            print("[CoreData] Save error: \(error)")
        }
    }
}
