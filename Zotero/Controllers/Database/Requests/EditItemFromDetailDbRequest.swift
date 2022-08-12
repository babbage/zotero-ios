//
//  EditItemDetailDbRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 25/03/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import CocoaLumberjackSwift
import RealmSwift

struct EditItemFromDetailDbRequest: DbRequest {
    var needsWrite: Bool { return true }
    var ignoreNotificationTokens: [NotificationToken]? { return nil }

    let libraryId: LibraryIdentifier
    let itemKey: String
    let data: ItemDetailState.Data
    let snapshot: ItemDetailState.Data
    let schemaController: SchemaController
    let dateParser: DateParser

    func process(in database: Realm) throws {
        guard let item = database.objects(RItem.self).filter(.key(self.itemKey, in: self.libraryId)).first else { return }

        let typeChanged = self.data.type != item.rawType
        if typeChanged {
            item.rawType = self.data.type
            item.changedFields.insert(.type)
        }
        item.dateModified = self.data.dateModified

        self.updateCreators(with: self.data, snapshot: self.snapshot, item: item, database: database)
        self.updateFields(with: self.data, snapshot: self.snapshot, item: item, typeChanged: typeChanged, database: database)

        // Item title depends on item type, creators and fields, so we update derived titles (displayTitle and sortTitle) after everything else synced
        item.updateDerivedTitles()
        item.changeType = .user
    }

    private func updateCreators(with data: ItemDetailState.Data, snapshot: ItemDetailState.Data, item: RItem, database: Realm) {
        guard data.creatorIds != snapshot.creatorIds else { return }

        database.delete(item.creators)

        for (offset, creatorId) in data.creatorIds.enumerated() {
            guard let creator = data.creators[creatorId] else { continue }

            let rCreator = RCreator()
            rCreator.rawType = creator.type
            rCreator.orderId = offset
            rCreator.primary = creator.primary

            switch creator.namePresentation {
            case .full:
                rCreator.name = creator.fullName
                rCreator.firstName = ""
                rCreator.lastName = ""
            case .separate:
                rCreator.name = ""
                rCreator.firstName = creator.firstName
                rCreator.lastName = creator.lastName
            }

            item.creators.append(rCreator)
        }

        item.updateCreatorSummary()
        item.changedFields.insert(.creators)
    }

    private func updateFields(with data: ItemDetailState.Data, snapshot: ItemDetailState.Data,
                              item: RItem, typeChanged: Bool, database: Realm) {
        let allFields = self.data.databaseFields(schemaController: self.schemaController)
        let snapshotFields = self.snapshot.databaseFields(schemaController: self.schemaController)

        var fieldsDidChange = false

        if typeChanged {
            // If type changed, we need to sync all fields, since different types can have different fields
            let fieldKeys = allFields.map({ $0.key })
            let toRemove = item.fields.filter(.key(notIn: fieldKeys))

            toRemove.forEach { field in
                if field.key == FieldKeys.Item.date {
                    item.setDateFieldMetadata(nil, parser: self.dateParser)
                } else if field.key == FieldKeys.Item.publisher || field.baseKey == FieldKeys.Item.publisher {
                    item.set(publisher: nil)
                } else if field.key == FieldKeys.Item.publicationTitle || field.baseKey == FieldKeys.Item.publicationTitle {
                    item.set(publicationTitle: nil)
                }
            }

            database.delete(toRemove)

            fieldsDidChange = !toRemove.isEmpty
        }

        for (offset, field) in allFields.enumerated() {
            // Either type changed and we're updating all fields (so that we create missing fields for this new type)
            // or type didn't change and we're updating only changed fields
            guard typeChanged || (field.value != snapshotFields[offset].value) else { continue }

            var fieldToChange: RItemField?

            if let existing = item.fields.filter(.key(field.key)).first {
                fieldToChange = (field.value != existing.value) ? existing : nil
            } else {
                let rField = RItemField()
                rField.key = field.key
                rField.baseKey = field.baseField
                item.fields.append(rField)
                fieldToChange = rField
            }

            if let rField = fieldToChange {
                rField.value = field.value
                rField.changed = true

                if field.isTitle {
                    item.baseTitle = field.value
                } else if field.key == FieldKeys.Item.date {
                    item.setDateFieldMetadata(field.value, parser: self.dateParser)
                } else if field.key == FieldKeys.Item.publisher || field.baseField == FieldKeys.Item.publisher {
                    item.set(publisher: field.value)
                } else if field.key == FieldKeys.Item.publicationTitle || field.baseField == FieldKeys.Item.publicationTitle {
                    item.set(publicationTitle: field.value)
                }

                fieldsDidChange = true
            }
        }

        if fieldsDidChange {
            item.changedFields.insert(.fields)
        }
    }
}
