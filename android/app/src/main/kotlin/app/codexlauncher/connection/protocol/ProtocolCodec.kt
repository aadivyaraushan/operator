package app.codexlauncher.connection.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.time.Instant
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

object ProtocolCodec {
    const val PROTOCOL_MAJOR = 1
    const val MAX_JSON_FRAME_BYTES = 256 * 1024
    const val MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024
    const val MAX_ATTACHMENT_FRAME_BYTES = MAX_ATTACHMENT_BYTES + 4096 + 12 + 32
    const val MAX_SNAPSHOT_TASKS = 20
    const val MAX_TRANSCRIPT_PAGE_ENTRIES = 64
    const val MAX_TRANSCRIPT_ENTRY_RUNES = 8192
    const val MAX_TRANSCRIPT_FILE_CHANGES = 64

    private val json = Json { isLenient = false }
    private val envelopeKeys = setOf("version", "messageId", "sender", "type", "seq", "body")
    private val attachmentMagic = byteArrayOf('C'.code.toByte(), 'L'.code.toByte(), 'A'.code.toByte(), 'T'.code.toByte())
    private const val ATTACHMENT_VERSION: Byte = 1
    private const val ATTACHMENT_TAG_BYTES = 32
    private const val ATTACHMENT_HEADER_MAX = 4096

    class Exception(val error: ProtocolError) : IllegalArgumentException(error.name)

    fun decodeText(frame: String): ProtocolMessage {
        if (frame.encodeToByteArray().size > MAX_JSON_FRAME_BYTES) fail(ProtocolError.FRAME_TOO_LARGE)
        val root = runCatching { json.parseToJsonElement(frame).jsonObject }
            .getOrElse { fail(ProtocolError.INVALID_ENVELOPE) }
        if (root.keys.any { it !in envelopeKeys }) fail(ProtocolError.INVALID_ENVELOPE)
        val versionObject = objectField(root, "version")
        if (versionObject.keys != setOf("major", "minor")) fail(ProtocolError.INVALID_ENVELOPE)
        val version = ProtocolVersion(
            major = intField(versionObject, "major"),
            minor = intField(versionObject, "minor"),
        )
        if (version.major != PROTOCOL_MAJOR || version.minor < 0) fail(ProtocolError.UNSUPPORTED_VERSION)
        val messageId = stringField(root, "messageId")
        if (!messageId.isValidId()) fail(ProtocolError.INVALID_ENVELOPE)
        val senderName = stringField(root, "sender")
        val sender = Sender.entries.find { it.wireName == senderName } ?: fail(ProtocolError.INVALID_ENVELOPE)
        val typeName = stringField(root, "type")
        val type = MessageType.entries.find { it.wireName == typeName } ?: fail(ProtocolError.INVALID_ENVELOPE)
        val sequence = root["seq"]?.jsonPrimitive?.longOrNull
        if ("seq" in root && sequence == null) fail(ProtocolError.INVALID_ENVELOPE)
        val sequenceType = type in setOf(MessageType.SNAPSHOT, MessageType.EVENT, MessageType.ACTION_RESULT, MessageType.ATTACHMENT_ACK)
        if (sequenceType != (sequence != null) || sequence != null && sequence < 1) fail(ProtocolError.INVALID_ENVELOPE)
        val body = objectField(root, "body")
        validateBody(sender, type, sequence, body)
        return ProtocolMessage(version, messageId, sender, type, sequence, body)
    }

    fun encodeAttachmentFrame(chunk: AttachmentChunk, key: ByteArray): ByteArray {
        if (key.size < 32 || !chunk.sessionId.isValidId() || !chunk.uploadId.isValidId() || chunk.chunk < 0 || chunk.offset < 0 ||
            chunk.declaredTotal !in 1..MAX_ATTACHMENT_BYTES.toLong() || chunk.payload.size > chunk.declaredTotal ||
            chunk.offset > chunk.declaredTotal - chunk.payload.size
        ) fail(ProtocolError.INVALID_ATTACHMENT)
        val digest = MessageDigest.getInstance("SHA-256").digest(chunk.payload).toHex()
        val header = buildJsonObject {
            put("sessionId", chunk.sessionId)
            put("uploadId", chunk.uploadId)
            put("chunk", chunk.chunk)
            put("offset", chunk.offset)
            put("declaredTotal", chunk.declaredTotal)
            put("sha256", digest)
        }.toString().encodeToByteArray()
        if (header.size > ATTACHMENT_HEADER_MAX) fail(ProtocolError.INVALID_ATTACHMENT)
        val unsigned = ByteBuffer.allocate(12 + header.size + chunk.payload.size).order(ByteOrder.BIG_ENDIAN).apply {
            put(attachmentMagic)
            put(ATTACHMENT_VERSION)
            put(if (chunk.final) 1 else 0)
            putShort(header.size.toShort())
            putInt(chunk.payload.size)
            put(header)
            put(chunk.payload)
        }.array()
        return unsigned + hmac(unsigned, key)
    }

