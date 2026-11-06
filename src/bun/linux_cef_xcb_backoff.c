#define _GNU_SOURCE

#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

/*
 * Electrobun 1.18.1's Linux CEF integration can repeatedly poll unanswered
 * XCB replies and empty queued-event sets from the GTK main thread without
 * yielding. Keep ready replies/events untouched. Reply misses retain the
 * established adaptive delay; queued-event misses use half that delay after
 * 64 consecutive empty polls, preserving input latency while bounding the
 * settled CEF loop. WIZP_CEF_XCB_BACKOFF_US=0 disables both.
 */

typedef struct xcb_connection_t xcb_connection_t;
typedef struct xcb_generic_error_t xcb_generic_error_t;
typedef struct xcb_generic_event_t xcb_generic_event_t;

typedef int (*xcb_poll_for_reply_fn)(
    xcb_connection_t *, unsigned int, void **, xcb_generic_error_t **);
typedef int (*xcb_poll_for_reply64_fn)(
    xcb_connection_t *, uint64_t, void **, xcb_generic_error_t **);
typedef xcb_generic_event_t *(*xcb_poll_for_event_fn)(xcb_connection_t *);

static pthread_t process_main_thread;
static long backoff_nanoseconds = 1000000L;
static __thread uint64_t consecutive_misses;
static __thread uint64_t consecutive_event_misses;

__attribute__((constructor)) static void initialize_backoff(void) {
    process_main_thread = pthread_self();
    const char *configured = getenv("WIZP_CEF_XCB_BACKOFF_US");
    if (configured == NULL || *configured == '\0') return;

    char *end = NULL;
    const long microseconds = strtol(configured, &end, 10);
    if (end != configured && *end == '\0' && microseconds >= 0 && microseconds <= 100000) {
        backoff_nanoseconds = microseconds * 1000L;
    }
}

static void apply_backoff(
    uint64_t request, int result, xcb_generic_error_t **error) {
    (void)request;
    if (!pthread_equal(pthread_self(), process_main_thread)) return;

    if (result != 0 || (error != NULL && *error != NULL)) {
        consecutive_misses = 0;
        return;
    }
    consecutive_misses += 1;
    if (backoff_nanoseconds <= 0 || consecutive_misses <= 64) return;

    const long delay_nanoseconds = consecutive_misses > 512
        ? (backoff_nanoseconds * 5) / 2
        : backoff_nanoseconds;
    const struct timespec delay = {
        .tv_sec = delay_nanoseconds / 1000000000L,
        .tv_nsec = delay_nanoseconds % 1000000000L,
    };
    nanosleep(&delay, NULL);
}
static void apply_event_backoff(int event_present) {
    if (!pthread_equal(pthread_self(), process_main_thread)) return;

    if (event_present) {
        consecutive_event_misses = 0;
        return;
    }
    consecutive_event_misses += 1;
    if (backoff_nanoseconds <= 0 || consecutive_event_misses <= 64) return;

    const long delay_nanoseconds = consecutive_event_misses > 512
        ? (backoff_nanoseconds * 5) / 4
        : backoff_nanoseconds / 2;
    const struct timespec delay = {
        .tv_sec = delay_nanoseconds / 1000000000L,
        .tv_nsec = delay_nanoseconds % 1000000000L,
    };
    nanosleep(&delay, NULL);
}


__attribute__((visibility("default"))) int xcb_poll_for_reply64(
    xcb_connection_t *connection,
    uint64_t request,
    void **reply,
    xcb_generic_error_t **error) {
    static xcb_poll_for_reply64_fn real_poll = NULL;
    if (real_poll == NULL) {
        real_poll = (xcb_poll_for_reply64_fn)dlsym(RTLD_NEXT, "xcb_poll_for_reply64");
    }
    if (real_poll == NULL) return 0;

    const int result = real_poll(connection, request, reply, error);
    apply_backoff(request, result, error);
    return result;
}

__attribute__((visibility("default"))) int xcb_poll_for_reply(
    xcb_connection_t *connection,
    unsigned int request,
    void **reply,
    xcb_generic_error_t **error) {
    static xcb_poll_for_reply_fn real_poll = NULL;
    if (real_poll == NULL) {
        real_poll = (xcb_poll_for_reply_fn)dlsym(RTLD_NEXT, "xcb_poll_for_reply");
    }
    if (real_poll == NULL) return 0;

    const int result = real_poll(connection, request, reply, error);
    apply_backoff(request, result, error);
    return result;
}

static xcb_generic_event_t *poll_for_event(
    xcb_connection_t *connection, xcb_poll_for_event_fn real_poll) {
    if (real_poll == NULL) return NULL;

    xcb_generic_event_t *event = real_poll(connection);
    apply_event_backoff(event != NULL);
    return event;
}

__attribute__((visibility("default"))) xcb_generic_event_t *xcb_poll_for_queued_event(
    xcb_connection_t *connection) {
    static xcb_poll_for_event_fn real_poll = NULL;
    if (real_poll == NULL) {
        real_poll = (xcb_poll_for_event_fn)dlsym(
            RTLD_NEXT, "xcb_poll_for_queued_event");
    }
    return poll_for_event(connection, real_poll);
}
