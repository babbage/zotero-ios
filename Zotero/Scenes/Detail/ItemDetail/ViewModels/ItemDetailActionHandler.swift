//
//  ItemDetailActionHandler.swift
//  Zotero
//
//  Created by Michal Rentka on 19/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

import Alamofire
import CocoaLumberjackSwift
import RealmSwift
import RxSwift
import ZIPFoundation

struct ItemDetailActionHandler: ViewModelActionHandler {
    typealias State = ItemDetailState
    typealias Action = ItemDetailAction

    private unowned let apiClient: ApiClient
    private unowned let fileStorage: FileStorage
    private unowned let dbStorage: DbStorage
    private unowned let schemaController: SchemaController
    private unowned let dateParser: DateParser
    private unowned let urlDetector: UrlDetector
    private unowned let fileDownloader: FileDownloader
    private let backgroundScheduler: SerialDispatchQueueScheduler
    private let disposeBag: DisposeBag

    init(apiClient: ApiClient, fileStorage: FileStorage, dbStorage: DbStorage, schemaController: SchemaController,
         dateParser: DateParser, urlDetector: UrlDetector, fileDownloader: FileDownloader) {
        self.apiClient = apiClient
        self.fileStorage = fileStorage
        self.dbStorage = dbStorage
        self.schemaController = schemaController
        self.dateParser = dateParser
        self.urlDetector = urlDetector
        self.fileDownloader = fileDownloader
        self.backgroundScheduler = SerialDispatchQueueScheduler(qos: .userInitiated, internalSerialQueueName: "org.zotero.ItemDetailActionHandler.background")
        self.disposeBag = DisposeBag()
    }

    func process(action: ItemDetailAction, in viewModel: ViewModel<ItemDetailActionHandler>) {
        switch action {
        case .reloadData:
            self.reloadData(in: viewModel)

        case .changeType(let type):
            self.changeType(to: type, in: viewModel)

        case .acceptPrompt:
            self.acceptPrompt(in: viewModel)

        case .cancelPrompt:
            self.update(viewModel: viewModel) { state in
                state.promptSnapshot = nil
            }

        case .addAttachments(let urls):
            self.addAttachments(from: urls, in: viewModel)

        case .deleteAttachments(let offsets):
            self.update(viewModel: viewModel) { state in
                state.data.deletedAttachments = state.data.deletedAttachments.union(offsets.map({ state.data.attachments[$0].key }))
                state.data.attachments.remove(atOffsets: offsets)
                state.diff = .attachments(insertions: [], deletions: Array(offsets), reloads: [])
            }

        case .openAttachment(let index):
            self.openAttachment(at: index, in: viewModel)

        case .saveCreator(let creator):
            self.save(creator: creator, in: viewModel)

        case .deleteCreators(let offsets):
            self.deleteCreators(at: offsets, in: viewModel)

        case .deleteCreator(let id):
            self.deleteCreator(with: id, in: viewModel)

        case .moveCreators(let from, let to):
            self.update(viewModel: viewModel) { state in
                state.data.creatorIds.move(fromOffsets: from, toOffset: to)
            }

        case .deleteNotes(let offsets):
            self.update(viewModel: viewModel) { state in
                state.data.deletedNotes = state.data.deletedNotes.union(offsets.map({ state.data.notes[$0].key }))
                state.data.notes.remove(atOffsets: offsets)
                state.diff = .notes(insertions: [], deletions: Array(offsets), reloads: [])
            }

        case .saveNote(let key, let text):
            self.saveNote(key: key, text: text, in: viewModel)

        case .setTags(let tags):
            self.set(tags: tags, in: viewModel)

        case .deleteTags(let offsets):
            self.update(viewModel: viewModel) { state in
                state.data.deletedTags = state.data.deletedTags.union(offsets.map({ state.data.tags[$0].name }))
                state.data.tags.remove(atOffsets: offsets)
                state.diff = .tags(insertions: [], deletions: Array(offsets), reloads: [])
            }

        case .startEditing:
            self.startEditing(in: viewModel)

        case .cancelEditing:
            self.cancelChanges(in: viewModel)

        case .save:
            self.saveChanges(in: viewModel)

        case .setTitle(let title):
            self.update(viewModel: viewModel) { state in
                state.data.title = title
            }

        case .setAbstract(let abstract):
            self.update(viewModel: viewModel) { state in
                state.data.abstract = abstract
            }

        case .setFieldValue(let id, let value):
            self.setField(value: value, for: id, in: viewModel)

        case .updateDownload(let update):
            self.process(downloadUpdate: update, in: viewModel)

        case .updateAttachments(let notification):
            self.updateDeletedAttachments(notification, in: viewModel)

        case .deleteAttachmentFile(let attachment):
            self.deleteFile(of: attachment, in: viewModel)

        case .toggleAbstractDetailCollapsed:
            self.update(viewModel: viewModel) { state in
                state.abstractCollapsed = !state.abstractCollapsed
                state.changes = [.abstractCollapsed]
            }

        case .trashAttachment(let attachment):
            self.trash(attachment: attachment, in: viewModel)
        }
    }

