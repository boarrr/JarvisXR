extends Node

signal app_ready
signal debug_message(message: String)
signal interaction_source_changed(source_name: String)
signal cockpit_panel_requested(panel: String)
signal qr_pairing_payload(payload: String)
signal pairing_required

