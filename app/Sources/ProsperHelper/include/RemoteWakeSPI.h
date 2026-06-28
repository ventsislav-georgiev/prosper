// Surfaces the IOPMConnection dark-wake observer SPI to Swift. These symbols are
// EXPORTED from IOKit.framework but declared only in IOPMLibPrivate.h (not shipped
// in the SDK), so we re-declare the stable prototypes here and link normally — the
// linker resolves them exactly like the public IOPMSchedulePowerEvent. Passes
// notarization: the notary checks Dev ID + hardened runtime + timestamp, not which
// API symbols a binary references. Needs NO private entitlement.
//
// Scheduling (IOPMSchedulePowerEvent / Cancel / CopyScheduledPowerEvents) and the
// assertion API (IOPMAssertionDeclareUserActivity, kIOPMAssertionTypePreventSystemSleep)
// ARE public — they come in via IOPMLib.h below. Only the IOPMConnection observer
// family is SPI. Validated end-to-end in the overnight feasibility spike.
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>

// --- SPI from IOPMLibPrivate.h (re-declared) ---
typedef const struct __IOPMConnection *IOPMConnection;
typedef uint32_t IOPMConnectionMessageToken;
typedef uint32_t IOPMCapabilityBits;

// Capability bits delivered in the handler's eventDescriptor.
enum {
  kIOPMCapabilityCPU     = (1 << 0),
  kIOPMCapabilityVideo   = (1 << 1),
  kIOPMCapabilityAudio   = (1 << 2),
  kIOPMCapabilityNetwork = (1 << 3),
  kIOPMCapabilityDisk    = (1 << 4),
};

typedef void (*IOPMEventHandlerType)(void *param,
                                     IOPMConnection connection,
                                     IOPMConnectionMessageToken token,
                                     IOPMCapabilityBits eventDescriptor);

IOReturn IOPMConnectionCreate(CFStringRef myName, IOPMCapabilityBits interests,
                              IOPMConnection *newConnection);
IOReturn IOPMConnectionSetNotification(IOPMConnection myConnection, void *param,
                                       IOPMEventHandlerType handler);
IOReturn IOPMConnectionScheduleWithRunLoop(IOPMConnection myConnection,
                                           CFRunLoopRef theRunLoop,
                                           CFStringRef runLoopMode);
IOReturn IOPMConnectionAcknowledgeEvent(IOPMConnection myConnection,
                                        IOPMConnectionMessageToken token);