    fun decodeAttachmentFrame(frame: ByteArray, key: ByteArray): AttachmentChunk {
        if (key.size < 32 || frame.size < 12 + ATTACHMENT_TAG_BYTES || frame.size > MAX_ATTACHMENT_FRAME_BYTES) fail(ProtocolError.INVALID_ATTACHMENT)
        val buffer = ByteBuffer.wrap(frame).order(ByteOrder.BIG_ENDIAN)
        val magic = ByteArray(4).also(buffer::get)
        val version = buffer.get()
        val flags = buffer.get().toInt()
        val headerSize = buffer.short.toInt() and 0xffff
        val payloadSize = buffer.int
        if (!magic.contentEquals(attachmentMagic) || version != ATTACHMENT_VERSION || flags and 1.inv() != 0 || headerSize !in 1..ATTACHMENT_HEADER_MAX ||
            payloadSize < 0 || frame.size != 12 + headerSize + payloadSize + ATTACHMENT_TAG_BYTES
        ) fail(ProtocolError.INVALID_ATTACHMENT)
        val unsignedSize = frame.size - ATTACHMENT_TAG_BYTES
        val expectedTag = hmac(frame.copyOfRange(0, unsignedSize), key)
        if (!MessageDigest.isEqual(expectedTag, frame.copyOfRange(unsignedSize, frame.size))) fail(ProtocolError.INVALID_ATTACHMENT)
        val headerBytes = ByteArray(headerSize).also(buffer::get)
        val payload = ByteArray(payloadSize).also(buffer::get)
        val header = runCatching { json.parseToJsonElement(headerBytes.decodeToString()).jsonObject }
            .getOrElse { fail(ProtocolError.INVALID_ATTACHMENT) }
        if (header.keys != setOf("sessionId", "uploadId", "chunk", "offset", "declaredTotal", "sha256")) fail(ProtocolError.INVALID_ATTACHMENT)
        val sessionId = optionalString(header, "sessionId")
        val uploadId = optionalString(header, "uploadId")
        val chunk = header["chunk"]?.jsonPrimitive?.intOrNull ?: fail(ProtocolError.INVALID_ATTACHMENT)
        val offset = header["offset"]?.jsonPrimitive?.longOrNull ?: fail(ProtocolError.INVALID_ATTACHMENT)
        val total = header["declaredTotal"]?.jsonPrimitive?.longOrNull ?: fail(ProtocolError.INVALID_ATTACHMENT)
        val digest = optionalString(header, "sha256")
        val actualDigest = MessageDigest.getInstance("SHA-256").digest(payload).toHex()
        if (!sessionId.isValidId() || !uploadId.isValidId() || chunk < 0 || offset < 0 || total !in 1..MAX_ATTACHMENT_BYTES.toLong() ||
            payload.size > total || offset > total - payload.size || !actualDigest.equals(digest, ignoreCase = true)
        ) fail(ProtocolError.INVALID_ATTACHMENT)
        return AttachmentChunk(sessionId, uploadId, chunk, offset, total, flags and 1 == 1, payload)
    }

