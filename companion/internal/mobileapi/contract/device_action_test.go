package contract

import (
	"strings"
	"testing"
)

// The two frames that let the Mac ask the phone to do something.
//
// Every capability so far decides and acts on the same machine. A notification
// reply cannot: routing needs the language model, which is on the Mac, and the
// reply box lives inside an Android notification, which is on the phone. So
// this is the first capability whose Execute has to happen somewhere else, and
// the wire's answer is RunOnDevice: the Mac asks with `device_action`, the
// phone answers with `device_action_result`.
//
// `device_action` is the Mac asking. `device_action_result` is the phone
// answering. Both are new, and both peers must ship them together: bodies are
// checked against an exact key set, so an older peer rejects the whole frame.
//
// What device_action deliberately does NOT carry: a conversation id. Android's
// per-notification `sbn.key` is made and thrown away on the phone
// (NotificationProbeService.kt:182-196) and has never crossed the wire. The Mac
// names a *person* — a contact handle, the same thing its routing already
// resolves (stage2/resolver.go:172) — and the phone turns that into a
// conversation with ReplyAdapter.pick, which declines rather than guessing
// between two matches. Sending a conversation key the Mac invented would be
// asking it to name something it has never seen.
//
// What device_action_result deliberately does NOT carry: any wording. It sends
// one word for what happened and nothing else. The sentence the user reads is
// built on the Mac, next to every other capability's sentence, so the phrasing
// for "we don't know" cannot drift between the two machines — which is the
// exact failure this whole round has been fixing.

const replyText = "on my way"

func deviceAction(body string) []byte {
	return []byte(`{"version":{"major":1,"minor":0},"messageId":"dev-1","sender":"companion","type":"device_action","body":` + body + `}`)
}

func deviceActionResult(body string) []byte {
	return []byte(`{"version":{"major":1,"minor":0},"messageId":"dev-r-1","sender":"phone","type":"device_action_result","body":` + body + `}`)
}

func TestTheMacCanAskThePhoneToSendAReply(t *testing.T) {
	frame := deviceAction(`{"requestId":"cap-action-1","kind":"notification_reply","handle":"maya","text":"` + replyText + `"}`)

	message, err := DecodeText(frame)
	if err != nil {
		t.Fatalf("a well-formed device_action was rejected: %v", err)
	}
	if message.Type != "device_action" {
		t.Fatalf("type = %q", message.Type)
	}
}

func TestTheMacCanAskThePhoneToPlayAnExactYouTubeVideo(t *testing.T) {
	frame := deviceAction(`{"requestId":"cap-action-1","kind":"youtube_play","handle":"https://www.youtube.com/watch?v=dQw4w9WgXcQ","text":"Never Gonna Give You Up"}`)

	message, err := DecodeText(frame)
	if err != nil {
		t.Fatalf("a well-formed YouTube device action was rejected: %v", err)
	}
	if message.Type != "device_action" {
		t.Fatalf("type = %q", message.Type)
	}
}

func TestTheMacCanAskThePhoneForItsLocation(t *testing.T) {
	frame := deviceAction(`{"requestId":"cap-action-1","kind":"get_location","handle":"current_location","text":"Read the device's current location"}`)

	message, err := DecodeText(frame)
	if err != nil {
		t.Fatalf("a well-formed get_location device action was rejected: %v", err)
	}
	if message.Type != "device_action" {
		t.Fatalf("type = %q", message.Type)
	}
}

func TestThePhoneCanReportEveryWayAReplyCanEnd(t *testing.T) {
	// Four answers, because the phone can distinguish four situations and the
	// Mac needs all four. "notification_gone" is not a failure the user caused
	// and not one they can retry into: the conversation moved on. Folding it
	// into "failed" would send someone back to a reply box that is not there.
	for _, outcome := range []string{"handed_to_the_app", "notification_gone", "failed", "refused"} {
		t.Run(outcome, func(t *testing.T) {
			if _, err := DecodeText(deviceActionResult(`{"requestId":"cap-action-1","outcome":"` + outcome + `"}`)); err != nil {
				t.Fatalf("a well-formed device_action_result was rejected: %v", err)
			}
		})
	}
}

