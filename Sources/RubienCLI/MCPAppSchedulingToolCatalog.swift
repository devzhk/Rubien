import Foundation
import RubienCore

/// Write tools exposed only to interactive Assistant turns launched by Rubien.
/// They are intentionally absent from the public native/Node MCP catalogs and
/// from unattended scheduled runs, whose library channel is read-only.
enum MCPAppSchedulingToolCatalog {
    static let tools = [createScheduledJobTool]

    private static let createScheduledJobTool = MCPTool(
        name: RubienAppSchedulingContract.createToolName,
        description: "Create a local recurring Rubien Assistant job after the user approves this write. Use weekday abbreviations mon through sun and a local 24-hour time in HH:mm form. The job runs only while Rubien is available on this Mac.",
        inputSchema: [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 200,
                    "description": "Short display name for the scheduled job",
                ],
                "prompt": [
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 20_000,
                    "description": "Instructions the Assistant will receive on every run",
                ],
                "weekdays": [
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 7,
                    "items": [
                        "type": "string",
                        "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"],
                    ],
                    "description": "Local weekdays on which the job runs",
                ],
                "time": [
                    "type": "string",
                    "minLength": 5,
                    "maxLength": 5,
                    "description": "Local wall-clock time in 24-hour HH:mm form",
                ],
                "provider": [
                    "type": "string",
                    "enum": ["claude", "codex"],
                    "description": "Assistant provider; defaults to claude",
                ],
                "model": [
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 200,
                    "description": "Optional provider model override",
                ],
                "effort": [
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 200,
                    "description": "Optional provider effort override",
                ],
                "enabled": [
                    "type": "boolean",
                    "description": "Whether the schedule starts enabled; defaults to true",
                ],
                "webAccess": [
                    "type": "boolean",
                    "description": "Whether runs may access the web; defaults to true",
                ],
                "notifyOnCompletion": [
                    "type": "boolean",
                    "description": "Whether Rubien posts completion notifications; defaults to true",
                ],
            ],
            "required": ["name", "prompt", "weekdays", "time"],
            "additionalProperties": false,
        ],
        access: RubienAppSchedulingContract.createToolAccess,
        destructive: false,
        idempotent: false,
        isImage: false,
        buildArgv: { _ in [] },
        validatesPublicPolicy: false,
        directHandler: createScheduledJob)

    private static func createScheduledJob(_ arguments: [String: Any]) throws -> [String: Any] {
        do {
            guard let name = arguments["name"] as? String,
                  let prompt = arguments["prompt"] as? String,
                  let weekdays = arguments["weekdays"] as? [String],
                  let time = arguments["time"] as? String
            else {
                throw MCPToolError.invalidArguments(
                    "Missing required arguments: name, prompt, weekdays, and time"
                )
            }

            let job = try AppDatabase.shared.createScheduledJob(.init(
                name: name,
                prompt: prompt,
                recurrence: .init(
                    weekdayMask: try parseScheduledWeekdayMask(weekdays.joined(separator: ",")),
                    localMinuteOfDay: try parseScheduledLocalTime(time)
                ),
                isEnabled: arguments["enabled"] as? Bool ?? true,
                provider: try parseScheduledProvider(arguments["provider"] as? String ?? "claude"),
                model: arguments["model"] as? String,
                effort: arguments["effort"] as? String,
                webAccess: arguments["webAccess"] as? Bool ?? true,
                notifyOnCompletion: arguments["notifyOnCompletion"] as? Bool ?? true
            ))
            notifyLibraryChanged()

            let data = try jsonEncoder.encode(ScheduledJobDTO(job))
            return [
                "content": [[
                    "type": "text",
                    "text": String(decoding: data, as: UTF8.self),
                ]],
            ]
        } catch let error as MCPToolError {
            throw error
        } catch {
            throw MCPToolError.invalidArguments(scheduledJobCLIErrorMessage(error))
        }
    }
}
