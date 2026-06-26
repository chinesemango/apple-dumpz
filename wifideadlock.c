#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <mach/mach.h>
#include <signal.h>
#include <sys/time.h>
#include <stdatomic.h>

static volatile sig_atomic_t g_stop = 0;
static _Atomic uint64_t g_opens = 0, g_calls = 0, g_crashes = 0;

#define MAX_HELD 2048
static io_connect_t g_held[MAX_HELD];
static _Atomic int g_held_count = 0;
static pthread_mutex_t g_held_lock = PTHREAD_MUTEX_INITIALIZER;

static void handle_sig(int s) { (void)s; g_stop = 1; }

static double now_sec(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

/* ==================== FAST & AGGRESSIVE OPENER ==================== */
static void* opener_thread(void *arg) {
    (void)arg;
    const char *classes[] = {"IOUserService", "IOUserClient", "IO80211", NULL};

    while (!g_stop) {
        for (int c = 0; classes[c] && !g_stop; c++) {
            io_iterator_t iter = IO_OBJECT_NULL;
            if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(classes[c]), &iter) != KERN_SUCCESS)
                continue;

            io_service_t svc;
            while ((svc = IOIteratorNext(iter)) && !g_stop) {
                io_name_t name = {0};
                IORegistryEntryGetName(svc, name);

                // Try many connection types quickly
                for (uint32_t type = 0; type <= 96; type++) {
                    io_connect_t conn = IO_OBJECT_NULL;
                    atomic_fetch_add(&g_opens, 1);

                    if (IOServiceOpen(svc, mach_task_self(), type, &conn) == KERN_SUCCESS && conn) {
                        pthread_mutex_lock(&g_held_lock);
                        if (g_held_count < MAX_HELD) {
                            g_held[g_held_count++] = conn;
                        } else {
                            IOServiceClose(conn);  // pool full
                        }
                        pthread_mutex_unlock(&g_held_lock);
                    }
                }
                IOObjectRelease(svc);
            }
            IOObjectRelease(iter);
        }
        usleep(5);        // almost no delay = maximum open rate
    }
    return NULL;
}

/* ==================== NUCLEAR COLLISION HAMMER ==================== */
static void* hammer_thread(void *arg) {
    (void)arg;
    uint64_t scalars[128];
    uint8_t buf[131072];
    uint32_t outc;
    size_t outsz;

    while (!g_stop) {
        pthread_mutex_lock(&g_held_lock);
        int count = g_held_count;
        io_connect_t local[MAX_HELD];
        if (count > 0)
            memcpy(local, g_held, count * sizeof(io_connect_t));
        pthread_mutex_unlock(&g_held_lock);

        if (count == 0) {
            usleep(100);
            continue;
        }

        for (int i = 0; i < count && !g_stop; i++) {
            for (uint32_t sel = 0; sel < 1024; sel += 1) {   // massive range
                outc = 128;
                outsz = sizeof(buf);

                // Create collisions and corruption attempts
                IOConnectCallMethod(local[i], sel, NULL, 0, NULL, 0, scalars, &outc, buf, &outsz);
                IOConnectCallScalarMethod(local[i], sel, NULL, 0, scalars, &outc);
                IOConnectCallStructMethod(local[i], sel, buf, 8192, buf, &outsz);
                IOConnectTrap0(local[i], sel);
                IOConnectTrap6(local[i], sel, 0xdeadbeef, 0xcafebabe, 0xf00d1337, sel, 0x11223344, 0x55667788);

                atomic_fetch_add(&g_calls, 1);
            }
        }
    }
    return NULL;
}

