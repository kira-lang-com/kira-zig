pub const CommonError = error{
    InvalidManifest,
    ParseFailed,
    SemanticFailed,
    MissingMain,
    NotImplemented,
    UnsupportedTarget,
    RuntimeFailure,
};