func TestThePhoneCanReturnALocationPayload(t *testing.T) {
	// get_location has no sentence for the Mac to assemble — the Mac never
	// saw the answer, only the phone did — so the payload carries it through
	// verbatim.
	frame := deviceActionResult(`{"requestId":"cap-action-1","outcome":"handed_to_the_app","payload":"{\"latitude\":37.7749,\"longitude\":-122.4194,\"accuracyMeters\":12.5,\"timestampMillis\":1750000000000,\"provider\":\"fused\"}"}`)
	if _, err := DecodeText(frame); err != nil {
		t.Fatalf("a device_action_result carrying a payload was rejected: %v", err)
	}
}

func TestAnOverLongPayloadIsRejected(t *testing.T) {
	tooLong := `{"requestId":"cap-action-1","outcome":"handed_to_the_app","payload":"` + strings.Repeat("a", 4097) + `"}`
	if _, err := DecodeText(deviceActionResult(tooLong)); err == nil {
		t.Fatal("an over-long payload was accepted")
	}
}

func TestAnOutcomeWordNobodyDefinedIsRejected(t *testing.T) {
	// The Mac turns this word into what the user is told. A word it does not
	// know would fall through to whatever the last branch said — the failure
	// mode this codebase keeps hitting. Refuse it at the door instead.
	for _, outcome := range []string{"", "sent", "ok", "unknown", "delivered", "HANDED_TO_THE_APP"} {
		if _, err := DecodeText(deviceActionResult(`{"requestId":"cap-action-1","outcome":"` + outcome + `"}`)); err == nil {
			t.Fatalf("an undefined outcome %q was accepted", outcome)
		}
	}
}

func TestOnlyTheMacMayAskAndOnlyThePhoneMayAnswer(t *testing.T) {
	// A phone that could send itself a device_action would be able to make
	// another phone act on a request the Mac never approved; a Mac that could
	// send a device_action_result could close out a request that was never
	// carried out. Both directions are pinned.
	backwards := []byte(`{"version":{"major":1,"minor":0},"messageId":"dev-1","sender":"phone","type":"device_action","body":{"requestId":"cap-action-1","kind":"notification_reply","handle":"maya","text":"` + replyText + `"}}`)
	if _, err := DecodeText(backwards); err == nil {
		t.Fatal("a phone was allowed to send a device_action")
	}

	backwards = []byte(`{"version":{"major":1,"minor":0},"messageId":"dev-r-1","sender":"companion","type":"device_action_result","body":{"requestId":"cap-action-1","outcome":"handed_to_the_app"}}`)
	if _, err := DecodeText(backwards); err == nil {
		t.Fatal("the companion was allowed to send a device_action_result")
	}
}

func TestADeviceActionCarriesExactlyTheFourThingsItNeeds(t *testing.T) {
	// An exact key set, like every other capability frame. The reason is not
	// tidiness: an extra key is how a token, a conversation id, or a second
	// copy of the message text gets onto the wire unnoticed.
	rejected := []string{
		`{"requestId":"cap-action-1","kind":"notification_reply","handle":"maya"}`,
		`{"requestId":"cap-action-1","kind":"notification_reply","text":"` + replyText + `"}`,
		`{"requestId":"cap-action-1","handle":"maya","text":"` + replyText + `"}`,
		`{"kind":"notification_reply","handle":"maya","text":"` + replyText + `"}`,
		`{"requestId":"cap-action-1","kind":"notification_reply","handle":"maya","text":"` + replyText + `","conversationKey":"0|com.whatsapp|1|null|123"}`,
		`{"requestId":"cap-action-1","kind":"notification_reply","handle":"maya","text":"` + replyText + `","accessToken":"secret"}`,
	}
	for _, body := range rejected {
		if _, err := DecodeText(deviceAction(body)); err == nil {
			t.Fatalf("a device_action with the wrong keys was accepted: %s", body)
		}
	}

	for _, body := range []string{
		`{"requestId":"cap-action-1"}`,
		`{"outcome":"handed_to_the_app"}`,
		`{"requestId":"cap-action-1","outcome":"handed_to_the_app","detail":"Sent to Maya"}`,
	} {
		if _, err := DecodeText(deviceActionResult(body)); err == nil {
			t.Fatalf("a device_action_result with the wrong keys was accepted: %s", body)
		}
	}
}

