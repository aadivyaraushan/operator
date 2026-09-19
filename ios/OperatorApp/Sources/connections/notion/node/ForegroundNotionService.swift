import Foundation
import OperatorCore

struct NotionToolConfirmationRequest: Equatable, Sendable { let name:String; let arguments:[String:NotionJSONValue] }
enum NotionToolDecision: Sendable { case confirmed(NotionToolConfirmationRequest), denied }
@MainActor protocol NotionToolConfirmationPresenting: AnyObject, Sendable { func confirm(_ request:NotionToolConfirmationRequest) async -> NotionToolDecision; func cancel() }
protocol NotionNodeClient: Sendable { func listTools() async throws -> [NotionTool]; func callTool(name:String,arguments:[String:NotionJSONValue]) async throws -> NotionJSONValue }

extension NotionMCPClient: NotionNodeClient {
    func listTools() async throws -> [NotionTool] {
        guard case let .object(root) = try await listTools(), case let .array(values)? = root["tools"] else { throw NotionMCPError.protocolError("invalid tools") }
        return try values.map { value in guard case let .object(item)=value, case let .string(name)?=item["name"], name.count <= 128 else { throw NotionMCPError.protocolError("invalid tool") }; let description:String? = if case let .string(text)?=item["description"] { text } else { nil }; return NotionTool(name:name,description:description) }
    }
}

@MainActor final class ForegroundNotionService: GatewayNodeCommandHandler {
    private let client:any NotionNodeClient; private let presenter:any NotionToolConfirmationPresenting; private let isAppActive:@MainActor @Sendable()->Bool; private var allowed:Set<String>=[]
    init(client:any NotionNodeClient,presenter:any NotionToolConfirmationPresenting,isAppActive:@escaping @MainActor @Sendable()->Bool){self.client=client;self.presenter=presenter;self.isAppActive=isAppActive}
    func handleNodeCommand(_ command:String,paramsJSON:String?,timeoutMilliseconds:Int?) async -> GatewayNodeCommandResult {
        guard ["notion.tools","notion.call"].contains(command) else{return .failure(code:"UNSUPPORTED_COMMAND",message:"This iPhone node does not support \(command)")}; guard isAppActive() else{return .failure(code:"APP_NOT_ACTIVE",message:"Open Operator to use Notion")}
        if command == "notion.tools" { guard Self.empty(paramsJSON) else{return .failure(code:"INVALID_REQUEST",message:"notion.tools takes no parameters")}; do{let tools=try await client.listTools(); guard tools.count<=100 else{throw NotionMCPError.protocolError("too many tools")}; allowed=Set(tools.map(\.name)); return try .success(payloadJSON:String(decoding:JSONEncoder().encode(["tools":tools]),as:UTF8.self))}catch NotionMCPError.missingTokens{return .failure(code:"NOTION_NOT_CONNECTED",message:"Connect Notion in Operator first")}catch{return .failure(code:"NOTION_UNAVAILABLE",message:"Notion tools are unavailable")} }
        guard let request=Self.call(paramsJSON),allowed.contains(request.name) else{return .failure(code:"INVALID_REQUEST",message:"Choose a currently available Notion tool")}
        let ms=max(1,min(timeoutMilliseconds ?? 30_000,30_000)); let deadline=Date().addingTimeInterval(Double(ms)/1000); let decision=await confirm(request,ms); guard case let .confirmed(copy)=decision else{presenter.cancel();return .failure(code:"OWNER_DENIED",message:"Notion tool was not called")}; guard copy == request,isAppActive(),!Task.isCancelled,Date()<deadline else{presenter.cancel();return .failure(code:"CONFIRMATION_MISMATCH",message:"Notion tool was not called")}
        do{return try .success(payloadJSON:String(decoding:JSONEncoder().encode(try await client.callTool(name:request.name,arguments:request.arguments)),as:UTF8.self))}catch{return .failure(code:"NOTION_OUTCOME_UNKNOWN",message:"Notion may or may not have completed this tool call")}
    }
    private func confirm(_ r:NotionToolConfirmationRequest,_ ms:Int) async->NotionToolDecision { await NotionConfirmationRace().run(presenter: presenter, request: r, milliseconds: ms) }
    private static func empty(_ raw:String?)->Bool { guard let data=(raw ?? "{}").data(using:.utf8),let o=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else{return false};return o.isEmpty }
    private static func call(_ raw:String?)->NotionToolConfirmationRequest? { guard let data=raw?.data(using:.utf8),data.count<=64_000,let o=try? JSONSerialization.jsonObject(with:data) as? [String:Any],Set(o.keys)==["name","arguments"],let name=o["name"] as? String,!name.isEmpty,name.count<=128,let args=o["arguments"],JSONSerialization.isValidJSONObject(args),let encoded=try? JSONSerialization.data(withJSONObject:args),let decoded=try? JSONDecoder().decode([String:NotionJSONValue].self,from:encoded) else{return nil};return .init(name:name,arguments:decoded) }
}

@MainActor private final class NotionConfirmationRace {
    private var confirmation:Task<Void,Never>?; private var timeout:Task<Void,Never>?; private var continuation:CheckedContinuation<NotionToolDecision,Never>?
    func run(presenter:any NotionToolConfirmationPresenting,request:NotionToolConfirmationRequest,milliseconds:Int) async->NotionToolDecision {
        await withCheckedContinuation { continuation in
            self.continuation=continuation
            confirmation=Task { [weak self] in let value=await presenter.confirm(request); self?.finish(value) }
            timeout=Task { [weak self] in try? await Task.sleep(for:.milliseconds(milliseconds)); guard !Task.isCancelled else{return}; self?.finish(.denied) }
        }
    }
    private func finish(_ value:NotionToolDecision){guard let saved=continuation else{return};continuation=nil;confirmation?.cancel();timeout?.cancel();saved.resume(returning:value)}
}
