import Foundation
import SwiftData

/// An app-owned snapshot, or an adopted legacy path. Missing files retain metadata.
@Model
final class NewFileTemplateEntity {
    var id: String
    var name: String
    var isEnabled: Bool
    var sortOrder: Int
    var storedPath: String?

    init(template: NewFile.Template, sortOrder: Int) {
        id = template.id
        name = template.name
        isEnabled = template.enabled
        self.sortOrder = sortOrder
        storedPath = template.path
    }

    var value: NewFile.Template {
        NewFile.Template(id: id, name: name, enabled: isEnabled, path: storedPath)
    }
}
