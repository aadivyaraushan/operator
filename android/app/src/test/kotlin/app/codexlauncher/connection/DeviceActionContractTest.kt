package app.codexlauncher.connection

import app.codexlauncher.connection.protocol.MessageType
import app.codexlauncher.connection.protocol.ProtocolCodec
import app.codexlauncher.connection.protocol.Sender
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * The phone half of the two frames that let the Mac ask this device to act.
 *
 * This file is the mirror of `companion/internal/mobileapi/contract/device_action_test.go`
 * and must stay in step with it, key for key and word for word. The bodies are
 * checked against an exact key set on both sides, so a rule that exists on one
 * machine and not the other does not degrade — it drops the whole frame, and
 * the user is told nothing at all.
 *
 * Why these frames exist: every capability so far decides and acts on the same
 * machine. A notification reply cannot. Routing needs the language model on the
 * Mac; the reply box lives inside an Android notification on the phone.
 *
 * What `device_action` deliberately does not carry is a conversation id.
 * Android's per-notification key is made and thrown away here
 * (`NotificationProbeService.kt:182-196`) and has never crossed the wire. The
 * Mac names a person; `ReplyAdapter.pick` turns that into a conversation, and
 * declines rather than guessing between two matches.
 */
class DeviceActionContractTest {

    private val replyText = "on my way"

    private fun deviceAction(body: String) =
        """{"version":{"major":1,"minor":0},"messageId":"dev-1","sender":"companion","type":"device_action","body":$body}"""

    private fun deviceActionResult(body: String) =
        """{"version":{"major":1,"minor":0},"messageId":"dev-r-1","sender":"phone","type":"device_action_result","body":$body}"""

    private fun wellFormedAction(
        handle: String = "maya",
        text: String = replyText,
        kind: String = "notification_reply",
    ) = deviceAction("""{"requestId":"cap-action-1","kind":"$kind","handle":"$handle","text":"$text"}""")

    @Test
    fun `the phone accepts a reply the mac asked it to send`() {
        val message = ProtocolCodec.decodeText(wellFormedAction())

        assertEquals(MessageType.DEVICE_ACTION, message.type)
        assertEquals(Sender.COMPANION, message.sender)
    }

    @Test
    fun `the phone accepts an exact youtube video the mac asked it to play`() {
        val message =
            ProtocolCodec.decodeText(
                wellFormedAction(
                    kind = "youtube_play",
                    handle = "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                    text = "Never Gonna Give You Up",
                ),
            )

        assertEquals(MessageType.DEVICE_ACTION, message.type)
        assertEquals(Sender.COMPANION, message.sender)
    }

    @Test
    fun `the phone accepts a request to read its current location`() {
        val message =
            ProtocolCodec.decodeText(
                wellFormedAction(
                    kind = "get_location",
                    handle = "current_location",
                    text = "Read the device's current location",
                ),
            )

        assertEquals(MessageType.DEVICE_ACTION, message.type)
        assertEquals(Sender.COMPANION, message.sender)
    }

    @Test
    fun `the phone can answer a location read with a payload`() {
        val payload = """{"latitude":37.7749,"longitude":-122.4194,"accuracyMeters":12.5,"timestampMillis":1750000000000,"provider":"fused"}"""
        val escaped = payload.replace("\"", "\\\"")
        val message = ProtocolCodec.decodeText(deviceActionResult("""{"requestId":"cap-action-1","outcome":"handed_to_the_app","payload":"$escaped"}"""))
        assertEquals(MessageType.DEVICE_ACTION_RESULT, message.type)
    }

    @Test
    fun `the phone can report every way a reply can end`() {
        // Four answers, because the phone can tell these four apart and the Mac
        // needs all four. "notification_gone" is not a failure anybody caused
        // and not one a person can retry into — the conversation moved on.
        for (outcome in listOf("handed_to_the_app", "notification_gone", "failed", "refused")) {
            val message = ProtocolCodec.decodeText(deviceActionResult("""{"requestId":"cap-action-1","outcome":"$outcome"}"""))
            assertEquals(MessageType.DEVICE_ACTION_RESULT, message.type)
        }
    }

    @Test
    fun `an outcome word nobody defined is refused`() {
        for (outcome in listOf("", "sent", "ok", "unknown", "delivered", "HANDED_TO_THE_APP")) {
            assertThrows(Exception::class.java) {
                ProtocolCodec.decodeText(deviceActionResult("""{"requestId":"cap-action-1","outcome":"$outcome"}"""))
            }
        }
    }

