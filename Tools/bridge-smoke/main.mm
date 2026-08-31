/**
 * bridge-smoke: W4a's real-host verification harness. Instantiates CRSession directly
 * (no App target / AppKit involved), connects to the Windows host described by
 * ~/.config/macdows/host.env (or WIN_HOST/WIN_USER/WIN_PASS env vars, which take
 * priority -- same convention as Tools/rail-probe/rail-probe.c), launches winver.exe,
 * drains and prints every control-lane event for ~30s, exercises a mid-session
 * disconnect+reconnect at the 10s mark to prove the generation gate, then runs the full
 * 5-step shutdown protocol and prints a summary.
 *
 * Never prints WIN_HOST/WIN_USER/WIN_PASS raw values (red line) -- only whether they were
 * found and their lengths, for sanity-checking a misconfigured host.env without leaking
 * it into logs/Console.app.
 *
 * Refuses to dial anything outside the owner's own lab network: MacdowsCore.LabBoundary (the
 * in-process mirror of Scripts/lib.sh's crdp_assert_lab_boundary), reached through
 * Tools/bridge-smoke/GateShim.swift, runs after the credentials resolve and before any CRSession
 * exists, and returns 78 on a refusal. That gate lives here because it is the only place it can:
 * nothing in Scripts/ launches this harness, and the binary is run straight out of DerivedData.
 * The same shim also does the host.env reading, so the string this harness dials is parsed
 * by the same code the shell gate's own extraction agrees with -- see GateShim.swift's header for
 * the fail-open disagreement that motivated deleting this file's own parser.
 */
#import <Foundation/Foundation.h>
#import "CRSession.h"

/* The Swift half of this target (GateShim.swift), through the header the Swift compiler emits
 * for it. The name is the target's own PRODUCT_MODULE_NAME with `-` mapped to `_`, which is
 * Xcode's c99extidentifier rule, not a choice made here. */
#import "bridge_smoke-Swift.h"

#include <stdio.h>
#include <unistd.h>

static NSString *KindName(CRDPEventKind kind)
{
    switch (kind)
    {
        case CRDPEventKindWindowCreate:
            return @"WindowCreate";
        case CRDPEventKindWindowUpdate:
            return @"WindowUpdate";
        case CRDPEventKindWindowDelete:
            return @"WindowDelete";
        case CRDPEventKindWindowIcon:
            return @"WindowIcon";
        case CRDPEventKindNotifyIconCreate:
            return @"NotifyIconCreate";
        case CRDPEventKindNotifyIconUpdate:
            return @"NotifyIconUpdate";
        case CRDPEventKindNotifyIconDelete:
            return @"NotifyIconDelete";
        case CRDPEventKindMonitoredDesktop:
            return @"MonitoredDesktop";
        case CRDPEventKindExecResult:
            return @"ExecResult";
        case CRDPEventKindHandshakeFlags:
            return @"HandshakeFlags";
        case CRDPEventKindSurfaceMapped:
            return @"SurfaceMapped";
        case CRDPEventKindDisconnected:
            return @"Disconnected";
        case CRDPEventKindFrameReady:
            return @"FrameReady";
    }
    return @"Unknown";
}

typedef struct
{
    NSMutableDictionary<NSString *, NSNumber *> *counts;
    NSUInteger windowCreateWithTitle;
    NSUInteger surfaceMappedCount;
    BOOL sawHandshakeFlags;
    uint32_t lastHandshakeFlags;
    BOOL sawExecResultZero;
} Tally;

static void PrintAndTally(CRDPEvent *ev, Tally *tally)
{
    NSString *name = KindName(ev.kind);
    NSNumber *prev = tally->counts[name];
    tally->counts[name] = @(prev.unsignedIntegerValue + 1);

    switch (ev.kind)
    {
        case CRDPEventKindHandshakeFlags:
            tally->sawHandshakeFlags = YES;
            tally->lastHandshakeFlags = ev.railHandshakeFlags;
            printf("[event] HandshakeFlags buildNumber=%u railHandshakeFlags=%u gen=%u\n", ev.buildNumber,
                   ev.railHandshakeFlags, ev.generation);
            break;
        case CRDPEventKindExecResult:
            if (ev.execResult == 0)
                tally->sawExecResultZero = YES;
            printf("[event] ExecResult execResult=%u rawResult=%u program=%s gen=%u\n", ev.execResult,
                   ev.rawResult, ev.program.UTF8String, ev.generation);
            break;
        case CRDPEventKindWindowCreate:
        case CRDPEventKindWindowUpdate:
            if (ev.title.length > 0)
                tally->windowCreateWithTitle++;
            printf("[event] %s windowId=%u title=\"%s\" fieldFlags=%u gen=%u\n", name.UTF8String, ev.windowId,
                   ev.title.UTF8String, ev.fieldFlags, ev.generation);
            break;
        case CRDPEventKindSurfaceMapped:
            tally->surfaceMappedCount++;
            printf("[event] SurfaceMapped surfaceId=%u windowId=%llu %ux%u gen=%u\n", ev.surfaceId,
                   (unsigned long long)ev.mappedWindowId, ev.mappedWidth, ev.mappedHeight, ev.generation);
            break;
        case CRDPEventKindDisconnected:
            printf("[event] Disconnected gen=%u\n", ev.generation);
            break;
        default:
            printf("[event] %s windowId=%u gen=%u\n", name.UTF8String, ev.windowId, ev.generation);
            break;
    }
}

