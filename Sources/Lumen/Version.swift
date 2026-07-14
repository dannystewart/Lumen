/// The current version of the Lumen server.
///
/// Follow semantic versioning when incrementing:
/// - **Major**: breaking API changes (endpoint removed/renamed, request/response shape changed)
/// - **Minor**: new endpoints or backward-compatible features
/// - **Patch**: bug fixes with no API surface changes
///
/// Prism enforces a minimum compatible version and will flag nodes running an older release.
let lumenVersion = "0.3.1"
