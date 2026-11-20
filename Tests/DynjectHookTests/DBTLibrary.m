// Compiles DynjectBridge.m into the test bundle itself, the way a tweak compiles it into its own dylib. Same reason
// as DHTLibrary.m: its symbols are hidden, so the DynjectTweakSDK target's prelinked copy can't be linked against.
#include "../../TweakSDK/DynjectBridge.m"
