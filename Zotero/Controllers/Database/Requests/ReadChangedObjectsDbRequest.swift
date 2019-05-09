//
//  ReadChangedObjectsDbRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 14/03/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import RealmSwift

struct ReadChangedObjectsDbRequest<Obj: UpdatableObject>: DbResponseRequest {
    typealias Response = Results<Obj>

    var needsWrite: Bool {
        return false
    }

    func process(in database: Realm) throws -> Results<Obj> {
        return database.objects(Obj.self).filter("rawChangedFields > 0 OR deleted = true")
    }
}
