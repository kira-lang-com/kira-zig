pub const LogLevel = enum {
    debug,
    info,
    warning,
    @"error",
};

pub const LogField = struct {
    key: []const u8,
    value: []const u8,
};

pub const LogEntry = struct {
    level: LogLevel,
    scope: []const u8,
    event: []const u8,
    message: []const u8,
    fields: []const LogField = &.{},
};
