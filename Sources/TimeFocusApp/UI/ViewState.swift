import SwiftUI

/// SwiftUI's `State` property wrapper, used as `@ViewState` instead of `@State`.
///
/// Since SDK 27, `@State` resolves to a SwiftUI macro whose compiler plugin (SwiftUIMacros) ships only with Xcode, not
/// with the Command Line Tools this project builds with. Going through an alias applies the property wrapper directly,
/// with the same runtime behaviour `@State` had before SDK 27.
typealias ViewState<Value> = SwiftUI.State<Value>