    private func reloadData(in viewModel: ViewModel<ItemDetailActionHandler>) {
        do {
            let type: ItemDetailDataCreator.Kind
            var token: NotificationToken?

            switch viewModel.state.type {
            case .creation(_, let itemType):
                type = .new(itemType: itemType)
            case .preview(let key):
                let item = try self.dbStorage.createCoordinator().perform(request: ReadItemDbRequest(libraryId: viewModel.state.library.identifier, key: key))
                token = item.observe({ [weak viewModel] change in
                    guard let viewModel = viewModel else { return }
                    self.itemChanged(change, in: viewModel)
                })
                type = .existing(item)
            case .duplication(let itemKey, _):
                let item = try dbStorage.createCoordinator().perform(request: ReadItemDbRequest(libraryId: viewModel.state.library.identifier, key: itemKey))
                type = .existing(item)
            }

            var (data, attachmentErrors) = try ItemDetailDataCreator.createData(from: type,
                                                                                schemaController: self.schemaController,
                                                                                dateParser: self.dateParser,
                                                                                fileStorage: self.fileStorage,
                                                                                urlDetector: self.urlDetector,
                                                                                doiDetector: FieldKeys.Item.isDoi)
            if !viewModel.state.isEditing {
                data.fieldIds = ItemDetailDataCreator.filteredFieldKeys(from: data.fieldIds, fields: data.fields)
            }

            self.update(viewModel: viewModel) { state in
                state.data = data
                if state.snapshot != nil {
                    state.snapshot = data
                    state.snapshot?.fieldIds = ItemDetailDataCreator.filteredFieldKeys(from: data.fieldIds, fields: data.fields)
                }
                state.attachmentErrors = attachmentErrors
                state.isLoadingData = false
                state.observationToken = token
                state.changes.insert(.reloadedData)
            }
        } catch let error {
            DDLogError("ItemDetailActionHandler: can't load data - \(error)")
            self.update(viewModel: viewModel) { state in
                state.error = .cantCreateData
            }
        }
    }

    private func itemChanged(_ change: ObjectChange<Object>, in viewModel: ViewModel<ItemDetailActionHandler>) {
        switch change {
        case .change(_, let changes):
            guard self.shouldReloadData(for: changes) else { return }
            self.update(viewModel: viewModel) { state in
                state.changes = .item
            }

        // Deletion is handled by sync process, so we don't need to kick the user out here (the sync should always ask whether the user wants to delete the item or not).
        case .deleted, .error: break
        }
    }

