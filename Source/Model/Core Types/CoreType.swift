//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  CoreType.swift
//  Axoloty
//
//

import Foundation

/// All Coaty core types as defined in https://github.com/coatyio/coaty-js/blob/master/src/model/types.ts
public enum CoreType: String, Codable, Sendable {
    
    // MARK: - Value definitions.
    
    case CoatyObject = "CoatyObject"
    case User = "User"
    case Annotation = "Annotation"
    case Task = "Task"
    case IoSource = "IoSource"
    case IoActor = "IoActor"
    case IoNode = "IoNode"
    case IoContext = "IoContext"
    case Identity = "Identity"
    case Log = "Log"
    case Location = "Location"
    case Snapshot = "Snapshot"
    
    enum ObjectType: String {
        case CoatyObject = "coaty.CoatyObject"
        case User = "coaty.User"
        case Annotation = "coaty.Annotation"
        case Task = "coaty.Task"
        case IoSource = "coaty.IoSource"
        case IoActor = "coaty.IoActor"
        case IoNode = "coaty.IoNode"
        case IoContext = "coaty.IoContext"
        case Identity = "coaty.Identity"
        case Log = "coaty.Log"
        case Location = "coaty.Location"
        case Snapshot = "coaty.Snapshot"
    }
    
    private static let classTypes: [CoreType: CoatyObject.Type] = [
        .CoatyObject: Axoloty.CoatyObject.self,
        .User: Axoloty.User.self,
        .Annotation: Axoloty.Annotation.self,
        .Task: Axoloty.CoatyTask.self,
        .IoSource: Axoloty.IoSource.self,
        .IoActor: Axoloty.IoActor.self,
        .IoNode: Axoloty.IoNode.self,
        .IoContext: Axoloty.IoContext.self,
        .Identity: Axoloty.Identity.self,
        .Log: Axoloty.Log.self,
        .Location: Axoloty.Location.self,
        .Snapshot: Axoloty.Snapshot.self,
    ]

    static func getClassType(forCoreType: CoreType) -> CoatyObject.Type {
        classTypes[forCoreType]!
    }

    /// Gets the core type for the given object type, if the object type corresponds
    /// to a Coaty core type.
    private static let coreTypesByObjectType: [String: CoreType] = [
        ObjectType.CoatyObject.rawValue: .CoatyObject,
        ObjectType.User.rawValue: .User,
        ObjectType.Annotation.rawValue: .Annotation,
        ObjectType.Task.rawValue: .Task,
        ObjectType.IoSource.rawValue: .IoSource,
        ObjectType.IoActor.rawValue: .IoActor,
        ObjectType.IoNode.rawValue: .IoNode,
        ObjectType.IoContext.rawValue: .IoContext,
        ObjectType.Identity.rawValue: .Identity,
        ObjectType.Log.rawValue: .Log,
        ObjectType.Location.rawValue: .Location,
        ObjectType.Snapshot.rawValue: .Snapshot,
    ]

    static func getCoreType(forObjectType: String) -> CoreType? {
        coreTypesByObjectType[forObjectType]
    }
    
    /// Registers all Coaty core object types.
    static func registerCoreObjectTypes() {
        _ = Axoloty.CoatyObject.objectType
        _ = Axoloty.User.objectType
        _ = Axoloty.Annotation.objectType
        _ = Axoloty.CoatyTask.objectType
        _ = Axoloty.IoSource.objectType
        _ = Axoloty.IoActor.objectType
        _ = Axoloty.IoNode.objectType
        _ = Axoloty.IoContext.objectType
        _ = Axoloty.Identity.objectType
        _ = Axoloty.Log.objectType
        _ = Axoloty.Location.objectType
        _ = Axoloty.Snapshot.objectType
    }
    
    static func registerSensorThingsTypes() {
        _ = Axoloty.Sensor.objectType
        _ = Axoloty.Thing.objectType
        _ = Axoloty.FeatureOfInterest.objectType
        _ = Axoloty.Observation.objectType
    }
    
    /// Gets the object type of this core type.
    public var objectType: String {
        switch self {
        case .CoatyObject: 
            return ObjectType.CoatyObject.rawValue
        case .User: 
            return ObjectType.User.rawValue
        case .Annotation: 
            return ObjectType.Annotation.rawValue
        case .Task: 
            return ObjectType.Task.rawValue
        case .IoSource: 
            return ObjectType.IoSource.rawValue
        case .IoActor: 
            return ObjectType.IoActor.rawValue
        case .IoNode: 
            return ObjectType.IoNode.rawValue
        case .IoContext: 
            return ObjectType.IoContext.rawValue
        case .Identity: 
            return ObjectType.Identity.rawValue
        case .Log: 
            return ObjectType.Log.rawValue
        case .Location: 
            return ObjectType.Location.rawValue
        case .Snapshot: 
            return ObjectType.Snapshot.rawValue
}
    }
    
    // MARK: - Codable methods.
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawString = try container.decode(String.self)
        
        // Try to parse the raw value to the actual enum.
        guard let coreType = CoreType(rawValue: rawString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Attempt to decode invalid CoreType."))
        }
        
        self = coreType
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}
