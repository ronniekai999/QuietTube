// QuietTube for macOS — GPL-3.0-or-later.
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        var requestId: String?
        let response: [String: Any]
        do {
            guard let item = context.inputItems.first as? NSExtensionItem,
                  let message = item.userInfo?[SFExtensionMessageKey], JSONSerialization.isValidJSONObject(message) else {
                throw QuietTubeError.message("Invalid Safari companion message.")
            }
            let data = try JSONSerialization.data(withJSONObject: message)
            guard data.count <= NativeFraming.maximumBytes else { throw QuietTubeError.message("Safari companion message exceeds the limit.") }
            let command = try JSONDecoder().decode(NativeCommand.self, from: data)
            requestId = command.requestId
            let session = NativeSession(store: try QuietTubeStore.shared())
            // Safari launches a handler for each request. Identify every request
            // using metadata provided by our bundled extension, not process state.
            try session.identify(command, safari: true)
            response = try session.handle(command)
        } catch { response = NativeSession.error(error, requestId: requestId) }
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