    private func shouldReloadData(for changes: [PropertyChange]) -> Bool {
        guard let change = changes.first(where: { $0.name == "rawChangeType" }), let newValue = change.newValue as? Int, let type = UpdatableChangeType(rawValue: newValue) else { return true }

        switch type {
        case .user:
            // This change was made by user, ignore
            return false
        case .sync:
            // This change was made by sync. Check whether it was just marking the object as synced or an actual change. When marking as synced, these attributed are updated:
            // `version`, `rawChangeType` and `rawChangedFields`.
            if changes.count != 3 {
                return true
            }
            let changes = Set(changes.map({ $0.name }))
            return !changes.contains("version") || !changes.contains("rawChangedFields") || !changes.contains("rawChangeType")
        }
    }

    // MARK: - Type

    private func changeType(to newType: String, in viewModel: ViewModel<ItemDetailActionHandler>) {
        let data: ItemDetailState.Data
        do {
            data = try self.data(for: newType, from: viewModel.state.data)
        } catch let error {
            self.update(viewModel: viewModel) { state in
                state.error = (error as? ItemDetailError) ?? .typeNotSupported
            }
            return
        }

        let droppedFields = self.droppedFields(from: viewModel.state.data, to: data)
        self.update(viewModel: viewModel) { state in
            if droppedFields.isEmpty {
                state.data = data
                state.changes.insert(.type)
            } else {
                // Notify the user, that some fields with values will be dropped
                state.promptSnapshot = data
                state.error = .droppedFields(droppedFields)
            }
        }
    }

    private func droppedFields(from fromData: ItemDetailState.Data, to toData: ItemDetailState.Data) -> [String] {
        let newFields = Set(toData.fields.values)
        var subtracted = Set(fromData.fields.values.filter({ !$0.value.isEmpty }))
        for field in newFields {
            guard let oldField = subtracted.first(where: { ($0.baseField ?? $0.name) == (field.baseField ?? field.name) }) else { continue }
            subtracted.remove(oldField)
        }
        return subtracted.map({ $0.name }).sorted()
    }

    private func data(for type: String, from originalData: ItemDetailState.Data) throws -> ItemDetailState.Data {
        guard let localizedType = self.schemaController.localized(itemType: type) else {
            throw ItemDetailError.typeNotSupported
        }

        let (fieldIds, fields, hasAbstract) = try ItemDetailDataCreator.fieldData(for: type,
                                                                                  schemaController: self.schemaController,
                                                                                  dateParser: self.dateParser,
                                                                                  urlDetector: self.urlDetector,
                                                                                  doiDetector: FieldKeys.Item.isDoi,
                                                                                  getExistingData: { key, baseField -> (String?, String?) in
            if let field = originalData.fields[key] {
                return (field.name, field.value)
            } else if let base = baseField, let field = originalData.fields.values.first(where: { $0.baseField == base }) {
                // We don't return existing name, because fields that are matching just by baseField will most likely have different names
                return (nil, field.value)
            }
            return (nil, nil)
        })

        var data = originalData
        data.type = type
        data.isAttachment = type == ItemTypes.attachment
        data.localizedType = localizedType
        data.fields = fields
        data.fieldIds = fieldIds
        data.abstract = hasAbstract ? (originalData.abstract ?? "") : nil
        data.creators = try self.creators(for: type, from: originalData.creators)
        data.creatorIds = originalData.creatorIds
        return data
    }

    private func creators(for type: String, from originalData: [UUID: ItemDetailState.Creator]) throws -> [UUID: ItemDetailState.Creator] {
        guard let schemas = self.schemaController.creators(for: type),
              let primary = schemas.first(where: { $0.primary }) else { throw ItemDetailError.typeNotSupported }

        var creators = originalData
        for (key, originalCreator) in originalData {
            guard !schemas.contains(where: { $0.creatorType == originalCreator.type }) else { continue }

            var creator = originalCreator

            if originalCreator.primary {
                creator.type = primary.creatorType
            } else {
                creator.type = "contributor"
            }
            creator.localizedType = self.schemaController.localized(creator: creator.type) ?? ""

            creators[key] = creator
        }

        return creators
    }

