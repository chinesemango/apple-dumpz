// victim.m - DART DMA Cross-Process PoC (victim side)
//
// Registers an XPC listener. Creates an IOSurface filled with 0xAA, binds a
// Metal texture with MTLTextureUsageShaderRead, applies VM_PROT_READ on its
// own mapping, and runs a compute shader in a loop printing the observed
// red channel value.
//
// When an XPC client connects, victim sends the IOSurface mach port over
// the XPC message. Attacker is then expected to DMA-corrupt the surface.
//
// Expected behavior BEFORE fix: observed red channel flips from 0xAA to 0x41.
//
// Build:
//   clang -fobjc-arc -framework Foundation -framework Metal \
//         -framework IOSurface -o victim victim.m

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <IOSurface/IOSurfaceRef.h>
#import <xpc/xpc.h>
#import <mach/mach.h>
#import <mach/vm_prot.h>
#import <sys/mman.h>

#define SURF_W 64
#define SURF_H 64
#define MACH_SERVICE_NAME "lol.apple.dart-victim"

static IOSurfaceRef g_surface = NULL;
static id<MTLDevice> g_device = nil;
static id<MTLCommandQueue> g_queue = nil;
static id<MTLComputePipelineState> g_pipeline = nil;
static id<MTLTexture> g_texture = nil;
static id<MTLBuffer> g_outbuf = nil;

// Trivial compute shader: read texture(0,0), store red channel as uint into buffer[0].
static NSString *kShaderSrc =
    @"#include <metal_stdlib>\n"
    @"using namespace metal;\n"
    @"kernel void read_red(texture2d<float, access::read> tex [[texture(0)]],\n"
    @"                     device uint *out [[buffer(0)]],\n"
    @"                     uint2 gid [[thread_position_in_grid]]) {\n"
    @"    if (gid.x == 0 && gid.y == 0) {\n"
    @"        float4 px = tex.read(uint2(0,0));\n"
    @"        out[0] = (uint)(px.r * 255.0f);\n"
    @"    }\n"
    @"}\n";

static IOSurfaceRef create_surface_filled(uint32_t fill) {
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

static BOOL setup_metal_pipeline(void) {
    g_device = MTLCreateSystemDefaultDevice();
    if (!g_device) { fprintf(stderr, "[victim] no Metal device\n"); return NO; }
    g_queue = [g_device newCommandQueue];

    NSError *err = nil;
    id<MTLLibrary> lib = [g_device newLibraryWithSource:kShaderSrc options:nil error:&err];
    if (!lib) { fprintf(stderr, "[victim] shader compile failed: %s\n",
                        err.localizedDescription.UTF8String); return NO; }
    id<MTLFunction> fn = [lib newFunctionWithName:@"read_red"];
    g_pipeline = [g_device newComputePipelineStateWithFunction:fn error:&err];
    if (!g_pipeline) { fprintf(stderr, "[victim] pipeline failed\n"); return NO; }

    g_outbuf = [g_device newBufferWithLength:sizeof(uint32_t)
                                     options:MTLResourceStorageModeShared];

    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:SURF_W
                                    height:SURF_H
                                 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;

    g_texture = [g_device newTextureWithDescriptor:td
                                         iosurface:g_surface
                                             plane:0];
    if (!g_texture) { fprintf(stderr, "[victim] MTLTexture bind failed\n"); return NO; }
    return YES;
}

static uint32_t run_shader_once(void) {
    id<MTLCommandBuffer> cb = [g_queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:g_pipeline];
    [enc setTexture:g_texture atIndex:0];
    [enc setBuffer:g_outbuf offset:0 atIndex:0];
    MTLSize grid = MTLSizeMake(1, 1, 1);
    MTLSize tg = MTLSizeMake(1, 1, 1);
    [enc dispatchThreads:grid threadsPerThreadgroup:tg];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    uint32_t *p = (uint32_t *)g_outbuf.contents;
    return p[0];
}

static void apply_vm_prot_read(void) {
    void *base = IOSurfaceGetBaseAddress(g_surface);
    size_t len = IOSurfaceGetAllocSize(g_surface);
    mach_vm_address_t addr = (mach_vm_address_t)base;
    kern_return_t kr = mach_vm_protect(mach_task_self(), addr, len, FALSE, VM_PROT_READ);
    fprintf(stderr, "[victim] mach_vm_protect(VM_PROT_READ) kr=0x%x len=%zu\n", kr, len);
}

static void handle_connection(xpc_connection_t peer) {
    xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
        xpc_type_t t = xpc_get_type(event);
        if (t == XPC_TYPE_ERROR) return;
        if (t != XPC_TYPE_DICTIONARY) return;

        const char *op = xpc_dictionary_get_string(event, "op");
        if (!op) return;

        if (strcmp(op, "get_surface") == 0) {
            // Send the IOSurface mach port back to the attacker.
            mach_port_t port = IOSurfaceCreateMachPort(g_surface);
            xpc_object_t reply = xpc_dictionary_create_reply(event);
            xpc_dictionary_set_mach_send(reply, "surface_port", port);
            xpc_connection_send_message(peer, reply);
            fprintf(stderr, "[victim] handed IOSurface mach port to attacker\n");
            // Do not deallocate the port here - IOSurface retains the right.
        }
    });
    xpc_connection_resume(peer);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        fprintf(stderr, "[victim] pid=%d starting\n", getpid());

        g_surface = create_surface_filled(0xAAAAAAAA);
        if (!g_surface) { fprintf(stderr, "[victim] IOSurfaceCreate failed\n"); return 1; }
        fprintf(stderr, "[victim] created IOSurface filled with 0xAAAAAAAA\n");

        if (!setup_metal_pipeline()) return 1;
        fprintf(stderr, "[victim] Metal pipeline ready, texture bound ShaderRead\n");

        uint32_t before = run_shader_once();
        fprintf(stderr, "[victim] PRE-attack shader red = 0x%02x (expect 0xaa)\n", before);

        apply_vm_prot_read();

        // Register the XPC mach service.
        xpc_connection_t listener = xpc_connection_create_mach_service(
            MACH_SERVICE_NAME, NULL,
            XPC_CONNECTION_MACH_SERVICE_LISTENER);
        xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
            if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) {
                handle_connection((xpc_connection_t)peer);
            }
        });
        xpc_connection_resume(listener);
        fprintf(stderr, "[victim] XPC listener registered on %s\n", MACH_SERVICE_NAME);

        // Poll loop: every 200ms, run shader and print red channel.
        fprintf(stderr, "[victim] polling GPU shader output every 200ms...\n");
        fprintf(stderr, "[victim] === WATCH FOR RED CHANNEL TO FLIP FROM 0xaa to 0x41 ===\n");
        int iter = 0;
        while (1) {
            uint32_t r = run_shader_once();
            fprintf(stderr, "[victim] iter=%d shader red = 0x%02x %s\n",
                    iter++, r,
                    (r == 0x41) ? "<<< CORRUPTED BY ATTACKER DMA"
                                : (r == 0xAA ? "(clean)" : "(?)"));
            usleep(200000);
        }
    }
    return 0;
}
