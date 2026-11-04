// `import os`, as on Apple platforms, where the os module re-exports OSLog
// (Logger and its kin): Isomer's OSLog (frameworks/os_log), re-exported.
// Nothing else of Apple's os (activities, signposts, `os_unfair_lock`).

@_exported import OSLog