    private func acceptPrompt(in viewModel: ViewModel<ItemDetailActionHandler>) {
        self.update(viewModel: viewModel) { state in
            guard let snapshot = state.promptSnapshot else { return }
            state.data = snapshot
            state.changes.insert(.type)
            state.promptSnapshot = nil
        }
    }

    // MARK: - Creators

    private func deleteCreators(at offsets: IndexSet, in viewModel: ViewModel<ItemDetailActionHandler>) {
        let keys = offsets.map({ viewModel.state.data.creatorIds[$0] })
        self.update(viewModel: viewModel) { state in
            state.data.creatorIds.remove(atOffsets: offsets)
            keys.forEach({ state.data.creators[$0] = nil })
            state.diff = .creators(insertions: [], deletions: Array(offsets), reloads: [])
        }
    }

    private func deleteCreator(with id: UUID, in viewModel: ViewModel<ItemDetailActionHandler>) {
        guard let index = viewModel.state.data.creatorIds.firstIndex(of: id) else { return }
        self.update(viewModel: viewModel) { state in
            state.data.creatorIds.remove(at: index)
            state.data.creators[id] = nil
            state.diff = .creators(insertions: [], deletions: [index], reloads: [])
        }
    }

    private func save(creator: State.Creator, in viewModel: ViewModel<ItemDetailActionHandler>) {
        self.update(viewModel: viewModel) { state in
            if let index = state.data.creatorIds.firstIndex(of: creator.id) {
                state.diff = .creators(insertions: [], deletions: [], reloads: [index])
            } else {
                state.diff = .creators(insertions: [state.data.creatorIds.count], deletions: [], reloads: [])
                state.data.creatorIds.append(creator.id)
            }
            state.data.creators[creator.id] = creator
        }
    }

    // MARK: - Notes

    private func saveNote(key: String?, text: String, in viewModel: ViewModel<ItemDetailActionHandler>) {
        self.update(viewModel: viewModel) { state in
            var note = key.flatMap({ key in state.data.notes.first(where: { $0.key == key }) }) ?? Note(key: KeyGenerator.newKey, text: "")
            note.text = text
            note.title = text.notePreview ?? ""

            if !state.isEditing {
                // Note was edited outside of editing mode, so it needs to be saved immediately
                do {
                    try self.saveNoteChanges(note, libraryId: state.library.identifier)
                } catch let error {
                    DDLogError("ItemDetailStore: can't store note - \(error)")
                    state.error = .cantStoreChanges
                    return
                }
            }

            if let index = state.data.notes.firstIndex(where: { $0.key == note.key }) {
                state.data.notes[index] = note
                state.diff = .notes(insertions: [], deletions: [], reloads: [index])
            } else {
                state.diff = .notes(insertions: [state.data.notes.count], deletions: [], reloads: [])
                state.data.notes.append(note)
            }
        }
    }

    private func saveNoteChanges(_ note: Note, libraryId: LibraryIdentifier) throws {
        let request = EditNoteDbRequest(note: note, libraryId: libraryId)
        try self.dbStorage.createCoordinator().perform(request: request)
    }

    // MARK: - Tags

    private func set(tags: [Tag], in viewModel: ViewModel<ItemDetailActionHandler>) {
        self.update(viewModel: viewModel) { state in
            let diff = tags.difference(from: state.data.tags).separated
            state.data.tags = tags
            state.diff = .tags(insertions: diff.insertions, deletions: diff.deletions, reloads: [])
        }
    }

    // MARK: - Attachments