    @Test
    fun `only the mac may ask and only the phone may answer`() {
        // A phone able to send itself a device_action could act on a request the
        // Mac never approved; a Mac able to send a device_action_result could
        // close out a request nobody carried out.
        assertThrows(Exception::class.java) {
            ProtocolCodec.decodeText(
                """{"version":{"major":1,"minor":0},"messageId":"dev-1","sender":"phone","type":"device_action","body":{"requestId":"cap-action-1","kind":"notification_reply","handle":"maya","text":"$replyText"}}""",
            )
        }
        assertThrows(Exception::class.java) {
            ProtocolCodec.decodeText(
                """{"version":{"major":1,"minor":0},"messageId":"dev-r-1","sender":"companion","type":"device_action_result","body":{"requestId":"cap-action-1","outcome":"handed_to_the_app"}}""",
            )
        }
    }

    @Test
    fun `a device action carries exactly the four things it needs`() {
        // An exact key set, like every other capability frame. Not tidiness: an
        // extra key is how a token, a conversation id, or a second copy of the
        // message text reaches the wire without anyone noticing.
        val rejected = listOf(
            """{"requestId":"cap-action-1","kind":"notification_reply","handle":"maya"}""",
            """{"requestId":"cap-action-1","kind":"notification_reply","text":"$replyText"}""",
            """{"requestId":"cap-action-1","handle":"maya","text":"$replyText"}""",
            """{"kind":"notification_reply","handle":"maya","text":"$replyText"}""",
            """{"requestId":"cap-action-1","kind":"notification_reply","handle":"maya","text":"$replyText","conversationKey":"0|com.whatsapp|1|null|123"}""",
            """{"requestId":"cap-action-1","kind":"notification_reply","handle":"maya","text":"$replyText","accessToken":"secret"}""",
        )
        for (body in rejected) {
            assertThrows(Exception::class.java) { ProtocolCodec.decodeText(deviceAction(body)) }
        }

        val rejectedResults = listOf(
            """{"requestId":"cap-action-1"}""",
            """{"outcome":"handed_to_the_app"}""",
            """{"requestId":"cap-action-1","outcome":"handed_to_the_app","detail":"Sent to Maya"}""",
        )
        for (body in rejectedResults) {
            assertThrows(Exception::class.java) { ProtocolCodec.decodeText(deviceActionResult(body)) }
        }
    }

    @Test
    fun `a kind this phone cannot carry out is refused`() {
        for (kind in listOf("", "notification_read", "reply", "send_sms")) {
            assertThrows(Exception::class.java) { ProtocolCodec.decodeText(wellFormedAction(kind = kind)) }
        }
    }

    @Test
    fun `the reply text is bounded and never blank`() {
        // The same bound start_turn's text gets, for the same
        // reason: raw text a person wrote, so length-checked rather than
        // display-sanitised. A blank one is a bug upstream — firing an empty
        // message into someone's chat is not a no-op.
        assertThrows(Exception::class.java) { ProtocolCodec.decodeText(wellFormedAction(text = "a".repeat(4097))) }
        for (text in listOf("", "   ")) {
            assertThrows(Exception::class.java) { ProtocolCodec.decodeText(wellFormedAction(text = text)) }
        }
        assertEquals(
            MessageType.DEVICE_ACTION,
            ProtocolCodec.decodeText(wellFormedAction(text = "a".repeat(4096))).type,
        )
    }

    @Test
    fun `a location payload past the bound is refused`() {
        assertThrows(Exception::class.java) {
            ProtocolCodec.decodeText(
                deviceActionResult("""{"requestId":"cap-action-1","outcome":"handed_to_the_app","payload":"${"a".repeat(4097)}"}"""),
            )
        }
    }

    @Test
    fun `the handle must name somebody`() {
        for (handle in listOf("", "   ")) {
            assertThrows(Exception::class.java) { ProtocolCodec.decodeText(wellFormedAction(handle = handle)) }
        }
        assertThrows(Exception::class.java) { ProtocolCodec.decodeText(wellFormedAction(handle = "m".repeat(257))) }
    }

    @Test
    fun `neither frame is sequenced`() {
        // device_action is not replayed from the journal: it asks for
        // something to happen now, and a request the phone missed while
        // offline must expire rather than fire late into a conversation
        // that has moved on.
        assertThrows(Exception::class.java) {
            ProtocolCodec.decodeText(
                """{"version":{"major":1,"minor":0},"messageId":"dev-1","sender":"companion","type":"device_action","seq":4,"body":{"requestId":"cap-action-1","kind":"notification_reply","handle":"maya","text":"$replyText"}}""",
            )
        }
        assertThrows(Exception::class.java) {
            ProtocolCodec.decodeText(
                """{"version":{"major":1,"minor":0},"messageId":"dev-r-1","sender":"phone","type":"device_action_result","seq":4,"body":{"requestId":"cap-action-1","outcome":"handed_to_the_app"}}""",
            )
        }
    }
}
