// Compiles DynjectHook.m into the test bundle itself, the way a tweak compiles it
// into its own dylib.
//
// Why: every DynjectHook symbol has hidden visibility (DH_HIDDEN). SwiftPM
// prelinks each library target into a single object with `ld -r`, which turns
// hidden ("private external") symbols into local ones, so the test bundle cannot
// link against the DynjectTweakSDK target's copy (undefined _DHHookMessage, ...).
// The DynjectTweakSDK copy stays local to its prelinked object, so the two copies
// do not collide. If DynjectHook's symbols are ever made linkable from the
// DynjectTweakSDK target (not hidden), delete this file to avoid duplicates.
#include "../../TweakSDK/DynjectHook.m"