    private func trash(attachment: Attachment, in viewModel: ViewModel<ItemDetailActionHandler>) {
        guard let index = viewModel.state.data.attachments.firstIndex(of: attachment) else { return }

        do {
            try self.dbStorage.createCoordinator().perform(request: MarkItemsAsTrashedDbRequest(keys: [attachment.key], libraryId: viewModel.state.library.identifier, trashed: true))

            self.update(viewModel: viewModel) { state in
                state.data.attachments.remove(at: index)
                state.diff = .attachments(insertions: [], deletions: [index], reloads: [])
            }
        } catch let error {
            DDLogError("ItemDetailActionHandler: can't trash attachment - \(error)")
            self.update(viewModel: viewModel) { state in
                state.error = .cantTrashAttachment
            }
        }
    }

    private func deleteFile(of attachment: Attachment, in viewModel: ViewModel<ItemDetailActionHandler>) {
        let key: String

        switch viewModel.state.type {
        case .preview(let _key):
            key = _key
        case .duplication, .creation: return
        }

        do {
            switch attachment.contentType {
            case .file(let file, _, _, let linkType):
                // Don't try to delete linked files
                guard linkType != .linked else { return }
                try self.fileStorage.remove(file)
                // Don't remove annotation container here. Annotations might still be syncing and it would lead to sync errors.
            case .snapshot(let htmlFile, _, let zipFile, _):
                // Remove downloaded zip
                try self.fileStorage.remove(zipFile)
                // Remove unzipped html directory
                try self.fileStorage.remove(htmlFile.directory)
            case .url: return
            }
            
            let deletionType = AttachmentFileDeletedNotification.individual(key: attachment.key,
                                                                            parentKey: key,
                                                                            libraryId: attachment.libraryId)
            NotificationCenter.default.post(name: .attachmentFileDeleted, object: deletionType)
        } catch let error {
            DDLogError("ItemDetailActionHandler: can't remove attachment file - \(error)")
            // TODO: - Show error to user
        }
    }

    private func updateDeletedAttachments(_ notification: AttachmentFileDeletedNotification, in viewModel: ViewModel<ItemDetailActionHandler>) {
        self.update(viewModel: viewModel) { state in
            // Set all affected attachments to remote. Since everything is cached here and the original `RItem` is not available, let's assume
            // that once downloaded attachment is still available remotely. In the worst case, it was deleted in the meanwhile. The only fallback is
            // that the user tries to download again without leaving the screen and will get an error message.
            switch notification {
            case .all:
                for (index, attachment) in state.data.attachments.enumerated() {
                    state.data.attachments[index] = attachment.changed(location: .remote)
                }
                state.changes = .attachmentFilesRemoved
            case .library(let libraryId):
                if libraryId == state.library.identifier {
                    for (index, attachment) in state.data.attachments.enumerated() {
                        state.data.attachments[index] = attachment.changed(location: .remote)
                    }
                    state.changes = .attachmentFilesRemoved
                }
            case .individual(let key, _, let libraryId):
                if let index = state.data.attachments.firstIndex(where: { $0.key == key && $0.libraryId == libraryId }) {
                    state.data.attachments[index] = state.data.attachments[index].changed(location: .remote)
                    state.updateAttachmentIndex = index
                }
            }
        }
    }

    private func process(downloadUpdate update: FileDownloader.Update, in viewModel: ViewModel<ItemDetailActionHandler>) {
        guard viewModel.state.library.identifier == update.libraryId,
              let index = viewModel.state.data.attachments.firstIndex(where: { $0.key == update.key }) else { return }

        let attachment = viewModel.state.data.attachments[index]

        if !update.kind.isDownloaded {
            self.update(viewModel: viewModel) { state in
                state.updateAttachmentIndex = index
                if case .failed(let error) = update.kind {
                    state.attachmentErrors[attachment.key] = error
                }
            }
            return
        }

        if case .snapshot(let htmlFile, _, let zipFile, _) = attachment.contentType {
            // If snapshot was downloaded, unzip it
            self.processSnapshot(from: zipFile, to: htmlFile)
                .subscribeOn(self.backgroundScheduler)
                .observeOn(MainScheduler.instance)
                .subscribe(onCompleted: { [weak viewModel] in
                    guard let viewModel = viewModel,
                          let index = viewModel.state.data.attachments.firstIndex(where: { $0.key == update.key }) else { return }
                    self.finishDownload(at: index, in: viewModel)
                }, onError: { [weak viewModel] error in
                    guard let viewModel = viewModel,
                          let index = viewModel.state.data.attachments.firstIndex(where: { $0.key == update.key }) else { return }
                    self.finishFailedDownload(error: error, at: index, in: viewModel)
                })
                .disposed(by: self.disposeBag)
            return
        }

        self.finishDownload(at: index, in: viewModel)
    }

