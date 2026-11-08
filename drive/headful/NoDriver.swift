// No driver (an app built without --@isomer//drive:headful, the default):
// `iso_drive_attach` does nothing, and nothing of drive/ is linked.

@_silgen_name("iso_drive_attach")
func _isoDriveAttach(_ platform: String, _ renderer: String) {}