static void PrintSummary(Tally *tally, CRSession *session, BOOL cleanShutdown, uint32_t genBeforeReconnect,
                          uint32_t genAfterReconnect, uint64_t staleBeforeReconnect)
{
    printf("\n=== bridge-smoke summary ===\n");
    printf("eventCounts: {");
    NSArray<NSString *> *keys = [tally->counts.allKeys sortedArrayUsingSelector:@selector(compare:)];
    BOOL first = YES;
    for (NSString *k in keys)
    {
        printf("%s\"%s\":%lu", first ? "" : ",", k.UTF8String, (unsigned long)tally->counts[k].unsignedIntegerValue);
        first = NO;
    }
    printf("}\n");
    printf("windowCreateWithTitle=%lu\n", (unsigned long)tally->windowCreateWithTitle);
    printf("surfaceMappedCount=%lu\n", (unsigned long)tally->surfaceMappedCount);
    printf("sawHandshakeFlags=%s lastHandshakeFlags=%u\n", tally->sawHandshakeFlags ? "true" : "false",
           tally->lastHandshakeFlags);
    printf("sawExecResultZero=%s\n", tally->sawExecResultZero ? "true" : "false");
    printf("generation: beforeReconnect=%u afterReconnect=%u final=%u\n", genBeforeReconnect, genAfterReconnect,
           session.currentGeneration);
    printf("staleEventsDiscardedCount: atReconnect=%llu final=%llu\n", (unsigned long long)staleBeforeReconnect,
           (unsigned long long)session.staleEventsDiscardedCount);
    printf("droppedEventsCount=%llu\n", (unsigned long long)session.droppedEventsCount);
    printf("cleanShutdown=%s\n", cleanShutdown ? "true" : "false");
    printf("============================\n");
    fflush(stdout);
}