    private func processSnapshot(from zipFile: File, to htmlFile: File) -> Completable {
        return Completable.create { observer -> Disposable in
            let zipUrl = zipFile.createUrl()
            let directory = htmlFile.directory
            let directoryUrl = directory.createUrl()

            DDLogInfo("ItemDetailActionHandler: will process downloaded snapshot")

            do {
                try self.fileStorage.createDirectories(for: directory)

                if self.fileStorage.isZip(file: zipFile) {
                    DDLogInfo("ItemDetailActionHandler: snapshot is zip")
                    try FileManager.default.unzipItem(at: zipUrl, to: directoryUrl)
                } else {
                    DDLogInfo("ItemDetailActionHandler: snapshot is html")
                    try self.fileStorage.move(from: zipFile, to: htmlFile)
                }

                DDLogInfo("ItemDetailActionHandler: did process downloaded snapshot")

                observer(.completed)
            } catch let error {
                DDLogError("ItemDetailActionHandler: error extracting file - \(error)")
                observer(.error(ItemDetailError.cantUnzipSnapshot))
            }
            return Disposables.create()
        }
    }

    private func finishDownload(at index: Int, in viewModel: ViewModel<ItemDetailActionHandler>) {
        var attachment = viewModel.state.data.attachments[index]
        if attachment.contentType.fileLocation == .remote {
            attachment = attachment.changed(location: .local)
        }
        self.update(viewModel: viewModel) { state in
            state.data.attachments[index] = attachment
            state.openAttachment = (attachment, index)
            state.updateAttachmentIndex = index
        }
    }

    private func finishFailedDownload(error: Error, at index: Int, in viewModel: ViewModel<ItemDetailActionHandler>) {
        let attachment = viewModel.state.data.attachments[index]
        self.update(viewModel: viewModel) { state in
            state.updateAttachmentIndex = index
            state.attachmentErrors[attachment.key] = error
        }
    }

    private func addAttachments(from urls: [URL], in viewModel: ViewModel<ItemDetailActionHandler>) {
        var attachments: [Attachment] = []
        var errors = 0

        for url in urls {
            let originalFile = Files.file(from: url)
            let nameWithExtension = originalFile.name + "." + originalFile.ext
            let key = KeyGenerator.newKey
            let file = Files.attachmentFile(in: viewModel.state.library.identifier, key: key, ext: originalFile.ext)
            let attachment = Attachment(key: key,
                                        title: nameWithExtension,
                                        type: .file(file: file, filename: nameWithExtension, location: .local, linkType: .imported),
                                        libraryId: viewModel.state.library.identifier)

            do {
                try self.fileStorage.move(from: originalFile, to: file)
                attachments.append(attachment)
            } catch let error {
                DDLogError("ItemDertailStore: can't copy attachment - \(error)")
                errors += 1
            }
        }

        if !attachments.isEmpty {
            self.update(viewModel: viewModel) { state in
                var insertions: [Int] = []
                attachments.forEach { attachment in
                    let index = state.data.attachments.index(of: attachment, sortedBy: { $0.title.caseInsensitiveCompare($1.title) == .orderedAscending })
                    state.data.attachments.insert(attachment, at: index)
                    insertions.append(index)
                }
                state.diff = .attachments(insertions: insertions, deletions: [], reloads: [])
                if errors > 0 {
                    state.error = .fileNotCopied(errors)
                }
            }
        } else if errors > 0 {
            self.update(viewModel: viewModel) { state in
                state.error = .fileNotCopied(errors)
            }
        }
    }

