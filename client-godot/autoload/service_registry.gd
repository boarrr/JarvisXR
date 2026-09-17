extends Node

const InputRouterService = preload("res://services/input_router.gd")

var input_router = InputRouterService.new()
var backend_transport = null
var speech_service = null