    private fun hmac(value: ByteArray, key: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(key, "HmacSHA256"))
            doFinal(value)
        }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
    private fun String.isSha256(): Boolean = length == 64 && all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }

    private fun validateBody(sender: Sender, type: MessageType, sequence: Long?, body: JsonObject) {
        when (type) {
            MessageType.HELLO -> {
                val resume = objectField(body, "resume")
                val majors = runCatching { body.getValue("supportedMajors").jsonArray.map { it.jsonPrimitive.intOrNull ?: fail(ProtocolError.INVALID_ENVELOPE) } }
                    .getOrElse { fail(ProtocolError.INVALID_ENVELOPE) }
                val mode = optionalString(resume, "mode")
                val lastAck = resume["lastAck"]?.jsonPrimitive?.longOrNull
                if (mode == "no_local_state" && (resume["lastAck"] != null || resume["uploads"] != null)) fail(ProtocolError.COLD_RESUME_CURSOR)
                if (sender != Sender.PHONE || body.keys != setOf("clientInstanceId", "supportedMajors", "resume") ||
                    !stringField(body, "clientInstanceId").isBounded(128) || PROTOCOL_MAJOR !in majors || majors.isEmpty() || majors.any { it < 1 } || majors.distinct().size != majors.size ||
                    resume.keys.any { it !in setOf("mode", "lastAck", "uploads") } || (mode != "warm" && mode != "no_local_state") ||
                    !validResumeUploads(resume["uploads"]) || mode == "warm" && (lastAck == null || lastAck < 1)
                ) fail(ProtocolError.INVALID_ENVELOPE)
            }
            MessageType.WELCOME -> {
                val limits = objectField(body, "limits")
                if (sender != Sender.COMPANION || body.keys.any { it !in setOf("sessionId", "capabilities", "limits", "newTaskOptions") } ||
                    !body.keys.containsAll(setOf("sessionId", "capabilities", "limits")) || !stringField(body, "sessionId").isBounded(128) ||
                    !validUniqueStrings(body["capabilities"]) || !validLimits(limits) || !validAdvertisedNewTaskOptions(body)
                ) fail(ProtocolError.INVALID_ENVELOPE)
            }
            MessageType.SNAPSHOT -> if (
                sender != Sender.COMPANION || sequence == null || body.keys != setOf("baseSeq", "computerName", "projects", "tasks") ||
                longField(body, "baseSeq") != sequence || !optionalString(body, "computerName").isSafeDisplay(80) ||
                !validProjects(body["projects"]) || !validTasks(body["tasks"])
            ) fail(ProtocolError.INVALID_ENVELOPE)
            MessageType.EVENT -> if (sender != Sender.COMPANION || sequence == null || body.keys != setOf("taskId", "event", "state", "summary") || !optionalString(body, "taskId").isValidId() || optionalString(body, "event") !in eventNames || optionalString(body, "state") !in taskStates || !optionalString(body, "summary").isSafeDisplay(512)) fail(ProtocolError.INVALID_ENVELOPE)
            MessageType.TASK_READ -> if (
                sender != Sender.PHONE || body.keys.any { it !in setOf("requestId", "taskId", "limit", "beforeEntryId") } ||
                !optionalString(body, "requestId").isValidId() || !optionalString(body, "taskId").isValidId() ||
                (body["limit"]?.jsonPrimitive?.intOrNull ?: 0) !in 1..MAX_TRANSCRIPT_PAGE_ENTRIES ||
                body["beforeEntryId"] != null && !optionalString(body, "beforeEntryId").isValidId()
            ) fail(ProtocolError.INVALID_ENVELOPE)
            MessageType.TASK_PAGE -> if (sender != Sender.COMPANION || !validTaskPage(body)) fail(ProtocolError.INVALID_ENVELOPE)
            MessageType.DECISION_READ -> if (
                sender != Sender.PHONE || body.keys != setOf("requestId", "taskId") ||
                !optionalString(body, "requestId").isValidId() || !optionalString(body, "taskId").isValidId()
            ) fail(ProtocolError.INVALID_ENVELOPE)
            MessageType.DECISION_PAGE -> if (sender != Sender.COMPANION || !validDecisionPage(body)) fail(ProtocolError.INVALID_ENVELOPE)
            // The predetermined-function pipeline that produced these two frame
            // types is gone (Phase 8). The enum members stay only because the
            // Unit 4 Kotlin UI wave (CapabilityInteraction, LauncherSessionViewModel)
            // still references them; on the wire they now fail exactly like any
            // frame type the codec has never heard of.
            MessageType.CAPABILITY_PREVIEW, MessageType.CAPABILITY_RESULT -> fail(ProtocolError.INVALID_ENVELOPE)
            // The Mac decides a reply is needed but cannot send it: only the
            // phone holds the live notification. "text" is bounded the same
            // way start_turn's text is, not isSafeDisplay'd,
            // because it is raw words a person wrote for another person, not
            // a label this app renders in its own UI — stripping it for
            // display would change what gets sent.
            MessageType.DEVICE_ACTION -> if (
                sender != Sender.COMPANION || body.keys != setOf("requestId", "kind", "handle", "text") ||
                !optionalString(body, "requestId").isValidId() || optionalString(body, "kind") !in deviceActionKinds ||
                !optionalString(body, "handle").isSafeDisplay(256) ||
                !optionalString(body, "text").isBounded(4096) || optionalString(body, "text").isBlank()
            ) fail(ProtocolError.INVALID_ENVELOPE)
            // Only the phone can report how a reply actually landed; it is
            // the one machine that watched the send happen. A data-fetch
            // capability like get_location has no sentence for the Mac to
            // assemble on its own, so the phone's answer rides along as an
            // opaque JSON string in the optional "payload".
            MessageType.DEVICE_ACTION_RESULT -> if (
                sender != Sender.PHONE || body.keys.any { it !in setOf("requestId", "outcome", "payload") } ||
                !optionalString(body, "requestId").isValidId() || optionalString(body, "outcome") !in deviceActionOutcomes ||
                (body["payload"] != null && !optionalString(body, "payload").isBounded(4096))
            ) fail(ProtocolError.INVALID_ENVELOPE)
            MessageType.ACTION_RESULT -> {
                val state = optionalString(body, "state")
                val resultCode = optionalString(body, "resultCode")
                val forkTaskId = optionalString(body, "forkTaskId")
                if (sender != Sender.COMPANION || sequence == null || body.keys.any { it !in setOf("actionId", "state", "resultCode", "error", "forkTaskId", "question") } ||
                    !optionalString(body, "actionId").isValidId() || state !in actionStates ||
                    body["resultCode"] != null && resultCode !in actionResultCodes ||
                    body["forkTaskId"] != null && (!forkTaskId.isValidId() || state != "confirmed") ||
                    !validOptionalError(body["error"], state in setOf("failed", "outcome_unknown")) ||
                    body["question"] != null && (!optionalString(body, "question").isSafeDisplay(512) || state != "cancelled")
                ) fail(ProtocolError.INVALID_ACTION_STATE)
            }
            MessageType.ACK -> if (sender != Sender.PHONE || body.keys != setOf("throughSeq") || (body["throughSeq"]?.jsonPrimitive?.longOrNull ?: 0) < 1) fail(ProtocolError.INVALID_ACK)
            MessageType.ACTION -> validateAction(sender, body)
            MessageType.ATTACHMENT_OFFER -> {
                if (sender != Sender.PHONE || body.keys != setOf("uploadId", "declaredTotal", "sha256") ||
                    !optionalString(body, "uploadId").isValidId() || (body["declaredTotal"]?.jsonPrimitive?.longOrNull ?: 0) !in 1..MAX_ATTACHMENT_BYTES.toLong() ||
                    !optionalString(body, "sha256").isSha256()
                ) fail(ProtocolError.INVALID_ATTACHMENT)
            }
            MessageType.ATTACHMENT_CANCEL, MessageType.ATTACHMENT_COMPLETE -> {
                if (sender != Sender.PHONE || body.keys != setOf("uploadId") || !optionalString(body, "uploadId").isValidId()) {
                    fail(ProtocolError.INVALID_ATTACHMENT)
                }
            }
            MessageType.ATTACHMENT_ACK -> {
                val state = optionalString(body, "state")
                if (sender != Sender.COMPANION || sequence == null ||
                    body.keys != setOf("uploadId", "state", "receivedBytes", "sha256", "nextChunk") ||
                    !optionalString(body, "uploadId").isValidId() || state !in setOf("accepted", "complete", "cancelled") ||
                    body["receivedBytes"]?.jsonPrimitive?.longOrNull == null || body.getValue("receivedBytes").jsonPrimitive.longOrNull!! !in 0..MAX_ATTACHMENT_BYTES.toLong() ||
                    body["nextChunk"]?.jsonPrimitive?.longOrNull == null || body.getValue("nextChunk").jsonPrimitive.longOrNull!! !in 0..Int.MAX_VALUE.toLong() ||
                    !optionalString(body, "sha256").isSha256()
                ) fail(ProtocolError.INVALID_ATTACHMENT)
            }
            MessageType.ERROR -> if (body.keys != setOf("code", "retryable") || optionalString(body, "code") !in errorCodes || !isJsonBoolean(body["retryable"])) fail(ProtocolError.INVALID_ENVELOPE)
        }
    }

    private fun validateAction(sender: Sender, body: JsonObject) {
        if (sender != Sender.PHONE || !optionalString(body, "actionId").isValidId()) fail(ProtocolError.INVALID_ACTION)
        when (optionalString(body, "kind")) {
            "start_turn" -> {
                val validText = optionalString(body, "text").isBounded(131072) && optionalString(body, "text").isNotBlank()
                val existingTask =
                    body.keys.all { it in setOf("actionId", "kind", "taskId", "text", "attachmentIds") } &&
                        optionalString(body, "taskId").isValidId() && validText && validOptionalIds(body["attachmentIds"])
                val newTask =
                    body.keys.all { it in setOf("actionId", "kind", "projectId", "text", "modelId", "reasoningId", "permissionModeId", "attachmentIds") } &&
                        optionalString(body, "projectId").isProjectId() && validText &&
                        optionalString(body, "modelId").isValidId() && optionalString(body, "reasoningId").isValidId() &&
                        optionalString(body, "permissionModeId").isValidId() && validOptionalIds(body["attachmentIds"])
                if (!existingTask && !newTask) fail(ProtocolError.INVALID_ACTION)
            }
            "steer_turn" -> if (body.keys.any { it !in setOf("actionId", "kind", "taskId", "text", "attachmentIds") } || !optionalString(body, "taskId").isValidId() || !optionalString(body, "text").isBounded(131072) || optionalString(body, "text").isBlank() || !validOptionalIds(body["attachmentIds"])) fail(ProtocolError.INVALID_ACTION)
            "interrupt_turn" -> if (body.keys != setOf("actionId", "kind", "taskId") || !optionalString(body, "taskId").isValidId()) fail(ProtocolError.INVALID_ACTION)
            "dismiss_unknown_control" -> {
                val existing = body.keys == setOf("actionId", "kind", "taskId", "targetActionId") && optionalString(body, "taskId").isValidId()
                val newTask = body.keys == setOf("actionId", "kind", "targetActionId")
                if ((!existing && !newTask) || !optionalString(body, "targetActionId").isValidId()) fail(ProtocolError.INVALID_ACTION)
            }
            "approval" -> {
                val requestKind = optionalString(body, "requestKind")
                val decision = optionalString(body, "decision")
                if (body.keys != setOf("actionId", "kind", "taskId", "requestId", "requestKind", "decision") || !optionalString(body, "taskId").isValidId() || !optionalString(body, "requestId").isValidId() ||
                    requestKind !in setOf("command", "file", "permissions", "mcp_elicitation") ||
                    decision !in setOf("accept", "accept_for_session", "decline", "cancel")
                ) fail(ProtocolError.INVALID_ACTION)
            }
            "question_response" -> if (
                body.keys != setOf("actionId", "kind", "taskId", "requestId", "answers") ||
                !optionalString(body, "taskId").isValidId() || !optionalString(body, "requestId").isValidId() || !validQuestionAnswers(body["answers"])
            ) fail(ProtocolError.INVALID_ACTION)
            "set_project" -> if (body.keys != setOf("actionId", "kind", "projectId") || !optionalString(body, "projectId").isProjectId()) fail(ProtocolError.INVALID_ACTION)
            "rename_task" -> if (
                body.keys != setOf("actionId", "kind", "taskId", "title") ||
                !optionalString(body, "taskId").isValidId() || !optionalString(body, "title").isSafeDisplay(256)
            ) fail(ProtocolError.INVALID_ACTION)
            "archive_task", "fork_task" -> if (
                body.keys != setOf("actionId", "kind", "taskId") || !optionalString(body, "taskId").isValidId()
            ) fail(ProtocolError.INVALID_ACTION)
            else -> fail(ProtocolError.INVALID_ACTION)
        }
    }

    private fun validResumeUploads(value: kotlinx.serialization.json.JsonElement?): Boolean =
        value == null || runCatching {
            val uploads = value.jsonObject
            uploads.size <= 2 && uploads.all { (uploadId, nextChunk) ->
                uploadId.isValidId() && (nextChunk.jsonPrimitive.longOrNull ?: -1) in 0..Int.MAX_VALUE.toLong()
            }
        }.getOrDefault(false)

    private fun validDecisionPage(body: JsonObject): Boolean = runCatching {
        if (body.keys != setOf("requestId", "taskId", "requests") || !optionalString(body, "requestId").isValidId() || !optionalString(body, "taskId").isValidId()) return@runCatching false
        val requests = body["requests"]?.jsonArray ?: return@runCatching false
        if (requests.size > 32) return@runCatching false
        val seen = mutableSetOf<String>()
        requests.all { element ->
            val request = element.jsonObject
            val requestId = optionalString(request, "requestId")
            val kind = optionalString(request, "kind")
            val base = request.keys.all { it in setOf("requestId", "turnId", "itemId", "kind", "computerName", "projectLabel", "workingDirectory", "reason", "access", "command", "commandUnderstandable", "affectedPaths", "allowedDecisions", "questions", "expiresAt") } &&
                requestId.isValidId() && seen.add(requestId) && optionalString(request, "turnId").isValidId() && optionalString(request, "itemId").isValidId() &&
                optionalString(request, "computerName").isSafeDisplay(80) && optionalString(request, "projectLabel").isSafeDisplay(128) &&
                runCatching { Instant.parse(optionalString(request, "expiresAt")) }.isSuccess && optionalSafeDisplay(request, "workingDirectory", 4096) &&
                optionalSafeDisplay(request, "reason", 4096) && optionalSafeDisplay(request, "access", 4096) && validOptionalSafeStrings(request["affectedPaths"], 64, 4096)
            base && when (kind) {
                "command" -> optionalString(request, "command").isSafeDisplay(4096) && isJsonBoolean(request["commandUnderstandable"]) && validAllowedDecisions(request["allowedDecisions"]) && request["questions"] == null
                "file", "permissions" -> validAllowedDecisions(request["allowedDecisions"]) && request["command"] == null && request["commandUnderstandable"] == null && request["questions"] == null
                "mcp_elicitation" -> validMcpDecisions(request["allowedDecisions"]) && request["command"] == null && request["commandUnderstandable"] == null && request["questions"] == null
                "question" -> validDecisionQuestions(request["questions"]) && request["allowedDecisions"] == null && request["command"] == null && request["commandUnderstandable"] == null
                else -> false
            }
        }
    }.getOrDefault(false)

    private fun validDecisionQuestions(value: kotlinx.serialization.json.JsonElement?): Boolean = runCatching {
        val questions = value?.jsonArray ?: return@runCatching false
        if (questions.isEmpty() || questions.size > 32) return@runCatching false
        val seen = mutableSetOf<String>()
        questions.all { element ->
            val question = element.jsonObject
            val id = optionalString(question, "id")
            question.keys == setOf("id", "header", "prompt", "options", "secret") && id.isValidId() && seen.add(id) &&
                optionalString(question, "header").isSafeDisplay(128) && optionalString(question, "prompt").isSafeDisplay(4096) &&
                isJsonBoolean(question["secret"]) && validOptionalSafeStrings(question["options"], 32, 512)
        }
    }.getOrDefault(false)

    private fun validQuestionAnswers(value: kotlinx.serialization.json.JsonElement?): Boolean = runCatching {
        val answers = value?.jsonObject ?: return@runCatching false
        var total = 0
        answers.isNotEmpty() && answers.size <= 32 && answers.all { (id, element) ->
            val values = element.jsonArray.map { it.jsonPrimitive.content }
            id.isValidId() && values.isNotEmpty() && values.size <= 32 && values.all { answer ->
                total += answer.encodeToByteArray().size
                answer.isNotEmpty() && answer.length <= 131072 && '\u0000' !in answer && total <= 131072
            }
        }
    }.getOrDefault(false)

    private fun validAllowedDecisions(value: kotlinx.serialization.json.JsonElement?): Boolean = runCatching {
        val decisions = value?.jsonArray?.map { it.jsonPrimitive.content } ?: return@runCatching false
        decisions.isNotEmpty() && decisions.size <= 4 && decisions.distinct().size == decisions.size && decisions.all { it in setOf("accept", "accept_for_session", "decline", "cancel") }
    }.getOrDefault(false)

    private fun validMcpDecisions(value: kotlinx.serialization.json.JsonElement?): Boolean = runCatching {
        val decisions = value?.jsonArray?.map { it.jsonPrimitive.content } ?: return@runCatching false
        decisions.isNotEmpty() && decisions.size <= 2 && decisions.distinct().size == decisions.size && decisions.all { it in setOf("decline", "cancel") }
    }.getOrDefault(false)

    private fun optionalSafeDisplay(body: JsonObject, key: String, maximum: Int): Boolean = body[key] == null || optionalString(body, key).isSafeDisplay(maximum)

    private fun validOptionalSafeStrings(value: kotlinx.serialization.json.JsonElement?, maximumItems: Int, maximumLength: Int): Boolean = runCatching {
        value == null || value.jsonArray.size <= maximumItems && value.jsonArray.all { it.jsonPrimitive.content.isSafeDisplay(maximumLength) }
    }.getOrDefault(false)

    private fun validTasks(value: kotlinx.serialization.json.JsonElement?): Boolean = runCatching {
        val tasks = value?.jsonArray ?: return@runCatching false
        if (tasks.size > MAX_SNAPSHOT_TASKS) return@runCatching false
        val ids = mutableSetOf<String>()
        tasks.all { element ->
            val task = element.jsonObject
            val id = optionalString(task, "taskId")
            task.keys.all { it in setOf("taskId", "title", "projectLabel", "state", "activeTurnId", "canRedirect", "queueState", "lastActivityAt", "pendingRequest", "lastMessage") } &&
                id.isValidId() && ids.add(id) && optionalString(task, "title").isSafeDisplay(256) &&
                optionalString(task, "projectLabel").isSafeDisplay(128) && optionalString(task, "state") in taskStates &&
                (task["activeTurnId"] == null || optionalString(task, "activeTurnId").isValidId()) &&
                (task["canRedirect"] == null || isJsonBoolean(task["canRedirect"])) &&
                optionalString(task, "queueState") in setOf("", "none", "queued", "outcome_unknown") &&
                runCatching { Instant.parse(optionalString(task, "lastActivityAt")) }.isSuccess && validPendingRequest(task["pendingRequest"]) &&
                validLastMessage(task["lastMessage"])
        }
    }.getOrDefault(false)

    private fun validTaskPage(body: JsonObject): Boolean = runCatching {
        if (body.keys.any { it !in setOf("requestId", "taskId", "entries", "earlierCursor", "truncated", "error") } ||
            !optionalString(body, "requestId").isValidId() || !optionalString(body, "taskId").isValidId() ||
            !isJsonBoolean(body["truncated"]) || body["earlierCursor"] != null && !optionalString(body, "earlierCursor").isValidId()
        ) return@runCatching false
        val entries = body["entries"]?.jsonArray ?: return@runCatching false
        if (entries.size > MAX_TRANSCRIPT_PAGE_ENTRIES) return@runCatching false
        if (body["error"] != null) {
            return@runCatching entries.isEmpty() && body["earlierCursor"] == null && validOptionalError(body["error"], required = true)
        }
        val ids = mutableSetOf<String>()
        entries.all { element ->
            val entry = element.jsonObject
            val id = optionalString(entry, "id")
            id.isValidId() && ids.add(id) && optionalString(entry, "turnId").isValidId() && validTranscriptEntry(entry)
        }
    }.getOrDefault(false)

    private fun validTranscriptEntry(entry: JsonObject): Boolean =
        when (optionalString(entry, "kind")) {
            "user", "agent", "reasoning", "plan", "activity" ->
                entry.keys == setOf("id", "turnId", "kind", "text") && optionalString(entry, "text").isBounded(MAX_TRANSCRIPT_ENTRY_RUNES)
            "message" ->
                // A message entry renders one received chat message as its own row:
                // the sender's display name, the body text (which may span multiple
                // lines), and when it was sent.
                entry.keys == setOf("id", "turnId", "kind", "sender", "text", "sentAt") &&
                    optionalString(entry, "sender").isSafeDisplay(256) &&
                    optionalString(entry, "text").isBounded(MAX_TRANSCRIPT_ENTRY_RUNES) &&
                    runCatching { Instant.parse(optionalString(entry, "sentAt")) }.isSuccess
            "command" ->
                entry.keys.all { it in setOf("id", "turnId", "kind", "status", "command", "output") } &&
                    optionalString(entry, "status") in transcriptStatuses && optionalString(entry, "command").isBounded(MAX_TRANSCRIPT_ENTRY_RUNES) &&
                    (entry["output"] == null || optionalString(entry, "output").isBounded(MAX_TRANSCRIPT_ENTRY_RUNES))
            "file_change" -> {
                if (entry.keys != setOf("id", "turnId", "kind", "status", "changes") || optionalString(entry, "status") !in transcriptStatuses) {
                    false
                } else {
                    runCatching {
                        val changes = entry.getValue("changes").jsonArray
                        changes.size <= MAX_TRANSCRIPT_FILE_CHANGES && changes.all { element ->
                            val change = element.jsonObject
                            change.keys.all { it in setOf("path", "kind", "diff") } && optionalString(change, "path").isBounded(4096) &&
                                optionalString(change, "kind").isSafeDisplay(64) &&
                                (change["diff"] == null || optionalString(change, "diff").isBounded(MAX_TRANSCRIPT_ENTRY_RUNES))
                        }
                    }.getOrDefault(false)
                }
            }
            else -> false
        }

    private fun validProjects(value: kotlinx.serialization.json.JsonElement?): Boolean = runCatching {
        val projects = value?.jsonArray ?: return@runCatching false
        if (projects.size > 128) return@runCatching false
        val ids = mutableSetOf<String>()
        projects.all { element ->
            val project = element.jsonObject
            val id = optionalString(project, "id")
            project.keys == setOf("id", "displayName") && id.isProjectId() && ids.add(id) &&
                optionalString(project, "displayName").isSafeDisplay(128)
        }
    }.getOrDefault(false)

    private fun validPendingRequest(value: kotlinx.serialization.json.JsonElement?): Boolean =
        value == null || runCatching {
            val request = value.jsonObject
            request.keys == setOf("requestId", "kind", "summary") && optionalString(request, "requestId").isValidId() &&
                optionalString(request, "kind") in requestKinds && optionalString(request, "summary").isSafeDisplay(512)
        }.getOrDefault(false)

    private fun validLastMessage(value: kotlinx.serialization.json.JsonElement?): Boolean =
        value == null || runCatching {
            val message = value.jsonObject
            message.keys == setOf("from", "text") && optionalString(message, "from") in setOf("agent", "user", "plain") &&
                optionalString(message, "text").isSafeDisplay(512)
        }.getOrDefault(false)

    private fun validOptionalError(value: kotlinx.serialization.json.JsonElement?, required: Boolean): Boolean {
        if (value == null) return !required
        return runCatching {
            val error = value.jsonObject
            error.keys == setOf("code", "retryable") && optionalString(error, "code") in errorCodes &&
                isJsonBoolean(error["retryable"])
        }.getOrDefault(false)
    }

    private fun validOptionalIds(value: kotlinx.serialization.json.JsonElement?): Boolean =
        value == null || runCatching {
            val ids = value.jsonArray.map {
                if (!it.jsonPrimitive.isString) return@runCatching false
                it.jsonPrimitive.content
            }
            ids.size <= 16 && ids.all { it.isValidId() } && ids.distinct().size == ids.size
        }.getOrDefault(false)

    private fun isJsonBoolean(value: kotlinx.serialization.json.JsonElement?): Boolean = runCatching {
        val primitive = value?.jsonPrimitive ?: return@runCatching false
        !primitive.isString && primitive.booleanOrNull != null
    }.getOrDefault(false)

    private fun validUniqueStrings(value: kotlinx.serialization.json.JsonElement?): Boolean = runCatching {
        val values = value?.jsonArray?.map {
            if (!it.jsonPrimitive.isString) return@runCatching false
            it.jsonPrimitive.content
        } ?: return@runCatching false
        values.all(String::isNotEmpty) && values.distinct().size == values.size
    }.getOrDefault(false)

    private fun validLimits(limits: JsonObject): Boolean =
        limits.keys == limitKeys && limits.all { (name, value) ->
            val number = value.jsonPrimitive.longOrNull ?: return@all false
            val maximum = when (name) {
                "maxJsonBytes" -> MAX_JSON_FRAME_BYTES.toLong()
                "maxAttachmentBytes" -> MAX_ATTACHMENT_BYTES.toLong()
                "maxDeviceUploads" -> 2L
                "maxGlobalUploads" -> 4L
                "maxTemporaryBytes" -> 100L * 1024 * 1024
                "uploadExpirySeconds" -> 15L * 60
                else -> return@all false
            }
            number in 1..maximum
        }

    private fun validAdvertisedNewTaskOptions(welcome: JsonObject): Boolean = runCatching {
        val capabilities = welcome.getValue("capabilities").jsonArray.map { it.jsonPrimitive.content }
        val advertised = "new_task_options" in capabilities
        val rawOptions = welcome["newTaskOptions"] ?: return@runCatching !advertised
        val options = rawOptions.jsonObject
        if (options.keys != setOf("models", "permissionModes")) return@runCatching false
        val models = options.getValue("models").jsonArray.map { it.jsonObject }
        val permissionModes = options.getValue("permissionModes").jsonArray.map { it.jsonObject }
        if (!advertised) return@runCatching models.isEmpty() && permissionModes.isEmpty()
        if (models.size !in 1..32 || permissionModes.size !in 1..8) return@runCatching false

        val modelIds = mutableSetOf<String>()
        var defaultModels = 0
        for (model in models) {
            if (model.keys != setOf("id", "displayName", "isDefault", "defaultReasoningId", "reasoning")) return@runCatching false
            val id = stringField(model, "id")
            val displayName = stringField(model, "displayName")
            val defaultReasoningId = stringField(model, "defaultReasoningId")
            val isDefault = model["isDefault"]?.jsonPrimitive?.booleanOrNull ?: return@runCatching false
            if (!id.isSafeOption(128) || !displayName.isSafeOption(128) || !defaultReasoningId.isSafeOption(128) || !modelIds.add(id) ||
                !validReasoningOptions(model.getValue("reasoning"), defaultReasoningId)
            ) return@runCatching false
            if (isDefault) defaultModels++
        }

        val permissionIds = mutableSetOf<String>()
        var defaultPermissions = 0
        for (mode in permissionModes) {
            if (mode.keys != setOf("id", "displayName", "description", "isDefault")) return@runCatching false
            val id = stringField(mode, "id")
            val displayName = stringField(mode, "displayName")
            val description = stringField(mode, "description")
            val isDefault = mode["isDefault"]?.jsonPrimitive?.booleanOrNull ?: return@runCatching false
            if (!id.isSafeOption(128) || !displayName.isSafeOption(128) || !description.isSafeOption(512) || !permissionIds.add(id)) return@runCatching false
            if (isDefault) defaultPermissions++
        }
        defaultModels == 1 && defaultPermissions == 1
    }.getOrDefault(false)

    private fun validReasoningOptions(value: kotlinx.serialization.json.JsonElement, defaultId: String): Boolean = runCatching {
        val options = value.jsonArray.map { it.jsonObject }
        if (options.size !in 1..16) return@runCatching false
        val ids = mutableSetOf<String>()
        for (option in options) {
            if (option.keys != setOf("id", "displayName", "description")) return@runCatching false
            val id = stringField(option, "id")
            if (!id.isSafeOption(128) || !stringField(option, "displayName").isSafeOption(128) ||
                !stringField(option, "description").isSafeOption(512) || !ids.add(id)
            ) return@runCatching false
        }
        defaultId in ids
    }.getOrDefault(false)

    private fun String.isValidId(): Boolean =
        length in 1..128 && all { it.isLetterOrDigit() && it.code < 128 || it in "._:-" }

    private fun String.isProjectId(): Boolean = matches(Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))

    private fun String.isBounded(maximum: Int): Boolean = codePointCount(0, length) in 1..maximum

    private fun String.isSafeDisplay(maximum: Int): Boolean =
        codePointCount(0, length) in 1..maximum && isNotBlank() && none(Char::isISOControl)

    private fun String.isSafeOption(maximum: Int): Boolean =
        codePointCount(0, length) in 1..maximum && trim() == this && none(Char::isISOControl)

    private fun objectField(objectValue: JsonObject, name: String): JsonObject =
        runCatching { objectValue.getValue(name).jsonObject }.getOrElse { fail(ProtocolError.INVALID_ENVELOPE) }

    private fun stringField(objectValue: JsonObject, name: String): String =
        runCatching {
            val value = objectValue.getValue(name).jsonPrimitive
            if (!value.isString) fail(ProtocolError.INVALID_ENVELOPE)
            value.content
        }.getOrElse { fail(ProtocolError.INVALID_ENVELOPE) }

    private fun optionalString(objectValue: JsonObject, name: String): String =
        runCatching {
            val value = objectValue[name]?.jsonPrimitive ?: return@runCatching ""
            if (!value.isString) return@runCatching ""
            value.content
        }.getOrDefault("")

    private fun intField(objectValue: JsonObject, name: String): Int =
        objectValue[name]?.jsonPrimitive?.intOrNull ?: fail(ProtocolError.INVALID_ENVELOPE)

    private fun longField(objectValue: JsonObject, name: String): Long =
        objectValue[name]?.jsonPrimitive?.longOrNull ?: fail(ProtocolError.INVALID_ENVELOPE)

    private fun fail(error: ProtocolError): Nothing = throw Exception(error)

    private val actionStates = setOf("queued", "sent", "confirmed", "outcome_unknown", "failed", "cancelled")
    private val actionResultCodes = setOf("accepted", "queued", "redirected", "interrupted")
    private val taskStates = setOf("working", "waiting_for_approval", "waiting_for_answer", "failed", "interrupted", "idle_after_reply")
    private val eventNames = setOf("activity", "reply", "approval", "answer", "failure", "interrupted", "metadata")
    private val transcriptStatuses = setOf("inProgress", "completed", "failed", "declined")
    private val requestKinds = setOf("command", "file", "permissions", "question", "mcp_elicitation")
    // Closed set of things this phone knows how to be asked to do. A wire
    // format that let this grow silently would let the Mac ask for an act
    // the phone was never built to carry out.
    private val deviceActionKinds = setOf("notification_reply", "youtube_play", "open_page", "get_location")
    // Four endings, not a boolean. "notification_gone" is neither a success
    // nor a failure worth retrying: the conversation moved on before the
    // phone could act, and lumping it in with "failed" would make the Mac
    // retry a reply into a notification that no longer exists.
    private val deviceActionOutcomes = setOf("handed_to_the_app", "notification_gone", "failed", "refused")
    private val errorCodes = setOf("computer_offline", "connection_lost", "desktop_incompatible", "owner_unavailable", "invalid_action", "outcome_unknown", "sequence_gap", "unauthorized", "quota_exceeded", "attachment_invalid", "internal")
    private val limitKeys = setOf("maxJsonBytes", "maxAttachmentBytes", "maxDeviceUploads", "maxGlobalUploads", "maxTemporaryBytes", "uploadExpirySeconds")
}