/* ==================== EXTREME CHURN (for race conditions) ==================== */
static void* churn_thread(void *arg) {
    (void)arg;
    while (!g_stop) {
        io_iterator_t iter = IO_OBJECT_NULL;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUserService"), &iter) == KERN_SUCCESS) {
            io_service_t svc;
            while ((svc = IOIteratorNext(iter)) && !g_stop) {
                for (uint32_t type = 0; type <= 64; type++) {
                    io_connect_t conn = IO_OBJECT_NULL;
                    atomic_fetch_add(&g_opens, 1);
                    if (IOServiceOpen(svc, mach_task_self(), type, &conn) == KERN_SUCCESS) {
                        // Immediate close to create races
                        IOServiceClose(conn);
                    }
                }
                IOObjectRelease(svc);
            }
            IOObjectRelease(iter);
        }
        usleep(10);
    }
    return NULL;
}

static int check_driver_alive(void) {
    io_iterator_t iter = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUserService"), &iter) != KERN_SUCCESS || !iter)
        return 0;

    int count = 0;
    io_service_t svc;
    while ((svc = IOIteratorNext(iter))) {
        io_name_t name = {0};
        IORegistryEntryGetName(svc, name);
        if (strcasestr(name, "WLAN") || strcasestr(name, "BCM") || strcasestr(name, "802"))
            count++;
        IOObjectRelease(svc);
    }
    IOObjectRelease(iter);
    return count;
}

static void cleanup_held(void) {
    pthread_mutex_lock(&g_held_lock);
    for (int i = 0; i < g_held_count; i++)
        if (g_held[i]) IOServiceClose(g_held[i]);
    g_held_count = 0;
    pthread_mutex_unlock(&g_held_lock);
}

int main(int argc, char **argv) {
    signal(SIGINT, handle_sig);
    signal(SIGTERM, handle_sig);

    int duration = argc > 1 ? atoi(argv[1]) : 40;

    printf("\033[1;31m=== ChineseMango ULTIMATE 2026 - MAXIMUM COLLISION MODE ===\033[0m\n");
    printf("Strategy: Mass open + immediate churn + huge selector spam\n\n");

    // Launch threads BEFORE any forking
    #define N_OPENERS 12
    #define N_HAMMERS 96
    #define N_CHURNS  24

    pthread_t threads[N_OPENERS + N_HAMMERS + N_CHURNS];
    int t = 0;

    for (int i = 0; i < N_OPENERS; i++) pthread_create(&threads[t++], NULL, opener_thread, NULL);
    for (int i = 0; i < N_HAMMERS; i++) pthread_create(&threads[t++], NULL, hammer_thread, NULL);
    for (int i = 0; i < N_CHURNS;  i++) pthread_create(&threads[t++], NULL, churn_thread, NULL);

    double start = now_sec();
    int last_alive = check_driver_alive();
    uint64_t last_opens = 0, stall = 0;

    while (!g_stop && (now_sec() - start < duration)) {
        sleep(1);
        uint64_t opens = atomic_load(&g_opens);
        uint64_t calls = atomic_load(&g_calls);
        int held = atomic_load(&g_held_count);
        int alive = check_driver_alive();

        printf(" [%3.0fs] opens=%llu calls=%llu held=%d alive=%d", now_sec()-start, opens, calls, held, alive);

        if (opens == last_opens && opens > 1000) {
            stall++;
            printf(" \033[31m<< STALL %llu\033[0m", stall);
            if (stall >= 5 && alive == 0) {
                printf("\n\n\033[1;31m[!!! WIFI DRIVER DEADLOCK / CRASH !!!]\033[0m\n");
                atomic_fetch_add(&g_crashes, 1);
            }
        } else {
            stall = 0;
        }
        printf("\n");

        last_opens = opens;
        last_alive = alive;
    }

    g_stop = 1;
    for (int i = 0; i < t; i++)
        pthread_join(threads[i], NULL);

    cleanup_held();

    printf("\n=== FINAL RESULTS ===\n");
    printf("Crashes: %llu\n", atomic_load(&g_crashes));
    printf("Opens  : %llu\n", atomic_load(&g_opens));
    printf("Calls  : %llu\n", atomic_load(&g_calls));

    return 0;
}
