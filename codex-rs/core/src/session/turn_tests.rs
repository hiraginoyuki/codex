use super::*;
use codex_extension_api::ExtensionData;
use codex_extension_api::TurnItemContributor;
use codex_protocol::ResponseItemId;
use codex_protocol::items::AgentMessageContent;
use pretty_assertions::assert_eq;
use std::sync::Arc;
use tracing_subscriber::prelude::*;

struct RewriteAgentMessageContributor;

impl TurnItemContributor for RewriteAgentMessageContributor {
    fn contribute<'a>(
        &'a self,
        _thread_store: &'a ExtensionData,
        _turn_store: &'a ExtensionData,
        item: &'a mut TurnItem,
    ) -> codex_extension_api::ExtensionFuture<'a, Result<(), String>> {
        Box::pin(async move {
            if let TurnItem::AgentMessage(agent_message) = item {
                agent_message.content = vec![AgentMessageContent::Text {
                    text: "plan contributed assistant text".to_string(),
                }];
            }
            Ok(())
        })
    }
}

fn assistant_output_text(text: &str) -> ResponseItem {
    ResponseItem::Message {
        id: Some(ResponseItemId::with_suffix("msg", "1")),
        role: "assistant".to_string(),
        content: vec![ContentItem::OutputText {
            text: text.to_string(),
        }],
        phase: None,
        internal_chat_message_metadata_passthrough: None,
    }
}

#[test]
fn post_sampling_token_estimate_is_disabled_by_always_on_sinks() {
    let feedback = codex_feedback::CodexFeedback::new();
    let subscriber = tracing_subscriber::registry()
        .with(feedback.logger_layer())
        .with(tracing_subscriber::fmt::layer().with_filter(codex_state::log_db::default_filter()));

    tracing::subscriber::with_default(subscriber, || {
        tracing::callsite::rebuild_interest_cache();
        assert!(!tracing::event_enabled!(
            target: POST_SAMPLING_TOKEN_ESTIMATE_TARGET,
            tracing::Level::TRACE,
            turn_id,
            estimated_token_count,
            message
        ));
    });
}

#[tokio::test]
async fn plan_mode_uses_contributed_turn_item_for_last_agent_message() {
    let (mut session, turn_context) = crate::session::tests::make_session_and_context().await;
    let mut builder = codex_extension_api::ExtensionRegistryBuilder::new();
    builder.turn_item_contributor(Arc::new(RewriteAgentMessageContributor));
    session.services.extensions = Arc::new(builder.build());
    let turn_store = ExtensionData::new(turn_context.sub_id.clone());
    let mut state = PlanModeStreamState::new(&turn_context.sub_id);
    let mut last_agent_message = None;
    let item = assistant_output_text("original assistant text");

    let handled = handle_assistant_item_done_in_plan_mode(
        &session,
        &turn_context,
        &turn_store,
        &item,
        &mut state,
        /*previously_active_item*/ None,
        &mut last_agent_message,
    )
    .await;

    assert!(handled);
    assert_eq!(
        last_agent_message.as_deref(),
        Some("plan contributed assistant text")
    );
}

#[test]
fn sanitize_input_arguments_drops_malformed_function_calls() {
    use codex_protocol::models::ContentItem;
    use codex_protocol::models::ResponseItem;

    fn fc(call_id: &str, args: &str) -> ResponseItem {
        ResponseItem::FunctionCall {
            id: None,
            name: "exec_command".to_string(),
            namespace: None,
            arguments: args.to_string(),
            encrypted_function_args: None,
            call_id: call_id.to_string(),
            internal_chat_message_metadata_passthrough: None,
        }
    }

    fn custom(call_id: &str, name: &str, input: &str) -> ResponseItem {
        ResponseItem::CustomToolCall {
            id: None,
            status: None,
            call_id: call_id.to_string(),
            name: name.to_string(),
            namespace: None,
            input: input.to_string(),
            internal_chat_message_metadata_passthrough: None,
        }
    }

    fn fco(call_id: &str, body: &str) -> ResponseItem {
        use codex_protocol::models::FunctionCallOutputPayload;
        ResponseItem::FunctionCallOutput {
            id: None,
            call_id: call_id.to_string(),
            output: FunctionCallOutputPayload::from_text(body.to_string()),
            internal_chat_message_metadata_passthrough: None,
        }
    }

    let mut input: Vec<ResponseItem> = vec![
        // A regular user message — must be kept untouched.
        ResponseItem::Message {
            id: None,
            role: "user".to_string(),
            content: vec![ContentItem::InputText {
                text: "yo".to_string(),
            }],
            phase: None,
            internal_chat_message_metadata_passthrough: None,
        },
        // A healthy function_call (arguments parse as JSON).
        fc("call_function_ok_1", r#"{"cmd":"ls -la"}"#),
        // A truncated function_call (the turn-1 MiniMax failure shape).
        fc(
            "call_function_bad_2",
            r#"{"cmd": "lsappinfo list 2>/dev/null | head", "justification": "x", "justification": "#,
        ),
        // A synthetic function_call_output for the bad call — must survive.
        fco("call_function_bad_2", "err: invalid JSON in arguments"),
        // A healthy custom_tool_call (apply_patch is freeform text, not
        // JSON) — must be kept even though its input is not valid JSON.
        custom(
            "call_function_ok_3",
            "apply_patch",
            "*** Begin Patch
*** End Patch",
        ),
    ];

    let dropped = sanitize_input_arguments(&mut input);
    assert_eq!(
        dropped, 1,
        "expected to drop the one malformed function_call"
    );

    // Remaining items, in order:
    //  0: user message
    //  1: healthy function_call
    //  2: synthetic function_call_output for the dropped call
    //  3: healthy custom_tool_call (kept as-is; not validated)
    assert_eq!(input.len(), 4);
    assert!(matches!(input[0], ResponseItem::Message { .. }));
    match &input[1] {
        ResponseItem::FunctionCall { call_id, .. } => {
            assert_eq!(call_id, "call_function_ok_1");
        }
        other => panic!("expected healthy FunctionCall at [1], got {other:?}"),
    }
    match &input[2] {
        ResponseItem::FunctionCallOutput { call_id, .. } => {
            assert_eq!(call_id, "call_function_bad_2");
        }
        other => panic!("expected synthetic FunctionCallOutput at [2], got {other:?}"),
    }
    match &input[3] {
        ResponseItem::CustomToolCall { call_id, .. } => {
            assert_eq!(call_id, "call_function_ok_3");
        }
        other => panic!("expected healthy CustomToolCall at [3], got {other:?}"),
    }
}
