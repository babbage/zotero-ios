//
//  CreateAnnotationsDbRequest.swift
//  Zotero
//
//  Created by Michal Rentka on 31.08.2022.
//  Copyright © 2022 Corporation for Digital Scholarship. All rights reserved.
//

#if PDFENABLED

import UIKit

import RealmSwift

struct CreateAnnotationsDbRequest: DbRequest {
    let attachmentKey: String
    let libraryId: LibraryIdentifier
    let annotations: [DocumentAnnotation]
    let userId: Int

    unowned let schemaController: SchemaController
    unowned let boundingBoxConverter: AnnotationBoundingBoxConverter

    var needsWrite: Bool { return true }

    func process(in database: Realm) throws {
        guard let parent = database.objects(RItem.self).filter(.key(self.attachmentKey, in: self.libraryId)).first else { return }

        for annotation in self.annotations {
            self.create(annotation: annotation, parent: parent, in: database)
        }
    }

    private func create(annotation: DocumentAnnotation, parent: RItem, in database: Realm) {
        let item: RItem

        if let _item = database.objects(RItem.self).filter(.key(annotation.key, in: self.libraryId)).first {
            if !_item.deleted {
                // If item exists and is not deleted locally, we can ignore this request
                return
            }

            // If item exists and was already deleted locally and not yet synced, we re-add the item
            item = _item
            item.deleted = false
        } else {
            // If item didn't exist, create it
            item = RItem()
            item.key = annotation.key
            item.rawType = ItemTypes.annotation
            item.localizedType = self.schemaController.localized(itemType: ItemTypes.annotation) ?? ""
            item.libraryId = self.libraryId
            item.dateAdded = annotation.dateModified
            database.add(item)
        }

        item.syncState = .synced
        item.changeType = .user
        item.dateModified = annotation.dateModified
        item.parent = parent

        if annotation.isAuthor {
            item.createdBy = database.object(ofType: RUser.self, forPrimaryKey: self.userId)
        }

        // We need to submit tags on creation even if they are empty, so we need to mark them as changed
        var changes: RItemChanges = [.parent, .fields, .type, .tags]
        self.addFields(for: annotation, to: item, database: database)
        self.add(rects: annotation.rects, to: item, changes: &changes, database: database)
        self.add(paths: annotation.paths, to: item, changes: &changes, database: database)
        item.changes.append(RObjectChange.create(changes: changes))
    }

    private func addFields(for annotation: Annotation, to item: RItem, database: Realm) {
        for field in FieldKeys.Item.Annotation.fields(for: annotation.type) {
            let rField = RItemField()
            rField.key = field.key
            rField.baseKey = field.baseKey
            rField.changed = true

            switch field.key {
            case FieldKeys.Item.Annotation.type:
                rField.value = annotation.type.rawValue
            case FieldKeys.Item.Annotation.color:
                rField.value = annotation.color
            case FieldKeys.Item.Annotation.comment:
                rField.value = annotation.comment
            case FieldKeys.Item.Annotation.Position.pageIndex where field.baseKey == FieldKeys.Item.Annotation.position:
                rField.value = "\(annotation.page)"
            case FieldKeys.Item.Annotation.Position.lineWidth where field.baseKey == FieldKeys.Item.Annotation.position:
                rField.value = annotation.lineWidth.flatMap({ "\(Decimal($0).rounded(to: 3))" }) ?? ""
            case FieldKeys.Item.Annotation.pageLabel:
                rField.value = annotation.pageLabel
            case FieldKeys.Item.Annotation.sortIndex:
                rField.value = annotation.sortIndex
                item.annotationSortIndex = annotation.sortIndex
            case FieldKeys.Item.Annotation.text:
                rField.value = annotation.text ?? ""
            default: break
            }

            item.fields.append(rField)
        }
    }

    private func add(rects: [CGRect], to item: RItem, changes: inout RItemChanges, database: Realm) {
        guard !rects.isEmpty else { return }

        let page = UInt(DatabaseAnnotation(item: item).page)

        for rect in rects {
            let dbRect = self.boundingBoxConverter.convertToDb(rect: rect, page: page) ?? rect
            
            let rRect = RRect()
            rRect.minX = Double(dbRect.minX)
            rRect.minY = Double(dbRect.minY)
            rRect.maxX = Double(dbRect.maxX)
            rRect.maxY = Double(dbRect.maxY)
            item.rects.append(rRect)
        }
        changes.insert(.rects)
    }

    private func add(paths: [[CGPoint]], to item: RItem, changes: inout RItemChanges, database: Realm) {
        guard !paths.isEmpty else { return }

        let page = UInt(DatabaseAnnotation(item: item).page)

        for (idx, path) in paths.enumerated() {
            let rPath = RPath()
            rPath.sortIndex = idx

            for (idy, point) in path.enumerated() {
                let dbPoint = self.boundingBoxConverter.convertToDb(point: point, page: page) ?? point

                let rXCoordinate = RPathCoordinate()
                rXCoordinate.value = Double(dbPoint.x)
                rXCoordinate.sortIndex = idy * 2
                rPath.coordinates.append(rXCoordinate)

                let rYCoordinate = RPathCoordinate()
                rYCoordinate.value = Double(dbPoint.y)
                rYCoordinate.sortIndex = (idy * 2) + 1
                rPath.coordinates.append(rYCoordinate)
            }

            item.paths.append(rPath)
        }

        changes.insert(.paths)
    }
}

#endif