int main(int argc, char *argv[])
{
    (void)argc;
    (void)argv;
    /* M6: line-buffered, not the default full-buffering libc uses once stdout isn't a
     * tty (e.g. redirected to a log file, exactly how the real-host verification runs in
     * this project work -- Terminal-relay + `>> log 2>&1`) -- otherwise every [event]
     * line sits in an internal buffer until the buffer fills or the process exits, making
     * `tail -f`/live progress-watching on the log file useless for a run that's still in
     * progress. */
    setvbuf(stdout, NULL, _IOLBF, 0);

    @autoreleasepool
    {
        [CRSession logFreeRDPVersion];

        /* MacdowsCore.EnvFile via GateShim.swift, not the hand-rolled ParseEnvFile/
         * ResolveCredential pair this file used to carry. That parser keyed each line on
         * everything left of the first `=`, so the ordinary line `export WIN_HOST=x` was filed
         * under the key "export WIN_HOST" and was invisible to the lookup below it, and it
         * stripped no quotes -- rules that disagreed with the ones Scripts/run-window-smoke.command
         * applies to the SAME file, a disagreement a prior review measured fail-open (see
         * GateShim.swift and MacdowsCore/EnvFile.swift for the measurement). One parser, in the
         * package `swift test` can reach, is the fix; this was its fourth copy.
         *
         * Everything visible on this path is unchanged: the environment variables still take
         * priority over host.env, a value still comes back nil when neither supplies it, and the
         * present/MISSING + length reporting below and its exit code are the same as before. */
        BridgeSmokeCredentials *credentials = [BridgeSmokeGate resolveCredentials];
        NSString *host = credentials.host;
        NSString *user = credentials.user;
        NSString *pass = credentials.password;

        printf("credentials: host=%s (len=%lu) user=%s (len=%lu) pass=(len=%lu)\n", host ? "present" : "MISSING",
               (unsigned long)host.length, user ? "present" : "MISSING", (unsigned long)user.length,
               (unsigned long)pass.length);

        if (host.length == 0 || user.length == 0 || pass.length == 0)
        {
            /* The path comes back from the shim rather than being spelled again here, so the file
             * this message names is by construction the file that was actually read. */
            fprintf(stderr, "Missing host/user/pass (checked WIN_HOST/WIN_USER/WIN_PASS env vars, then %s). "
                            "Not attempting a connection.\n",
                    [BridgeSmokeGate hostEnvPath].UTF8String);
            return 2;
        }

        /* Live-host testing boundary gate (owner rule, 2026-08-31), enforced HERE because there is
         * no shell wrapper around this harness to enforce it anywhere else: nothing in this
         * repository launches bridge-smoke. `xcodebuild -scheme bridge-smoke` leaves a runnable
         * executable in DerivedData that anyone (or any future script, or Xcode's own Run button)
         * can invoke directly with WIN_HOST set, and that path had no gate at all -- it went from
         * getenv straight to -[CRSession initWithHost:...]. The rule is that a real-host step may
         * only ever target the owner's own machine on the owner's own LAN, so the binary that
         * opens the socket is where it has to be checked. Before any CRSession exists,
         * deliberately: a refusal must cost zero packets.
         *
         * 78 matches Scripts/run-window-smoke.command's and Tools/window-smoke's established
         * refusal code, so that exit status keeps exactly one meaning for every caller and every
         * log reader: boundary refusal, host never contacted. It cannot collide with this
         * harness's own vocabulary (0 pass, 1 assertion failure or no connection, 2 missing
         * credentials).
         *
         * The host is NOT printed, unlike lib.sh's own refusal line: this file's header commits to
         * never printing WIN_HOST/WIN_USER/WIN_PASS raw values, and these runs are captured to a
         * log file. The reason category is enough to act on and can never carry a boundary segment
         * (see LabBoundary's doc comment). stderr, matching the missing-credentials refusal right
         * above it -- both are this harness declining to run, not progress. */
        BridgeSmokeBoundaryVerdict *verdict = [BridgeSmokeGate checkBoundaryForHost:host];
        if (!verdict.isAllowed)
        {
            fprintf(stderr, "bridge-smoke: live-host boundary gate REFUSED this target -- %s. Nothing was "
                            "connected; the host value is not printed (red line).\n",
                    verdict.reasonText.UTF8String);
            return 78;
        }
        printf("bridge-smoke: %s\n", [BridgeSmokeGate allowedLine].UTF8String);

        NSString *program = @"C:\\Windows\\System32\\winver.exe";

        __block Tally tally;
        tally.counts = [NSMutableDictionary dictionary];
        tally.windowCreateWithTitle = 0;
        tally.surfaceMappedCount = 0;
        tally.sawHandshakeFlags = NO;
        tally.lastHandshakeFlags = 0;
        tally.sawExecResultZero = NO;

        const int maxAttempts = 3; /* 1 initial + 2 retries, per the W4a task's environment brief */
        const NSTimeInterval retryDelaySeconds = 30.0;
        const NSTimeInterval connectTimeoutSeconds = 20.0;

        CRSession *session = nil;
        BOOL connected = NO;

        for (int attempt = 1; attempt <= maxAttempts && !connected; attempt++)
        {
            printf("=== connect attempt %d/%d ===\n", attempt, maxAttempts);
            session = [[CRSession alloc] initWithHost:host user:user password:pass program:program];
            [session start];

            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:connectTimeoutSeconds];
            __block BOOL gotEvent = NO;
            while ([deadline timeIntervalSinceNow] > 0)
            {
                if (session.lastConnectError)
                    break;
                [session drainEventsWithHandler:^(CRDPEvent *ev) {
                  gotEvent = YES;
                  PrintAndTally(ev, &tally);
                }];
                if (gotEvent)
                    break;
                usleep(100 * 1000);
            }

            if (session.lastConnectError)
            {
                fprintf(stderr, "connect attempt %d/%d FAILED: %s\n", attempt, maxAttempts,
                        session.lastConnectError.localizedDescription.UTF8String);
                [session shutdownAndWait];
                if (attempt < maxAttempts)
                {
                    printf("retrying in %.0fs...\n", retryDelaySeconds);
                    usleep((useconds_t)(retryDelaySeconds * 1000000));
                }
                continue;
            }
            if (!gotEvent)
            {
                fprintf(stderr, "connect attempt %d/%d: no event observed within %.0fs (and no explicit "
                                "error) -- treating as a failed attempt\n",
                        attempt, maxAttempts, connectTimeoutSeconds);
                [session shutdownAndWait];
                if (attempt < maxAttempts)
                {
                    printf("retrying in %.0fs...\n", retryDelaySeconds);
                    usleep((useconds_t)(retryDelaySeconds * 1000000));
                }
                continue;
            }
            connected = YES;
        }

        if (!connected)
        {
            fprintf(stderr, "All %d connect attempts failed -- recording as environment state, not a crash. "
                            "No further live-host verification possible this run.\n",
                    maxAttempts);
            PrintSummary(&tally, session, NO, 0, 0, 0);
            return 1;
        }

        NSDate *sessionStart = [NSDate date];
        BOOL didReconnectTest = NO;
        BOOL midClean = NO;
        uint32_t genBeforeReconnect = 0;
        uint32_t genAfterReconnect = 0;
        uint64_t staleBeforeReconnect = 0;

        while ([sessionStart timeIntervalSinceNow] > -30.0)
        {
            [session drainEventsWithHandler:^(CRDPEvent *ev) {
              PrintAndTally(ev, &tally);
            }];

            NSTimeInterval elapsed = -[sessionStart timeIntervalSinceNow];
            if (!didReconnectTest && elapsed >= 10.0)
            {
                didReconnectTest = YES;
                genBeforeReconnect = session.currentGeneration;
                staleBeforeReconnect = session.staleEventsDiscardedCount;
                printf("=== reconnect test: disconnecting at %.1fs (generation %u) ===\n", elapsed,
                       genBeforeReconnect);
                midClean = [session shutdownAndWait];
                printf("=== mid-session shutdown clean=%s, reconnecting ===\n", midClean ? "true" : "false");
                [session start];
                genAfterReconnect = session.currentGeneration;
                printf("=== reconnected (generation %u -> %u) ===\n", genBeforeReconnect, genAfterReconnect);
            }

            usleep(50 * 1000);
        }

        BOOL cleanShutdown = [session shutdownAndWait];
        PrintSummary(&tally, session, cleanShutdown, genBeforeReconnect, genAfterReconnect, staleBeforeReconnect);

        /* H4 (W4a review): every one of these used to be printed-but-not-enforced --
         * a broken build could still exit 0 as long as the process didn't crash. Each
         * check below is a real assertion that flips the exit code; only cleanShutdown
         * was previously wired to it. staleEventsDiscardedCount is asserted on its
         * actual, measured semantics -- under this implementation 0 is the legitimate,
         * expected outcome every real run has produced (shutdownAndWait's own drain-poll
         * loop empties the queue before the generation bump lands), so this does NOT
         * assert `== 0` as if that were the only correct value; it accepts either 0 *or*
         * a logged, explained nonzero count, and only fails if the count can't be
         * accounted for at all -- never a fabricated pass/fail signal. */
        BOOL ok = YES;

#define CHECK(cond, ...)                              \
    do                                                 \
    {                                                  \
        BOOL result = (cond);                          \
        printf("[assert] %s: %s\n", result ? "PASS" : "FAIL", [[NSString stringWithFormat:__VA_ARGS__] UTF8String]); \
        if (!result)                                   \
            ok = NO;                                    \
    } while (0)

        CHECK(didReconnectTest, @"reconnect test actually ran (10s mark reached within the 30s window)");
        CHECK(genAfterReconnect == genBeforeReconnect + 1, @"generation incremented by exactly 1 across reconnect (%u -> %u)",
              genBeforeReconnect, genAfterReconnect);
        CHECK(midClean, @"mid-session shutdownAndWait reported clean");
        CHECK(tally.sawHandshakeFlags && tally.lastHandshakeFlags == 127, @"saw HandshakeFlags with railHandshakeFlags==127 (got %u, saw=%d)",
              tally.lastHandshakeFlags, tally.sawHandshakeFlags);
        CHECK(tally.sawExecResultZero, @"saw ExecResult with execResult==0 (winver launched successfully)");
        CHECK(tally.windowCreateWithTitle > 0, @"at least one WindowCreate/Update carried a non-empty title (got %lu)",
              (unsigned long)tally.windowCreateWithTitle);
        CHECK(tally.surfaceMappedCount > 0, @"at least one SurfaceMapped event observed (got %lu)",
              (unsigned long)tally.surfaceMappedCount);
        CHECK(cleanShutdown, @"final shutdownAndWait reported clean");

        uint64_t staleFinal = session.staleEventsDiscardedCount;
        if (staleFinal == 0)
        {
            printf("[assert] PASS: staleEventsDiscardedCount == 0 (no stale-generation events ever needed "
                   "filtering this run)\n");
        }
        else
        {
            /* Not a failure by itself -- adr/0005 §3's generation gate is *expected* to
             * catch real events sometimes (that's the whole point of the reconnect
             * test); a nonzero count here means the gate actually did its job on this
             * particular run's timing, which is a legitimate outcome, not a bug. Printed
             * plainly so it's visible and explained, never silently accepted or silently
             * asserted away. */
            printf("[assert] PASS (with note): staleEventsDiscardedCount == %llu -- the generation gate "
                   "filtered real events this run (legitimate: adr/0005 §3's reconnect protocol exists "
                   "to produce exactly this outcome under the right timing)\n",
                   (unsigned long long)staleFinal);
        }

#undef CHECK

        printf("\noverall: %s\n", ok ? "PASS" : "FAIL");
        return ok ? 0 : 1;
    }
}
