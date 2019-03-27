//
//  Files.swift
//  Zotero
//
//  Created by Michal Rentka on 07/02/2019.
//  Copyright © 2019 Corporation for Digital Scholarship. All rights reserved.
//

import Foundation

struct Files {
    static var documentsRootPath: String = {
        return NSSearchPathForDirectoriesInDomains(.documentDirectory, .allDomainsMask, true).first ?? "/"
    }()

    static var cachesRootPath: String = {
        return NSSearchPathForDirectoriesInDomains(.cachesDirectory, .allDomainsMask, true).first ?? "/"
    }()

    static func itemFile(libraryId: LibraryIdentifier, key: String, ext: String) -> File {
        return FileData(rootPath: Files.documentsRootPath,
                        relativeComponents: ["downloads"],
                        name: "library_\(libraryId.fileName)_item_\(key)", ext: ext)
    }

    static var dbFile: File {
        return FileData(rootPath: Files.documentsRootPath, relativeComponents: [], name: "maindb", ext: "realm")
    }
}

extension LibraryIdentifier {
    fileprivate var fileName: String {
        switch self {
        case .custom(let type):
            switch type {
            case .myLibrary:
                return "custom_my_library"
            }
        case .group(let identifier):
            return "group_\(identifier)"
        }
    }
}
