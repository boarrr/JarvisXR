extends RefCounted

const SOURCE := """# HAND LAB DEMONSTRATION — illustrative code, not a live agent edit.
# Try pinch-drag scrolling, then Shift-pinch to move this surface.
class_name DemonstrationRouter
extends RefCounted

signal status_changed(state: String)
signal transcript_changed(lines: PackedStringArray)
signal consent_required(tool: Dictionary)

const MAX_HISTORY := 128
const MAX_PENDING := 16

var last_sequence := 0
var transcript := PackedStringArray()
var pending_tools: Array[Dictionary] = []
var connected := false
var privacy_active := false


func route_agent_delta(event: BackendEvent) -> void:
    if event.sequence <= last_sequence:
        return
    last_sequence = event.sequence
    var delta := str(event.payload.get("delta", ""))
    if delta.is_empty():
        return
    append_transcript(delta)
    status_changed.emit("streaming")


func append_transcript(delta: String) -> void:
    transcript.append(delta)
    while transcript.size() > MAX_HISTORY:
        transcript.remove_at(0)
    if not privacy_active:
        transcript_changed.emit(transcript.duplicate())


func request_tool(tool: Dictionary) -> bool:
    if pending_tools.size() >= MAX_PENDING:
        return false
    pending_tools.append(tool.duplicate(true))
    consent_required.emit({
        "name": tool.get("name", "unknown"),
        "scope": tool.get("scope", "local"),
        "requires_explicit_pinch": true,
    })
    return true


func deny_next_tool() -> void:
    if pending_tools.is_empty():
        return
    pending_tools.pop_front()
    status_changed.emit("denied")


func set_privacy(enabled: bool) -> void:
    privacy_active = enabled
    if privacy_active:
        transcript_changed.emit(PackedStringArray())
    else:
        transcript_changed.emit(transcript.duplicate())


func on_tracking_lost() -> void:
    # Release input; never infer approval from a missing hand.
    status_changed.emit("tracking_lost")


func disconnect_session() -> void:
    connected = false
    pending_tools.clear()
    status_changed.emit("offline")


func reset_session() -> void:
    last_sequence = 0
    transcript.clear()
    pending_tools.clear()
    status_changed.emit("ready")
"""
