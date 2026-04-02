pub const LogLevel = enum {
    debug,
    info,
    warning,
    error,
};

pub const LogEntry = struct {
    level: LogLevel,
    scope: []const u8,
    message: []const u8,
};
