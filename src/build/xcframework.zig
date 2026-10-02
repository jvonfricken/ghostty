/// Target for xcframework builds. This is a separate file so that
/// our runtime code doesn't need to import build code.
///
/// - native: the host's macOS architecture only.
/// - universal: macOS arm64+x86_64, iOS arm64, iOS Simulator arm64.
/// - @"native-ios": the native macOS slice (identical to `native`) plus the
///   iOS and iOS Simulator slices, for apps that ship a Mac app built from
///   `native` and add an iOS app beside it.
pub const Target = enum { native, universal, @"native-ios" };