    private func openAttachment(at index: Int, in viewModel: ViewModel<ItemDetailActionHandler>) {
        guard index < viewModel.state.data.attachments.count else { return }

        let attachment = viewModel.state.data.attachments[index]
        switch attachment.contentType {
        case .url:
            self.update(viewModel: viewModel) { state in
                state.openAttachment = (attachment, index)
            }

        case .file(let file, _, let location, let linkType):
            guard let location = location else { return }
            switch linkType {
            case .imported:
                self.open(file: file, location: location, attachment: attachment, index: index, in: viewModel)
            case .linked, .embeddedImage: break // Dont open linked attachments
            }
        case .snapshot(_, _, let file, let location):
            guard let location = location else { return }
            self.open(file: file, location: location, attachment: attachment, index: index, in: viewModel)
        }
    }

    private func open(file: File, location: Attachment.FileLocation, attachment: Attachment, index: Int, in viewModel: ViewModel<ItemDetailActionHandler>) {
        switch location {
        case .remote:
            // Item creation or duplication shouldn't have a .remote location, limit this to preview only
            guard let previewKey = viewModel.state.type.previewKey else { return }

            let (progress, _) = self.fileDownloader.data(for: attachment.key, libraryId: attachment.libraryId)
            if progress != nil {
                self.fileDownloader.cancel(key: attachment.key, libraryId: attachment.libraryId)
            } else {
                self.fileDownloader.download(file: file, key: attachment.key, parentKey: previewKey, libraryId: attachment.libraryId)
            }

        case .local:
            self.update(viewModel: viewModel) { state in
                state.openAttachment = (attachment, index)
            }
        }
    }

    // MARK: - Editing

    private func startEditing(in viewModel: ViewModel<ItemDetailActionHandler>) {
        self.update(viewModel: viewModel) { state in
            state.snapshot = state.data
            state.data.fieldIds = ItemDetailDataCreator.allFieldKeys(for: state.data.type, schemaController: self.schemaController)
            state.isEditing = true
            state.changes.insert(.editing)
        }
    }

    private func cancelChanges(in viewModel: ViewModel<ItemDetailActionHandler>) {
        guard let snapshot = viewModel.state.snapshot else { return }
        self.update(viewModel: viewModel) { state in
            state.data = snapshot
            state.snapshot = nil
            state.isEditing = false
            state.changes.insert(.editing)
        }
    }

    private func saveChanges(in viewModel: ViewModel<ItemDetailActionHandler>) {
        if viewModel.state.snapshot != viewModel.state.data {
            self._saveChanges(in: viewModel)
        }
    }

    private func _saveChanges(in viewModel: ViewModel<ItemDetailActionHandler>) {
        self.update(viewModel: viewModel) { state in
            state.isSaving = true
        }

        self.save(state: viewModel.state)
            .subscribeOn(self.backgroundScheduler)
            .observeOn(MainScheduler.instance)
            .subscribe(onSuccess: { [weak viewModel] newState in
                guard let viewModel = viewModel else { return }
                self.update(viewModel: viewModel) { state in
                    state = newState
                    state.isSaving = false
                }
            }, onError: { [weak viewModel] error in
                DDLogError("ItemDetailStore: can't store changes - \(error)")
                guard let viewModel = viewModel else { return }
                self.update(viewModel: viewModel) { state in
                    state.error = (error as? ItemDetailError) ?? .cantStoreChanges
                    state.isSaving = false
                }
            })
            .disposed(by: self.disposeBag)
    }

