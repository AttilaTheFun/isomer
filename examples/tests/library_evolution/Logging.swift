// The os module (OSLog's, re-exported), imported as on Apple platforms. A
// file of its own: an import is checked for use file by file, and each
// public import here must be used in a public declaration.
public import os

public let resilientLogger = Logger(subsystem: "dev.isomer.tests", category: "library_evolution")
