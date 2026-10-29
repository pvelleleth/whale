import AppKit

/// The same transparent whale artwork is used throughout the app.
enum WhaleBrand {
    static let mark: NSImage = {
        let resources: Bundle
        if let url = Bundle.main.url(forResource: "Whale_WhaleApp", withExtension: "bundle"),
           let packaged = Bundle(url: url) {
            resources = packaged
        } else {
            resources = .module // SwiftPM development builds.
        }
        guard let url = resources.url(forResource: "WhaleLogo", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("WhaleLogo.png is missing from the app's resource bundle.")
        }
        return image
    }()

    static let menuBarMark: NSImage = {
        let image = mark.copy() as! NSImage
        image.size = NSSize(width: 22, height: 22)
        image.isTemplate = true
        return image
    }()
}