    private func save(state: ItemDetailState) -> Single<ItemDetailState> {
        // Preview key has to be assigned here, because the `Single` below can be subscribed on background thread (and currently is),
        // in which case the app will crash, because RItem in preview has been loaded on main thread.
        let previewKey = state.type.previewKey
        return Single.create { subscriber -> Disposable in
            do {
                try self.fileStorage.copyAttachmentFilesIfNeeded(for: state.data.attachments)

                var newState = state
                var newType = state.type

                self.updateDateFieldIfNeeded(in: &newState)
                newState.data.dateModified = Date()

                switch state.type {
                case .preview:
                    if let snapshot = state.snapshot, let key = previewKey {
                        try self.updateItem(key: key, libraryId: state.library.identifier, data: newState.data, snapshot: snapshot)
                    }

                case .creation(let collectionKey, _), .duplication(_, let collectionKey):
                    let item = try self.createItem(with: state.library.identifier, collectionKey: collectionKey, data: newState.data)
                    newType = .preview(key: item.key)
                }

                newState.snapshot = nil
                newState.type = newType
                newState.data.fieldIds = ItemDetailDataCreator.filteredFieldKeys(from: newState.data.fieldIds, fields: newState.data.fields)
                newState.data.deletedNotes = []
                newState.data.deletedTags = []
                newState.data.deletedAttachments = []
                newState.isEditing = false
                newState.changes.insert(.editing)

                subscriber(.success(newState))
            } catch let error {
                subscriber(.error(error))
            }
            return Disposables.create()
        }
    }

    private func updateDateFieldIfNeeded(in state: inout State) {
        guard var field = state.data.fields.values.first(where: { $0.baseField == FieldKeys.Item.date || $0.key == FieldKeys.Item.date }) else { return }

        let date: Date?

        // TODO: - check for current localization
        switch field.value.lowercased() {
        case "tomorrow":
            date = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        case "today":
            date = Date()
        case "yesterday":
            date = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        default:
            date = nil
        }

        if let date = date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"

            field.value = formatter.string(from: date)
            if let order = self.dateParser.parse(string: field.value)?.orderWithSpaces {
                field.additionalInfo?[.dateOrder] = order
            }
            state.data.fields[field.key] = field
        }
    }

    private func setField(value: String, for id: String, in viewModel: ViewModel<ItemDetailActionHandler>) {
        guard var field = viewModel.state.data.fields[id] else { return }

        field.value = value
        field.isTappable = ItemDetailDataCreator.isTappable(key: field.key, value: field.value, urlDetector: self.urlDetector, doiDetector: FieldKeys.Item.isDoi)

        if field.key == FieldKeys.Item.date || field.baseField == FieldKeys.Item.date,
           let order = self.dateParser.parse(string: value)?.orderWithSpaces {
            var info = field.additionalInfo ?? [:]
            info[.dateOrder] = order
            field.additionalInfo = info
        } else if field.additionalInfo != nil {
            field.additionalInfo = nil
        }

        self.update(viewModel: viewModel) { state in
            state.data.fields[id] = field
        }
    }

    private func createItem(with libraryId: LibraryIdentifier, collectionKey: String?, data: ItemDetailState.Data) throws -> RItem {
        let request = CreateItemDbRequest(libraryId: libraryId,
                                          collectionKey: collectionKey,
                                          data: data,
                                          schemaController: self.schemaController,
                                          dateParser: self.dateParser)
        return try self.dbStorage.createCoordinator().perform(request: request)
    }

    private func updateItem(key: String, libraryId: LibraryIdentifier, data: ItemDetailState.Data, snapshot: ItemDetailState.Data) throws {
        let request = EditItemDetailDbRequest(libraryId: libraryId,
                                              itemKey: key,
                                              data: data,
                                              snapshot: snapshot,
                                              schemaController: self.schemaController,
                                              dateParser: self.dateParser)
        try self.dbStorage.createCoordinator().perform(request: request)
    }
}
