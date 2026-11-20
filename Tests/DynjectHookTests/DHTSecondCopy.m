// A second copy of DynjectHook inside the test bundle, standing in for a second
// tweak in the same process: its own registry and its own registry lock.
//
// Both copies end up in one linked image here, so this copy's external symbols
// get a DHT2_ prefix (in a real process each copy lives in its own dylib and
// the hidden symbols never meet). Tests that drive it declare the DHT2_
// functions they call themselves; see DHTTwoCopyTests.m.
#define DHSetLogSubsystem DHT2_DHSetLogSubsystem
#define DHLogFormat DHT2_DHLogFormat
#define DHGroupCreate DHT2_DHGroupCreate
#define DHGroupSetEnabled DHT2_DHGroupSetEnabled
#define DHGroupIsEnabled DHT2_DHGroupIsEnabled
#define DHHookMessage DHT2_DHHookMessage
#define DHHookMessageEx DHT2_DHHookMessageEx
#define DHOriginal DHT2_DHOriginal
#define DHHookIsActive DHT2_DHHookIsActive
#define DHHookClass DHT2_DHHookClass
#define DHOriginalForSource DHT2_DHOriginalForSource
#define DHClass DHT2_DHClass
#define DHSwiftClass DHT2_DHSwiftClass
#define DHFindClassWithSuffix DHT2_DHFindClassWithSuffix
#define DHWhenClassLoads DHT2_DHWhenClassLoads
#define DHCheckPendingClasses DHT2_DHCheckPendingClasses
#define DHShouldLoad DHT2_DHShouldLoad
#define DHSetPreferencesDomainForTesting DHT2_DHSetPreferencesDomainForTesting
#define DHSetBundleIdentifierForTesting DHT2_DHSetBundleIdentifierForTesting
#define DHSystemVersionAtLeast DHT2_DHSystemVersionAtLeast
#define DHRequireSystemVersion DHT2_DHRequireSystemVersion
#define DHSetSystemVersionForTesting DHT2_DHSetSystemVersionForTesting
#include "../../TweakSDK/DynjectHook.m"
