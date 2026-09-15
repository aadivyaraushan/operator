#if canImport(UIKit)
import UIKit

@MainActor final class SystemNotionToolConfirmationPresenter: NotionToolConfirmationPresenting {
    private weak var alert:UIAlertController?; private var continuation:CheckedContinuation<NotionToolDecision,Never>?; private var generation=0
    func confirm(_ request:NotionToolConfirmationRequest) async -> NotionToolDecision {
        cancel(); generation += 1; let run=generation
        guard let host=Self.host() else{return .denied}
        return await withCheckedContinuation { continuation in
            self.continuation=continuation
            let data=(try? JSONEncoder().encode(request.arguments)) ?? Data("{}".utf8); let arguments=String(decoding:data,as:UTF8.self)
            let alert=UIAlertController(title:"Allow Notion action?",message:"Tool: \(request.name)\n\n\(arguments)",preferredStyle:.alert)
            alert.addAction(UIAlertAction(title:"Cancel",style:.cancel){[weak self] _ in self?.finish(.denied,run:run)})
            alert.addAction(UIAlertAction(title:"Allow",style:.default){[weak self] _ in self?.finish(.confirmed(request),run:run)})
            self.alert=alert;host.present(alert,animated:true)
        }
    }
    func cancel(){generation += 1;alert?.dismiss(animated:true);let saved=continuation;continuation=nil;alert=nil;saved?.resume(returning:.denied)}
    private func finish(_ value:NotionToolDecision,run:Int){guard generation==run else{return};let saved=continuation;continuation=nil;alert=nil;saved?.resume(returning:value)}
    private static func host()->UIViewController?{ForegroundPresentationHost.topmost()}
}
#endif