class ProtocolSession(
    private val attachmentKey: ByteArray = byteArrayOf(),
    private val quota: AttachmentQuota = AttachmentQuota(AttachmentLimits()),
    private val expectedSessionId: String = "",
    private var deviceId: String = "",
    initialSequence: Long? = null,
) {
    private val seenActions = mutableSetOf<String>()
    private val actionStates = mutableMapOf<String, String>()
    private val uploads = mutableMapOf<String, UploadState>()
    private val requestedUploads = mutableMapOf<String, Int>()
    private val completedUploads = mutableMapOf<String, AttachmentAck>()
    private var closed = false
    var lastSequence: Long? = initialSequence
        private set
    private var lastAck: Long? = initialSequence
    var hasFreshSnapshot: Boolean = false
        private set

    fun acceptText(frame: String): ProtocolMessage {
        if (closed) fail(ProtocolError.SESSION_CLOSED)
        return try {
            acceptTextOpen(frame)
        } catch (error: ProtocolCodec.Exception) {
            closed = true
            throw error
        }
    }

    private fun acceptTextOpen(frame: String): ProtocolMessage {
        val message = ProtocolCodec.decodeText(frame)
        if (message.type == MessageType.HELLO) {
            val clientInstanceId = message.body.getValue("clientInstanceId").jsonPrimitive.content
            if (deviceId.isBlank()) deviceId = clientInstanceId else if (deviceId != clientInstanceId) fail(ProtocolError.INVALID_ENVELOPE)
            val resume = message.body.getValue("resume").jsonObject
            if (resume.getValue("mode").jsonPrimitive.content == "no_local_state" && (resume["lastAck"] != null || resume["uploads"] != null)) {
                fail(ProtocolError.COLD_RESUME_CURSOR)
            }
            if (resume.getValue("mode").jsonPrimitive.content == "warm") {
                resume["lastAck"]?.jsonPrimitive?.longOrNull?.let {
                    lastSequence = it
                    lastAck = it
                }
            }
            resume["uploads"]?.jsonObject?.forEach { (uploadId, value) ->
                value.jsonPrimitive.intOrNull?.let { requestedUploads[uploadId] = it }
            }
        }
        message.sequence?.let { sequence ->
            if (message.type == MessageType.SNAPSHOT) {
                if (lastSequence != null && sequence <= lastSequence!!) fail(ProtocolError.SEQUENCE_GAP)
                lastSequence = sequence
                hasFreshSnapshot = true
            } else if (lastSequence == null || sequence != lastSequence!! + 1) {
                fail(ProtocolError.SEQUENCE_GAP)
            } else {
                lastSequence = sequence
            }
        }
        if (message.type == MessageType.ACTION) {
            val actionId = message.body.getValue("actionId").jsonPrimitive.content
            if (!seenActions.add(actionId)) fail(ProtocolError.DUPLICATE_ACTION)
        }
        if (message.type == MessageType.ACTION_RESULT) {
            val actionId = message.body.getValue("actionId").jsonPrimitive.content
            val next = message.body.getValue("state").jsonPrimitive.content
            if (!validActionTransition(actionStates[actionId], next)) fail(ProtocolError.INVALID_ACTION_STATE)
            actionStates[actionId] = next
        }
        if (message.type == MessageType.ACK) {
            val through = message.body.getValue("throughSeq").jsonPrimitive.longOrNull ?: fail(ProtocolError.INVALID_ACK)
            if (lastSequence == null || through > lastSequence!! || lastAck != null && through < lastAck!!) fail(ProtocolError.INVALID_ACK)
            lastAck = through
        }
        if (message.type == MessageType.ATTACHMENT_OFFER) {
            offerAttachment(
                AttachmentOffer(
                    uploadId = message.body.getValue("uploadId").jsonPrimitive.content,
                    declaredTotal = message.body.getValue("declaredTotal").jsonPrimitive.longOrNull
                        ?: fail(ProtocolError.INVALID_ATTACHMENT),
                    sha256 = message.body.getValue("sha256").jsonPrimitive.content,
                ),
            )
        }
        if (message.type == MessageType.ATTACHMENT_CANCEL) {
            cancelAttachment(message.body.getValue("uploadId").jsonPrimitive.content)
        }
        if (message.type == MessageType.ATTACHMENT_COMPLETE) {
            val uploadId = message.body.getValue("uploadId").jsonPrimitive.content
            completedUploads[uploadId] = completeAttachment(uploadId)
        }
        return message
    }

    // This is the phone's untrusted claim. The Go companion accepts it only
    // after matching retained authenticated upload state.
    fun claimedUploadChunk(uploadId: String): Int = requestedUploads[uploadId] ?: 0

    fun completedAttachment(uploadId: String): AttachmentAck? = completedUploads[uploadId]

    fun offerAttachment(
        offer: AttachmentOffer,
        nowEpochSeconds: Long = System.currentTimeMillis() / 1_000,
    ) {
        expireAttachments(nowEpochSeconds)
        if (!offer.uploadId.matches(Regex("^[A-Za-z0-9._:-]{1,128}$")) || offer.declaredTotal <= 0 ||
            offer.sha256.length != 64 || !offer.sha256.isHex()
        ) fail(ProtocolError.INVALID_ATTACHMENT)
        if (offer.declaredTotal > ProtocolCodec.MAX_ATTACHMENT_BYTES || offer.declaredTotal > quota.limits.maxAttachmentBytes || offer.uploadId in uploads) {
            fail(ProtocolError.ATTACHMENT_QUOTA)
        }
        val expiresAt = nowEpochSeconds + 15 * 60
        val quotaToken = quota.reserve(deviceId, offer.declaredTotal, expiresAt, nowEpochSeconds) ?: fail(ProtocolError.ATTACHMENT_QUOTA)
        uploads[offer.uploadId] = UploadState(offer, expiresAt = expiresAt, quotaToken = quotaToken)
    }

    fun expireAttachments(nowEpochSeconds: Long) {
        uploads.filterValues { nowEpochSeconds > it.expiresAt }.keys.toList().forEach(::releaseAttachment)
    }

    fun acceptAttachmentFrame(frame: ByteArray) {
        expireAttachments(System.currentTimeMillis() / 1_000)
        val chunk = ProtocolCodec.decodeAttachmentFrame(frame, attachmentKey)
        if (expectedSessionId.isBlank() || chunk.sessionId != expectedSessionId) fail(ProtocolError.INVALID_ATTACHMENT)
        val upload = uploads[chunk.uploadId] ?: fail(ProtocolError.INVALID_ATTACHMENT)
        if (upload.final || chunk.chunk != upload.nextChunk || chunk.offset != upload.received ||
            chunk.declaredTotal != upload.offer.declaredTotal || upload.received > upload.offer.declaredTotal ||
            chunk.payload.size > upload.offer.declaredTotal - upload.received
        ) fail(ProtocolError.INVALID_ATTACHMENT)
        if (chunk.final && chunk.payload.size.toLong() != upload.offer.declaredTotal - upload.received) fail(ProtocolError.INVALID_ATTACHMENT)
        upload.digest.update(chunk.payload)
        upload.received += chunk.payload.size
        upload.nextChunk++
        upload.final = chunk.final
    }

    fun completeAttachment(uploadId: String): AttachmentAck {
        expireAttachments(System.currentTimeMillis() / 1_000)
        val upload = uploads[uploadId] ?: fail(ProtocolError.INVALID_ATTACHMENT)
        if (!upload.final || upload.received != upload.offer.declaredTotal) fail(ProtocolError.INVALID_ATTACHMENT)
        val digest = upload.digest.digest().toHex()
        if (!digest.equals(upload.offer.sha256, ignoreCase = true)) {
            releaseAttachment(uploadId)
            fail(ProtocolError.INVALID_ATTACHMENT)
        }
        releaseAttachment(uploadId)
        return AttachmentAck(uploadId, upload.received, digest)
    }

    fun cancelAttachment(uploadId: String) {
        releaseAttachment(uploadId)
    }

    private fun releaseAttachment(uploadId: String) {
        uploads.remove(uploadId)?.let { quota.release(it.quotaToken) }
    }

    private fun String.isHex(): Boolean = length % 2 == 0 && all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }
    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
    private fun validActionTransition(previous: String?, next: String): Boolean = when (previous) {
        null -> true
        "queued" -> next in setOf("sent", "confirmed", "outcome_unknown", "failed", "cancelled")
        "sent" -> next in setOf("confirmed", "outcome_unknown", "failed", "cancelled")
        else -> false
    }
    private fun fail(error: ProtocolError): Nothing = throw ProtocolCodec.Exception(error)

    private data class UploadState(
        val offer: AttachmentOffer,
        var nextChunk: Int = 0,
        var received: Long = 0,
        var final: Boolean = false,
        val digest: MessageDigest = MessageDigest.getInstance("SHA-256"),
        val expiresAt: Long,
        val quotaToken: Long,
    )
}