func TestAKindThePhoneCannotCarryOutIsRejected(t *testing.T) {
	// Only one kind exists. Accepting an unknown one means the phone receives
	// an instruction it has no code for and must decide what to do with it —
	// and the honest answer there is "refuse", which is cheaper to enforce
	// here, once, than in every phone build that ever ships.
	for _, kind := range []string{"", "notification_read", "reply", "send_sms"} {
		body := `{"requestId":"cap-action-1","kind":"` + kind + `","handle":"maya","text":"` + replyText + `"}`
		if _, err := DecodeText(deviceAction(body)); err == nil {
			t.Fatalf("an unsupported kind %q was accepted", kind)
		}
	}
}

func TestTheReplyTextIsBoundedAndNeverEmpty(t *testing.T) {
	// Same reasoning as any other raw-text field the wire carries (e.g.
	// start_turn's text, validation.go:1011): it is raw text a person wrote,
	// so it is length-checked
	// rather than display-sanitised, and an empty one is a bug upstream —
	// firing a blank message into someone's chat is not a no-op.
	tooLong := `{"requestId":"cap-action-1","kind":"notification_reply","handle":"maya","text":"` + strings.Repeat("a", 4097) + `"}`
	if _, err := DecodeText(deviceAction(tooLong)); err == nil {
		t.Fatal("an over-long reply text was accepted")
	}

	for _, text := range []string{"", "   "} {
		body := `{"requestId":"cap-action-1","kind":"notification_reply","handle":"maya","text":"` + text + `"}`
		if _, err := DecodeText(deviceAction(body)); err == nil {
			t.Fatalf("a blank reply text %q was accepted", text)
		}
	}

	atTheLimit := `{"requestId":"cap-action-1","kind":"notification_reply","handle":"maya","text":"` + strings.Repeat("a", 4096) + `"}`
	if _, err := DecodeText(deviceAction(atTheLimit)); err != nil {
		t.Fatalf("a reply exactly at the limit was rejected: %v", err)
	}
}

func TestTheHandleMustNameSomebody(t *testing.T) {
	for _, handle := range []string{"", "   "} {
		body := `{"requestId":"cap-action-1","kind":"notification_reply","handle":"` + handle + `","text":"` + replyText + `"}`
		if _, err := DecodeText(deviceAction(body)); err == nil {
			t.Fatalf("a blank handle %q was accepted", handle)
		}
	}

	tooLong := `{"requestId":"cap-action-1","kind":"notification_reply","handle":"` + strings.Repeat("m", 257) + `","text":"` + replyText + `"}`
	if _, err := DecodeText(deviceAction(tooLong)); err == nil {
		t.Fatal("an over-long handle was accepted")
	}
}

func TestNeitherFrameIsSequenced(t *testing.T) {
	// device_action is not replayed from the journal: it asks for something
	// to happen *now*, and a request the phone missed while offline must
	// expire rather than fire late
	// into a conversation that has moved on. The waiting record's timeout is
	// what ends it (see the plan's three cleanup rules), not a redelivery.
	sequenced := []byte(`{"version":{"major":1,"minor":0},"messageId":"dev-1","sender":"companion","type":"device_action","seq":4,"body":{"requestId":"cap-action-1","kind":"notification_reply","handle":"maya","text":"` + replyText + `"}}`)
	if _, err := DecodeText(sequenced); err == nil {
		t.Fatal("a sequenced device_action was accepted")
	}

	sequenced = []byte(`{"version":{"major":1,"minor":0},"messageId":"dev-r-1","sender":"phone","type":"device_action_result","seq":4,"body":{"requestId":"cap-action-1","outcome":"handed_to_the_app"}}`)
	if _, err := DecodeText(sequenced); err == nil {
		t.Fatal("a sequenced device_action_result was accepted")
	}
}
